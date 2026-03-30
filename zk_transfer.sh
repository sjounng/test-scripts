#!/bin/bash
# ============================================
# 06. zktransfer 전체 플로우
#     approve → deposit → 비밀계좌2 → send → receive → withdraw
#
#     모든 호출: SDS-25 (8080) /rest/zktransfer/* 경유
# ============================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib.sh"
load_state

log_header "zktransfer 전체 플로우"

# .state에서 필수 변수 확인
[[ -z "${ZK_ACCOUNT_ID_01:-}" ]] && die "ZK_ACCOUNT_ID_01 없음 (setup.sh 먼저 실행)"
[[ -z "${TOKEN_ADDRESS:-}" ]] && die "TOKEN_ADDRESS 없음 (setup.sh 먼저 실행)"

# ── 1) approve (SDS-25) ──
log_step "1) approve"
call_api POST "${SDS_ZK_BASE}/transfer/approve" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET" \
    "{
        \"accountId\": \"${ZK_ACCOUNT_ID_01}\",
        \"tokenAddress\": \"${TOKEN_ADDRESS}\",
        \"amount\": ${ZK_APPROVE_AMOUNT}
    }"
check_http_ok "approve" || die "approve 실패"

# ── 2) deposit (SDS-25) ──
log_step "2) deposit"
call_api POST "${SDS_ZK_BASE}/transfer/deposit" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET" \
    "{
        \"fromAccountId\": \"${ZK_ACCOUNT_ID_01}\",
        \"tokenAddress\": \"${TOKEN_ADDRESS}\",
        \"amount\": ${ZK_DEPOSIT_AMOUNT}
    }"
check_http_ok "deposit" || die "deposit 실패"

# ── 3) 비밀 계좌 생성 2 (SDS-25 경유) ──
log_step "3) 비밀 계좌 생성 2"
call_api POST "${SDS_ZK_BASE}/accounts" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET"
check_http_ok "비밀계좌 생성 2" || die "비밀계좌 생성 2 실패"

ZK_ACCOUNT_ID_02=$(extract_and_verify "$RESPONSE" '.data.accountId' "accountId") || die "accountId 추출 실패"
save_var "ZK_ACCOUNT_ID_02" "$ZK_ACCOUNT_ID_02"
log_ok "비밀계좌 2 ID: ${ZK_ACCOUNT_ID_02}"

EOA_RECV=$(extract_json "$RESPONSE" '.data.signerAddress // empty')
if [[ -n "$EOA_RECV" && "$EOA_RECV" != "null" ]]; then
    save_var "EOA_RECV" "$EOA_RECV"
    log_ok "EOA (수신주소): ${EOA_RECV}"
else
    die "signerAddress(EOA_RECV) 추출 실패"
fi

# ── 4) send (SDS-25) ──
log_step "4) send (비밀전송: account_01 → account_02)"
call_api POST "${SDS_ZK_BASE}/transfer/send" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET" \
    "{
        \"fromAccountId\": \"${ZK_ACCOUNT_ID_01}\",
        \"toAccountId\": \"${ZK_ACCOUNT_ID_02}\",
        \"tokenAddress\": \"${TOKEN_ADDRESS}\",
        \"amount\": ${ZK_SEND_AMOUNT}
    }"
check_http_ok "send" || die "send 실패"

TX_HASH=$(extract_and_verify "$RESPONSE" '.data.txHash' "txHash") || die "txHash 추출 실패"
save_var "TX_HASH" "$TX_HASH"
log_ok "txHash: ${TX_HASH}"

# ── 5) receive (SDS-25) ──
log_step "5) receive (account_02가 수신 확인)"
call_api POST "${SDS_ZK_BASE}/transfer/receive" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET" \
    "{
        \"toAccountId\": \"${ZK_ACCOUNT_ID_02}\",
        \"tokenAddress\": \"${TOKEN_ADDRESS}\",
        \"noteTxHash\": \"${TX_HASH}\"
    }"
check_http_ok "receive" || die "receive 실패"

# ── 6) withdraw (SDS-25) ──
log_step "6) withdraw (account_02 → EOA 출금)"
call_api POST "${SDS_ZK_BASE}/transfer/withdraw" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET" \
    "{
        \"fromAccountId\": \"${ZK_ACCOUNT_ID_02}\",
        \"eoaRecv\": \"${EOA_RECV}\",
        \"tokenAddress\": \"${TOKEN_ADDRESS}\",
        \"amount\": ${ZK_WITHDRAW_AMOUNT}
    }"
check_http_ok "withdraw" || die "withdraw 실패"

# ── 검증) 잔액 조회 (SDS-25) ──
log_step "검증) 비밀계좌 잔액 조회"
call_api GET "${SDS_ZK_BASE}/accounts/${ZK_ACCOUNT_ID_01}/balance?tokenAddress=${TOKEN_ADDRESS}" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET"
if [[ "$HTTP_STATUS" == "200" ]]; then
    BALANCE_01=$(extract_json "$RESPONSE" '.data.balance // .data')
    log_ok "계좌1 잔액: ${BALANCE_01}"
fi

call_api GET "${SDS_ZK_BASE}/accounts/${ZK_ACCOUNT_ID_02}/balance?tokenAddress=${TOKEN_ADDRESS}" \
    "$ADMIN_CLIENT_ID" "$ADMIN_CLIENT_SECRET"
if [[ "$HTTP_STATUS" == "200" ]]; then
    BALANCE_02=$(extract_json "$RESPONSE" '.data.balance // .data')
    log_ok "계좌2 잔액: ${BALANCE_02}"
fi

finish_script "06. zktransfer 전체 플로우"
