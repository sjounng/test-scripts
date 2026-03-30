#!/bin/bash
# ============================================
# [테스트 실행] 단건 / 부하 테스트 통합
# 사용법:
#   ./run_single.sh [단계...] [옵션]
#
# 단계 (복수 지정 가능):
#   -account  -approve  -deposit  -send  -receive  -withdraw  -e2e  -all
#
# 옵션:
#   --iterations N     반복 횟수 (기본: 1, 단건 모드)
#   --vus N            가상 유저 수 (기본: 1)
#   --duration Xs      부하 지속 시간 (기본: 없음, iterations 모드)
#
# 예시:
#   ./run_single.sh -e2e
#   ./run_single.sh -approve -deposit --iterations 5
#   ./run_single.sh -all --vus 10 --duration 30s
# ============================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config/config.sh"
source "${SCRIPT_DIR}/config/lib.sh"

if [ ! -f .state ]; then
    log_warn ".state 파일이 없습니다. 환경 변수가 비어있을 수 있습니다."
fi

TOKEN_ADDRESS=$(grep "^TOKEN_ADDRESS=" .state | cut -d'=' -f2 || echo "")
ZK_ACCOUNT_ID_01=$(grep "^ZK_ACCOUNT_ID_01=" .state | cut -d'=' -f2 || echo "")
ZK_ACCOUNT_ID_02=$(grep "^ZK_ACCOUNT_ID_02=" .state | cut -d'=' -f2 || echo "")
SIGNER_ADDRESS=$(grep "^SIGNER_ADDRESS=" .state | cut -d'=' -f2 || echo "")

APIS=()
ITERATIONS=1
VUS=1
DURATION=""

# 인자 파싱
while [[ $# -gt 0 ]]; do
    case "$1" in
        -all)       APIS=("account" "approve" "deposit" "send" "receive" "withdraw" "e2e") ;;
        -account)   APIS+=("account") ;;
        -approve)   APIS+=("approve") ;;
        -deposit)   APIS+=("deposit") ;;
        -send)      APIS+=("send") ;;
        -receive)   APIS+=("receive") ;;
        -withdraw)  APIS+=("withdraw") ;;
        -e2e)       APIS+=("e2e") ;;
        --iterations) ITERATIONS="$2"; shift ;;
        --vus)        VUS="$2"; shift ;;
        --duration)   DURATION="$2"; shift ;;
        *) log_warn "알 수 없는 인자: $1" ;;
    esac
    shift
done

# 기본값: 단계 미지정 시 e2e
[[ ${#APIS[@]} -eq 0 ]] && APIS=("e2e")

if [[ -n "$DURATION" ]]; then
    MODE_DESC="부하 테스트 | VUs: ${VUS} | Duration: ${DURATION}"
else
    MODE_DESC="단건 테스트 | 반복: ${ITERATIONS}회 | VUs: ${VUS}"
fi

# 로그 디렉토리 및 파일 설정
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/${TIMESTAMP}_$(IFS=_; echo "${APIS[*]}")_vus${VUS}.log"

log_header "${MODE_DESC} | 대상: ${APIS[*]}"
log_info "로그 파일: ${LOG_FILE}"

{
    echo "========================================"
    echo "  실행 시각 : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  대상      : ${APIS[*]}"
    echo "  VUs       : ${VUS}"
    if [[ -n "$DURATION" ]]; then
        echo "  Duration  : ${DURATION}"
    else
        echo "  Iterations: ${ITERATIONS}"
    fi
    echo "========================================"
} >> "$LOG_FILE"

for api in "${APIS[@]}"; do
    log_step "${api} 측정 중..."
    _START=$(date +%s)

    K6_ARGS=(
        -e SDS_ZK_BASE=http://localhost:8080/rest/zktransfer
        -e TOKEN_ADDRESS="$TOKEN_ADDRESS"
        -e ZK_ACCOUNT_ID_01="$ZK_ACCOUNT_ID_01"
        -e ZK_ACCOUNT_ID_02="$ZK_ACCOUNT_ID_02"
        -e SIGNER_ADDRESS="$SIGNER_ADDRESS"
        -e TEST_MODE="$api"
        --vus "$VUS"
    )

    if [[ -n "$DURATION" ]]; then
        K6_ARGS+=(--duration "$DURATION")
    else
        K6_ARGS+=(--iterations "$ITERATIONS")
    fi

    echo "" >> "$LOG_FILE"
    echo "---- [${api}] ----" >> "$LOG_FILE"

    k6 run "${K6_ARGS[@]}" loadtest.js 2>&1 | tee -a "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    ELAPSED=$(( $(date +%s) - _START ))

    if [[ $EXIT_CODE -eq 0 ]]; then
        log_ok "${api} 완료 (${ELAPSED}s)"
        echo "[PASS] ${api} 완료 (${ELAPSED}s)" >> "$LOG_FILE"
    else
        log_fail "${api} 실패 (${ELAPSED}s)"
        echo "[FAIL] ${api} 실패 (${ELAPSED}s)" >> "$LOG_FILE"
    fi
done

finish_script "테스트"
log_info "로그 저장됨: ${LOG_FILE}"
