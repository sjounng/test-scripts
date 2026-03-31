#!/bin/bash
# ============================================
# 성능 평가 통합 실행 스크립트
#
# 사용법: ./run_eval.sh <CPU_CORES> [SECTION]
#   CPU_CORES: 현재 서버 CPU 코어 수 (예: 8, 12, 16, 24)
#   SECTION  : single | multi | e2e | all (기본: all)
#
# 예시:
#   ./run_eval.sh 8           # 전체 실행
#   ./run_eval.sh 8 single    # 단건 테스트만
#   ./run_eval.sh 8 multi     # 다중 테스트만
#   ./run_eval.sh 8 e2e       # E2E 테스트만
#
# 출력: logs/cpu_<N>_<timestamp>.md
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config/config.sh"
source "${SCRIPT_DIR}/config/lib.sh"

# ---- 인자 확인 ----
CPU_CORES="${1:-}"
SECTION="${2:-all}"

if [[ -z "$CPU_CORES" ]]; then
    echo "사용법: $0 <CPU_CORES> [single|multi|e2e|all]"
    echo "  예시: $0 8"
    echo "        $0 8 single"
    exit 1
fi

case "$SECTION" in
    single|multi|e2e|all) ;;
    *) echo "SECTION은 single|multi|e2e|all 중 하나여야 합니다."; exit 1 ;;
esac

# ---- .state 로드 ----
if [[ ! -f "${SCRIPT_DIR}/.state" ]]; then
    log_fail ".state 파일이 없습니다. setup.sh를 먼저 실행하세요."
    exit 1
fi
TOKEN_ADDRESS=$(grep "^TOKEN_ADDRESS=" "${SCRIPT_DIR}/.state" | cut -d'=' -f2 || echo "")
ZK_ACCOUNT_ID_01=$(grep "^ZK_ACCOUNT_ID_01=" "${SCRIPT_DIR}/.state" | cut -d'=' -f2 || echo "")
ZK_ACCOUNT_ID_02=$(grep "^ZK_ACCOUNT_ID_02=" "${SCRIPT_DIR}/.state" | cut -d'=' -f2 || echo "")
SIGNER_ADDRESS=$(grep "^SIGNER_ADDRESS=" "${SCRIPT_DIR}/.state" | cut -d'=' -f2 || echo "")
SC_ID=$(grep "^SC_ID=" "${SCRIPT_DIR}/.state" | cut -d'=' -f2 || echo "")

# ---- 설정 ----
SINGLE_ITERATIONS=10
MULTI_ITERATIONS=10
VUS_LIST=(10 20 30)
APIS=(account approve deposit send receive withdraw)

LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${LOG_DIR}/cpu_${CPU_CORES}_${TIMESTAMP}.md"
DEFAULT_ACCOUNTS_FILE="${SCRIPT_DIR}/accounts.json"

# ---- k6 실행 함수 ----
# 반환값: k6 텍스트 출력이 저장된 임시 파일 경로
# 인자: mode vus count_flag count_val [accounts_file]
run_k6() {
    local mode="$1"
    local vus="$2"
    local count_flag="$3"   # --iterations 또는 --duration
    local count_val="$4"
    local accounts_file="${5:-}"
    local tmp_out
    tmp_out=$(mktemp /tmp/k6_out_XXXXXX)

    local accounts_arg=""
    if [[ -n "$accounts_file" ]]; then
        accounts_arg="ACCOUNTS_FILE=${accounts_file}"
    fi

    if [[ -n "$accounts_arg" ]]; then
        k6 run \
            -e SDS_ZK_BASE="http://localhost:8080/rest/zktransfer" \
            -e TOKEN_ADDRESS="$TOKEN_ADDRESS" \
            -e ZK_ACCOUNT_ID_01="$ZK_ACCOUNT_ID_01" \
            -e ZK_ACCOUNT_ID_02="$ZK_ACCOUNT_ID_02" \
            -e SIGNER_ADDRESS="$SIGNER_ADDRESS" \
            -e TEST_MODE="$mode" \
            -e "$accounts_arg" \
            --vus "$vus" \
            "$count_flag" "$count_val" \
            "${SCRIPT_DIR}/loadtest.js" > "$tmp_out" || true
    else
        k6 run \
            -e SDS_ZK_BASE="http://localhost:8080/rest/zktransfer" \
            -e TOKEN_ADDRESS="$TOKEN_ADDRESS" \
            -e ZK_ACCOUNT_ID_01="$ZK_ACCOUNT_ID_01" \
            -e ZK_ACCOUNT_ID_02="$ZK_ACCOUNT_ID_02" \
            -e SIGNER_ADDRESS="$SIGNER_ADDRESS" \
            -e TEST_MODE="$mode" \
            --vus "$vus" \
            "$count_flag" "$count_val" \
            "${SCRIPT_DIR}/loadtest.js" > "$tmp_out" || true
    fi

    echo "$tmp_out"
}

