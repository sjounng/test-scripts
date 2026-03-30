#!/bin/bash
# ============================================
# 사전 세팅: 발행 → 사용자 → 전환 → 비밀계좌 → 전송
# ============================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib.sh"

# ============================================
# 1. 발행 [최초발행]
# ============================================
log_header "1. 발행 [최초발행]"

# 메인넷 등록
log_step "1-1) 메인넷 등록"
call_api POST "${LIFECYCLE_BASE}/sc/mainnets" \
    "$PLATFORM_CLIENT_ID" "$PLATFORM_CLIENT_SECRET" \
    "{
        \"mainnetName\": \"${MAINNET_NAME}\",
        \"mainnetType\": \"${MAINNET_TYPE}\",
        \"endpoint\": \"${MAINNET_ENDPOINT}\",
        \"chainId\": ${MAINNET_CHAIN_ID}
    }"
if [[ "$HTTP_STATUS" == "302" ]]; then
    log_ok "메인넷 이미 등록됨 (HTTP 302)"
else
    check_http_ok "메인넷 등록" || die "메인넷 등록 실패"
fi

# 발행 계획 등록
log_step "1-2) 발행 계획 등록"
call_api POST "${LIFECYCLE_BASE}/issuances" \
    "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
    "{
        \"mainnetId\": 1,
        \"scName\": \"${SC_NAME}\",
        \"scSymbol\": \"${SC_SYMBOL}\",
        \"scIssueAmount\": ${SC_ISSUE_AMOUNT},
        \"scPlannedIssuanceDate\": \"${SC_PLANNED_DATE}\",
        \"scIssueNote\": \"${SC_ISSUE_NOTE}\"
    }"
check_http_ok "발행 계획 등록" || die "발행 계획 등록 실패"

SC_ISSUE_ID=$(extract_and_verify "$RESPONSE" '.data.scIssueId' "scIssueId") || die "scIssueId 추출 실패"
SC_ID=$(extract_and_verify "$RESPONSE" '.data.scId' "scId") || die "scId 추출 실패"
save_var "SC_ISSUE_ID" "$SC_ISSUE_ID"
save_var "SC_ID" "$SC_ID"

# 준비금 등록
log_step "1-3) 준비금 등록"
call_api POST "${LIFECYCLE_BASE}/reserves" \
    "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
    "{
        \"scIssueId\": \"${SC_ISSUE_ID}\",
        \"scId\": \"${SC_ID}\",
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
check_http_ok "준비금 등록" || die "준비금 등록 실패"

RESERVE_ID=$(extract_and_verify "$RESPONSE" '.data.reserveId' "reserveId") || die "reserveId 추출 실패"
save_var "RESERVE_ID" "$RESERVE_ID"

# 준비금 승인
log_step "1-4) 준비금 승인"
call_api PUT "${LIFECYCLE_BASE}/reserves/${RESERVE_ID}/approval" \
    "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
    '{"approval":"Approved"}'
check_http_ok "준비금 승인" || die "준비금 승인 실패"

# 발행 계획 승인
log_step "1-5) 발행 계획 승인"
call_api PUT "${LIFECYCLE_BASE}/issuances/${SC_ISSUE_ID}/approval" \
    "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
    '{"approval":"Approved"}'
check_http_ok "발행 계획 승인" || die "발행 계획 승인 실패"

# 발행 실행
log_step "1-6) 발행 실행"
call_api PUT "${LIFECYCLE_BASE}/issuances/${SC_ISSUE_ID}/issue" \
    "$ISSUER_CLIENT_ID" "$ISSUER_CLIENT_SECRET" \
    ""
check_http_ok "발행 실행" || die "발행 실행 실패"

# token_address DB 조회
log_step "1-7) token_address DB 조회"
TOKEN_ADDRESS=$(query_db "SELECT token_address FROM stc_sc WHERE sc_id = ${SC_ID} ORDER BY created_date DESC LIMIT 1;")
[[ -n "$TOKEN_ADDRESS" && "$TOKEN_ADDRESS" == 0x* ]] || die "token_address 조회 실패 (결과: ${TOKEN_ADDRESS:-없음})"
save_var "TOKEN_ADDRESS" "$TOKEN_ADDRESS"
log_ok "token_address: ${TOKEN_ADDRESS}"

# ============================================
# 2. 개인사용자 관리
# ============================================
log_header "2. 개인사용자 관리"

# 개인사용자 추가
log_step "2-1) 개인사용자 추가"
call_api POST "${LIFECYCLE_BASE}/users/individuals" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET" \
    "{
        \"loginId\": \"${INDV1_LOGIN_ID}\",
        \"email\": \"${INDV1_EMAIL}\",
        \"password\": \"${INDV1_PASSWORD}\",
        \"name\": \"${INDV1_NAME}\",
        \"phoneNumber\": \"${INDV1_PHONE}\",
        \"address\": \"${INDV1_ADDRESS}\",
        \"detailAddress\": \"${INDV1_DETAIL_ADDRESS}\",
        \"zipCode\": \"${INDV1_ZIPCODE}\"
    }"
