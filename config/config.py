"""
테스트 환경 설정
"""
import os
import time

# --- 경로 설정 ---
CONFIG_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_DIR = os.path.dirname(CONFIG_DIR)
STATE_FILE = os.path.join(SCRIPT_DIR, ".state")

# --- Lifecycle API ---
LIFECYCLE_HOST = "http://localhost"
LIFECYCLE_PORT = "8080"
LIFECYCLE_BASE = f"{LIFECYCLE_HOST}:{LIFECYCLE_PORT}/rest/v1/dlt/stc"

# --- SDS-25 ZKTransfer API (8080) ---
SDS_ZK_BASE = f"{LIFECYCLE_HOST}:{LIFECYCLE_PORT}/rest/zktransfer"

# --- 인증: 플랫폼 ---
PLATFORM_CLIENT_ID = "PLATFORM"
PLATFORM_CLIENT_SECRET = "2337a4ecd69947bf8db8f09f5d1f592d"

# --- 인증: 발행사 ---
ISSUER_CLIENT_ID = "ISSUER01"
ISSUER_CLIENT_SECRET = "1b090a608e2a4b7ebab04cad233ade25"

# --- 인증: ADMIN (사용자 등록 / zktransfer) ---
ADMIN_CLIENT_ID = "ADMIN_TOKEN"
ADMIN_CLIENT_SECRET = "41b5732026d04f9eb73b06021435ebb8"

# --- Lifecycle DB (docker exec 방식 - MariaDB 인증 호환 문제) ---
LC_DB_CONTAINER = "stc-mariadb"
LC_DB_USER = "root"
LC_DB_PASS = "root"
LC_DB_NAME = "lego"


def _load_run_id() -> str:
    """RUN_ID를 환경변수, state 파일, 또는 현재 시각으로부터 결정."""
    env_val = os.environ.get("RUN_ID", "")
    if env_val:
        return env_val

    if os.path.isfile(STATE_FILE):
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("RUN_ID="):
                    val = line[len("RUN_ID="):]
                    if val:
                        os.environ["RUN_ID"] = val
                        return val

    val = str(int(time.time()))
    os.environ["RUN_ID"] = val
    return val


RUN_ID: str = _load_run_id()
SHORT_ID: str = RUN_ID[-5:]

# --- 테스트 데이터: 발행 ---
MAINNET_NAME = f"SDSMainNet_{RUN_ID}"
MAINNET_TYPE = "Besu"
MAINNET_ENDPOINT = "http://localhost:9999"
MAINNET_CHAIN_ID = int(RUN_ID) if RUN_ID.isdigit() else int(time.time())

SC_NAME = f"MySC_{RUN_ID}"
SC_SYMBOL = f"MS{SHORT_ID}"
SC_ISSUE_AMOUNT = 900000.0
SC_PLANNED_DATE = "2025-12-31"
SC_ISSUE_NOTE = "Initial issuance planned for Q4 close, pending final regulatory review."

RESERVE_NOTE = "예금 + MMF 병행 운용"
RESERVE_FIAT_AMOUNT = 400000.0
RESERVE_MMF_AMOUNT = 600000.0

# --- 테스트 데이터: 개인사용자 ---
INDV1_LOGIN_ID = f"user_{RUN_ID}"
INDV1_EMAIL = f"user_{RUN_ID}@test.com"
INDV1_PASSWORD = "q1w2e3r4!"
INDV1_NAME = "김분"
INDV1_PHONE = "010-3486-6789"
INDV1_ADDRESS = "서울시 성동구 사근동"
INDV1_DETAIL_ADDRESS = "312호"
INDV1_ZIPCODE = "01234"

# --- 테스트 데이터: 전환 ---
DEPOSIT_AMOUNT = 1000000
CONVERSION_AMOUNT = 400000.0

# --- 테스트 데이터: 전송 ---
TRANSFER_AMOUNT = 10000.0

# --- 테스트 데이터: zktransfer ---
ZK_APPROVE_AMOUNT = 10
ZK_DEPOSIT_AMOUNT = 10
ZK_SEND_AMOUNT = 10
ZK_WITHDRAW_AMOUNT = 10
