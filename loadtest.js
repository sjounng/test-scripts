import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const SDS_ZK_BASE = __ENV.SDS_ZK_BASE || 'http://localhost:8080/rest/zktransfer';
const SDS_CLIENT_ID = __ENV.SDS_CLIENT_ID || 'ADMIN_TOKEN';
const SDS_CLIENT_SECRET = __ENV.SDS_CLIENT_SECRET || '41b5732026d04f9eb73b06021435ebb8';

// 단건 테스트 폴백용 (e2e 모드에서 ACCOUNTS_FILE 없을 때)
const TOKEN_ADDRESS = __ENV.TOKEN_ADDRESS || '';
const ZK_ACCOUNT_ID_01 = __ENV.ZK_ACCOUNT_ID_01 || '';
const SIGNER_ADDRESS = __ENV.SIGNER_ADDRESS || '';
const MODE = __ENV.TEST_MODE || 'e2e';

// VU별 계정 목록: [{accountId, signerAddress, tokenAddress}, ...]
const ACCOUNTS_FILE = __ENV.ACCOUNTS_FILE || '';
const e2eAccounts = ACCOUNTS_FILE ? JSON.parse(open(ACCOUNTS_FILE)) : [];

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

// --- 개별 API 함수 (tokenAddress를 인자로 받음) ---

function doAccount() {
    const res = http.post(`${SDS_ZK_BASE}/accounts`, null, {
        headers: sdsHeaders(),
        tags: { api: 'account' },
    });
    accountDuration.add(res.timings.duration);
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

function doApprove(accountId, tokenAddress) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/approve`, JSON.stringify({
        accountId,
        tokenAddress,
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

function doDeposit(accountId, tokenAddress) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/deposit`, JSON.stringify({
        fromAccountId: accountId,
        tokenAddress,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'deposit' } });
    depositDuration.add(res.timings.duration);
    check(res, { '[deposit] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('deposit', res);
        throw new Error('deposit 실패');
    }
}

function doSend(fromAccountId, toAccountId, tokenAddress) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/send`, JSON.stringify({
        fromAccountId,
        toAccountId,
        tokenAddress,
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

function doReceive(toAccountId, txHash, tokenAddress) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/receive`, JSON.stringify({
        toAccountId,
        tokenAddress,
        noteTxHash: txHash,
    }), { headers: sdsHeaders(), tags: { api: 'receive' } });
    receiveDuration.add(res.timings.duration);
    check(res, { '[receive] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('receive', res);
        throw new Error('receive 실패');
    }
}

function doWithdraw(fromAccountId, eoaRecv, tokenAddress) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/withdraw`, JSON.stringify({
        fromAccountId,
        eoaRecv,
        tokenAddress,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'withdraw' } });
    withdrawDuration.add(res.timings.duration);
    check(res, { '[withdraw] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('withdraw', res);
        throw new Error('withdraw 실패');
    }
}

// --- 풀 사이클: approve → deposit → account(acct2) → send → receive → withdraw ---
function runFullCycle(sender, label) {
    const tokenAddress = sender.tokenAddress;
    let acct2;
    try {
        console.log(`[${label}] 1/6 approve`);
        doApprove(sender.accountId, tokenAddress);

        console.log(`[${label}] 2/6 deposit`);
        doDeposit(sender.accountId, tokenAddress);

        console.log(`[${label}] 3/6 account`);
        acct2 = doAccount();
        console.log(`[${label}] acct2=${acct2.accountId}`);

        console.log(`[${label}] 4/6 send`);
        const txHash = doSend(sender.accountId, acct2.accountId, tokenAddress);
        console.log(`[${label}] txHash=${txHash}`);

        console.log(`[${label}] 5/6 receive`);
        doReceive(acct2.accountId, txHash, tokenAddress);
    } catch (e) {
        console.error(`[${label}] 중단: ${e.message}`);
    } finally {
        if (acct2) {
            console.log(`[${label}] 6/6 withdraw`);
            try { doWithdraw(acct2.accountId, acct2.signerAddress, tokenAddress); } catch { }
        }
    }
}

// --- 메인 ---
export default function () {
    if (MODE === 'e2e') {
        const sender = e2eAccounts.length > 0
            ? e2eAccounts[(__VU - 1) % e2eAccounts.length]
            : { accountId: ZK_ACCOUNT_ID_01, signerAddress: SIGNER_ADDRESS, tokenAddress: TOKEN_ADDRESS };

        runFullCycle(sender, `e2e:VU=${__VU}`);
    }
}