# ---- 다중 테스트 / E2E 공용 계정 사전 준비 ----
# setup.sh 1~5단계 전체를 VU 수만큼 반복
# 반환값: [{accountId, signerAddress}, ...] JSON 파일 경로
prepare_single_account() {
    local i="$1"
    local count="$2"

    log_step "(${i}/${count}) ── 계정 세팅 시작 ──────────────────"

    local idx="${RUN_ID}_e2e${i}"

    # ============================================
    # 1. 발행
    # ============================================

    # 1-1. 메인넷 등록 (chainId는 반복마다 고유하게)
    call_api POST "${LIFECYCLE_BASE}/sc/mainnets" \
        "$PLATFORM_CLIENT_ID" "$PLATFORM_CLIENT_SECRET" \
        "{
            \"mainnetName\": \"SDSMainNet_${idx}\",
            \"mainnetType\": \"${MAINNET_TYPE}\",
            \"endpoint\": \"${MAINNET_ENDPOINT}\",
            \"chainId\": $(( (MAINNET_CHAIN_ID % 100000) * 100 + i ))
        }"
    if ! check_http_ok "메인넷 등록 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local mainnet_id
    mainnet_id=$(extract_json "$RESPONSE" '.data.mainnetId // .data.id // empty')
    [[ -n "$mainnet_id" && "$mainnet_id" != "null" ]] || { log_warn "(${i}) mainnetId 없음, 건너뜀"; return 1; }

    # 1-2. 발행 계획 등록
    local rand
    rand=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 6)
    call_api POST "${LIFECYCLE_BASE}/issuances" \
        "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
        "{
            \"mainnetId\": ${mainnet_id},
            \"scName\": \"MySC_${rand}\",
            \"scSymbol\": \"MS${rand}\",
            \"scIssueAmount\": ${SC_ISSUE_AMOUNT},
            \"scPlannedIssuanceDate\": \"${SC_PLANNED_DATE}\",
            \"scIssueNote\": \"${SC_ISSUE_NOTE}\"
        }"
    if ! check_http_ok "발행 계획 등록 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local sc_issue_id sc_id
    sc_issue_id=$(extract_json "$RESPONSE" '.data.scIssueId')
    sc_id=$(extract_json "$RESPONSE" '.data.scId')
    [[ -n "$sc_issue_id" && "$sc_issue_id" != "null" ]] || { log_warn "(${i}) scIssueId 없음, 건너뜀"; return 1; }

    # 1-3. 준비금 등록
    call_api POST "${LIFECYCLE_BASE}/reserves" \
        "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
        "{
            \"scIssueId\": \"${sc_issue_id}\",
            \"scId\": \"${sc_id}\",
            \"reserve\": {
                \"reserveNote\": \"${RESERVE_NOTE}\",
                \"reserveOp\": [
                    {
                        \"reserveOpInstitutionName\": \"국민은행\",
                        \"reserveOpType\": \"FiatDeposit\",
                        \"reserveOpPeriodStart\": \"2025-10-22T09:00:00\",
                        \"reserveOpPeriodEnd\": \"2026-03-31T23:59:59\",
                        \"reserveOpNote\": \"유동성 확보\",
                        \"reserveOpAmount\": ${RESERVE_FIAT_AMOUNT}
                    },
                    {
                        \"reserveOpInstitutionName\": \"삼성자산운용 MMF\",
                        \"reserveOpType\": \"Mmf\",
                        \"reserveOpPeriodStart\": \"2025-10-22T09:00:00\",
                        \"reserveOpPeriodEnd\": \"2026-03-31T23:59:59\",
                        \"reserveOpNote\": \"단기 MMF 운용\",
                        \"reserveOpAmount\": ${RESERVE_MMF_AMOUNT}
                    }
                ]
            }
        }"
    if ! check_http_ok "준비금 등록 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local reserve_id
    reserve_id=$(extract_json "$RESPONSE" '.data.reserveId')

    # 1-4. 준비금 승인
    call_api PUT "${LIFECYCLE_BASE}/reserves/${reserve_id}/approval" \
        "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
        '{"approval":"Approved"}'
    if ! check_http_ok "준비금 승인 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi

    # 1-5. 발행 계획 승인
    call_api PUT "${LIFECYCLE_BASE}/issuances/${sc_issue_id}/approval" \
        "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
        '{"approval":"Approved"}'
    if ! check_http_ok "발행 계획 승인 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi

    # 1-6. 발행 실행
    if issue_issuance_with_retry "$sc_issue_id" "$i"; then
        log_ok "발행 실행 (${i}) (HTTP ${HTTP_STATUS})"
    else
        check_http_ok "발행 실행 (${i})" || true
        log_warn "(${i}) 건너뜀"
        return 1
    fi

    # 1-7. token_address DB 조회
    local token_address
    token_address=$(query_db "SELECT token_address FROM stc_sc WHERE sc_id = ${sc_id} ORDER BY created_date DESC LIMIT 1;")
    [[ -n "$token_address" && "$token_address" == 0x* ]] || { log_warn "(${i}) token_address 조회 실패, 건너뜀"; return 1; }
    log_ok "(${i}) token_address: ${token_address}"

    # ============================================
    # 2. 개인사용자 관리
    # ============================================

    # 2-1. 개인사용자 추가
    call_api POST "${LIFECYCLE_BASE}/users/individuals" \
        "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET" \
        "{
            \"loginId\": \"e2u_${idx}\",
            \"email\": \"e2u_${idx}@test.com\",
            \"password\": \"${INDV1_PASSWORD}\",
            \"name\": \"E2U${i}\",
            \"phoneNumber\": \"010-0000-$(printf '%04d' "$i")\",
            \"address\": \"서울시 성동구\",
            \"detailAddress\": \"${i}호\",
            \"zipCode\": \"01234\"
        }"
    if ! check_http_ok "사용자 추가 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local user_id cli_id cli_secret
    user_id=$(extract_json "$RESPONSE" '.data.userId')
    cli_id=$(extract_json "$RESPONSE" '.data.longTokenClientId')
    cli_secret=$(extract_json "$RESPONSE" '.data.longToken')

    # 2-2. 사용자 승인
    call_api PUT "${LIFECYCLE_BASE}/users/${user_id}/individuals/approval" \
        "$PLATFORM_CLIENT_ID" "$PLATFORM_CLIENT_SECRET" \
        '{"approval":"Approved"}'
    if ! check_http_ok "사용자 승인 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi

    # 2-3. 포트폴리오 조회
    call_api GET "${LIFECYCLE_BASE}/portfolios" \
        "$PLATFORM_CLIENT_ID" "$PLATFORM_CLIENT_SECRET"
    if ! check_http_ok "포트폴리오 조회 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local portfolio_id
    portfolio_id=$(extract_json "$RESPONSE" \
        "[.data.content[]? | select(.ownerId == ${user_id} or .ownerId == \"${user_id}\")] | first | .portfolioId // empty")
    [[ -n "$portfolio_id" && "$portfolio_id" != "null" ]] || { log_warn "(${i}) portfolioId 없음, 건너뜀"; return 1; }

    # 2-4. 원화계좌 조회
    call_api GET "${LIFECYCLE_BASE}/portfolios/${portfolio_id}/accounts" \
        "$cli_id" "$cli_secret"
    if ! check_http_ok "원화계좌 조회 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local fiat_account_id
    fiat_account_id=$(extract_json "$RESPONSE" \
        '[.data.content[]? | select(.type == "Fiat")] | first | .accountId // empty')
    [[ -n "$fiat_account_id" && "$fiat_account_id" != "null" ]] || { log_warn "(${i}) fiatAccountId 없음, 건너뜀"; return 1; }

    # ============================================
    # 3. 전환
    # ============================================

    # 3-1. 가상계좌 조회
    call_api GET "${LIFECYCLE_BASE}/accounts/fiat/virtual-and-withdrawal" \
        "$cli_id" "$cli_secret"
    if ! check_http_ok "가상계좌 조회 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local virtual_account
    virtual_account=$(extract_json "$RESPONSE" \
        '[.data.content[]? | select(.accountType == "Virtual")] | first | .accountNumber // empty')
    [[ -n "$virtual_account" && "$virtual_account" != "null" ]] || { log_warn "(${i}) 가상계좌번호 없음, 건너뜀"; return 1; }

    # 3-2. 원화 입금
    call_api POST "${LIFECYCLE_BASE}/webhook/accounts/fiat/deposit" \
        "$cli_id" "$cli_secret" \
        "{
            \"amount\": ${DEPOSIT_AMOUNT},
            \"virtualAccountNumber\": \"${virtual_account}\",
            \"bankCode\": \"099\"
        }"
    if ! check_http_ok "원화 입금 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi

    # 3-3. 온체인 매수 (FiatToOnchain)
    call_api POST "${LIFECYCLE_BASE}/conversions" \
        "$cli_id" "$cli_secret" \
        "{
            \"fiatAccountId\": ${fiat_account_id},
            \"scAccountId\": null,
            \"scId\": ${sc_id},
            \"amount\": ${CONVERSION_AMOUNT},
            \"conversionType\": \"FiatToOnchain\"
        }"
    if ! check_http_ok "온체인 매수 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi

    # 3-4. 포트폴리오 재조회 (코인계좌 확인)
    call_api GET "${LIFECYCLE_BASE}/portfolios/${portfolio_id}/accounts" \
        "$cli_id" "$cli_secret"
    if ! check_http_ok "포트폴리오 재조회 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local sc_account_id
    sc_account_id=$(extract_json "$RESPONSE" \
        '[.data.content[]? | select(.type == "Sc" or .type == "SC" or .type == "sc")] | first | .accountId // empty')
    [[ -n "$sc_account_id" && "$sc_account_id" != "null" ]] || { log_warn "(${i}) scAccountId 없음, 건너뜀"; return 1; }

    # 3-5. 코인 계좌 조회 (지갑주소)
    call_api GET "${LIFECYCLE_BASE}/accounts/sc/${sc_account_id}" \
        "$cli_id" "$cli_secret"
    if ! check_http_ok "코인계좌 조회 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local wallet_address
    wallet_address=$(extract_json "$RESPONSE" '.data.scWalletAddress // .data.walletAddress // empty')
    [[ -n "$wallet_address" && "$wallet_address" != "null" ]] || { log_warn "(${i}) 지갑주소 없음, 건너뜀"; return 1; }

    # ============================================
    # 4. ZK 비밀계좌 생성
    # ============================================
    call_api POST "${SDS_ZK_BASE}/accounts" \
        "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET"
    if ! check_http_ok "ZK 계좌 생성 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    local zk_account_id signer_address
    zk_account_id=$(extract_json "$RESPONSE" '.data.accountId // empty')
    signer_address=$(extract_json "$RESPONSE" '.data.signerAddress // empty')
    [[ -n "$zk_account_id" && "$zk_account_id" != "null" ]] || { log_warn "(${i}) ZK accountId 없음, 건너뜀"; return 1; }

    # ============================================
    # 5. 전송 (On to On)
    # ============================================

    # 5-1. 코인 계좌 재조회
    call_api GET "${LIFECYCLE_BASE}/accounts/sc/${sc_account_id}" \
        "$cli_id" "$cli_secret"
    if ! check_http_ok "코인계좌 재조회 (${i})"; then log_warn "(${i}) 건너뜀"; return 1; fi
    wallet_address=$(extract_json "$RESPONSE" '.data.scWalletAddress // .data.walletAddress // empty')
    [[ -n "$wallet_address" && "$wallet_address" != "null" ]] || { log_warn "(${i}) 지갑주소 재조회 실패, 건너뜀"; return 1; }

    # 5-2. SC 토큰 → ZK signer address 전송
    call_api POST "${LIFECYCLE_BASE}/transfers" \
        "$cli_id" "$cli_secret" \
        "{
            \"fromScWalletAddress\": \"${wallet_address}\",
            \"toScWalletAddress\": \"${signer_address}\",
            \"scId\": ${sc_id},
            \"amount\": ${TRANSFER_AMOUNT},
            \"transferType\": \"OnchainToOnchain\"
        }"
    if ! check_http_ok "SC 전송 (${i})"; then log_warn "(${i}) SC 전송 실패, 건너뜀"; return 1; fi

    jq -cn \
        --arg accountId "$zk_account_id" \
        --arg signerAddress "$signer_address" \
        --arg tokenAddress "$token_address" \
        '{accountId: $accountId, signerAddress: $signerAddress, tokenAddress: $tokenAddress}' >&4
    log_ok "(${i}/${count}) 완료 → accountId: ${zk_account_id}"
}

