"""
공통 함수 라이브러리
"""
import json
import os
import subprocess
import sys
import threading
import time
from typing import Any, Optional, Tuple

import requests

_print_lock = threading.Lock()

from config.config import (
    LC_DB_CONTAINER,
    LC_DB_NAME,
    LC_DB_PASS,
    LC_DB_USER,
    STATE_FILE,
)

# ============================================
# ANSI 색상 코드
# ============================================
_RED = "\033[0;31m"
_GREEN = "\033[0;32m"
_YELLOW = "\033[1;33m"
_BLUE = "\033[0;34m"
_CYAN = "\033[0;36m"
_NC = "\033[0m"

# 스크립트 시작 시간
_script_start: float = time.time()

# ZK API 키 (call_zk_api 사용 전 설정)
ZK_API_KEY: str = ""


# ============================================
# 로그 함수
# ============================================

def log_info(msg: str) -> None:
    with _print_lock:
        print(f"{_BLUE}[INFO]{_NC}  {msg}")


def log_ok(msg: str) -> None:
    with _print_lock:
        print(f"{_GREEN}[PASS]{_NC}  {msg}")


def log_fail(msg: str) -> None:
    with _print_lock:
        print(f"{_RED}[FAIL]{_NC}  {msg}")


def log_warn(msg: str) -> None:
    with _print_lock:
        print(f"{_YELLOW}[WARN]{_NC}  {msg}")


def log_step(msg: str) -> None:
    with _print_lock:
        print(f"{_CYAN}──── {msg}{_NC}")


def log_header(msg: str) -> None:
    with _print_lock:
        print()
        print(f"{_CYAN}============================================{_NC}")
        print(f"{_CYAN}  {msg}{_NC}")
        print(f"{_CYAN}============================================{_NC}")


# ============================================
# 상태 파일 관리
# ============================================

def save_var(key: str, value: Any) -> None:
    """key=value를 .state 파일에 저장. 기존 키는 업데이트, 없으면 추가."""
    str_value = str(value)
    lines: list[str] = []
    found = False

    if os.path.isfile(STATE_FILE):
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            lines = f.readlines()

    updated_lines: list[str] = []
    for line in lines:
        if line.startswith(f"{key}="):
            updated_lines.append(f"{key}={str_value}\n")
            found = True
        else:
            updated_lines.append(line)

    if not found:
        updated_lines.append(f"{key}={str_value}\n")

    with open(STATE_FILE, "w", encoding="utf-8") as f:
        f.writelines(updated_lines)

    log_info(f"저장: {key}={str_value}")


