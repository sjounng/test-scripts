# ZKTransfer Test Scripts

## 사전 요구사항

- `bash`, `curl`, `jq`, `k6` 설치
- Lifecycle API (`localhost:8080`), ZKTransfer Core API (`localhost:9080`) 실행 중
- MariaDB Docker 컨테이너 (`stc-mariadb`) 실행 중

---

## 파일 구조

| 파일 | 설명 |
|------|------|
| `config.sh` | 환경 변수 및 테스트 데이터 설정 |
| `lib.sh` | 공통 함수 (로그, API 호출, 상태 파일 관리) |
| `setup.sh` | 전체 사전 세팅 (발행 → 사용자 → 전환 → 비밀계좌 → 전송) |
| `run_single.sh` | 단건 / 부하 테스트 실행 |
| `prepare_accounts.sh` | 부하 테스트용 다중 계좌 생성 |
| `loadtest.js` | k6 테스트 스크립트 |

---

## 실행 순서

### 1. 사전 세팅

```bash
./setup.sh
```

`setup.sh`가 완료되면 `.state` 파일에 테스트에 필요한 상태값이 저장됩니다.

setup.sh 단계:

| 단계 | 내용 |
|------|------|
| 1-1 | 메인넷 등록 |
| 1-2 | 발행 계획 등록 |
| 1-3 | 준비금 등록 |
| 1-4 | 준비금 승인 |
| 1-5 | 발행 계획 승인 |
| 1-6 | 발행 실행 |
| 1-7 | token_address DB 조회 |
| 2-1 | 개인사용자 추가 |
| 2-2 | 개인사용자 승인 |
| 2-3 | 포트폴리오 목록 조회 |
| 2-4 | 포트폴리오 자산 조회 |
| 3-1 | 입출금 가상계좌 조회 |
| 3-2 | 원화 입금 결과 수신 |
| 3-3 | 온체인 매수 (FiatToOnchain) |
| 3-4 | 포트폴리오 재조회 |
| 3-5 | 코인 계좌 조회 (지갑주소) |
| 4-1 | 비밀 계좌 생성 |
| 5-1 | 코인 계좌 단건 조회 |
| 5-2 | 전송 (On to On) |

### 2. 테스트 실행

```bash
./run_single.sh [단계...] [옵션]
```

#### 단계 플래그 (복수 지정 가능)

| 플래그 | 설명 |
|--------|------|
| `-account` | 비밀 계좌 생성 |
| `-approve` | 토큰 approve |
| `-deposit` | 비밀 계좌 입금 |
| `-send` | 비밀 전송 |
| `-receive` | 수신 확인 |
| `-withdraw` | 출금 |
| `-e2e` | 전체 플로우 (기본값) |
| `-all` | 모든 단계 순차 실행 |

#### 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--iterations N` | 1 | 반복 횟수 |
| `--vus N` | 1 | 가상 유저 수 |
| `--duration Xs` | 없음 | 부하 지속 시간 (`--iterations` 대신 사용) |

#### 예시

```bash
# 단건 e2e (기본)
./run_single.sh

# 특정 단계만
./run_single.sh -approve
./run_single.sh -approve -deposit

# 반복 실행
./run_single.sh -e2e --iterations 10

# 부하 테스트 (VU 10명, 30초)
./run_single.sh -e2e --vus 10 --duration 30s

# 전체 단계 부하 테스트
./run_single.sh -all --vus 5 --duration 60s
```

### 3. 부하 테스트용 다중 계좌 준비 (선택)

```bash
./prepare_accounts.sh [계좌수]   # 기본: 30
```

`setup.sh` 완료 후 실행. 지정한 수만큼 독립 계좌를 생성하고 각 계좌에 10,000 토큰을 충전합니다.

---

## 상태 파일 (.state)

`setup.sh` 실행 시 자동 생성되며, `run_single.sh`가 이를 참조합니다.

```
RUN_ID=...
SC_ID=...
SC_ISSUE_ID=...
TOKEN_ADDRESS=...
ZK_ACCOUNT_ID_01=...
ZK_ACCOUNT_ID_02=...
WALLET_ADDRESS_INDV01=...
SIGNER_ADDRESS=...
```

> 새로운 테스트 환경을 구성하려면 `.state` 파일을 삭제하고 `setup.sh`를 다시 실행하세요.

---

## 주요 환경 변수 (`config.sh`)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `LIFECYCLE_BASE` | `http://localhost:8080/rest/v1/dlt/stc` | Lifecycle API |
| `ZK_BASE` | `http://localhost:9080/v1` | ZKTransfer Core API |
| `MAINNET_NAME` | `SDSMainNet_{RUN_ID}` | 메인넷 이름 (실행마다 고유) |
| `MAINNET_CHAIN_ID` | `{RUN_ID}` | 체인 ID (실행마다 고유) |
| `SC_NAME` | `MySC_{RUN_ID}` | 스마트 컨트랙트 이름 |
| `SC_SYMBOL` | `MS{SHORT_ID}` | 토큰 심볼 |
