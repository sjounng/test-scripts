#!/usr/bin/env python3
"""
사전 세팅: 발행 → 사용자 → 전환 → 비밀계좌 → 전송
"""
import json
import os
import sys
import time

# 스크립트 디렉토리를 모듈 경로에 추가
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPT_DIR)

from config.config import (
    ADMIN_CLIENT_ID,
    ADMIN_CLIENT_SECRET,
    CONVERSION_AMOUNT,
    DEPOSIT_AMOUNT,
    INDV1_ADDRESS,
    INDV1_DETAIL_ADDRESS,
    INDV1_EMAIL,
    INDV1_LOGIN_ID,
    INDV1_NAME,
    INDV1_PASSWORD,
    INDV1_PHONE,
    INDV1_ZIPCODE,
    ISSUER_CLIENT_ID,
    ISSUER_CLIENT_SECRET,
    LIFECYCLE_BASE,
    MAINNET_CHAIN_ID,
    MAINNET_ENDPOINT,
    MAINNET_NAME,
    MAINNET_TYPE,
    PLATFORM_CLIENT_ID,
    PLATFORM_CLIENT_SECRET,
    RESERVE_FIAT_AMOUNT,
    RESERVE_MMF_AMOUNT,
    RESERVE_NOTE,
    SC_ISSUE_AMOUNT,
    SC_ISSUE_NOTE,
    SC_NAME,
    SC_PLANNED_DATE,
    SC_SYMBOL,
    SDS_ZK_BASE,
    TRANSFER_AMOUNT,
)
from config.lib import (
    call_api,
    check_http_ok,
    die,
    extract_and_verify,
    extract_json,
    finish_script,
    load_state,
    log_header,
    log_info,
    log_ok,
    log_step,
    query_db,
    reset_timer,
    save_var,
)


