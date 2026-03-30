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
const sendDuration    = new Trend('api_send', true);
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

function bodyOk(r) {
    try { return r.json('status') === 200; } catch { return false; }
}

function logFail(api, res) {
    console.error(`\n[${api}] FAIL`);
    console.error(`  HTTP  : ${res.status}`);
    try {
        const body = res.json();
        console.error(`  status: ${body.status}`);
        if (body.error) console.error(`  error : ${JSON.stringify(body.error)}`);
        if (body.data)  console.error(`  data  : ${JSON.stringify(body.data)}`);
    } catch {
        console.error(`  body  : ${res.body}`);
    }
}

// --- 개별 API 함수 (실패 시 throw) ---

function doAccount(measure = false) {
    const res = http.post(`${SDS_ZK_BASE}/accounts`, null, {
        headers: sdsHeaders(),
        tags: { api: 'account' },
    });
    if (measure) accountDuration.add(res.timings.duration);
    check(res, { '[account] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('account', res);
        throw new Error('account 실패');
    }
    return {
        accountId: res.json('data.accountId'),
        signerAddress: res.json('data.signerAddress'),
    };
}

function doApprove(accountId) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/approve`, JSON.stringify({
        accountId,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'approve' } });
    approveDuration.add(res.timings.duration);
    check(res, { '[approve] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('approve', res);
        throw new Error('approve 실패');
    }
    const txHash = res.json('data.txHash');
    if (!txHash) {
        logFail('approve', res);
        throw new Error('approve tx 미확정 (txHash 없음)');
    }
    return txHash;
}

function doDeposit(accountId) {
    const payload = JSON.stringify({
        fromAccountId: accountId,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    });
    const headers = sdsHeaders();
    console.log(`\n[deposit] REQUEST`);
    console.log(`  URL    : POST ${SDS_ZK_BASE}/transfer/deposit`);
    console.log(`  headers: ${JSON.stringify(headers)}`);
    console.log(`  body   : ${payload}`);

    const res = http.post(`${SDS_ZK_BASE}/transfer/deposit`, payload, {
        headers,
        tags: { api: 'deposit' },
    });
    console.log(`[deposit] RESPONSE`);
    console.log(`  HTTP   : ${res.status}`);
    console.log(`  body   : ${res.body}`);
    depositDuration.add(res.timings.duration);
    check(res, { '[deposit] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('deposit', res);
        throw new Error('deposit 실패');
    }
}

function doSend(fromAccountId, toAccountId) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/send`, JSON.stringify({
        fromAccountId,
        toAccountId,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'send' } });
    sendDuration.add(res.timings.duration);
    check(res, { '[send] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('send', res);
        throw new Error('send 실패');
    }
    return res.json('data.txHash');
}

function doReceive(toAccountId, txHash) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/receive`, JSON.stringify({
        toAccountId,
        tokenAddress: TOKEN_ADDRESS,
        noteTxHash: txHash,
    }), { headers: sdsHeaders(), tags: { api: 'receive' } });
    receiveDuration.add(res.timings.duration);
    check(res, { '[receive] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('receive', res);
        throw new Error('receive 실패');
    }
}

function doWithdraw(fromAccountId, eoaRecv) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/withdraw`, JSON.stringify({
        fromAccountId,
        eoaRecv,
        tokenAddress: TOKEN_ADDRESS,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'withdraw' } });
    withdrawDuration.add(res.timings.duration);
    check(res, { '[withdraw] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('withdraw', res);
        throw new Error('withdraw 실패');
    }
}

// --- 메인 ---

export default function () {

    if (MODE === 'account') {
        try { doAccount(true); } catch { /* logFail에서 출력 */ }
        return;
    }

    if (MODE === 'approve') {
        try { doApprove(ZK_ACCOUNT_ID_01); } catch { }
        return;
    }

    if (MODE === 'deposit') {
        try { doDeposit(ZK_ACCOUNT_ID_01); } catch { }
        return;
    }

    if (MODE === 'send') {
        try { doSend(ZK_ACCOUNT_ID_01, ZK_ACCOUNT_ID_02); } catch { }
        return;
    }

    if (MODE === 'receive') {
        try {
            const txHash = doSend(ZK_ACCOUNT_ID_01, ZK_ACCOUNT_ID_02);
            doReceive(ZK_ACCOUNT_ID_02, txHash);
        } catch { }
        return;
    }

    if (MODE === 'withdraw') {
        try { doWithdraw(ZK_ACCOUNT_ID_02, SIGNER_ADDRESS); } catch { }
        return;
    }

    // E2E: 전체 파이프라인
    // acct1(ZK_ACCOUNT_ID_01)은 setup 때 생성된 계좌 사용
    if (MODE === 'e2e') {
        let acct2;
        try {
            doApprove(ZK_ACCOUNT_ID_01);
            doDeposit(ZK_ACCOUNT_ID_01);
            acct2 = doAccount(true);    // 비밀계좌생성2 (#16)
            const txHash = doSend(ZK_ACCOUNT_ID_01, acct2.accountId);
            doReceive(acct2.accountId, txHash);
        } catch (e) {
            console.error(`[e2e] 중단: ${e.message}`);
        } finally {
            if (acct2) {
                try { doWithdraw(acct2.accountId, acct2.signerAddress); } catch { }
            }
        }
    }
}
