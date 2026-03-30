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
TARGET_API=${1:-"all"}
ITERATIONS=${2:-10}
LOGFILE="single_$(date +%Y%m%d_%H%M%S).log"

APIS_INDIVIDUAL=("account" "approve" "deposit" "send" "receive" "withdraw")
APIS_ALL=("account" "approve" "deposit" "send" "receive" "withdraw" "e2e")

if [ "$TARGET_API" == "all" ]; then
    APIS=("${APIS_ALL[@]}")
else
    APIS=("$TARGET_API")
fi

# k6 실행
run_k6() {
    local api="$1"
    local iters="$2"
    k6 run \
        -e SDS_ZK_BASE=http://localhost:8080/rest/zktransfer \
        -e TOKEN_ADDRESS="$TOKEN_ADDRESS" \
        -e ZK_ACCOUNT_ID_01="$ZK_ACCOUNT_ID_01" \
        -e ZK_ACCOUNT_ID_02="$ZK_ACCOUNT_ID_02" \
        -e SIGNER_ADDRESS="$SIGNER_ADDRESS" \
        -e TEST_MODE="$api" \
        --vus 1 --iterations "$iters" \
        --summary-export="/tmp/k6_${api}.json" \
        loadtest.js 2>&1
}

# 개별 API 결과 파싱 (커스텀 메트릭 api_xxx 사용)
parse_single() {
    local api="$1"
    local json="/tmp/k6_${api}.json"
    if [ ! -f "$json" ]; then
        printf "  %-10s | ⚠️  결과 파일 없음\n" "$api"
        return
    fi

    local metric="api_${api}"
    local avg=$(jq -r ".metrics.${metric}.values.avg // 0" "$json")
    local p95=$(jq -r ".metrics.${metric}.values[\"p(95)\"] // 0" "$json")
    local p99=$(jq -r ".metrics.${metric}.values[\"p(99)\"] // 0" "$json")
    local count=$(jq -r ".metrics.${metric}.values.count // 0" "$json")
    local checks_pass=$(jq -r '.metrics.checks.values.passes // 0' "$json")
    local checks_fail=$(jq -r '.metrics.checks.values.fails // 0' "$json")
    local total=$((checks_pass + checks_fail))
    local success="0.00"
    if [ "$total" -gt 0 ]; then
        success=$(awk "BEGIN { printf \"%.2f\", ($checks_pass / $total) * 100 }")
    fi

    printf "  %-10s | %4s회 | %10.2fms | %10.2fms | %10.2fms | %6s%%\n" \
        "$api" "$count" "$avg" "$p95" "$p99" "$success"
}

# E2E 결과 파싱 (API별 개별 메트릭 출력)
parse_e2e() {
    local json="/tmp/k6_e2e.json"
    if [ ! -f "$json" ]; then
        printf "  %-10s | ⚠️  결과 파일 없음\n" "e2e"
        return
    fi

    echo ""
    echo "  [ E2E 내 API별 응답시간 ]"
    for api in "${APIS_INDIVIDUAL[@]}"; do
        local metric="api_${api}"
        local avg=$(jq -r ".metrics.${metric}.values.avg // 0" "$json")
        local p95=$(jq -r ".metrics.${metric}.values[\"p(95)\"] // 0" "$json")
        local p99=$(jq -r ".metrics.${metric}.values[\"p(99)\"] // 0" "$json")
        local count=$(jq -r ".metrics.${metric}.values.count // 0" "$json")
        printf "  %-10s | %4s회 | %10.2fms | %10.2fms | %10.2fms\n" \
            "$api" "$count" "$avg" "$p95" "$p99"
    done
}

# 실행
echo "============================================"
echo " 단건 테스트 | 반복: ${ITERATIONS}회"
echo " 대상: ${APIS[*]}"
echo "============================================"
echo ""

{
    echo "============================================"
    echo " 단건 테스트 결과 | $(date '+%Y-%m-%d %H:%M:%S')"
    echo " 반복: ${ITERATIONS}회"
    echo "============================================"
    echo ""
    printf "  %-10s | %5s | %12s | %12s | %12s | %s\n" \
        "API" "반복" "평균" "P95" "P99" "성공률"
    echo "  -----------+-------+--------------+--------------+--------------+--------"
} | tee "$LOGFILE"

for api in "${APIS[@]}"; do
    echo ""
    echo "──── ${api} 측정 중... ────"
    run_k6 "$api" "$ITERATIONS" > /dev/null 2>&1 || true

    if [ "$api" == "e2e" ]; then
        parse_e2e | tee -a "$LOGFILE"
    else
        parse_single "$api" | tee -a "$LOGFILE"
    fi
done

echo "" | tee -a "$LOGFILE"
echo "============================================" | tee -a "$LOGFILE"
echo " 결과 저장: ${LOGFILE}" | tee -a "$LOGFILE"
echo "============================================" | tee -a "$LOGFILE"