def main() -> None:
    reset_timer()
    load_state()

    # ============================================
    # 1. 발행 [최초발행]
    # ============================================
    log_header("1. 발행 [최초발행]")

    # 1-1. 메인넷 등록
    log_step("1-1) 메인넷 등록")
    body = json.dumps({
        "mainnetName": MAINNET_NAME,
        "mainnetType": MAINNET_TYPE,
        "endpoint": MAINNET_ENDPOINT,
        "chainId": MAINNET_CHAIN_ID,
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/sc/mainnets",
        PLATFORM_CLIENT_ID,
        PLATFORM_CLIENT_SECRET,
        body,
    )
    if not check_http_ok("메인넷 등록", status, response):
        die("메인넷 등록 실패")

    # 1-2. 발행 계획 등록
    log_step("1-2) 발행 계획 등록")
    body = json.dumps({
        "mainnetId": 1,
        "scName": SC_NAME,
        "scSymbol": SC_SYMBOL,
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
    if not check_http_ok("발행 계획 등록", status, response):
        die("발행 계획 등록 실패")

    sc_issue_id = extract_and_verify(response, ".data.scIssueId", "scIssueId")
    if not sc_issue_id:
        die("scIssueId 추출 실패")
    sc_id = extract_and_verify(response, ".data.scId", "scId")
    if not sc_id:
        die("scId 추출 실패")
    save_var("SC_ISSUE_ID", sc_issue_id)
    save_var("SC_ID", sc_id)

    # 1-3. 준비금 등록
    log_step("1-3) 준비금 등록")
    body = json.dumps({
        "scIssueId": sc_issue_id,
        "scId": sc_id,
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
    if not check_http_ok("준비금 등록", status, response):
        die("준비금 등록 실패")

    reserve_id = extract_and_verify(response, ".data.reserveId", "reserveId")
    if not reserve_id:
        die("reserveId 추출 실패")
    save_var("RESERVE_ID", reserve_id)

    # 1-4. 준비금 승인
    log_step("1-4) 준비금 승인")
    response, status = call_api(
        "PUT",
        f"{LIFECYCLE_BASE}/reserves/{reserve_id}/approval",
        ISSUER_CLIENT_ID,
        ISSUER_CLIENT_SECRET,
        '{"approval":"Approved"}',
    )
    if not check_http_ok("준비금 승인", status, response):
        die("준비금 승인 실패")

    # 1-5. 발행 계획 승인
    log_step("1-5) 발행 계획 승인")
    response, status = call_api(
        "PUT",
        f"{LIFECYCLE_BASE}/issuances/{sc_issue_id}/approval",
        ISSUER_CLIENT_ID,
        ISSUER_CLIENT_SECRET,
        '{"approval":"Approved"}',
    )
    if not check_http_ok("발행 계획 승인", status, response):
        die("발행 계획 승인 실패")

    # 1-6. 발행 실행
    log_step("1-6) 발행 실행")
    response, status = call_api(
        "PUT",
        f"{LIFECYCLE_BASE}/issuances/{sc_issue_id}/issue",
        ISSUER_CLIENT_ID,
        ISSUER_CLIENT_SECRET,
        "",
    )
    if not check_http_ok("발행 실행", status, response):
        die("발행 실행 실패")

    # 1-7. token_address DB 조회 (블록체인 처리 대기 - 최대 30초 폴링)
    log_step("1-7) token_address DB 조회")
    token_address = None
    for attempt in range(1, 31):
        result = query_db(
            f"SELECT token_address FROM stc_sc WHERE sc_id = {sc_id} ORDER BY created_date DESC LIMIT 1;"
        )
        if result and result.startswith("0x"):
            token_address = result
            break
        log_warn(f"token_address 대기 중... ({attempt}/30)")
        time.sleep(1)
    if not token_address:
        die(f"token_address 조회 실패 (30초 초과)")
    save_var("TOKEN_ADDRESS", token_address)
    log_ok(f"token_address: {token_address}")

    # ============================================
    # 2. 개인사용자 관리
    # ============================================
    log_header("2. 개인사용자 관리")

    # 2-1. 개인사용자 추가
    log_step("2-1) 개인사용자 추가")
    body = json.dumps({
        "loginId": INDV1_LOGIN_ID,
        "email": INDV1_EMAIL,
        "password": INDV1_PASSWORD,
        "name": INDV1_NAME,
        "phoneNumber": INDV1_PHONE,
        "address": INDV1_ADDRESS,
        "detailAddress": INDV1_DETAIL_ADDRESS,
        "zipCode": INDV1_ZIPCODE,
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/users/individuals",
        ADMIN_CLIENT_ID,
        ADMIN_CLIENT_SECRET,
        body,
    )
    if not check_http_ok("개인사용자 추가", status, response):
        die("개인사용자 추가 실패")

    user_id_indv01 = extract_and_verify(response, ".data.userId", "userId")
    if not user_id_indv01:
        die("userId 추출 실패")
    indv1_client_id = extract_and_verify(response, ".data.longTokenClientId", "longTokenClientId")
    if not indv1_client_id:
        die("longTokenClientId 추출 실패")
    indv1_client_secret = extract_and_verify(response, ".data.longToken", "longToken")
    if not indv1_client_secret:
        die("longToken 추출 실패")

    save_var("USER_ID_INDV01", user_id_indv01)
    save_var("INDV1_CLIENT_ID", indv1_client_id)
    save_var("INDV1_CLIENT_SECRET", indv1_client_secret)

    # 2-2. 개인사용자 승인
    log_step("2-2) [플랫폼] 개인사용자 승인")
    response, status = call_api(
        "PUT",
        f"{LIFECYCLE_BASE}/users/{user_id_indv01}/individuals/approval",
        PLATFORM_CLIENT_ID,
        PLATFORM_CLIENT_SECRET,
        '{"approval":"Approved"}',
    )
    if not check_http_ok("개인사용자 승인", status, response):
        die("개인사용자 승인 실패")

    # 2-3. 포트폴리오 목록 조회
    log_step("2-3) 포트폴리오 목록 조회")
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/portfolios",
        PLATFORM_CLIENT_ID,
        PLATFORM_CLIENT_SECRET,
    )
    if not check_http_ok("포트폴리오 목록 조회", status, response):
        die("포트폴리오 목록 조회 실패")

    select_path = (
        f"[.data.content[]? | select(.ownerId == {user_id_indv01} or "
        f'.ownerId == "{user_id_indv01}")] | first | .portfolioId'
    )
    portfolio_id_indv01 = extract_json(response, select_path)
    if not portfolio_id_indv01 or str(portfolio_id_indv01) == "null":
        die("포트폴리오 ID 추출 실패")
    portfolio_id_indv01 = str(portfolio_id_indv01)
    save_var("PORTFOLIO_ID_INDV01", portfolio_id_indv01)
    log_ok(f"포트폴리오 ID: {portfolio_id_indv01}")

    # 2-4. 포트폴리오 자산 조회 (원화계좌)
    log_step("2-4) 포트폴리오 자산 조회")
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/portfolios/{portfolio_id_indv01}/accounts",
        indv1_client_id,
        indv1_client_secret,
    )
    if not check_http_ok("포트폴리오 자산 조회", status, response):
        die("포트폴리오 자산 조회 실패")

    fiat_account_id = extract_json(
        response,
        '[.data.content[]? | select(.type == "Fiat")] | first | .accountId',
    )
    if not fiat_account_id or str(fiat_account_id) == "null":
        die("원화계좌 ID 추출 실패")
    fiat_account_id = str(fiat_account_id)
    save_var("FIAT_ACCOUNT_ID_INDV01", fiat_account_id)
    log_ok(f"원화계좌 ID: {fiat_account_id}")

    # ============================================
    # 3. 전환 (개인사용자)
    # ============================================
    log_header("3. 전환 (개인사용자)")

    # 3-1. 가상계좌 조회
    log_step("3-1) 입출금 가상계좌 조회")
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/accounts/fiat/virtual-and-withdrawal",
        indv1_client_id,
        indv1_client_secret,
    )
    if not check_http_ok("가상계좌 조회", status, response):
        die("가상계좌 조회 실패")

    virtual_account_number = extract_json(
        response,
        '[.data.content[]? | select(.accountType == "Virtual")] | first | .accountNumber',
    )
    if not virtual_account_number or str(virtual_account_number) == "null":
        die("가상계좌번호 추출 실패")
    virtual_account_number = str(virtual_account_number)
    save_var("VIRTUAL_ACCOUNT_NUMBER", virtual_account_number)
    log_ok(f"가상계좌: {virtual_account_number}")

    # 3-2. 원화 입금
    log_step("3-2) 원화 입금 결과 수신")
    body = json.dumps({
        "amount": DEPOSIT_AMOUNT,
        "virtualAccountNumber": virtual_account_number,
        "bankCode": "099",
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/webhook/accounts/fiat/deposit",
        indv1_client_id,
        indv1_client_secret,
        body,
    )
    if not check_http_ok("원화 입금", status, response):
        die("원화 입금 실패")

    # 3-3. 온체인 매수
    log_step("3-3) 온체인 매수 (FiatToOnchain)")
    body = json.dumps({
        "fiatAccountId": int(fiat_account_id),
        "scAccountId": None,
        "scId": int(sc_id),
        "amount": CONVERSION_AMOUNT,
        "conversionType": "FiatToOnchain",
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/conversions",
        indv1_client_id,
        indv1_client_secret,
        body,
    )
    if not check_http_ok("온체인 매수", status, response):
        die("온체인 매수 실패")

    # 3-4. 포트폴리오 재조회 (코인계좌 확인)
    log_step("3-4) 포트폴리오 재조회 (코인계좌 확인)")
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/portfolios/{portfolio_id_indv01}/accounts",
        indv1_client_id,
        indv1_client_secret,
    )
    if not check_http_ok("포트폴리오 재조회", status, response):
        die("포트폴리오 재조회 실패")

    sc_account_id = extract_json(
        response,
        '[.data.content[]? | select(.type == "Sc" or .type == "SC" or .type == "sc")] | first | .accountId',
    )
    if not sc_account_id or str(sc_account_id) == "null":
        die("코인계좌 ID 추출 실패")
    sc_account_id = str(sc_account_id)
    save_var("SC_ACCOUNT_ID_INDV01", sc_account_id)
    log_ok(f"코인계좌 ID: {sc_account_id}")

    # 3-5. 코인 계좌 조회 (지갑주소)
    log_step("3-5) 코인 계좌 조회 (지갑주소)")
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/accounts/sc/{sc_account_id}",
        indv1_client_id,
        indv1_client_secret,
    )
    if not check_http_ok("코인 계좌 조회", status, response):
        die("코인 계좌 조회 실패")

    wallet_address_indv01 = extract_json(
        response,
        ".data.scWalletAddress // .data.walletAddress",
    )
    if not wallet_address_indv01 or str(wallet_address_indv01) == "null":
        die("지갑주소 추출 실패")
    wallet_address_indv01 = str(wallet_address_indv01)
    save_var("WALLET_ADDRESS_INDV01", wallet_address_indv01)
    log_ok(f"지갑주소: {wallet_address_indv01}")

    # ============================================
    # 4. zktransfer 비밀계좌 생성
    # ============================================
    log_header("4. zktransfer 비밀계좌 생성")

    log_step("4-1) 비밀 계좌 생성")
    response, status = call_api(
        "POST",
        f"{SDS_ZK_BASE}/accounts",
        ADMIN_CLIENT_ID,
        ADMIN_CLIENT_SECRET,
    )
    if not check_http_ok("비밀계좌 생성", status, response):
        die("비밀계좌 생성 실패")

    zk_account_id_01 = extract_and_verify(response, ".data.accountId", "accountId")
    if not zk_account_id_01:
        die("accountId 추출 실패")
    save_var("ZK_ACCOUNT_ID_01", zk_account_id_01)
    log_ok(f"비밀계좌 ID: {zk_account_id_01}")

    signer_address = extract_json(response, ".data.signerAddress")
    if not signer_address or str(signer_address) == "null":
        die("signerAddress 추출 실패")
    signer_address = str(signer_address)
    save_var("SIGNER_ADDRESS", signer_address)
    save_var("WALLET_ADDRESS_INDV02", signer_address)
    log_ok(f"signerAddress: {signer_address} (→ WALLET_ADDRESS_INDV02)")

    # ============================================
    # 5. 전송 (개인사용자) - On to On
    # ============================================
    log_header("5. 전송 (개인사용자)")

    # 5-1. 코인 계좌 단건 조회
    log_step("5-1) 코인 계좌 단건 조회")
    response, status = call_api(
        "GET",
        f"{LIFECYCLE_BASE}/accounts/sc/{sc_account_id}",
        indv1_client_id,
        indv1_client_secret,
    )
    if not check_http_ok("코인 계좌 조회", status, response):
        die("코인 계좌 조회 실패")

    wallet_address_indv01 = extract_json(
        response,
        ".data.scWalletAddress // .data.walletAddress",
    )
    wallet_address_indv01 = str(wallet_address_indv01) if wallet_address_indv01 else wallet_address_indv01
    log_ok(f"발신 지갑주소: {wallet_address_indv01}")
    log_info(f"수신 지갑주소 (signerAddress): {signer_address}")

    # 5-2. 전송 (On to On)
    log_step("5-2) 전송 (On to On)")
    body = json.dumps({
        "fromScWalletAddress": wallet_address_indv01,
        "toScWalletAddress": signer_address,
        "scId": int(sc_id),
        "amount": TRANSFER_AMOUNT,
        "transferType": "OnchainToOnchain",
    })
    response, status = call_api(
        "POST",
        f"{LIFECYCLE_BASE}/transfers",
        indv1_client_id,
        indv1_client_secret,
        body,
    )
    if not check_http_ok("전송 (On to On)", status, response):
        die("전송 실패")
    log_ok(f"전송 완료: {wallet_address_indv01} → {signer_address} ({TRANSFER_AMOUNT})")

    finish_script("사전 세팅 (1~5단계)")


if __name__ == "__main__":
    main()
