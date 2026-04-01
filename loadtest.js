import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const SDS_ZK_BASE = __ENV.SDS_ZK_BASE || 'http://localhost:8080/rest/zktransfer';
const SDS_CLIENT_ID = __ENV.SDS_CLIENT_ID || 'ADMIN_TOKEN';
const SDS_CLIENT_SECRET = __ENV.SDS_CLIENT_SECRET || '41b5732026d04f9eb73b06021435ebb8';

// 단건 테스트 폴백용 (e2e 모드에서 ACCOUNTS_FILE 없을 때)
const TOKEN_ADDRESS = __ENV.TOKEN_ADDRESS || '';
const ZK_ACCOUNT_ID_01 = __ENV.ZK_ACCOUNT_ID_01 || '';
const SIGNER_ADDRESS = __ENV.SIGNER_ADDRESS || '';
const MODE = __ENV.TEST_MODE || 'e2e';
const PHASE_LEN = parseFloat(__ENV.PHASE_LEN || '15') * 1000; // ms per barrier phase

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

const accountCount = new Counter('api_account_count');
const approveCount = new Counter('api_approve_count');
const depositCount = new Counter('api_deposit_count');
const sendCount    = new Counter('api_send_count');
const receiveCount = new Counter('api_receive_count');
const withdrawCount = new Counter('api_withdraw_count');

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

function doAccount(trackMetric = true) {
    const res = http.post(`${SDS_ZK_BASE}/accounts`, null, {
        headers: sdsHeaders(),
        tags: { api: 'account' },
    });
    if (trackMetric) {
        accountDuration.add(res.timings.duration);
        accountCount.add(1);
    }
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

function doApprove(accountId, tokenAddress, trackMetric = true) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/approve`, JSON.stringify({
        accountId,
        tokenAddress,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'approve' } });
    if (trackMetric) {
        approveDuration.add(res.timings.duration);
        approveCount.add(1);
    }
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

function doDeposit(accountId, tokenAddress, trackMetric = true) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/deposit`, JSON.stringify({
        fromAccountId: accountId,
        tokenAddress,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'deposit' } });
    if (trackMetric) {
        depositDuration.add(res.timings.duration);
        depositCount.add(1);
    }
    check(res, { '[deposit] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('deposit', res);
        throw new Error('deposit 실패');
    }
}

function doSend(fromAccountId, toAccountId, tokenAddress, trackMetric = true) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/send`, JSON.stringify({
        fromAccountId,
        toAccountId,
        tokenAddress,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'send' } });
    if (trackMetric) {
        sendDuration.add(res.timings.duration);
        sendCount.add(1);
    }
    check(res, { '[send] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('send', res);
        throw new Error('send 실패');
    }
    return res.json('data.txHash');
}

function doReceive(toAccountId, txHash, tokenAddress, trackMetric = true) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/receive`, JSON.stringify({
        toAccountId,
        tokenAddress,
        noteTxHash: txHash,
    }), { headers: sdsHeaders(), tags: { api: 'receive' } });
    if (trackMetric) {
        receiveDuration.add(res.timings.duration);
        receiveCount.add(1);
    }
    check(res, { '[receive] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('receive', res);
        throw new Error('receive 실패');
    }
}

function doWithdraw(fromAccountId, eoaRecv, tokenAddress, trackMetric = true) {
    const res = http.post(`${SDS_ZK_BASE}/transfer/withdraw`, JSON.stringify({
        fromAccountId,
        eoaRecv,
        tokenAddress,
        amount: 10,
    }), { headers: sdsHeaders(), tags: { api: 'withdraw' } });
    if (trackMetric) {
        withdrawDuration.add(res.timings.duration);
        withdrawCount.add(1);
    }
    check(res, { '[withdraw] status 200': bodyOk });
    if (!bodyOk(res)) {
        logFail('withdraw', res);
        throw new Error('withdraw 실패');
    }
}