issue_issuance_with_retry() {
    local sc_issue_id="$1"
    local worker_index="$2"
    local attempt
    local max_attempts=6
    local delay=1

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        call_api PUT "${LIFECYCLE_BASE}/issuances/${sc_issue_id}/issue" \
            "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
            ""

        if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "201" ]]; then
            return 0
        fi

        if [[ "$HTTP_STATUS" != "302" && "$HTTP_STATUS" != "409" && "$HTTP_STATUS" != "423" && "$HTTP_STATUS" != "429" && "$HTTP_STATUS" != "500" && "$HTTP_STATUS" != "502" && "$HTTP_STATUS" != "503" ]]; then
            return 1
        fi

        if (( attempt == max_attempts )); then
            return 1
        fi

        log_warn "(${worker_index}) 발행 실행 재시도 대기 (${attempt}/${max_attempts}, HTTP ${HTTP_STATUS}, ${delay}s)"
        sleep "$delay"
        if (( delay < 5 )); then
            delay=$(( delay + 1 ))
        fi
    done
}

prepare_accounts() {
    local count="$1"
    local accounts_file
    accounts_file="${SCRIPT_DIR}/accounts_${TIMESTAMP}.json"

    # 이 함수 내 모든 로그(stdout)를 stderr로 redirect — 호출자가 파일 경로만 캡처할 수 있도록
    exec 3>&1 1>&2

    log_header "E2E 계정 사전 준비 (${count}개) — setup.sh 1~5단계"

    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/accounts_prepare_${TIMESTAMP}_XXXXXX")

    local success_count=0
    local had_failures=0
    local i
    for (( i=1; i<=count; i++ )); do
        local out_file
        out_file="${tmp_dir}/$(printf '%05d' "$i").json"
        if ! prepare_single_account "$i" "$count" 4> "$out_file"; then
            rm -f "$out_file"
            had_failures=1
            continue
        fi
        if [[ -s "$out_file" ]]; then
            success_count=$(( success_count + 1 ))
        else
            rm -f "$out_file"
            had_failures=1
        fi
    done

    if [[ "$success_count" == "0" ]]; then
        log_fail "E2E 계정 준비 전체 실패"
        rm -rf "$tmp_dir"
        exec 1>&3 3>&-
        return 1
    fi

    jq -s '.' "${tmp_dir}"/*.json > "$accounts_file"
    rm -rf "$tmp_dir"

    if (( had_failures )); then
        log_warn "일부 계정 준비는 실패했지만 성공한 ${success_count}개 계정을 사용합니다."
    fi
    log_ok "계정 ${success_count}개 준비 완료 → ${accounts_file}"

    exec 1>&3 3>&-
    echo "$accounts_file"
}

resolve_shared_accounts_file() {
    local required_count="$1"

    if [[ -f "$DEFAULT_ACCOUNTS_FILE" ]]; then
        local account_count
        account_count=$(jq 'length' "$DEFAULT_ACCOUNTS_FILE" 2>/dev/null || echo 0)

        if [[ "$account_count" =~ ^[0-9]+$ ]] && (( account_count >= required_count )); then
            log_ok "기존 accounts.json 재사용: ${DEFAULT_ACCOUNTS_FILE} (${account_count}개)" >&2
            echo "$DEFAULT_ACCOUNTS_FILE"
            return 0
        fi

        log_warn "accounts.json 계정 수 부족 또는 파싱 실패 (${account_count}) — ${required_count}개 새로 준비" >&2
    fi

    prepare_accounts "$required_count"
}

# ---- 메트릭 파싱 헬퍼 ----
# k6 텍스트 요약 형식 예시:
#   api_account.............: avg=1234.56ms min=100ms med=1200ms max=5000ms p(90)=2000ms p(95)=2500ms p(99)=4000ms
#   checks..................: 95.00% ✓ 28       ✗ 2
#   http_reqs...............: 30     0.857142/s

# Trend 메트릭에서 특정 통계값(ms) 추출
trend_val() {
    local file="$1" metric="$2" stat="$3"
    # stat: avg, min, max, p(95), p(99) 등
    # 괄호는 정규식 특수문자이므로 이스케이프
    local stat_re
    stat_re=$(echo "$stat" | sed 's/(/\\(/g; s/)/\\)/g')
    grep -m1 "${metric}" "$file" 2>/dev/null \
        | grep -oE "${stat_re}=[0-9]+(\.[0-9]+)?(µs|ms|s)" \
        | grep -oE "[0-9]+(\.[0-9]+)?(µs|ms|s)" \
        | awk '{
            v = $0
            if (v ~ /µs$/) { gsub(/µs$/, "", v); printf "%.3f", v/1000 }
            else if (v ~ /ms$/) { gsub(/ms$/, "", v); printf "%s", v }
            else if (v ~ /s$/)  { gsub(/s$/,  "", v); printf "%.0f", v*1000 }
            else { print v }
        }' \
        || echo "0"
}

# http_reqs rate (TPS) 추출
# 커스텀 Counter 기반 TPS 추출
# k6 Counter 출력 형식: "api_account_count...: 100 3.33/s"
rate_val() {
    local file="$1" metric="${2:-http_reqs}"
    grep -m1 "${metric}\b" "$file" 2>/dev/null \
        | grep -oE "[0-9]+\.[0-9]+/s" \
        | grep -oE "^[0-9]+\.[0-9]+" \
        || echo "0"
}

# 성공률 계산
# 실제 k6 v1.7.0 형식: "checks_succeeded...: 100.00% 3 out of 3"
success_rate() {
    local file="$1"
    local pct
    pct=$(grep -m1 "checks_succeeded" "$file" 2>/dev/null \
        | grep -oE "[0-9]+\.[0-9]+%" \
        | tr -d '%' || echo "")
    if [[ -z "$pct" ]]; then echo "N/A"; return; fi
    awk "BEGIN { printf \"%.1f\", $pct }"
}

# 에러율 계산
# 실제 k6 v1.7.0 형식: "checks_failed......: 0.00%  0 out of 3"
error_rate() {
    local file="$1"
    local pct
    pct=$(grep -m1 "checks_failed" "$file" 2>/dev/null \
        | grep -oE "[0-9]+\.[0-9]+%" \
        | tr -d '%' || echo "")
    if [[ -z "$pct" ]]; then echo "N/A"; return; fi
    awk "BEGIN { printf \"%.1f\", $pct }"
}

# float → 정수 ms 문자열
fmt_ms() {
    local v="${1:-0}"
    [[ -z "$v" || "$v" == "null" ]] && v=0
    awk "BEGIN { printf \"%.0f ms\", $v }"
}

# float → 소수점 2자리
fmt_tps() {
    local v="${1:-0}"
    [[ -z "$v" || "$v" == "null" ]] && v=0
    awk "BEGIN { printf \"%.2f\", $v }"
}

# ============================================
# 결과 파일 헤더
# ============================================
{
    echo "# 성능 평가 결과 — CPU ${CPU_CORES} Core"
    echo ""
    echo "| 항목 | 내용 |"
    echo "| --- | --- |"
    echo "| 테스트 일시 | $(date '+%Y-%m-%d %H:%M:%S') |"
    echo "| CPU | ${CPU_CORES} Core |"
    echo "| 단건 반복 횟수 | ${SINGLE_ITERATIONS} |"
    echo "| 다중 VU당 반복 횟수 | ${MULTI_ITERATIONS} |"
    echo "| VU | ${VUS_LIST[*]} |"
    echo ""
    echo "---"
    echo ""
} > "$RESULT_FILE"

# ============================================
# 8. 단건 테스트
# ============================================
if [[ "$SECTION" == "single" || "$SECTION" == "all" ]]; then
    log_header "단건 테스트 (CPU: ${CPU_CORES} Core)"

    {
        echo "## 단건 테스트"
        echo ""
        echo "| API | CPU | 반복 횟수 | 평균 응답 시간 | P95 | P99 | 성공률 |"
        echo "| --- | --- | --- | --- | --- | --- | --- |"
    } >> "$RESULT_FILE"

    log_step "풀 사이클 ${SINGLE_ITERATIONS}회 실행 (approve→deposit→account→send→receive→withdraw)..."
    tmp=$(run_k6 "e2e" 1 --iterations "$SINGLE_ITERATIONS")

    for api in "${APIS[@]}"; do
        avg=$(trend_val "$tmp" "api_${api}" "avg")
        p95=$(trend_val "$tmp" "api_${api}" "p(95)")
        p99=$(trend_val "$tmp" "api_${api}" "p(99)")
        sr=$(success_rate "$tmp")
        echo "| ${api} | ${CPU_CORES} | ${SINGLE_ITERATIONS} | $(fmt_ms "$avg") | $(fmt_ms "$p95") | $(fmt_ms "$p99") | ${sr}% |" \
            >> "$RESULT_FILE"
    done

    rm -f "$tmp"
    log_ok "단건 테스트 완료"

    echo "" >> "$RESULT_FILE"
    echo "---" >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
fi

# ============================================
# 9 & 10. 다중 테스트 + E2E 테스트
#   - VU 수만큼 sender 계정 사전 준비 (한 번만)
#   - multi: API 단계를 순차 배리어 방식으로 실행
#   - e2e: 각 VU가 자신의 계정으로 풀 사이클 반복
# ============================================

# 다중/E2E 테스트는 계정 사전 준비가 필요
if [[ "$SECTION" == "multi" || "$SECTION" == "e2e" || "$SECTION" == "all" ]]; then
    MAX_VU="${VUS_LIST[${#VUS_LIST[@]}-1]}"
    log_header "계정 사전 준비 (최대 VU: ${MAX_VU}개)"
    SHARED_ACCOUNTS_FILE=$(resolve_shared_accounts_file "$MAX_VU") || SHARED_ACCOUNTS_FILE=""

    if [[ -z "$SHARED_ACCOUNTS_FILE" ]]; then
        log_warn "계정 준비 실패 — ZK_ACCOUNT_ID_01 단일 계정으로 진행 (충돌 가능)"
    fi
fi

# ---- 9. 다중 테스트 ----
if [[ "$SECTION" == "multi" || "$SECTION" == "all" ]]; then
    log_header "다중 테스트 (CPU: ${CPU_CORES} Core)"

    {
        echo "## 다중 테스트"
        echo ""
        echo "| API | CPU | VU | TPS | 평균 응답 시간 | P95 | P99 | 에러율 |"
        echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
    } >> "$RESULT_FILE"

    for api in account approve deposit send receive withdraw; do
      for vu in "${VUS_LIST[@]}"; do
            local_iters=$(( MULTI_ITERATIONS * vu ))
            log_step "다중 테스트 VU=${vu} 실행 중: ${api}"
            tmp=$(run_k6 "$api" "$vu" --iterations "$local_iters" "${SHARED_ACCOUNTS_FILE:-}")
            log_ok "VU=${vu} ${api} 완료, 메트릭 추출 중..."

            tps=$(rate_val "$tmp" "api_${api}_count")
            er=$(error_rate "$tmp")
            avg=$(trend_val "$tmp" "api_${api}" "avg")
            p95=$(trend_val "$tmp" "api_${api}" "p(95)")
            p99=$(trend_val "$tmp" "api_${api}" "p(99)")
            log_info "  [${api}] avg=$(fmt_ms "$avg") p95=$(fmt_ms "$p95") p99=$(fmt_ms "$p99")"
            echo "| ${api} | ${CPU_CORES} | ${vu} | $(fmt_tps "$tps") | $(fmt_ms "$avg") | $(fmt_ms "$p95") | $(fmt_ms "$p99") | ${er}% |" \
                >> "$RESULT_FILE"
            rm -f "$tmp"
        done
        log_ok "다중 테스트 ${api} 완료"
    done

    echo "" >> "$RESULT_FILE"
    echo "---" >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
fi

# ---- 10. E2E 테스트 ----
if [[ "$SECTION" == "e2e" || "$SECTION" == "all" ]]; then
    log_header "E2E 테스트 (CPU: ${CPU_CORES} Core)"

    {
        echo "## E2E 테스트"
        echo ""
        echo "| 시나리오 | CPU | VU | TPS | 평균 응답 시간 | P95 | P99 | 성공률 |"
        echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
    } >> "$RESULT_FILE"

    E2E_SCENARIO="approve > deposit > account > send > receive > withdraw"

    for vu in "${VUS_LIST[@]}"; do
        log_step "E2E VU=${vu} 실행 중 (계정 ${vu}개)..."
        tmp=$(run_k6 "e2e" "$vu" --duration "$MULTI_DURATION" "${SHARED_ACCOUNTS_FILE:-}")
        log_ok "VU=${vu} k6 완료, E2E 메트릭 추출 중..."

        tps=$(rate_val "$tmp")
        avg=$(trend_val "$tmp" "http_req_duration" "avg")
        p95=$(trend_val "$tmp" "http_req_duration" "p(95)")
        p99=$(trend_val "$tmp" "http_req_duration" "p(99)")
        sr=$(success_rate "$tmp")

        log_info "  TPS=$(fmt_tps "$tps") avg=$(fmt_ms "$avg") p95=$(fmt_ms "$p95") p99=$(fmt_ms "$p99") 성공률=${sr}%"

        echo "| ${E2E_SCENARIO} | ${CPU_CORES} | ${vu} | $(fmt_tps "$tps") | $(fmt_ms "$avg") | $(fmt_ms "$p95") | $(fmt_ms "$p99") | ${sr}% |" \
            >> "$RESULT_FILE"

        rm -f "$tmp"
        log_ok "E2E VU=${vu} 완료"
    done

    echo "" >> "$RESULT_FILE"
fi

[[ -n "${SHARED_ACCOUNTS_FILE:-}" ]] && log_ok "계정 파일 저장됨: ${SHARED_ACCOUNTS_FILE}"

# ============================================
# 완료
# ============================================
echo "" >> "$RESULT_FILE"

finish_script "성능 평가"
echo ""
log_ok "결과 저장: ${RESULT_FILE}"
echo ""
cat "$RESULT_FILE"