def load_state() -> dict[str, str]:
    """
    .state 파일을 읽어 dict로 반환.
    각 key의 값을 현재 모듈의 전역(globals)에도 설정하지 않으므로
    호출자가 반환된 dict를 사용해야 한다.
    """
    if not os.path.isfile(STATE_FILE):
        log_warn(".state 파일 없음 (첫 실행)")
        return {}

    state: dict[str, str] = {}
    with open(STATE_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                state[k.strip()] = v.strip()

    log_info(".state 파일 로드 완료")
    return state


def init_state() -> None:
    """STATE 파일 초기화 (비우기)."""
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        f.write("")
    log_info(".state 파일 초기화")


def read_state_var(key: str, default: str = "") -> str:
    """STATE 파일에서 특정 키의 값을 반환."""
    if not os.path.isfile(STATE_FILE):
        return default
    with open(STATE_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith(f"{key}="):
                return line[len(f"{key}="):]
    return default


# ============================================
# API 호출 함수
# ============================================

def call_api(
    method: str,
    url: str,
    client_id: str,
    client_secret: str,
    body: Optional[str] = None,
) -> Tuple[str, int]:
    """
    REST API 호출 (X-Lego-Client-Id / X-Lego-Client-Secret 인증).

    반환: (response_text, http_status_code)
    """
    headers = {
        "Content-Type": "application/json",
        "X-Lego-Client-Id": client_id,
        "X-Lego-Client-Secret": client_secret,
    }
    data = body.encode("utf-8") if body else None

    try:
        resp = requests.request(
            method=method.upper(),
            url=url,
            headers=headers,
            data=data,
            timeout=60,
        )
        return resp.text, resp.status_code
    except requests.RequestException as exc:
        log_fail(f"HTTP 요청 오류: {exc}")
        return "", 0


def call_zk_api(
    method: str,
    url: str,
    body: Optional[str] = None,
) -> Tuple[str, int]:
    """
    ZKTransfer 전용 API 호출 (x-api-key 인증).

    반환: (response_text, http_status_code)
    """
    headers = {
        "Content-Type": "application/json",
        "x-api-key": ZK_API_KEY,
    }
    data = body.encode("utf-8") if body else None

    try:
        resp = requests.request(
            method=method.upper(),
            url=url,
            headers=headers,
            data=data,
            timeout=60,
        )
        return resp.text, resp.status_code
    except requests.RequestException as exc:
        log_fail(f"ZK HTTP 요청 오류: {exc}")
        return "", 0


# ============================================
# 응답 검증 함수
# ============================================

def check_http_ok(step_name: str, http_status: int, response: str) -> bool:
    """HTTP 200 또는 201 여부 확인. 성공이면 True, 실패면 False."""
    if http_status in (200, 201):
        log_ok(f"{step_name} (HTTP {http_status})")
        return True
    log_fail(f"{step_name} (HTTP {http_status})")
    log_fail(f"응답: {response}")
    return False


# ============================================
# JSON 필드 추출
# ============================================

def extract_json(json_str: str, path: str) -> Any:
    """
    JSON 문자열에서 jq 스타일 경로로 값 추출.

    지원 패턴:
      - .field
      - .field.nested
      - .data.field
      - .data.scWalletAddress // .data.walletAddress        (// 대안 연산자)
      - [.data.content[]? | select(.key == val)] | first | .field
      - [.data.content[]? | select(.key == val or .key == val2)] | first | .field
    """
    try:
        data = json.loads(json_str)
    except (json.JSONDecodeError, TypeError):
        return None

    # 대안 연산자 처리: "pathA // pathB"
    if " // " in path:
        parts = [p.strip() for p in path.split(" // ")]
        for part in parts:
            if part in ("empty", "null", ""):
                continue
            result = extract_json(json_str, part)
            if result is not None and result != "null":
                return result
        return None

    # select 필터가 있는 배열 경로
    # 형식: [.data.content[]? | select(...)] | first | .field
    if path.strip().startswith("[") and "select(" in path:
        return _extract_with_select(data, path)

    # 단순 점 경로
    return _extract_simple_path(data, path.strip())


def _extract_simple_path(data: Any, path: str) -> Any:
    """점으로 구분된 단순 경로 탐색."""
    if not path or path in ("empty", "null"):
        return None

    # 선행 점 제거
    path = path.lstrip(".")

    if not path:
        return data

    parts = path.split(".")
    current = data
    for part in parts:
        if part == "" or part in ("empty", "null"):
            continue
        if isinstance(current, dict):
            current = current.get(part)
        else:
            return None
        if current is None:
            return None

    return current


def _extract_with_select(data: Any, path: str) -> Any:
    """
    jq의 [.data.content[]? | select(...)] | first | .field 패턴 처리.
    """
    import re

    path = path.strip()

    # 전체 패턴: [...] | first | .field  또는  [...] | first | .field // empty
    outer_match = re.match(r"^\[(.+)\]\s*\|\s*first\s*\|\s*(.+)$", path, re.DOTALL)
    if not outer_match:
        return None

    inner_expr = outer_match.group(1).strip()
    field_path = outer_match.group(2).strip()

    # .data.content[]? 부분과 | select(...) 분리
    # 형식: .some.path[]? | select(...)
    inner_match = re.match(r"^(.+?)\[\](\?)?\s*\|\s*select\((.+)\)$", inner_expr, re.DOTALL)
    if not inner_match:
        return None

    array_path = inner_match.group(1).strip()
    select_expr = inner_match.group(3).strip()

    # array_path에서 배열 데이터 추출
    array_data = _extract_simple_path(data, array_path.lstrip("."))
    if not isinstance(array_data, list):
        return None

    # select 조건 파싱 및 필터링
    matched_items = [item for item in array_data if _eval_select(item, select_expr)]

    if not matched_items:
        return None

    first_item = matched_items[0]

    # .field // empty 처리
    if " // " in field_path:
        field_parts = [p.strip() for p in field_path.split(" // ")]
        for fp in field_parts:
            if fp in ("empty", "null", ""):
                continue
            result = _extract_simple_path(first_item, fp.lstrip("."))
            if result is not None:
                return result
        return None

    return _extract_simple_path(first_item, field_path.lstrip("."))


def _eval_select(item: Any, expr: str) -> bool:
    """
    단순 select 표현식 평가.

    지원 형식:
      .field == "value"
      .field == value (숫자/문자열 자동 판별)
      .field == X or .field == "Y"
      .ownerId == X or .ownerId == "X"  (동적 값 포함)
    """
    import re

    if not isinstance(item, dict):
        return False

    expr = expr.strip()

    # or 연산자로 분리
    or_parts = re.split(r"\bor\b", expr)
    for part in or_parts:
        if _eval_single_condition(item, part.strip()):
            return True
    return False


def _eval_single_condition(item: dict, expr: str) -> bool:
    """단일 조건 평가: .field == "value" 또는 .field == value."""
    import re

    expr = expr.strip()

    # 형식: .field == "value" 또는 .field == value
    match = re.match(r"^\.(\w+)\s*==\s*(.+)$", expr)
    if not match:
        return False

    field_name = match.group(1)
    raw_val = match.group(2).strip()

    item_val = item.get(field_name)

    # 문자열 리터럴
    if (raw_val.startswith('"') and raw_val.endswith('"')) or \
       (raw_val.startswith("'") and raw_val.endswith("'")):
        compare_val = raw_val[1:-1]
        return str(item_val).lower() == compare_val.lower() if item_val is not None else False

    # 숫자 또는 변수 값 - 양쪽 모두 시도
    try:
        numeric_val = int(raw_val)
        if item_val == numeric_val:
            return True
        if str(item_val) == raw_val:
            return True
    except ValueError:
        try:
            float_val = float(raw_val)
            if item_val == float_val:
                return True
        except ValueError:
            pass

    # 문자열로 비교
    return str(item_val) == raw_val


def extract_and_verify(
    json_str: str,
    path: str,
    field_name: str,
) -> Optional[str]:
    """
    JSON에서 값을 추출하고 유효성 확인.
    유효하면 문자열로 반환, 없으면 None 반환.
    """
    value = extract_json(json_str, path)

    if value is None or str(value) in ("null", "", "None"):
        log_fail(f"{field_name} 추출 실패 (path: {path})")
        return None

    return str(value)


# ============================================
# DB 조회 함수
# ============================================

def query_db(query: str) -> str:
    """docker exec으로 MariaDB 쿼리 실행. 결과 문자열 반환."""
    cmd = [
        "docker", "exec", LC_DB_CONTAINER,
        "mysql",
        f"-u{LC_DB_USER}",
        f"-p{LC_DB_PASS}",
        f"-D{LC_DB_NAME}",
        "-N", "-s",
        "-e", query,
    ]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        log_warn("DB 쿼리 타임아웃")
        return ""
    except FileNotFoundError:
        log_warn("docker 명령어를 찾을 수 없습니다")
        return ""


# ============================================
# 스크립트 실행 결과 처리
# ============================================

def die(msg: str) -> None:
    """오류 메시지 출력 후 sys.exit(1)."""
    log_fail(msg)
    sys.exit(1)


def finish_script(script_name: str) -> None:
    """스크립트 완료 메시지 출력."""
    elapsed = int(time.time() - _script_start)
    print()
    log_ok(f"{script_name} 완료 ({elapsed}s)")
    print()


def reset_timer() -> None:
    """스크립트 타이머 재설정."""
    global _script_start
    _script_start = time.time()
