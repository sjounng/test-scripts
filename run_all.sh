#!/bin/bash
# ============================================
# 전체 QA 테스트 자동화 실행
# ============================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 옵션 파싱 ---
CONTINUE_ON_FAIL=false
START_FROM=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --continue-on-fail) CONTINUE_ON_FAIL=true; shift ;;
        --from) START_FROM="$2"; shift 2 ;;
        -h|--help)
            echo "사용법: ./run_all.sh [옵션]"
            echo ""
            echo "옵션:"
            echo "  --continue-on-fail    실패해도 다음 단계 계속 진행"
            echo "  --from <이름>         해당 스크립트부터 실행 (예: --from zk)"
            echo "  -h, --help            도움말"
            echo ""
            echo "예시:"
            echo "  ./run_all.sh                         전체 실행 (실패 시 중단)"
            echo "  ./run_all.sh --continue-on-fail      실패해도 계속"
            echo "  ./run_all.sh --from zk               zk_transfer.sh부터 실행 (.state 유지)"
            exit 0
            ;;
        *) echo "알 수 없는 옵션: $1"; exit 1 ;;
    esac
done

# --- RUN_ID 생성 (.state 초기화 전에 미리 주입) ---
if [[ -z "$START_FROM" ]]; then
    export RUN_ID=$(date +%s)
    > "${SCRIPT_DIR}/.state"
    echo "RUN_ID=$RUN_ID" >> "${SCRIPT_DIR}/.state"
fi

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib.sh"

# --- 스크립트 목록 ---
SCRIPTS=(
    "setup.sh|사전 세팅 (발행→사용자→전환→비밀계좌→전송)"
    "zk_transfer.sh|zk 전송 플로우"
)

# --- jq 의존성 확인 ---
if ! command -v jq &>/dev/null; then
    echo "[ERROR] jq가 설치되어 있지 않습니다. brew install jq"
    exit 1
fi

# --- 상태 파일 초기화 (--from 없을 때만) ---
if [[ -z "$START_FROM" ]]; then
    init_state
    save_var "RUN_ID" "$RUN_ID"
fi

# --- 실행 ---
log_header "QA 테스트 자동화 시작"
echo ""

TOTAL=${#SCRIPTS[@]}
PASS=0
FAIL=0
SKIP=0
RESULTS=()
TOTAL_START=$(date +%s)
FAILED_SCRIPT=""
_FROM_MATCHED=""

for entry in "${SCRIPTS[@]}"; do
    IFS='|' read -r script_file script_name <<< "$entry"
    # --from 옵션 처리 (파일명에 키워드 포함 여부로 판단)
    if [[ -n "$START_FROM" && "$script_file" != *"$START_FROM"* && -z "$_FROM_MATCHED" ]]; then
        RESULTS+=("SKIP|${script_file}|${script_name}|0")
        ((SKIP++))
        continue
    fi
    _FROM_MATCHED="true"

    # 이전 실패로 인한 스킵
    if [[ -n "$FAILED_SCRIPT" && "$CONTINUE_ON_FAIL" == false ]]; then
        RESULTS+=("SKIP|${script_file}|${script_name}|0")
        ((SKIP++))
        continue
    fi

    # 실행
    step_start=$(date +%s)
    echo -e "${CYAN}▶ 실행: ${script_file} (${script_name})${NC}"

    if bash "${SCRIPT_DIR}/${script_file}"; then
        elapsed=$(( $(date +%s) - step_start ))
        RESULTS+=("PASS|${script_file}|${script_name}|${elapsed}")
        ((PASS++))
    else
        elapsed=$(( $(date +%s) - step_start ))
        RESULTS+=("FAIL|${script_file}|${script_name}|${elapsed}")
        ((FAIL++))
        FAILED_SCRIPT="$script_file"
    fi
done

TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))

# --- 결과 리포트 ---
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  QA 테스트 자동화 결과${NC}"
echo -e "${CYAN}============================================${NC}"

for result in "${RESULTS[@]}"; do
    IFS='|' read -r status file name elapsed <<< "$result"
    case $status in
        PASS) printf "  ${GREEN}[PASS]${NC}  %-30s %-20s (%ss)\n" "$file" "$name" "$elapsed" ;;
        FAIL) printf "  ${RED}[FAIL]${NC}  %-30s %-20s (%ss)\n" "$file" "$name" "$elapsed" ;;
        SKIP) printf "  ${YELLOW}[SKIP]${NC}  %-30s %-20s\n" "$file" "$name" ;;
    esac
done

echo -e "${CYAN}============================================${NC}"
echo -e "  총 ${TOTAL}개  |  ${GREEN}통과: ${PASS}${NC}  |  ${RED}실패: ${FAIL}${NC}  |  ${YELLOW}스킵: ${SKIP}${NC}  |  소요: ${TOTAL_ELAPSED}s"
echo -e "${CYAN}============================================${NC}"

# .state 변수 목록 출력
if [[ -f "$STATE_FILE" ]]; then
    echo ""
    echo -e "${BLUE}[저장된 변수 (.state)]${NC}"
    while IFS='=' read -r key value; do
        printf "  %-30s = %s\n" "$key" "$value"
    done < "$STATE_FILE"
fi

echo ""

# 실패 있으면 exit 1
[[ $FAIL -gt 0 ]] && exit 1
exit 0
