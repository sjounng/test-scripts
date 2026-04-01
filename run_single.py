#!/usr/bin/env python3
"""
[테스트 실행] 단건 / 부하 테스트 통합

사용법:
  python run_single.py [단계...] [옵션]

단계 (복수 지정 가능):
  -account  -approve  -deposit  -send  -receive  -withdraw  -e2e  -all

옵션:
  --iterations N     반복 횟수 (기본: 1, 단건 모드)
  --vus N            가상 유저 수 (기본: 1)
  --duration Xs      부하 지속 시간 (기본: 없음, iterations 모드)

예시:
  python run_single.py -e2e
  python run_single.py -approve -deposit --iterations 5
  python run_single.py -all --vus 10 --duration 30s
"""
import argparse
import os
import subprocess
import sys
import time
from datetime import datetime
from typing import Optional

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPT_DIR)

from config.lib import (
    finish_script,
    log_fail,
    log_header,
    log_info,
    log_ok,
    log_step,
    log_warn,
    read_state_var,
    reset_timer,
)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="단건 / 부하 테스트 통합 실행",
        add_help=True,
    )
    parser.add_argument("-account", action="store_true", help="account API 테스트")
    parser.add_argument("-approve", action="store_true", help="approve API 테스트")
    parser.add_argument("-deposit", action="store_true", help="deposit API 테스트")
    parser.add_argument("-send", action="store_true", help="send API 테스트")
    parser.add_argument("-receive", action="store_true", help="receive API 테스트")
    parser.add_argument("-withdraw", action="store_true", help="withdraw API 테스트")
    parser.add_argument("-e2e", action="store_true", help="e2e 테스트")
    parser.add_argument("-all", action="store_true", help="모든 API 테스트")
    parser.add_argument("--iterations", type=int, default=1, metavar="N", help="반복 횟수 (기본: 1)")
    parser.add_argument("--vus", type=int, default=1, metavar="N", help="가상 유저 수 (기본: 1)")
    parser.add_argument("--duration", type=str, default="", metavar="Xs", help="부하 지속 시간 (예: 30s)")
    return parser.parse_args()


def main() -> None:
    reset_timer()
    args = _parse_args()

    # .state 파일 확인
    state_file = os.path.join(_SCRIPT_DIR, ".state")
    if not os.path.isfile(state_file):
        log_warn(".state 파일이 없습니다. 환경 변수가 비어있을 수 있습니다.")

    token_address = read_state_var("TOKEN_ADDRESS")
    zk_account_id_01 = read_state_var("ZK_ACCOUNT_ID_01")
    zk_account_id_02 = read_state_var("ZK_ACCOUNT_ID_02")
    signer_address = read_state_var("SIGNER_ADDRESS")

    # 실행 API 목록 결정
    all_apis = ["account", "approve", "deposit", "send", "receive", "withdraw", "e2e"]
    apis: list[str] = []

    if args.__dict__.get("all"):
        apis = all_apis[:]
    else:
        for api in ["account", "approve", "deposit", "send", "receive", "withdraw", "e2e"]:
            if args.__dict__.get(api):
                apis.append(api)

    if not apis:
        apis = ["e2e"]

    # 모드 설명
    if args.duration:
        mode_desc = f"부하 테스트 | VUs: {args.vus} | Duration: {args.duration}"
    else:
        mode_desc = f"단건 테스트 | 반복: {args.iterations}회 | VUs: {args.vus}"

    # 로그 디렉토리 및 파일 설정
    log_dir = os.path.join(_SCRIPT_DIR, "logs")
    os.makedirs(log_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    apis_str = "_".join(apis)
    log_file = os.path.join(log_dir, f"{timestamp}_{apis_str}_vus{args.vus}.log")

    log_header(f"{mode_desc} | 대상: {' '.join(apis)}")
    log_info(f"로그 파일: {log_file}")

    with open(log_file, "a", encoding="utf-8") as lf:
        lf.write("========================================\n")
        lf.write(f"  실행 시각 : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        lf.write(f"  대상      : {' '.join(apis)}\n")
        lf.write(f"  VUs       : {args.vus}\n")
        if args.duration:
            lf.write(f"  Duration  : {args.duration}\n")
        else:
            lf.write(f"  Iterations: {args.iterations}\n")
        lf.write("========================================\n")

    loadtest_js = os.path.join(_SCRIPT_DIR, "loadtest.js")

    for api in apis:
        log_step(f"{api} 측정 중...")
        start_ts = time.time()

        k6_cmd = [
            "k6", "run",
            "-e", "SDS_ZK_BASE=http://localhost:8080/rest/zktransfer",
            "-e", f"TOKEN_ADDRESS={token_address}",
            "-e", f"ZK_ACCOUNT_ID_01={zk_account_id_01}",
            "-e", f"ZK_ACCOUNT_ID_02={zk_account_id_02}",
            "-e", f"SIGNER_ADDRESS={signer_address}",
            "-e", f"TEST_MODE={api}",
            "--vus", str(args.vus),
        ]

        if args.duration:
            k6_cmd += ["--duration", args.duration]
        else:
            k6_cmd += ["--iterations", str(args.iterations)]

        k6_cmd.append(loadtest_js)

        with open(log_file, "a", encoding="utf-8") as lf:
            lf.write(f"\n---- [{api}] ----\n")

        exit_code = _run_k6_tee(k6_cmd, log_file)
        elapsed = int(time.time() - start_ts)

        if exit_code == 0:
            log_ok(f"{api} 완료 ({elapsed}s)")
            _append_log(log_file, f"[PASS] {api} 완료 ({elapsed}s)")
        else:
            log_fail(f"{api} 실패 ({elapsed}s)")
            _append_log(log_file, f"[FAIL] {api} 실패 ({elapsed}s)")

    finish_script("테스트")
    log_info(f"로그 저장됨: {log_file}")


def _run_k6_tee(cmd: list[str], log_file: str) -> int:
    """k6를 실행하면서 stdout을 터미널과 로그 파일에 동시 기록. exit code 반환."""
    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        with open(log_file, "a", encoding="utf-8") as lf:
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                lf.write(line)
        process.wait()
        return process.returncode
    except FileNotFoundError:
        log_fail("k6 명령어를 찾을 수 없습니다. k6가 설치되어 있는지 확인하세요.")
        return 1


def _append_log(log_file: str, msg: str) -> None:
    with open(log_file, "a", encoding="utf-8") as lf:
        lf.write(f"{msg}\n")


if __name__ == "__main__":
    main()
