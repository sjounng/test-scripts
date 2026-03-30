# ZKTransfer Test Scripts

ZKTransfer 성능 평가 및 기능 검증을 위한 테스트 스크립트 모음.

---
테스트 법:
brew install k6
./setup.sh
./run_eval.sh
순서대로 실행.

---

## 사전 요구사항

- `bash`, `curl`, `jq`, `k6` 설치
- SDS-lifecycle (`localhost:8080`) 실행 중
- MariaDB Docker 컨테이너 (`stc-mariadb`) 실행 중

---

## 파일 구조

```
test-scripts/
├── config/
│   ├── config.sh        # 환경 변수 및 테스트 데이터 설정
│   └── lib.sh           # 공통 함수 (로그, API 호출, 상태 파일 관리)
├── setup.sh             # 사전 세팅 (발행 → 사용자 → 전환 → 비밀계좌 → 전송)
├── run_eval.sh          # 성능 평가 통합 실행 (단건 / 다중 / E2E)
├── run_single.sh        # 단건 / 부하 테스트 직접 실행
├── loadtest.js          # k6 테스트 스크립트
├── accounts.json        # 부하 테스트용 계정 목록 (자동 생성)
└── logs/                # 결과 파일 저장 디렉토리
```

---

## 실행 순서

### 1단계: 사전 세팅

```bash
./setup.sh
```

Lifecycle API와 ZKTransfer API를 통해 테스트 환경을 구성합니다.
완료되면 `.state` 파일에 이후 테스트에 필요한 상태값이 저장됩니다.

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
| 4-1 | ZK 비밀 계좌 생성 |
| 5-1 | 코인 계좌 단건 조회 |
| 5-2 | 전송 (On to On) |

---

### 2단계: 성능 평가 실행 (`run_eval.sh`)

`run_eval.sh`는 단건 / 다중 / E2E 세 가지 테스트 섹션을 통합 실행하고, 결과를 `logs/cpu_<N>_<timestamp>.md` 파일로 저장합니다.

```bash
./run_eval.sh <CPU_CORES> [SECTION]
```

| 인자 | 필수 | 설명 |
|------|------|------|
| `CPU_CORES` | 필수 | 서버 CPU 코어 수 (결과 파일 식별용) |
| `SECTION` | 선택 | `single` \| `multi` \| `e2e` \| `all` (기본: `all`) |

#### 예시

```bash
# 전체 테스트 (단건 + 다중 + E2E)
./run_eval.sh 8

# 단건 테스트만
./run_eval.sh 8 single

# 다중 테스트만
./run_eval.sh 8 multi

# E2E 테스트만
./run_eval.sh 8 e2e

# 다른 CPU 환경
./run_eval.sh 16
./run_eval.sh 24 single
```

#### 테스트 섹션 설명

| 섹션 | 내용 | 기본 설정 |
|------|------|-----------|
| `single` | 풀 사이클 단건 반복 측정 | 10회 반복, VU 1 |
| `multi` | API 단계별 동시 부하 측정 | VU 10/20/30, Duration 30s |
| `e2e` | 각 VU가 풀 사이클 반복 | VU 10/20/30, Duration 30s |

#### 출력 결과

```
logs/cpu_8_20260330_153000.md
```

Markdown 표 형식으로 각 API의 평균 응답시간, P95, P99, TPS, 성공률/에러율을 기록합니다.

---

### (선택) 부하 테스트용 계정 사전 준비

`run_eval.sh`의 `multi` / `e2e` 섹션은 VU 수만큼 독립 계정이 필요합니다.
`accounts.json`이 없거나 계정 수가 부족하면 자동으로 준비합니다.

수동으로 미리 준비하려면:

```bash
# accounts.json을 직접 생성하려면 run_eval.sh의 prepare_accounts 함수가 자동 실행됨
# 별도 준비 없이 run_eval.sh 실행 시 자동 처리됨
```

> `accounts.json`이 이미 있고 필요한 VU 수 이상의 계정이 있으면 재사용합니다.

---

## 단건 / 부하 테스트 직접 실행 (`run_single.sh`)

개별 단계를 직접 실행하거나 빠르게 부하를 줄 때 사용합니다.

```bash
./run_single.sh [단계...] [옵션]
```

#### 단계 플래그

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

---

## 상태 파일 (`.state`)

`setup.sh` 실행 시 자동 생성되며, `run_eval.sh`와 `run_single.sh`가 참조합니다.

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

## 주요 환경 변수 (`config/config.sh`)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `LIFECYCLE_BASE` | `http://localhost:8080/rest/v1/dlt/stc` | Lifecycle API |
| `SDS_ZK_BASE` | `http://localhost:8080/rest/zktransfer` | ZKTransfer API |
| `MAINNET_NAME` | `SDSMainNet_{RUN_ID}` | 메인넷 이름 (실행마다 고유) |
| `MAINNET_CHAIN_ID` | `{RUN_ID}` | 체인 ID (실행마다 고유) |
| `SC_NAME` | `MySC_{RUN_ID}` | 스마트 컨트랙트 이름 |
| `SC_SYMBOL` | `MS{SHORT_ID}` | 토큰 심볼 |
| `SINGLE_ITERATIONS` | `10` | 단건 테스트 반복 횟수 (`run_eval.sh`) |
| `MULTI_DURATION` | `30s` | 다중/E2E 테스트 지속 시간 |
| `VUS_LIST` | `(10 20 30)` | 다중/E2E 테스트 VU 단계 |
