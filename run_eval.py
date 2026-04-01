#!/usr/bin/env python3
"""
성능 평가 통합 실행 스크립트

사용법: python run_eval.py <CPU_CORES> [SECTION]
  CPU_CORES: 현재 서버 CPU 코어 수 (예: 8, 12, 16, 24)
  SECTION  : single | multi | e2e | all (기본: all)

예시:
  python run_eval.py 8
  python run_eval.py 8 single
  python run_eval.py 8 multi
  python run_eval.py 8 e2e

출력: logs/cpu_<N>_<timestamp>.md
"""
import json
import os
import re
import secrets
import string
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from typing import Optional

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPT_DIR)


from config.config import (
    ADMIN_CLIENT_ID,
    ADMIN_CLIENT_SECRET,
    CONVERSION_AMOUNT,
    DEPOSIT_AMOUNT,
    INDV1_PASSWORD,
    ISSUER_CLIENT_ID,
    ISSUER_CLIENT_SECRET,
    LIFECYCLE_BASE,
    MAINNET_CHAIN_ID,
    MAINNET_ENDPOINT,
    MAINNET_TYPE,
    PLATFORM_CLIENT_ID,
    PLATFORM_CLIENT_SECRET,
    RESERVE_FIAT_AMOUNT,
    RESERVE_MMF_AMOUNT,
    RESERVE_NOTE,
    RUN_ID,
    SC_ISSUE_AMOUNT,
    SC_ISSUE_NOTE,
    SC_PLANNED_DATE,
    SDS_ZK_BASE,
    STATE_FILE,
    TRANSFER_AMOUNT,
)
from config.lib import (
    call_api,
    check_http_ok,
    extract_json,
    log_fail,
    log_header,
    log_info,
    log_ok,
    log_step,
    log_warn,
    finish_script,
    query_db,
    read_state_var,
    reset_timer,
)

# ============================================
# 설정
# ============================================
SINGLE_ITERATIONS = 10
MULTI_ITERATIONS = 10
VUS_LIST = [10, 20, 30]
APIS = ["approve", "deposit", "account", "send", "receive", "withdraw"]


def _load_state_vars() -> dict[str, str]:
    """STATE 파일에서 필요한 변수들을 로드."""
    if not os.path.isfile(STATE_FILE):
        log_fail(".state 파일이 없습니다. setup.py를 먼저 실행하세요.")
        sys.exit(1)

    return {
        "TOKEN_ADDRESS": read_state_var("TOKEN_ADDRESS"),
        "ZK_ACCOUNT_ID_01": read_state_var("ZK_ACCOUNT_ID_01"),
        "ZK_ACCOUNT_ID_02": read_state_var("ZK_ACCOUNT_ID_02"),
        "SIGNER_ADDRESS": read_state_var("SIGNER_ADDRESS"),
        "SC_ID": read_state_var("SC_ID"),
    }


# ============================================
# k6 실행 함수
# ============================================

def run_k6(
    mode: str,
    vus: int,
    count_flag: str,
    count_val: str,
    state: dict[str, str],
    accounts_file: str = "",
) -> str:
    """
    k6를 실행하고 stdout이 저장된 임시 파일 경로를 반환.

    count_flag: "--iterations" 또는 "--duration"
    """
    tmp_fd, tmp_path = tempfile.mkstemp(prefix="k6_out_", suffix=".txt")
    os.close(tmp_fd)

    loadtest_js = os.path.join(_SCRIPT_DIR, "loadtest.js")

    cmd = [
        "k6", "run",
        "-e", f"SDS_ZK_BASE=http://localhost:8080/rest/zktransfer",
        "-e", f"TOKEN_ADDRESS={state['TOKEN_ADDRESS']}",
        "-e", f"ZK_ACCOUNT_ID_01={state['ZK_ACCOUNT_ID_01']}",
        "-e", f"ZK_ACCOUNT_ID_02={state['ZK_ACCOUNT_ID_02']}",
        "-e", f"SIGNER_ADDRESS={state['SIGNER_ADDRESS']}",
        "-e", f"TEST_MODE={mode}",
    ]

    if accounts_file:
        cmd += ["-e", f"ACCOUNTS_FILE={accounts_file}"]

    cmd += [
        "--vus", str(vus),
        count_flag, count_val,
        loadtest_js,
    ]

    try:
        with open(tmp_path, "w", encoding="utf-8") as out_f:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            assert proc.stdout is not None
            deadline = time.time() + 1800
            for line in proc.stdout:
                text = line.decode("utf-8", errors="replace")
                sys.stdout.write(text)
                sys.stdout.flush()
                out_f.write(text)
                if time.time() > deadline:
                    proc.kill()
                    log_warn("k6 실행 타임아웃")
                    break
            proc.wait()
    except FileNotFoundError:
        log_fail("k6 명령어를 찾을 수 없습니다.")

    return tmp_path


