#!/bin/bash
# ============================================
# 공통 함수 라이브러리
# ============================================

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 스크립트 시작 시간
_SCRIPT_START=$(date +%s)

# --------------------------------------------
# 로그 함수
# --------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $1"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_step()  { echo -e "${CYAN}──── $1${NC}"; }
log_header() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}============================================${NC}"
}

# --------------------------------------------
# 상태 파일 관리
# --------------------------------------------

# 변수를 .state 파일에 저장
save_var() {
    local key="$1"
    local value="$2"
    # 기존 키가 있으면 업데이트, 없으면 추가
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
    else
        echo "${key}=${value}" >> "$STATE_FILE"
    fi
    log_info "저장: ${key}=${value}"
}

# .state 파일 로드
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        log_info ".state 파일 로드 완료"
    else
        log_warn ".state 파일 없음 (첫 실행)"
    fi
}

# .state 파일 초기화
init_state() {
    > "$STATE_FILE"
    log_info ".state 파일 초기화"
}

# --------------------------------------------
# API 호출 함수
# --------------------------------------------

# call_api METHOD URL CLIENT_ID CLIENT_SECRET [BODY]
# 결과: RESPONSE (body), HTTP_STATUS (code)
call_api() {
    local method="$1"
    local url="$2"
    local client_id="$3"
    local client_secret="$4"
    local body="${5:-}"

    local curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Content-Type: application/json"
        -H "X-Lego-Client-Id: ${client_id}"
        -H "X-Lego-Client-Secret: ${client_secret}"
    )

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    local raw_output
    raw_output=$(curl "${curl_args[@]}" "$url")

    # 마지막 줄 = HTTP status, 나머지 = body
    HTTP_STATUS=$(echo "$raw_output" | tail -n1)
    RESPONSE=$(echo "$raw_output" | sed '$d')
}

# call_zk_api METHOD URL [BODY]
# zktransfer 서버 전용 (x-api-key 인증)
call_zk_api() {
    local method="$1"
    local url="$2"
    local body="${3:-}"

    local curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Content-Type: application/json"
        -H "x-api-key: ${ZK_API_KEY}"
    )

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    local raw_output
    raw_output=$(curl "${curl_args[@]}" "$url")

    HTTP_STATUS=$(echo "$raw_output" | tail -n1)
    RESPONSE=$(echo "$raw_output" | sed '$d')
}

# --------------------------------------------
# 응답 검증 함수
# --------------------------------------------

# HTTP 상태 코드 확인 (200 또는 201)
check_http_ok() {
    local step_name="$1"
    if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "201" ]]; then
        log_ok "${step_name} (HTTP ${HTTP_STATUS})"
        return 0
    else
        log_fail "${step_name} (HTTP ${HTTP_STATUS})"
        log_fail "응답: ${RESPONSE}"
        return 1
    fi
}

# JSON 필드 추출
extract_json() {
    local json="$1"
    local path="$2"
    echo "$json" | jq -r "$path"
}

# JSON 필드 존재 확인 + 추출
extract_and_verify() {
    local json="$1"
    local path="$2"
    local field_name="$3"

    local value
    value=$(echo "$json" | jq -r "$path")

    if [[ -z "$value" || "$value" == "null" ]]; then
        log_fail "${field_name} 추출 실패 (path: ${path})"
        return 1
    fi

    echo "$value"
    return 0
}

# --------------------------------------------
# DB 조회 함수
# --------------------------------------------
query_db() {
    local query="$1"
    docker exec "$LC_DB_CONTAINER" mysql -u "$LC_DB_USER" -p"$LC_DB_PASS" \
          -D "$LC_DB_NAME" -N -s -e "$query" 2>/dev/null
}

# --------------------------------------------
# 스크립트 실행 결과 처리
# --------------------------------------------

# 실패 시 스크립트 종료
die() {
    log_fail "$1"
    exit 1
}

# 스크립트 초기화 (각 스크립트 시작부에서 호출)
init_script() {
    local script_name="$1"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    source "${SCRIPT_DIR}/config.sh"
    source "${SCRIPT_DIR}/lib.sh" 2>/dev/null  # 이미 로드됨, 무시
    STATE_FILE="${SCRIPT_DIR}/.state"
    load_state
    log_header "$script_name"
    _SCRIPT_START=$(date +%s)
}

# 스크립트 완료 메시지
finish_script() {
    local script_name="$1"
    local elapsed=$(( $(date +%s) - _SCRIPT_START ))
    echo ""
    log_ok "${script_name} 완료 (${elapsed}s)"
    echo ""
}