// --- 풀 사이클: approve → deposit → send → receive → withdraw ---
function runFullCycle(sender, label) {
    const tokenAddress = sender.tokenAddress;
    // 미리 생성된 receiver가 있으면 사용, 없으면 즉석 생성
    let acct2 = sender.receiverAccountId
        ? { accountId: sender.receiverAccountId, signerAddress: sender.receiverSignerAddress }
        : null;
    try {
        console.log(`[${label}] 1/6 approve`);
        doApprove(sender.accountId, tokenAddress);

        console.log(`[${label}] 2/6 deposit`);
        doDeposit(sender.accountId, tokenAddress);

        if (!acct2) {
            console.log(`[${label}] 3/6 account`);
            acct2 = doAccount();
            console.log(`[${label}] acct2=${acct2.accountId}`);
        } else {
            console.log(`[${label}] 3/6 account (미리 생성된 receiver 사용)`);
        }

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

function getSender() {
    return e2eAccounts.length > 0
        ? e2eAccounts[(__VU - 1) % e2eAccounts.length]
        : { accountId: ZK_ACCOUNT_ID_01, signerAddress: SIGNER_ADDRESS, tokenAddress: TOKEN_ADDRESS };
}

function runMode(sender, label) {
    const tokenAddress = sender.tokenAddress;

    switch (MODE) {
    case 'account':
        console.log(`[${label}] account`);
        doAccount();
        break;
    case 'approve':
        console.log(`[${label}] approve`);
        doApprove(sender.accountId, tokenAddress);
        break;
    case 'deposit':
        console.log(`[${label}] deposit`);
        doApprove(sender.accountId, tokenAddress, false);
        doDeposit(sender.accountId, tokenAddress);
        break;
    case 'send': {
        console.log(`[${label}] send`);
        // 사전 충전된 계정이 없으면 폴백으로 approve/deposit 실행
        if (!sender.receiverAccountId) {
            doApprove(sender.accountId, tokenAddress, false);
            doDeposit(sender.accountId, tokenAddress, false);
        }
        const receiverS = sender.receiverAccountId || doAccount(false).accountId;
        doSend(sender.accountId, receiverS, tokenAddress);
        break;
    }
    case 'receive': {
        console.log(`[${label}] receive`);
        if (!sender.receiverAccountId) {
            doApprove(sender.accountId, tokenAddress, false);
            doDeposit(sender.accountId, tokenAddress, false);
        }
        const recvId = sender.receiverAccountId || (() => { const r = doAccount(false); return r.accountId; })();
        const txHash = doSend(sender.accountId, recvId, tokenAddress, false);
        doReceive(recvId, txHash, tokenAddress);
        break;
    }
    case 'withdraw': {
        console.log(`[${label}] withdraw`);
        // 사전 충전된 계정이면 sender에서 바로 출금
        if (sender.receiverAccountId) {
            doWithdraw(sender.accountId, sender.signerAddress, tokenAddress);
        } else {
            doApprove(sender.accountId, tokenAddress, false);
            doDeposit(sender.accountId, tokenAddress, false);
            const r = doAccount(false);
            const txHash2 = doSend(sender.accountId, r.accountId, tokenAddress, false);
            doReceive(r.accountId, txHash2, tokenAddress, false);
            doWithdraw(r.accountId, r.signerAddress, tokenAddress);
        }
        break;
    }
    case 'e2e':
        runFullCycle(sender, label);
        break;
    case 'barrier': {
        const recvId = sender.receiverAccountId;
        const recvSigner = sender.receiverSignerAddress;
        const baseTime = barrierStart;

        function waitForPhase(phase) {
            const target = baseTime + phase * PHASE_LEN;
            const remaining = (target - Date.now()) / 1000;
            if (remaining > 0) sleep(remaining);
        }

        // Phase 0: approve — 모든 VU 동시 시작
        waitForPhase(0);
        console.log(`[${label}] phase approve`);
        doApprove(sender.accountId, tokenAddress);

        // Phase 1: deposit
        waitForPhase(1);
        console.log(`[${label}] phase deposit`);
        doDeposit(sender.accountId, tokenAddress);

        // Phase 2: account
        waitForPhase(2);
        console.log(`[${label}] phase account`);
        doAccount();

        // Phase 3: send
        waitForPhase(3);
        console.log(`[${label}] phase send`);
        const txHash = doSend(sender.accountId, recvId, tokenAddress);

        // Phase 4: receive
        waitForPhase(4);
        console.log(`[${label}] phase receive`);
        doReceive(recvId, txHash, tokenAddress);

        // Phase 5: withdraw
        waitForPhase(5);
        console.log(`[${label}] phase withdraw`);
        doWithdraw(recvId, recvSigner, tokenAddress);
        break;
    }
    default:
        throw new Error(`지원하지 않는 TEST_MODE: ${MODE}`);
    }
}

// --- 메인 ---
let barrierStart = 0;

export function setup() {
    return { barrierStart: Date.now() };
}

export default function (data) {
    barrierStart = data.barrierStart;
    const sender = getSender();
    runMode(sender, `${MODE}:VU=${__VU}`);
}