# ============================================
# 계정 준비 함수
# ============================================

def _random_str(length: int = 6) -> str:
    """알파벳 소문자 + 숫자로 구성된 랜덤 문자열 생성."""
    alphabet = string.ascii_lowercase + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def issue_issuance_with_retry(sc_issue_id: str, worker_index: int) -> tuple[str, int]:
    """발행 실행 API를 최대 6회 재시도. 성공 시 (response, status) 반환."""
    max_attempts = 6
    delay = 1
    retryable_statuses = {302, 409, 423, 429, 500, 502, 503}

    for attempt in range(1, max_attempts + 1):
        response, status = call_api(
            "PUT",
            f"{LIFECYCLE_BASE}/issuances/{sc_issue_id}/issue",
            ISSUER_CLIENT_ID,
            ISSUER_CLIENT_SECRET,
            "",
        )
        if status in (200, 201):
            return response, status

        if status not in retryable_statuses:
            return response, status

        if attempt == max_attempts:
            return response, status

        log_warn(
            f"({worker_index}) 발행 실행 재시도 대기 "
            f"({attempt}/{max_attempts}, HTTP {status}, {delay}s)"
        )
        time.sleep(delay)
        if delay < 5:
            delay += 1

    return "", 0


def prepare_single_account(i: int, count: int) -> Optional[dict]:
    """
    setup.py 1~5단계를 실행하여 단일 계정 준비.
    성공 시 {accountId, signerAddress, tokenAddress} dict 반환.
    실패 시 None 반환.
    """
    log_step(f"({i}/{count}) ── 계정 세팅 시작 ──────────────────")

    idx = f"{RUN_ID}_e2e{i}"

    # 1-1. 메인넷 등록
    chain_id = (MAINNET_CHAIN_ID % 100000) * 100 + i
    body = json.dumps({
        "mainnetName": f"SDSMainNet_{idx}",
        "mainnetType": MAINNET_TYPE,
        "endpoint": MAINNET_ENDPOINT,
        "chainId": chain_id,
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/sc/mainnets",
        PLATFORM_CLIENT_ID,
        PLATFORM_CLIENT_SECRET,
        body,
    )
    if not check_http_ok(f"메인넷 등록 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    mainnet_id = extract_json(response, ".data.mainnetId // .data.id")
    if not mainnet_id or str(mainnet_id) == "null":
        log_warn(f"({i}) mainnetId 없음, 건너뜀")
        return None

    # 1-2. 발행 계획 등록
    rand = _random_str(6)
    body = json.dumps({
        "mainnetId": mainnet_id,
        "scName": f"MySC_{rand}",
        "scSymbol": f"MS{rand}",
        "scIssueAmount": SC_ISSUE_AMOUNT,
        "scPlannedIssuanceDate": SC_PLANNED_DATE,
        "scIssueNote": SC_ISSUE_NOTE,
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/issuances",
        ISSUER_CLIENT_ID,
        ISSUER_CLIENT_SECRET,
        body,
    )
    if not check_http_ok(f"발행 계획 등록 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    sc_issue_id = extract_json(response, ".data.scIssueId")
    sc_id = extract_json(response, ".data.scId")
    if not sc_issue_id or str(sc_issue_id) == "null":
        log_warn(f"({i}) scIssueId 없음, 건너뜀")
        return None

    # 1-3. 준비금 등록
    body = json.dumps({
        "scIssueId": str(sc_issue_id),
        "scId": str(sc_id),
        "reserve": {
            "reserveNote": RESERVE_NOTE,
            "reserveOp": [
                {
                    "reserveOpInstitutionName": "국민은행",
                    "reserveOpType": "FiatDeposit",
                    "reserveOpPeriodStart": "2025-10-22T09:00:00",
                    "reserveOpPeriodEnd": "2026-03-31T23:59:59",
                    "reserveOpNote": "유동성 확보",
                    "reserveOpAmount": RESERVE_FIAT_AMOUNT,
                },
                {
                    "reserveOpInstitutionName": "삼성자산운용 MMF",
                    "reserveOpType": "Mmf",
                    "reserveOpPeriodStart": "2025-10-22T09:00:00",
                    "reserveOpPeriodEnd": "2026-03-31T23:59:59",
                    "reserveOpNote": "단기 MMF 운용",
                    "reserveOpAmount": RESERVE_MMF_AMOUNT,
                },
            ],
        },
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/reserves",
        ISSUER_CLIENT_ID,
        ISSUER_CLIENT_SECRET,
        body,
    )
    if not check_http_ok(f"준비금 등록 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    reserve_id = extract_json(response, ".data.reserveId")

    # 1-4. 준비금 승인
    response, status = call_api(
        "PUT",
        f"{LIFECYCLE_BASE}/reserves/{reserve_id}/approval",
        ISSUER_CLIENT_ID,
        ISSUER_CLIENT_SECRET,
        '{"approval":"Approved"}',
    )
    if not check_http_ok(f"준비금 승인 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    # 1-5. 발행 계획 승인
    response, status = call_api(
        "PUT",
        f"{LIFECYCLE_BASE}/issuances/{sc_issue_id}/approval",
        ISSUER_CLIENT_ID,
        ISSUER_CLIENT_SECRET,
        '{"approval":"Approved"}',
    )
    if not check_http_ok(f"발행 계획 승인 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    # 1-6. 발행 실행 (재시도)
    response, status = issue_issuance_with_retry(str(sc_issue_id), i)
    if status not in (200, 201):
        log_warn(f"({i}) 발행 실행 실패 (HTTP {status}), 건너뜀")
        return None
    log_ok(f"발행 실행 ({i}) (HTTP {status})")

    # 1-7. token_address DB 조회 (최대 30초 폴링)
    token_address = None
    for attempt in range(1, 31):
        result = query_db(
            f"SELECT token_address FROM stc_sc WHERE sc_id = {sc_id} ORDER BY created_date DESC LIMIT 1;"
        )
        if result and result.startswith("0x"):
            token_address = result
            break
        log_warn(f"({i}) token_address 대기 중... ({attempt}/30)")
        time.sleep(1)
    if not token_address:
        log_warn(f"({i}) token_address 조회 실패, 건너뜀")
        return None
    log_ok(f"({i}) token_address: {token_address}")

    # 2-1. 개인사용자 추가
    body = json.dumps({
        "loginId": f"e2u_{idx}",
        "email": f"e2u_{idx}@test.com",
        "password": INDV1_PASSWORD,
        "name": f"E2U{i}",
        "phoneNumber": f"010-0000-{i:04d}",
        "address": "서울시 성동구",
        "detailAddress": f"{i}호",
        "zipCode": "01234",
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/users/individuals",
        ADMIN_CLIENT_ID,
        ADMIN_CLIENT_SECRET,
        body,
    )
    if not check_http_ok(f"사용자 추가 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    user_id = extract_json(response, ".data.userId")
    cli_id = extract_json(response, ".data.longTokenClientId")
    cli_secret = extract_json(response, ".data.longToken")

    # 2-2. 사용자 승인
    response, status = call_api(
        "PUT",
        f"{LIFECYCLE_BASE}/users/{user_id}/individuals/approval",
        PLATFORM_CLIENT_ID,
        PLATFORM_CLIENT_SECRET,
        '{"approval":"Approved"}',
    )
    if not check_http_ok(f"사용자 승인 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    # 2-3. 포트폴리오 조회
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/portfolios",
        PLATFORM_CLIENT_ID,
        PLATFORM_CLIENT_SECRET,
    )
    if not check_http_ok(f"포트폴리오 조회 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    select_path = (
        f"[.data.content[]? | select(.ownerId == {user_id} or "
        f'.ownerId == "{user_id}")] | first | .portfolioId'
    )
    portfolio_id = extract_json(response, select_path)
    if not portfolio_id or str(portfolio_id) == "null":
        log_warn(f"({i}) portfolioId 없음, 건너뜀")
        return None

    # 2-4. 원화계좌 조회
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/portfolios/{portfolio_id}/accounts",
        str(cli_id),
        str(cli_secret),
    )
    if not check_http_ok(f"원화계좌 조회 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    fiat_account_id = extract_json(
        response,
        '[.data.content[]? | select(.type == "Fiat")] | first | .accountId',
    )
    if not fiat_account_id or str(fiat_account_id) == "null":
        log_warn(f"({i}) fiatAccountId 없음, 건너뜀")
        return None

    # 3-1. 가상계좌 조회
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/accounts/fiat/virtual-and-withdrawal",
        str(cli_id),
        str(cli_secret),
    )
    if not check_http_ok(f"가상계좌 조회 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    virtual_account = extract_json(
        response,
        '[.data.content[]? | select(.accountType == "Virtual")] | first | .accountNumber',
    )
    if not virtual_account or str(virtual_account) == "null":
        log_warn(f"({i}) 가상계좌번호 없음, 건너뜀")
        return None

    # 3-2. 원화 입금
    body = json.dumps({
        "amount": DEPOSIT_AMOUNT,
        "virtualAccountNumber": str(virtual_account),
        "bankCode": "099",
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/webhook/accounts/fiat/deposit",
        str(cli_id),
        str(cli_secret),
        body,
    )
    if not check_http_ok(f"원화 입금 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    # 3-3. 온체인 매수
    body = json.dumps({
        "fiatAccountId": fiat_account_id,
        "scAccountId": None,
        "scId": sc_id,
        "amount": CONVERSION_AMOUNT,
        "conversionType": "FiatToOnchain",
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/conversions",
        str(cli_id),
        str(cli_secret),
        body,
    )
    if not check_http_ok(f"온체인 매수 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    # 3-4. 포트폴리오 재조회 (코인계좌)
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/portfolios/{portfolio_id}/accounts",
        str(cli_id),
        str(cli_secret),
    )
    if not check_http_ok(f"포트폴리오 재조회 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    sc_account_id = extract_json(
        response,
        '[.data.content[]? | select(.type == "Sc" or .type == "SC" or .type == "sc")] | first | .accountId',
    )
    if not sc_account_id or str(sc_account_id) == "null":
        log_warn(f"({i}) scAccountId 없음, 건너뜀")
        return None

    # 3-5. 코인 계좌 조회 (지갑주소)
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/accounts/sc/{sc_account_id}",
        str(cli_id),
        str(cli_secret),
    )
    if not check_http_ok(f"코인계좌 조회 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    wallet_address = extract_json(response, ".data.scWalletAddress // .data.walletAddress")
    if not wallet_address or str(wallet_address) == "null":
        log_warn(f"({i}) 지갑주소 없음, 건너뜀")
        return None

    # 4. ZK 비밀계좌 생성
    response, status = call_api(
        "POST",
        f"{SDS_ZK_BASE}/accounts",
        ADMIN_CLIENT_ID,
        ADMIN_CLIENT_SECRET,
    )
    if not check_http_ok(f"ZK 계좌 생성 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    zk_account_id = extract_json(response, ".data.accountId")
    signer_address = extract_json(response, ".data.signerAddress")
    if not zk_account_id or str(zk_account_id) == "null":
        log_warn(f"({i}) ZK accountId 없음, 건너뜀")
        return None

    # 5-1. 코인 계좌 재조회
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/accounts/sc/{sc_account_id}",
        str(cli_id),
        str(cli_secret),
    )
    if not check_http_ok(f"코인계좌 재조회 ({i})", status, response):
        log_warn(f"({i}) 건너뜀")
        return None

    wallet_address = extract_json(response, ".data.scWalletAddress // .data.walletAddress")
    if not wallet_address or str(wallet_address) == "null":
        log_warn(f"({i}) 지갑주소 재조회 실패, 건너뜀")
        return None

    # 5-2. SC 전송
    body = json.dumps({
        "fromScWalletAddress": str(wallet_address),
        "toScWalletAddress": str(signer_address),
        "scId": sc_id,
        "amount": TRANSFER_AMOUNT,
        "transferType": "OnchainToOnchain",
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/transfers",
        str(cli_id),
        str(cli_secret),
        body,
    )
    if not check_http_ok(f"SC 전송 ({i})", status, response):
        log_warn(f"({i}) SC 전송 실패, 건너뜀")
        return None

    log_ok(f"({i}/{count}) 완료 → accountId: {zk_account_id}")
    return {
        "accountId": str(zk_account_id),
        "signerAddress": str(signer_address),
        "tokenAddress": token_address,
    }


def prepare_accounts(count: int, timestamp: str) -> Optional[str]:
    """count개 계정을 순차 준비 후 JSON 파일 경로 반환. 전체 실패 시 None."""
    accounts_file = os.path.join(_SCRIPT_DIR, f"accounts.json")

    log_header(f"E2E 계정 사전 준비 ({count}개) — setup.py 1~5단계")

    results: list[dict] = []
    had_failures = False

    for i in range(1, count + 1):
        account = prepare_single_account(i, count)
        if account is None:
            had_failures = True
        else:
            results.append(account)

    if not results:
        log_fail("E2E 계정 준비 전체 실패")
        return None

    with open(accounts_file, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

    if had_failures:
        log_warn(f"일부 계정 준비는 실패했지만 성공한 {len(results)}개 계정을 사용합니다.")
    log_ok(f"계정 {len(results)}개 준비 완료 → {accounts_file}")

    return accounts_file


def resolve_shared_accounts_file(required_count: int, timestamp: str) -> Optional[str]:
    """
    기존 accounts.json이 충분하면 재사용.
    부족하거나 없으면 prepare_accounts 호출.
    """
    default_file = os.path.join(_SCRIPT_DIR, "accounts.json")

    if os.path.isfile(default_file):
        try:
            with open(default_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            account_count = len(data) if isinstance(data, list) else 0
        except (json.JSONDecodeError, OSError):
            account_count = 0

        if account_count >= required_count:
            log_ok(
                f"기존 accounts.json 재사용: {default_file} ({account_count}개)"
            )
            return default_file

        log_warn(
            f"accounts.json 계정 수 부족 ({account_count}) — {required_count}개 새로 준비"
        )

    return prepare_accounts(required_count, timestamp)


# ============================================
# 메트릭 파싱 헬퍼
# ============================================

def trend_val(file_path: str, metric: str, stat: str) -> str:
    """
    k6 텍스트 요약에서 Trend 메트릭의 특정 통계값(ms 단위) 추출.

    stat: "avg", "min", "max", "p(95)", "p(99)" 등
    """
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError:
        return "0"

    # metric이 포함된 첫 번째 줄 찾기
    target_line = ""
    for line in content.splitlines():
        if metric in line:
            target_line = line
            break

    if not target_line:
        return "0"

    # stat 이름 이스케이프 (괄호 처리)
    stat_escaped = re.escape(stat)
    pattern = rf"{stat_escaped}=([0-9]+(?:\.[0-9]+)?)(µs|ms|s)\b"
    match = re.search(pattern, target_line)
    if not match:
        return "0"

    value_str = match.group(1)
    unit = match.group(2)

    try:
        value = float(value_str)
    except ValueError:
        return "0"

    if unit == "µs":
        return f"{value / 1000:.3f}"
    elif unit == "ms":
        return value_str
    elif unit == "s":
        return f"{value * 1000:.0f}"
    return value_str


def rate_val(file_path: str, metric: str = "http_reqs") -> str:
    """
    k6 Counter 출력에서 TPS(rate) 추출.
    형식: "api_account_count...: 100 3.33/s"
    """
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError:
        return "0"

    for line in content.splitlines():
        if re.search(rf"\b{re.escape(metric)}\b", line):
            match = re.search(r"([0-9]+\.[0-9]+)/s", line)
            if match:
                return match.group(1)
    return "0"


def success_rate(file_path: str) -> str:
    """
    k6 출력에서 성공률 추출.
    형식: "checks_succeeded...: 100.00% 3 out of 3"
    """
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError:
        return "N/A"

    for line in content.splitlines():
        if "checks_succeeded" in line:
            match = re.search(r"([0-9]+\.[0-9]+)%", line)
            if match:
                pct = float(match.group(1))
                return f"{pct:.1f}"
    return "N/A"


def error_rate(file_path: str) -> str:
    """
    k6 출력에서 에러율 추출.
    형식: "checks_failed......: 0.00%  0 out of 3"
    """
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError:
        return "N/A"

    for line in content.splitlines():
        if "checks_failed" in line:
            match = re.search(r"([0-9]+\.[0-9]+)%", line)
            if match:
                pct = float(match.group(1))
                return f"{pct:.1f}"
    return "N/A"


def fmt_ms(val: str) -> str:
    """float 문자열을 정수 ms 표현으로 변환."""
    try:
        return f"{float(val):.0f} ms"
    except (ValueError, TypeError):
        return "0 ms"


def fmt_tps(val: str) -> str:
    """float 문자열을 소수점 2자리로 포맷."""
    try:
        return f"{float(val):.2f}"
    except (ValueError, TypeError):
        return "0.00"


# ============================================
# 메인
# ============================================

def main() -> None:
    reset_timer()

    if len(sys.argv) < 2:
        print("사용법: python run_eval.py <CPU_CORES> [single|multi|e2e|all]")
        print("  예시: python run_eval.py 8")
        print("        python run_eval.py 8 single")
        sys.exit(1)

    cpu_cores = sys.argv[1]
    section = sys.argv[2] if len(sys.argv) > 2 else "all"

    if section not in ("single", "multi", "e2e", "all"):
        print("SECTION은 single|multi|e2e|all 중 하나여야 합니다.")
        sys.exit(1)

    state = _load_state_vars()

    log_dir = os.path.join(_SCRIPT_DIR, "logs")
    os.makedirs(log_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    result_file = os.path.join(log_dir, f"cpu_{cpu_cores}_{timestamp}.md")

    # ============================================
    # 결과 파일 헤더
    # ============================================
    with open(result_file, "w", encoding="utf-8") as rf:
        rf.write(f"# 성능 평가 결과 — CPU {cpu_cores} Core\n\n")
        rf.write("| 항목 | 내용 |\n")
        rf.write("| --- | --- |\n")
        rf.write(f"| 테스트 일시 | {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} |\n")
        rf.write(f"| CPU | {cpu_cores} Core |\n")
        rf.write(f"| 단건 반복 횟수 | {SINGLE_ITERATIONS} |\n")
        rf.write(f"| 다중 VU당 반복 횟수 | {MULTI_ITERATIONS} |\n")
        rf.write(f"| VU | {' '.join(str(v) for v in VUS_LIST)} |\n")
        rf.write("\n---\n\n")

    # ============================================
    # 단건 테스트
    # ============================================
    if section in ("single", "all"):
        log_header(f"단건 테스트 (CPU: {cpu_cores} Core)")

        with open(result_file, "a", encoding="utf-8") as rf:
            rf.write("## 단건 테스트\n\n")
            rf.write("| API | CPU | 반복 횟수 | 평균 응답 시간 | P95 | P99 | 성공률 |\n")
            rf.write("| --- | --- | --- | --- | --- | --- | --- |\n")

        log_step(f"풀 사이클 {SINGLE_ITERATIONS}회 실행 (approve→deposit→account→send→receive→withdraw)...")
        tmp = run_k6("e2e", 1, "--iterations", str(SINGLE_ITERATIONS), state)

        for api in APIS:
            avg = trend_val(tmp, f"api_{api}", "avg")
            p95 = trend_val(tmp, f"api_{api}", "p(95)")
            p99 = trend_val(tmp, f"api_{api}", "p(99)")
            sr = success_rate(tmp)
            with open(result_file, "a", encoding="utf-8") as rf:
                rf.write(
                    f"| {api} | {cpu_cores} | {SINGLE_ITERATIONS} | "
                    f"{fmt_ms(avg)} | {fmt_ms(p95)} | {fmt_ms(p99)} | {sr}% |\n"
                )

        os.unlink(tmp)
        log_ok("단건 테스트 완료")

        with open(result_file, "a", encoding="utf-8") as rf:
            rf.write("\n---\n\n")

    # ============================================
    # 계정 사전 준비 (다중/E2E 공통)
    # ============================================
    shared_accounts_file: Optional[str] = None
    if section in ("multi", "e2e", "all"):
        max_vu = VUS_LIST[-1]
        log_header(f"계정 사전 준비 (최대 VU: {max_vu}개)")
        shared_accounts_file = resolve_shared_accounts_file(max_vu, timestamp)

        if not shared_accounts_file:
            log_warn("계정 준비 실패 — ZK_ACCOUNT_ID_01 단일 계정으로 진행 (충돌 가능)")

    # ============================================
    # 다중 테스트
    # ============================================
    if section in ("multi", "all"):
        log_header(f"다중 테스트 (CPU: {cpu_cores} Core)")

        with open(result_file, "a", encoding="utf-8") as rf:
            rf.write("## 다중 테스트\n\n")
            rf.write("| API | CPU | VU | TPS | 평균 응답 시간 | P95 | P99 | 에러율 |\n")
            rf.write("| --- | --- | --- | --- | --- | --- | --- | --- |\n")

        for vu in VUS_LIST:
            log_header(f"다중 테스트 VU={vu} (단계별 순차 실행)")
            for api in APIS:
                log_step(f"[VU={vu}] {api} — {MULTI_ITERATIONS}회 × {vu} VU")
                tmp = run_k6(
                    api,
                    vu,
                    "--iterations",
                    str(MULTI_ITERATIONS * vu),
                    state,
                    shared_accounts_file or "",
                )
                log_ok(f"[VU={vu}] {api} 완료, 메트릭 추출 중...")

                tps = rate_val(tmp, f"api_{api}_count")
                er = error_rate(tmp)
                avg = trend_val(tmp, f"api_{api}", "avg")
                p95 = trend_val(tmp, f"api_{api}", "p(95)")
                p99 = trend_val(tmp, f"api_{api}", "p(99)")
                log_info(f"  [{api}] avg={fmt_ms(avg)} p95={fmt_ms(p95)} p99={fmt_ms(p99)}")

                with open(result_file, "a", encoding="utf-8") as rf:
                    rf.write(
                        f"| {api} | {cpu_cores} | {vu} | {fmt_tps(tps)} | "
                        f"{fmt_ms(avg)} | {fmt_ms(p95)} | {fmt_ms(p99)} | {er}% |\n"
                    )
                os.unlink(tmp)

            log_ok(f"다중 테스트 VU={vu} 완료")

        with open(result_file, "a", encoding="utf-8") as rf:
            rf.write("\n---\n\n")

    # ============================================
    # E2E 테스트
    # ============================================
    if section in ("e2e", "all"):
        log_header(f"E2E 테스트 (CPU: {cpu_cores} Core)")

        with open(result_file, "a", encoding="utf-8") as rf:
            rf.write("## E2E 테스트\n\n")
            rf.write("| 시나리오 | CPU | VU | TPS | 평균 응답 시간 | P95 | P99 | 성공률 |\n")
            rf.write("| --- | --- | --- | --- | --- | --- | --- | --- |\n")

        e2e_scenario = "approve > deposit > account > send > receive > withdraw"

        for vu in VUS_LIST:
            local_iters = MULTI_ITERATIONS * vu
            log_step(f"E2E VU={vu} 실행 중 (계정 {vu}개, {local_iters}회)...")
            tmp = run_k6(
                "e2e",
                vu,
                "--iterations",
                str(local_iters),
                state,
                shared_accounts_file or "",
            )
            log_ok(f"VU={vu} k6 완료, E2E 메트릭 추출 중...")

            tps = rate_val(tmp)
            avg = trend_val(tmp, "http_req_duration", "avg")
            p95 = trend_val(tmp, "http_req_duration", "p(95)")
            p99 = trend_val(tmp, "http_req_duration", "p(99)")
            sr = success_rate(tmp)

            log_info(
                f"  TPS={fmt_tps(tps)} avg={fmt_ms(avg)} "
                f"p95={fmt_ms(p95)} p99={fmt_ms(p99)} 성공률={sr}%"
            )

            with open(result_file, "a", encoding="utf-8") as rf:
                rf.write(
                    f"| {e2e_scenario} | {cpu_cores} | {vu} | {fmt_tps(tps)} | "
                    f"{fmt_ms(avg)} | {fmt_ms(p95)} | {fmt_ms(p99)} | {sr}% |\n"
                )

            os.unlink(tmp)
            log_ok(f"E2E VU={vu} 완료")

        with open(result_file, "a", encoding="utf-8") as rf:
            rf.write("\n")

    if shared_accounts_file:
        log_ok(f"계정 파일 저장됨: {shared_accounts_file}")

    with open(result_file, "a", encoding="utf-8") as rf:
        rf.write("\n")

    finish_script("성능 평가")
    print()
    log_ok(f"결과 저장: {result_file}")
    print()

    with open(result_file, "r", encoding="utf-8") as rf:
        print(rf.read())


if __name__ == "__main__":
    main()
