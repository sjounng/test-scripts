#!/bin/bash
# ============================================
# [단건 테스트] API별 응답 속도 측정
# ============================================
set -euo pipefail

if [ ! -f .state ]; then
    echo "ERROR: .state 파일이 없습니다. 먼저 ./run_setup.sh를 실행하세요."
    exit 1
fi

TOKEN_ADDRESS=$(grep "^TOKEN_ADDRESS=" .state | cut -d'=' -f2 || echo "")
ZK_ACCOUNT_ID_01=$(grep "^ZK_ACCOUNT_ID_01=" .state | cut -d'=' -f2 || echo "")
ZK_ACCOUNT_ID_02=$(grep "^ZK_ACCOUNT_ID_02=" .state | cut -d'=' -f2 || echo "")
SIGNER_ADDRESS=$(grep "^SIGNER_ADDRESS=" .state | cut -d'=' -f2 || echo "")
TARGET_API=${1:-"e2e"}
ITERATIONS=${2:-1}

if [ "$TARGET_API" == "all" ]; then
    APIS=("account" "approve" "deposit" "send" "receive" "withdraw" "e2e")
else
    APIS=("$TARGET_API")
fi

echo "============================================"
echo " 단건 테스트 | 반복: ${ITERATIONS}회 | 대상: ${APIS[*]}"
echo "============================================"

for api in "${APIS[@]}"; do
    echo ""
    echo "──── ${api} 측정 중... ────"
    k6 run \
        -e SDS_ZK_BASE=http://localhost:8080/rest/zktransfer \
        -e TOKEN_ADDRESS="$TOKEN_ADDRESS" \
        -e ZK_ACCOUNT_ID_01="$ZK_ACCOUNT_ID_01" \
        -e ZK_ACCOUNT_ID_02="$ZK_ACCOUNT_ID_02" \
        -e SIGNER_ADDRESS="$SIGNER_ADDRESS" \
        -e TEST_MODE="$api" \
        --vus 1 --iterations "$ITERATIONS" \
        loadtest.js || true
done