check_http_ok "개인사용자 추가" || die "개인사용자 추가 실패"

USER_ID_INDV01=$(extract_and_verify "$RESPONSE" '.data.userId' "userId") || die "userId 추출 실패"
INDV1_CLIENT_ID=$(extract_and_verify "$RESPONSE" '.data.longTokenClientId' "longTokenClientId") || die "longTokenClientId 추출 실패"
INDV1_CLIENT_SECRET=$(extract_and_verify "$RESPONSE" '.data.longToken' "longToken") || die "longToken 추출 실패"
save_var "USER_ID_INDV01" "$USER_ID_INDV01"
save_var "INDV1_CLIENT_ID" "$INDV1_CLIENT_ID"
save_var "INDV1_CLIENT_SECRET" "$INDV1_CLIENT_SECRET"

# 개인사용자 승인
log_step "2-2) [플랫폼] 개인사용자 승인"
call_api PUT "${LIFECYCLE_BASE}/users/${USER_ID_INDV01}/individuals/approval" \
    "$PLATFORM_CLIENT_ID" "$PLATFORM_CLIENT_SECRET" \
    '{"approval":"Approved"}'
check_http_ok "개인사용자 승인" || die "개인사용자 승인 실패"

# 포트폴리오 조회
log_step "2-3) 포트폴리오 목록 조회"
call_api GET "${LIFECYCLE_BASE}/portfolios" \
    "$PLATFORM_CLIENT_ID" "$PLATFORM_CLIENT_SECRET"
check_http_ok "포트폴리오 목록 조회" || die "포트폴리오 목록 조회 실패"

PORTFOLIO_ID_INDV01=$(extract_json "$RESPONSE" \
    "[.data.content[]? | select(.ownerId == ${USER_ID_INDV01} or .ownerId == \"${USER_ID_INDV01}\")] | first | .portfolioId // empty")
[[ -n "$PORTFOLIO_ID_INDV01" && "$PORTFOLIO_ID_INDV01" != "null" ]] || die "포트폴리오 ID 추출 실패"
save_var "PORTFOLIO_ID_INDV01" "$PORTFOLIO_ID_INDV01"
log_ok "포트폴리오 ID: ${PORTFOLIO_ID_INDV01}"

# 포트폴리오 자산 조회 (원화계좌)
log_step "2-4) 포트폴리오 자산 조회"
call_api GET "${LIFECYCLE_BASE}/portfolios/${PORTFOLIO_ID_INDV01}/accounts" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET"
check_http_ok "포트폴리오 자산 조회" || die "포트폴리오 자산 조회 실패"

FIAT_ACCOUNT_ID_INDV01=$(extract_json "$RESPONSE" \
    '[.data.content[]? | select(.type == "Fiat")] | first | .accountId // empty')
[[ -n "$FIAT_ACCOUNT_ID_INDV01" && "$FIAT_ACCOUNT_ID_INDV01" != "null" ]] || die "원화계좌 ID 추출 실패"
save_var "FIAT_ACCOUNT_ID_INDV01" "$FIAT_ACCOUNT_ID_INDV01"
log_ok "원화계좌 ID: ${FIAT_ACCOUNT_ID_INDV01}"

# ============================================
# 3. 전환 (개인사용자)
# ============================================
log_header "3. 전환 (개인사용자)"

# 가상계좌 조회
log_step "3-1) 입출금 가상계좌 조회"
call_api GET "${LIFECYCLE_BASE}/accounts/fiat/virtual-and-withdrawal" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET"
check_http_ok "가상계좌 조회" || die "가상계좌 조회 실패"

VIRTUAL_ACCOUNT_NUMBER=$(extract_json "$RESPONSE" '[.data.content[]? | select(.accountType == "Virtual")] | first | .accountNumber // empty')
[[ -n "$VIRTUAL_ACCOUNT_NUMBER" && "$VIRTUAL_ACCOUNT_NUMBER" != "null" ]] || die "가상계좌번호 추출 실패"
save_var "VIRTUAL_ACCOUNT_NUMBER" "$VIRTUAL_ACCOUNT_NUMBER"
log_ok "가상계좌: ${VIRTUAL_ACCOUNT_NUMBER}"

# 원화 입금
log_step "3-2) 원화 입금 결과 수신"
call_api POST "${LIFECYCLE_BASE}/webhook/accounts/fiat/deposit" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET" \
    "{
        \"amount\": ${DEPOSIT_AMOUNT},
        \"virtualAccountNumber\": \"${VIRTUAL_ACCOUNT_NUMBER}\",
        \"bankCode\": \"099\"
    }"
check_http_ok "원화 입금" || die "원화 입금 실패"

