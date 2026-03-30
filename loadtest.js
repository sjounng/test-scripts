import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

// sds25-sc-lifecycle (8080) — 모든 zktransfer API 경유
const SDS_ZK_BASE = __ENV.SDS_ZK_BASE || 'http://localhost:8080/rest/zktransfer';
const SDS_CLIENT_ID = __ENV.SDS_CLIENT_ID || 'ADMIN_TOKEN';
const SDS_CLIENT_SECRET = __ENV.SDS_CLIENT_SECRET || '41b5732026d04f9eb73b06021435ebb8';

const TOKEN_ADDRESS = __ENV.TOKEN_ADDRESS || '';
const ZK_ACCOUNT_ID_01 = __ENV.ZK_ACCOUNT_ID_01 || '';
const ZK_ACCOUNT_ID_02 = __ENV.ZK_ACCOUNT_ID_02 || '';
const SIGNER_ADDRESS = __ENV.SIGNER_ADDRESS || '';
const MODE = __ENV.TEST_MODE || 'e2e';

// API별 커스텀 메트릭
const accountDuration = new Trend('api_account', true);
const approveDuration = new Trend('api_approve', true);
const depositDuration = new Trend('api_deposit', true);
const sendDuration = new Trend('api_send', true);
const receiveDuration = new Trend('api_receive', true);
const withdrawDuration = new Trend('api_withdraw', true);

export const options = {
    summaryTrendStats: ['avg', 'min', 'max', 'p(95)', 'p(99)'],
};

function sdsHeaders() {
    return {
        'Content-Type': 'application/json',
        'X-Lego-Client-Id': SDS_CLIENT_ID,
        'X-Lego-Client-Secret': SDS_CLIENT_SECRET,
    };
}

// --- 개별 API 함수 ---

function doAccount() {
    const res = http.post(`${SDS_ZK_BASE}/accounts`, null, {
        headers: sdsHeaders(),
        tags: { api: 'account' },
    });
    accountDuration.add(res.timings.duration);
    check(res, { '[account] 20X': (r) => r.status >= 200 && r.status < 300 });
    if (res.status >= 200 && res.status < 300) {
        return {
            accountId: res.json('data.accountId'),
            signerAddress: res.json('data.signerAddress'),
        };
    }
    return null;
}

function doApprove(accountId) {
    const payload = JSON.stringify({
        accountId: accountId,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    });
    const res = http.post(`${SDS_ZK_BASE}/transfer/approve`, payload, {
        headers: sdsHeaders(),
        tags: { api: 'approve' },
    });
    approveDuration.add(res.timings.duration);
    check(res, { '[approve] 20X': (r) => r.status >= 200 && r.status < 300 });
}

function doDeposit(accountId) {
    const payload = JSON.stringify({
        fromAccountId: accountId,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    });
    const res = http.post(`${SDS_ZK_BASE}/transfer/deposit`, payload, {
        headers: sdsHeaders(),
        tags: { api: 'deposit' },
    });
    depositDuration.add(res.timings.duration);
    check(res, { '[deposit] 20X': (r) => r.status >= 200 && r.status < 300 });
}

function doSend(fromAccountId, toAccountId) {
    const payload = JSON.stringify({
        fromAccountId: fromAccountId,
        toAccountId: toAccountId,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    });
    const res = http.post(`${SDS_ZK_BASE}/transfer/send`, payload, {
        headers: sdsHeaders(),
        tags: { api: 'send' },
    });
    sendDuration.add(res.timings.duration);
    check(res, { '[send] 20X': (r) => r.status >= 200 && r.status < 300 });
    if (res.status >= 200 && res.status < 300) {
        const txHash = res.json('data.txHash');
        if (!txHash) {
            console.warn(`[SEND 이상] 20X이지만 txHash 없음: ${res.body}`);
        }
        return txHash;
    }
    return null;
}

function doReceive(toAccountId, txHash) {
    const payload = JSON.stringify({
        toAccountId: toAccountId,
        tokenAddress: TOKEN_ADDRESS,
        noteTxHash: txHash,
    });
    const res = http.post(`${SDS_ZK_BASE}/transfer/receive`, payload, {
        headers: sdsHeaders(),
        tags: { api: 'receive' },
    });
    receiveDuration.add(res.timings.duration);
    check(res, { '[receive] 20X': (r) => r.status >= 200 && r.status < 300 });
}

function doWithdraw(fromAccountId, eoaRecv) {
    const payload = JSON.stringify({
        fromAccountId: fromAccountId,
        eoaRecv: eoaRecv,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    });
    const res = http.post(`${SDS_ZK_BASE}/transfer/withdraw`, payload, {
        headers: sdsHeaders(),
        tags: { api: 'withdraw' },
    });
    withdrawDuration.add(res.timings.duration);
    check(res, { '[withdraw] 20X': (r) => r.status >= 200 && r.status < 300 });
}

// --- 메인 ---

export default function () {

    // 개별 API 모드: .state의 기존 계좌로 해당 API만 측정
    if (MODE === 'account') {
        doAccount();
        return;
    }

    if (MODE === 'approve') {
        doApprove(ZK_ACCOUNT_ID_01);
        return;
    }

    if (MODE === 'deposit') {
        doDeposit(ZK_ACCOUNT_ID_01);
        return;
    }

    if (MODE === 'send') {
        doSend(ZK_ACCOUNT_ID_01, ZK_ACCOUNT_ID_02);
        return;
    }

    if (MODE === 'receive') {
        const txHash = doSend(ZK_ACCOUNT_ID_01, ZK_ACCOUNT_ID_02);
        if (txHash) doReceive(ZK_ACCOUNT_ID_02, txHash);
        return;
    }

    if (MODE === 'withdraw') {
        doWithdraw(ZK_ACCOUNT_ID_01, SIGNER_ADDRESS);
        return;
    }

    // E2E: 전체 파이프라인 (매 iteration마다 신규 계좌 생성)
    if (MODE === 'e2e') {
        const acct1 = doAccount();
        if (!acct1) return;

        doApprove(acct1.accountId);
        doDeposit(acct1.accountId);

        const acct2 = doAccount();
        if (!acct2) return;
        const txHash = doSend(acct1.accountId, acct2.accountId);

        if (txHash) doReceive(acct2.accountId, txHash);
        doWithdraw(acct2.accountId, acct2.signerAddress);
    }
}
