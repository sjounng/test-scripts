#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib.sh"
load_state
echo ""

VUS=${1:-30}
echo "============================================"
echo " [부하 테스트 전용 세팅] 독립된 $VUS 개의 계좌를 순차 생성 및 충전합니다."
echo " 이 과정은 약 $((VUS))초 가량 소요됩니다..."
echo "============================================"

# .state 필수 변수 확인
[[ -z "${WALLET_ADDRESS_INDV01:-}" ]] && { echo "WALLET_ADDRESS_INDV01 없음"; exit 1; }
[[ -z "${SC_ID:-}" ]] && { echo "SC_ID 없음"; exit 1; }

echo "[" > accounts.json

for i in $(seq 1 $VUS); do
    # 1. 비밀 계좌 생성 (SDS-25 경유)
    RES1=$(curl -s -X POST "${SDS_ZK_BASE}/accounts" \
           -H "Content-Type: application/json" \
           -H "X-Lego-Client-Id: ${ADMIN_CLIENT_ID}" \
           -H "X-Lego-Client-Secret: ${ADMIN_CLIENT_SECRET}")

    NEW_ACCOUNT_ID=$(echo "$RES1" | jq -r '.data.accountId // empty')
    NEW_SIGNER=$(echo "$RES1" | jq -r '.data.signerAddress // empty')
    
    if [[ -z "$NEW_ACCOUNT_ID" || "$NEW_ACCOUNT_ID" == "null" ]]; then
        echo "❌ 계좌 생성 실패: $RES1"
        exit 1
    fi

    # 2. 기초 자금(L1) 송금 (INDV01 -> 새 계좌)
    PAYLOAD="{
        \"fromScWalletAddress\": \"${WALLET_ADDRESS_INDV01}\",
        \"toScWalletAddress\": \"${NEW_SIGNER}\",
        \"scId\": ${SC_ID},
        \"amount\": 10000.0,
        \"transferType\": \"OnchainToOnchain\"
    }"
    
    RES2=$(curl -s -X POST "${LIFECYCLE_BASE}/transfers" \
           -H "Content-Type: application/json" \
           -H "X-Lego-Client-Id: ${INDV1_CLIENT_ID}" \
           -H "X-Lego-Client-Secret: ${INDV1_CLIENT_SECRET}" \
           -d "$PAYLOAD")

    # JSON 배열 구성
    if [ "$i" -eq "$VUS" ]; then
        echo "  \"$NEW_ACCOUNT_ID\"" >> accounts.json
    else
        echo "  \"$NEW_ACCOUNT_ID\"," >> accounts.json
    fi
    
    echo " ✅ [$i/$VUS] ${NEW_ACCOUNT_ID} (생성 및 1만 토큰 충전 완료)"
done

echo "]" >> accounts.json
echo "============================================"
echo " ${VUS}개 독립 계좌 기반 다중 부하 테스트 세팅 완료! (accounts.json 저장됨)"
echo "============================================"