# 온체인 매수
log_step "3-3) 온체인 매수 (FiatToOnchain)"
call_api POST "${LIFECYCLE_BASE}/conversions" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET" \
    "{
        \"fiatAccountId\": ${FIAT_ACCOUNT_ID_INDV01},
        \"scAccountId\": null,
        \"scId\": ${SC_ID},
        \"amount\": ${CONVERSION_AMOUNT},
        \"conversionType\": \"FiatToOnchain\"
    }"
check_http_ok "온체인 매수" || die "온체인 매수 실패"

# 코인계좌 확인
log_step "3-4) 포트폴리오 재조회 (코인계좌 확인)"
call_api GET "${LIFECYCLE_BASE}/portfolios/${PORTFOLIO_ID_INDV01}/accounts" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET"
check_http_ok "포트폴리오 재조회" || die "포트폴리오 재조회 실패"

SC_ACCOUNT_ID_INDV01=$(extract_json "$RESPONSE" \
    '[.data.content[]? | select(.type == "Sc" or .type == "SC" or .type == "sc")] | first | .accountId // empty')
[[ -n "$SC_ACCOUNT_ID_INDV01" && "$SC_ACCOUNT_ID_INDV01" != "null" ]] || die "코인계좌 ID 추출 실패"
save_var "SC_ACCOUNT_ID_INDV01" "$SC_ACCOUNT_ID_INDV01"
log_ok "코인계좌 ID: ${SC_ACCOUNT_ID_INDV01}"

# 지갑주소 확인
log_step "3-5) 코인 계좌 조회 (지갑주소)"
call_api GET "${LIFECYCLE_BASE}/accounts/sc/${SC_ACCOUNT_ID_INDV01}" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET"
check_http_ok "코인 계좌 조회" || die "코인 계좌 조회 실패"

WALLET_ADDRESS_INDV01=$(extract_json "$RESPONSE" '.data.scWalletAddress // .data.walletAddress // empty')
[[ -n "$WALLET_ADDRESS_INDV01" && "$WALLET_ADDRESS_INDV01" != "null" ]] || die "지갑주소 추출 실패"
save_var "WALLET_ADDRESS_INDV01" "$WALLET_ADDRESS_INDV01"
log_ok "지갑주소: ${WALLET_ADDRESS_INDV01}"

# ============================================
# 4. zktransfer 비밀계좌 생성
# ============================================
log_header "4. zktransfer 비밀계좌 생성"

log_step "4-1) 비밀 계좌 생성"
call_api POST "${SDS_ZK_BASE}/accounts" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET"
check_http_ok "비밀계좌 생성" || die "비밀계좌 생성 실패"

ZK_ACCOUNT_ID_01=$(extract_and_verify "$RESPONSE" '.data.accountId' "accountId") || die "accountId 추출 실패"
save_var "ZK_ACCOUNT_ID_01" "$ZK_ACCOUNT_ID_01"
log_ok "비밀계좌 ID: ${ZK_ACCOUNT_ID_01}"

SIGNER_ADDRESS=$(extract_json "$RESPONSE" '.data.signerAddress // empty')
[[ -n "$SIGNER_ADDRESS" && "$SIGNER_ADDRESS" != "null" ]] || die "signerAddress 추출 실패"
save_var "SIGNER_ADDRESS" "$SIGNER_ADDRESS"
save_var "WALLET_ADDRESS_INDV02" "$SIGNER_ADDRESS"
log_ok "signerAddress: ${SIGNER_ADDRESS} (→ WALLET_ADDRESS_INDV02)"

# ============================================
# 5. 전송 (개인사용자) - On to On
# ============================================
log_header "5. 전송 (개인사용자)"

log_step "5-1) 코인 계좌 단건 조회"
call_api GET "${LIFECYCLE_BASE}/accounts/sc/${SC_ACCOUNT_ID_INDV01}" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET"
check_http_ok "코인 계좌 조회" || die "코인 계좌 조회 실패"

WALLET_ADDRESS_INDV01=$(extract_json "$RESPONSE" '.data.scWalletAddress // .data.walletAddress // empty')
log_ok "발신 지갑주소: ${WALLET_ADDRESS_INDV01}"
log_info "수신 지갑주소 (signerAddress): ${SIGNER_ADDRESS}"

log_step "5-2) 전송 (On to On)"
call_api POST "${LIFECYCLE_BASE}/transfers" \
    "$INDV1_CLIENT_ID" "$INDV1_CLIENT_SECRET" \
    "{
        \"fromScWalletAddress\": \"${WALLET_ADDRESS_INDV01}\",
        \"toScWalletAddress\": \"${SIGNER_ADDRESS}\",
        \"scId\": ${SC_ID},
        \"amount\": ${TRANSFER_AMOUNT},
        \"transferType\": \"OnchainToOnchain\"
    }"
check_http_ok "전송 (On to On)" || die "전송 실패"
log_ok "전송 완료: ${WALLET_ADDRESS_INDV01} → ${SIGNER_ADDRESS} (${TRANSFER_AMOUNT})"

finish_script "사전 세팅 (1~5단계)"
