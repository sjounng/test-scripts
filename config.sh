#!/bin/bash
# ============================================
# 테스트 환경 설정
# ============================================

# --- Lifecycle API ---
LIFECYCLE_HOST="http://localhost"
LIFECYCLE_PORT="8080"
LIFECYCLE_BASE="${LIFECYCLE_HOST}:${LIFECYCLE_PORT}/rest/v1/dlt/stc"

# --- ZKTransfer Core API (9080) ---
ZK_HOST="http://localhost"
ZK_PORT="9080"
ZK_BASE="${ZK_HOST}:${ZK_PORT}/v1"
ZK_API_KEY="${ZKTRANSFER_CORE_API_KEY:-dev-api-key}"

# --- SDS-25 ZKTransfer API (8080) ---
SDS_ZK_BASE="${LIFECYCLE_HOST}:${LIFECYCLE_PORT}/rest/zktransfer"

# --- 인증: 플랫폼 ---
PLATFORM_CLIENT_ID="PLATFORM"
PLATFORM_CLIENT_SECRET="2337a4ecd69947bf8db8f09f5d1f592d"

# --- 인증: 발행사 ---
ISSUER_CLIENT_ID="ISSUER01"
ISSUER_CLIENT_SECRET="1b090a608e2a4b7ebab04cad233ade25"

# --- 인증: ADMIN (사용자 등록 / zktransfer) ---
ADMIN_CLIENT_ID="ADMIN_TOKEN"
ADMIN_CLIENT_SECRET="41b5732026d04f9eb73b06021435ebb8"

# --- Lifecycle DB (docker exec 방식 - MariaDB 인증 호환 문제) ---
LC_DB_CONTAINER="stc-mariadb"
LC_DB_USER="root"
LC_DB_PASS="root"
LC_DB_NAME="lego"

# --- 성능 테스트를 위한 고유 실행 ID ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.state"

if [[ -z "${RUN_ID:-}" ]]; then
    if [[ -f "$STATE_FILE" ]] && grep -q "^RUN_ID=" "$STATE_FILE"; then
        export RUN_ID=$(grep "^RUN_ID=" "$STATE_FILE" | cut -d'=' -f2)
    else
        export RUN_ID=$(date +%s)
    fi
fi
SHORT_ID=${RUN_ID: -5}

# --- 테스트 데이터: 발행 ---
MAINNET_NAME="SDSMainNet"
MAINNET_TYPE="Besu"
MAINNET_ENDPOINT="http://localhost:9999"
MAINNET_CHAIN_ID=1

SC_NAME="MySC_${RUN_ID}"
SC_SYMBOL="MS${SHORT_ID}"
SC_ISSUE_AMOUNT=900000.0
SC_PLANNED_DATE="2025-12-31"
SC_ISSUE_NOTE="Initial issuance planned for Q4 close, pending final regulatory review."

RESERVE_NOTE="예금 + MMF 병행 운용"
RESERVE_FIAT_AMOUNT=400000.0
RESERVE_MMF_AMOUNT=600000.0

# --- 테스트 데이터: 개인사용자 ---
INDV1_LOGIN_ID="user_${RUN_ID}"
INDV1_EMAIL="user_${RUN_ID}@test.com"
INDV1_PASSWORD="q1w2e3r4!"
INDV1_NAME="김분"
INDV1_PHONE="010-3486-6789"
INDV1_ADDRESS="서울시 성동구 사근동"
INDV1_DETAIL_ADDRESS="312호"
INDV1_ZIPCODE="01234"

# --- 테스트 데이터: 전환 ---
DEPOSIT_AMOUNT=1000000
CONVERSION_AMOUNT=400000.0

# --- 테스트 데이터: 전송 ---
TRANSFER_AMOUNT=10000.0

# --- 테스트 데이터: zktransfer ---
ZK_APPROVE_AMOUNT=10
ZK_DEPOSIT_AMOUNT=10
ZK_SEND_AMOUNT=10
ZK_WITHDRAW_AMOUNT=10

# --- 상태 파일 경로 ---
# SCRIPT_DIR과 STATE_FILE은 위에서 이미 정의됨
