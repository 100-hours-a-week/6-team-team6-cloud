# 무중단 DB 마이그레이션 테스트 계획서

> **프로젝트**: Billage C2C 렌탈 플랫폼
> **대상**: 단일 EC2 인스턴스 내 MySQL → Amazon RDS MySQL 마이그레이션
> **환경**: MAU 30만 / 300 QPS / 동일 VPC 내 마이그레이션
> **작성일**: 2025-02-12

---

## 1. "무중단"의 정의와 허용 기준

### 1.1 왜 기준을 먼저 정의해야 하는가

"무중단"이라는 표현은 모호하다. 실제로 완전한 Zero Downtime(0ms)은 어떤 마이그레이션 방식에서도 보장할 수 없으며, 사용자 경험 관점에서 허용 가능한 수준을 사전에 정의해야 테스트 결과를 판단할 수 있다. 기준 없이 테스트를 수행하면 "성공인지 실패인지" 판단 자체가 불가능하다.

### 1.2 허용 기준 정의

| 항목 | 기준 | 근거 |
|------|------|------|
| **최대 다운타임** | ≤ 3초 | HTTP 클라이언트의 일반적 타임아웃(5~10초) 이내. 사용자가 "서비스 장애"로 인지하지 않는 임계치. AWS RDS 공식 문서에서도 DNS 전파 + 커넥션 전환에 1~3초를 가이드한다. |
| **에러율** | ≤ 0.1% (1,000건 중 1건 이하) | 300 QPS 기준 3초 다운타임 시 최대 900건의 요청이 영향받을 수 있으나, Connection Pool의 retry + 큐잉으로 실제 에러는 이보다 적어야 한다. |
| **데이터 유실** | 0건 | 커밋된 트랜잭션의 유실은 어떤 경우에도 허용하지 않는다. 200 OK를 반환한 요청의 데이터는 마이그레이션 후 RDS에 반드시 존재해야 한다. |
| **데이터 정합성** | Row count 일치, Checksum 일치 | 원본 DB와 타겟 RDS 간 테이블별 row count 및 checksum이 100% 일치해야 한다. |
| **복제 지연** | 전환 시점 Replication Lag = 0 | 전환 직전 `Seconds_Behind_Master = 0` (Native Replication) 또는 CDC Latency = 0 (DMS)이 확인된 상태에서만 전환을 수행한다. |

### 1.3 기준 설정의 배경

300 QPS, MAU 30만 규모에서 3초의 다운타임은 사용자 경험상 "새로고침 한 번"에 해당한다. 이 수준의 서비스에서 Blue-Green 수준의 완전 무중단(0ms)을 구현하는 것은 인프라 복잡도 대비 이점이 크지 않다. 따라서 "사용자가 인지할 수 없는 수준의 짧은 전환 시간"을 무중단으로 정의한다.

---

## 2. 마이그레이션 방식 비교

### 2.1 후보 방식 개요

#### 방식 A: MySQL Native Replication (Read Replica → Master 승격)

EC2 내 MySQL을 Master로 두고, RDS를 외부 Read Replica로 설정하여 binlog 기반 복제를 수행한 뒤, 복제 완료 시점에 RDS를 새로운 Master로 승격시키는 방식이다.

**동작 원리:**

1. EC2 MySQL에서 binlog 활성화 및 replication user 생성
2. `mysqldump`로 초기 데이터 Full Dump (with `--master-data=2` 옵션으로 binlog position 기록)
3. RDS에 Full Dump 적재
4. RDS에서 `mysql.rds_set_external_master`로 EC2 MySQL을 Master로 지정
5. GTID 또는 binlog position 기반으로 복제 시작
6. `Seconds_Behind_Master = 0` 확인 후 전환

**초기 덤프 및 복제 설정:**

```bash
# 1. EC2 MySQL에서 binlog 설정 확인/활성화
# my.cnf에 다음 설정 필요:
#   log_bin = mysql-bin
#   binlog_format = ROW
#   server-id = 1
#   gtid_mode = ON (권장)
#   enforce_gtid_consistency = ON (권장)

# 2. Replication 유저 생성
mysql> CREATE USER 'repl_user'@'%' IDENTIFIED BY 'repl_password';
mysql> GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
mysql> FLUSH PRIVILEGES;

# 3. Full Dump with binlog position
mysqldump -u root -p \
  --single-transaction \
  --routines \
  --triggers \
  --master-data=2 \
  --set-gtid-purged=ON \
  billage > billage_dump.sql

# 4. RDS에 덤프 적재
mysql -h <rds-endpoint> -u admin -p billage < billage_dump.sql

# 5. RDS에서 복제 설정 (binlog position 방식)
CALL mysql.rds_set_external_master(
  'ec2-private-ip',  -- Source host
  3306,              -- Source port
  'repl_user',       -- Replication user
  'repl_password',   -- Password
  'mysql-bin.000001', -- Binlog file (덤프 파일 헤더에서 확인)
  12345,             -- Binlog position (덤프 파일 헤더에서 확인)
  0                  -- SSL disabled
);

# 6. 복제 시작
CALL mysql.rds_start_replication;

# 7. 복제 상태 확인
SHOW SLAVE STATUS\G
```

**GTID 기반 복제 설정 (권장):**

GTID(Global Transaction ID)를 사용하면 binlog position 추적 없이 더 안정적으로 복제할 수 있다.

```sql
-- RDS에서 GTID 기반 복제 설정
CALL mysql.rds_set_external_master_with_auto_position(
  'ec2-private-ip',
  3306,
  'repl_user',
  'repl_password',
  0,  -- SSL disabled
  0   -- Auto position enabled
);

CALL mysql.rds_start_replication;
```

**특징:**

- MySQL 네이티브 메커니즘이므로 가장 안정적이고 검증된 방식이다.
- 트랜잭션 단위로 binlog를 리플레이하므로 커밋된 데이터의 정합성이 보장된다.
- 전환 시 짧은 다운타임(수초)이 발생한다.
- 별도 비용이 발생하지 않는다.
- 부하 스파이크 시에도 binlog 리플레이가 비교적 안정적으로 따라간다.
- GTID 모드 사용 시 failover가 더 간단해진다.

**다운타임 발생 구간:**

```
[Write 중단] → [Lag=0 확인] → [Nginx 라우팅 전환] → [새 커넥션 확립]
     ↑                                                      ↑
     └──────────── 이 구간이 다운타임 (1~5초) ──────────────┘
```

#### 방식 B: AWS Database Migration Service (DMS)

AWS DMS를 사용하여 Full Load + CDC(Change Data Capture)로 데이터를 이관하는 방식이다.

**동작 원리:**

1. DMS Replication Instance 생성
2. Source Endpoint (EC2 MySQL) / Target Endpoint (RDS MySQL) 설정
3. Full Load로 기존 데이터 이관
4. CDC 모드로 전환되어 실시간 변경분 동기화
5. CDC Latency = 0 확인 후 전환

**특징:**

- AWS 관리형 서비스로 설정이 비교적 간단하다.
- Full Load + CDC가 자동으로 이어지므로 운영 부담이 적다.
- LOB 컬럼, 특수 DDL에서 간헐적 이슈가 발생할 수 있다.
- DMS Replication Instance 비용이 추가로 발생한다.
- DMS 자체가 다운타임을 0으로 만들어주는 것이 아니다. 최종 전환(cutover)은 여전히 애플리케이션 레벨에서 수행해야 한다.
- 중간에 변환 레이어(DMS 엔진)가 존재하므로, 부하 스파이크 시 복제 지연(Lag)이 Native Replication보다 더 크게 튀는 경향이 있다.

**다운타임 발생 구간:**

```
[CDC Latency=0 확인] → [Write 중단] → [최종 동기화] → [라우팅 전환]
                            ↑                              ↑
                            └── 이 구간이 다운타임 (1~5초) ─┘
```

#### 방식 C: Dual Write (이중 쓰기)

애플리케이션 레벨에서 원본 DB와 타겟 RDS에 동시에 쓰기를 수행하는 방식이다. 이론적으로 다운타임 0이 가능하나, 두 DB 간 트랜잭션 일관성 보장이 극도로 어렵고, 애플리케이션 코드 변경이 필수이며, write latency가 2배로 증가한다. 복잡도 대비 이점이 크지 않아 이 규모에서는 비추천한다.

### 2.2 방식 비교 요약

| 항목 | Native Replication | AWS DMS | Dual Write |
|------|-------------------|---------|------------|
| 다운타임 | 1~5초 | 1~5초 | ~0초 |
| 데이터 정합성 | 매우 높음 (binlog 기반) | 높음 (CDC 기반) | 낮음 |
| 구현 복잡도 | 중간 | 낮음 | 매우 높음 |
| 추가 비용 | 없음 | DMS 인스턴스 비용 | 없음 |
| 앱 코드 변경 | 불필요 | 불필요 | 필수 |
| 부하 스파이크 시 Lag | 안정적 | 변환 레이어로 인해 튈 수 있음 | N/A |
| 롤백 용이성 | 높음 | 중간 | 낮음 |

### 2.3 선택: Native Replication + DMS 비교 테스트

두 방식을 모두 테스트하여 비교한다. Native Replication은 MySQL 복제 메커니즘에 대한 깊은 이해를, DMS는 AWS 관리형 서비스 활용 능력을 증명한다. 특히 부하 스파이크 시 Lag 그래프 비교는 실무적 인사이트를 보여주는 핵심 자료가 된다.

---

## 3. 테스트 시나리오

### 3.1 테스트 환경 구성

**현재 아키텍처**: 단일 EC2 인스턴스에 Nginx + Spring Boot + MySQL이 공존

```
┌────────────────────── VPC ──────────────────────┐
│                                                  │
│  ┌─────────── EC2 Instance (단일) ────────────┐ │
│  │                                             │ │
│  │  ┌─────────┐                                │ │
│  │  │  Nginx  │ ← 외부 트래픽                   │ │
│  │  │  :80    │                                │ │
│  │  └────┬────┘                                │ │
│  │       │                                     │ │
│  │       ├─────────────────┬───────────────┐   │ │
│  │       ▼                 ▼               │   │ │
│  │  ┌─────────┐      ┌─────────┐           │   │ │
│  │  │ Spring  │      │ Spring  │           │   │ │
│  │  │ :8080   │      │ :8081   │           │   │ │
│  │  │(원본DB) │      │ (RDS)   │  ← 전환 후 │   │ │
│  │  └────┬────┘      └────┬────┘           │   │ │
│  │       │                │                │   │ │
│  │       ▼                │                │   │ │
│  │  ┌─────────┐           │                │   │ │
│  │  │ MySQL   │           │                │   │ │
│  │  │ :3306   │ ─ Replication ─┐           │   │ │
│  │  │ (원본)  │                │           │   │ │
│  │  └─────────┘                │           │   │ │
│  └─────────────────────────────┼───────────┘   │ │
│                                │               │ │
│  ┌─────── RDS MySQL ──────┐    │               │ │
│  │   (마이그레이션 타겟)    │ ◄──┘               │ │
│  └────────────────────────┘                    │ │
│                                                  │
│  ┌─── 별도 EC2: 모니터링 ───┐                    │
│  │  Prometheus + Grafana    │ ← K6 부하생성기   │
│  │  mysqld_exporter         │                   │
│  │  CloudWatch (RDS)        │                   │
│  └──────────────────────────┘                   │
└──────────────────────────────────────────────────┘
```

**전환 방식: 동일 EC2에서 이중 포트 Spring Boot 운영**

1. **:8080** - 기존 Spring Boot (로컬 MySQL 연결)
2. **:8081** - 새 Spring Boot 인스턴스 (RDS 연결)

전환 시 Nginx upstream만 :8080 → :8081로 변경하면 된다. 앱 재시작 없이 라우팅만 전환.

**핵심 구성 요소:**

- **Nginx**: 8080과 8081 간 라우팅 전환. `nginx -s reload`로 무중단 전환.
- **Spring Boot 이중 포트**: 동일 EC2에서 두 개의 Spring Boot를 각각 다른 포트로 실행. 하나는 로컬 MySQL, 하나는 RDS에 연결.
- **K6**: 전환 전/중/후 지속적으로 부하를 생성하여 다운타임과 에러율을 측정. (별도 서버 또는 로컬에서 실행)

### 3.2 사전 데이터 준비

| 항목 | 값 | 근거 |
|------|---|------|
| 초기 데이터 규모 | 100만~500만 rows | mysqldump/Full Load에 수 분~수십 분 소요되는 수준. |
| 총 DB 크기 | 1~5GB | 네트워크 전송, 복제 시간을 유의미하게 측정 가능. |

> **참고**: 데이터 분할 이관이 필요한 임계치는 일반적으로 수십 GB 이상이다. 1~5GB에서는 단일 실행으로 충분하다.

### 3.3 테스트 시나리오 흐름

#### Phase 1: 기준선 측정 (Baseline)

```
K6 → Nginx → :8080 (원본 DB)
기간: 10분 / QPS: 300
측정: p50/p95/p99 latency, 에러율, throughput
```

#### Phase 2: 복제 중 부하 테스트

복제가 진행 중인 상태에서 원본 DB의 성능 저하 여부를 확인한다. 부하 스파이크(QPS 500~600)를 간헐적으로 발생시켜, Native Replication과 DMS의 복제 지연 차이를 비교 관찰한다.

```
K6 → Nginx → :8080 (원본 DB)  ← binlog를 RDS가 읽는 중
기간: 10분 (중간에 2분간 QPS 500~600 스파이크 포함)
측정: 기준선 대비 latency 증가율, Replication Lag 추이 그래프
```

#### Phase 3: 전환 (Cutover)

**Step 1 — Warm-up (전환 1~2분 전):**

> **중요: Warm-up은 읽기 전용(GET 요청)만 수행한다. 쓰기 요청(POST/PUT/DELETE)은 절대 금지.**

K6 별도 스레드로 :8081에 **읽기 전용** 소량 트래픽을 전송한다. HikariCP는 실제 트래픽이 없으면 `minimum-idle`만큼만 커넥션을 유지하므로, warm-up 없이 전환하면 커넥션 확보 지연이 발생한다. **GET 요청만으로** 커넥션 풀을 `maximum-pool-size`까지 확장하고 JVM JIT도 예열한다.

```
K6 warm-up → :8081 (RDS 연결 앱)
QPS: 30~50 / 기간: 1~2분
요청 유형: GET만 (읽기 전용, 목록 조회 등)
쓰기 요청: 절대 금지 (데이터 정합성 훼손 방지)
```

**왜 쓰기를 금지하는가?**
- 이 시점에 RDS는 아직 replica 상태이며, Source(EC2 MySQL)로부터 복제를 받고 있다.
- RDS에 직접 쓰기를 하면 복제 충돌이 발생하거나, Source와 데이터가 불일치하게 된다.
- Warm-up의 목적은 커넥션 풀과 JVM 예열이므로, GET 요청으로 충분하다.

**Step 2 — Lag 확인:**

```sql
-- Native Replication
SHOW SLAVE STATUS\G  -- Seconds_Behind_Master = 0 확인
-- DMS: AWS 콘솔에서 CDC Latency = 0 확인
```

**Step 3 — Source DB Write 차단:**

```sql
SET GLOBAL read_only = ON;
```

> **주의: `read_only = ON`의 SUPER 권한 함정**
>
> MySQL에서 `read_only = ON`을 설정해도 SUPER 권한이 있는 계정(root, admin 등)은 여전히 쓰기가 가능하다.
>
> - 사전 확인 필수: `SHOW GRANTS FOR 'app_user'@'%';`
> - SUPER 권한이 있다면 `read_only`만으로는 write 차단이 불완전하다. Nginx에서 :8080 라우팅을 먼저 끊거나, Security Group으로 앱→DB 포트를 차단해야 한다.
> - Best Practice: 앱 유저는 SUPER 권한 없이 최소 권한으로 운영한다.

**Step 4 — Final Sync 확인:**

```sql
SHOW SLAVE STATUS\G  -- Seconds_Behind_Master = 0 재확인
SHOW MASTER STATUS;  -- 원본 File, Position
-- RDS 측 Relay_Master_Log_File, Exec_Master_Log_Pos와 비교하여 일치 확인

SHOW PROCESSLIST;
-- 진행 중인 트랜잭션(executing/updating)이 없는지 확인
-- 있다면 완료될 때까지 대기
```

**Step 5 — Switch:**

```bash
# Nginx upstream 전환 (8080 → 8081)
cp /etc/nginx/conf.d/upstream-target.conf /etc/nginx/conf.d/upstream.conf
nginx -s reload
```

**Step 6 — Verify:**

K6 로그에서 에러 멈추고 200 OK 확인. Grafana에서 RDS 커넥션 수 증가 및 원본 커넥션 수 감소 관찰.

**Step 7 — 복제 중단:**

```sql
-- Native Replication
CALL mysql.rds_stop_replication;
-- DMS: AWS 콘솔에서 태스크 중단
```

**전환 전체 흐름:**

```
[Warm-up :8081 (GET only)] → [Lag=0 확인] → [read_only=ON] → [PROCESSLIST 확인]
                                                                    ↓
[복제 중단] ← [Verify 200 OK] ← [Nginx reload] ← [Lag=0 + binlog position 재확인]
```

#### Phase 4: 전환 후 안정성 검증

```
K6 → Nginx → :8081 (RDS)
기간: 10분 / QPS: 300
측정: p50/p95/p99 latency, 에러율, throughput
```

#### Phase 5: 데이터 정합성 검증

부하 테스트 종료 후, 원본과 타겟 간 데이터 정합성을 검증한다. (상세 내용은 5.3절 참조)

---

## 4. 발생 가능한 문제

### 4.1 전환 과정에서 발생할 수 있는 문제

| 문제 | 발생 조건 | 영향 | 대응 |
|------|----------|------|------|
| **Replication Lag 잔존 상태에서 전환** | lag > 0인데 전환 수행 | 최근 트랜잭션 유실 | 전환 전 lag=0 확인을 스크립트에 포함. 0이 아니면 전환 차단. |
| **Long-running Transaction** | 전환 시점에 미커밋 트랜잭션 존재 | 복제 이미 중단했다면 해당 트랜잭션 데이터 유실 | `read_only` 설정 후 `SHOW PROCESSLIST`로 확인. 모두 완료 뒤 복제 중단. |
| **SUPER 권한으로 인한 write 미차단** | 앱 DB 계정이 SUPER 권한 보유 | `read_only = ON`에도 앱이 쓰기 성공. 복제 끊긴 뒤 데이터 유실. | 사전 계정 권한 확인 필수. SUPER 있으면 Nginx/SG 차단 병행. |
| **Connection Pool 미예열** | :8081 HikariCP가 커넥션 미확보 상태에서 전환 | 전환 직후 커넥션 타임아웃, 다운타임 증가 | 전환 1~2분 전 K6로 :8081에 QPS 30~50 **읽기 전용** warm-up 트래픽 전송. |
| **DNS 캐싱** | RDS 엔드포인트 DNS 캐싱 | 앱이 잘못된 IP로 접속, 커넥션 실패 | JVM DNS TTL 낮게 설정 (`networkaddress.cache.ttl=10`). |
| **Nginx Reload 지연** | reload 후 worker가 기존 요청 마무리 중 | 일부 요청이 구 upstream으로 라우팅 | graceful shutdown이므로 실질적 문제 없으나 다운타임 측정 시 고려. |
| **Warm-up 중 쓰기 수행** | warm-up 시 POST/PUT 요청 전송 | RDS에 직접 쓰기로 데이터 불일치 발생 | warm-up은 **GET 요청만** 수행. 스크립트에서 쓰기 요청 원천 차단. |

### 4.2 복제 과정에서 발생할 수 있는 문제

| 문제 | 발생 조건 | 영향 |
|------|----------|------|
| **Character Set 불일치** | 원본과 RDS의 character_set/collation 상이 | 한글 깨짐, checksum 불일치 |
| **Time Zone 차이** | timezone 설정 상이 | DATETIME/TIMESTAMP 값 차이 |
| **Auto Increment 값 차이** | DMS Full Load 시 카운터 리셋 | 전환 후 PK 충돌 가능 |
| **Foreign Key Constraint** | DMS Full Load 테이블 적재 순서 | DMS Full Load 시 FK 체크 비활성화 필요 |
| **GTID 불일치** | Source와 Target의 GTID 설정 불일치 | 복제 시작 실패 또는 중단 |

### 4.3 시스템 vs 휴먼 에러 구분

이 규모(300 QPS, 1~5GB)에서 **실질적으로 위험한 것은 대부분 휴먼 에러**다.

**시스템적 정합성 오류 가능성**: MySQL binlog 기반 복제는 트랜잭션 단위로 리플레이하므로, 커밋된 트랜잭션의 부분 복제나 순서 역전은 발생하지 않는다. DMS CDC도 커밋된 트랜잭션만 반영한다. 복제 메커니즘 자체에서 정합성 오류가 발생할 확률은 극히 낮다.

**휴먼 에러 가능성**: lag 미확인 전환, SUPER 권한 계정으로 인한 write 미차단, 미커밋 트랜잭션 미확인 상태에서 복제 중단, Nginx 설정 오타, 커넥션 풀 warm-up 누락, **warm-up 중 쓰기 수행** 등이 실제 장애의 주요 원인이다. 체크리스트 기반의 단계별 수행이 이를 방지한다.

---

## 5. 장애 검증 및 모니터링

### 5.1 K6 부하테스트 코드 설계

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';

const errorCount = new Counter('migration_errors');
const successCount = new Counter('migration_success');
const writeLatency = new Trend('write_latency');
const readLatency = new Trend('read_latency');
const errorRate = new Rate('error_rate');

export const options = {
  scenarios: {
    constant_load: {
      executor: 'constant-arrival-rate',
      rate: 300,
      timeUnit: '1s',
      duration: '30m',
      preAllocatedVUs: 500,
      maxVUs: 1000,
    },
  },
};

export default function () {
  const seq = __ITER;
  const timestamp = Date.now();

  // Write: 고유 식별 가능한 데이터 삽입
  const writePayload = JSON.stringify({
    title: `load-test-${seq}-${timestamp}`,
    content: `migration-validation-${seq}`,
  });

  const writeRes = http.post(`${BASE_URL}/groups/1/posts`, writePayload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { type: 'write' },
  });

  writeLatency.add(writeRes.timings.duration);
  const writeOk = check(writeRes, {
    'write status 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  if (writeOk) {
    successCount.add(1);
    errorRate.add(false);
  } else {
    errorCount.add(1);
    errorRate.add(true);
    console.error(`FAIL seq=${seq} status=${writeRes.status} ts=${timestamp}`);
  }

  // Read
  const readRes = http.get(`${BASE_URL}/groups/1/posts`, {
    tags: { type: 'read' },
  });
  readLatency.add(readRes.timings.duration);
  sleep(0.1);
}
```

**시퀀스 추적**: `__ITER` + `Date.now()`를 요청 본문 데이터에 포함시켜, 백엔드 수정 없이 DB에서 직접 검증 가능.

### 5.2 다운타임 측정 방법

K6 `--out csv=results.csv`로 CSV 출력 후, 연속 에러 구간을 추출하여 다운타임을 계산한다.

- **첫 번째 에러 발생 시각** = 전환 시작 시점
- **마지막 에러 발생 시각** = 전환 완료 시점
- **다운타임 = 마지막 에러 시각 - 첫 번째 에러 시각**
- **에러율 = 에러 요청 수 / 전체 요청 수**

### 5.3 데이터 정합성 검증

```sql
-- 1. Row Count 비교 (테이블별)
SELECT table_name, table_rows
FROM information_schema.tables
WHERE table_schema = 'billage' ORDER BY table_name;
-- 양쪽에서 실행 후 diff

-- 2. Checksum 비교
CHECKSUM TABLE users, post, membership, billage_group, chatroom, chat_message;
-- 양쪽에서 실행하여 값 비교

-- 3. K6 삽입 데이터 검증
SELECT COUNT(*) FROM post WHERE title LIKE 'load-test-%';
-- K6의 successCount와 비교

-- 4. 최근 데이터 샘플링
SELECT * FROM post
WHERE created_at >= NOW() - INTERVAL 1 MINUTE
ORDER BY created_at DESC LIMIT 100;

-- 5. FK 무결성 확인
SELECT pi.id FROM post_image pi
LEFT JOIN post p ON pi.post_id = p.id
WHERE p.id IS NULL;
```

> **실무 참고: pt-table-checksum**
>
> `CHECKSUM TABLE`은 테이블 전체를 스캔하므로 대용량에서는 운영 부하가 크다. 실무에서 수십 GB 이상의 프로덕션 검증 시에는 Percona Toolkit의 `pt-table-checksum`을 사용하는 것이 표준이다. 청크 단위 검증으로 운영 부하를 최소화한다. 이번 테스트 규모(1~5GB)에서는 `CHECKSUM TABLE`로 충분하다.

### 5.4 모니터링 구성

| 대상 | 도구 | 수집 지표 |
|------|------|----------|
| **EC2 MySQL (원본)** | Prometheus + mysqld_exporter + Grafana | QPS, Connections, Replication Lag, binlog position |
| **RDS MySQL (타겟)** | CloudWatch + Grafana CloudWatch DataSource | CPUUtilization, DatabaseConnections, ReadLatency, WriteLatency |
| **Nginx** | Prometheus + nginx_exporter | Active connections, 5xx count, upstream response time |
| **K6** | K6 → InfluxDB → Grafana | QPS, p95/p99 latency, error rate, custom metrics |
| **DMS** | CloudWatch | CDCLatencySource, CDCLatencyTarget |

**RDS 모니터링**: RDS는 mysqld_exporter를 직접 붙일 수 없다. Grafana의 CloudWatch DataSource로 RDS 메트릭을 통합하여, 원본 MySQL(Prometheus)과 타겟 RDS(CloudWatch)를 하나의 대시보드에서 비교 관찰한다.

**Grafana 대시보드 패널:**

1. **복제 지연 패널**: Native Replication과 DMS의 Lag 그래프를 오버레이 비교
2. **에러율 패널**: K6 에러율 + Nginx 5xx 비율
3. **Latency 패널**: K6 p50/p95/p99 + Nginx upstream response time
4. **DB 커넥션 패널**: 원본 MySQL connections + RDS DatabaseConnections

### 5.5 장애 감지 기준

| 지표 | 정상 | 경고 | 장애 |
|------|------|------|------|
| K6 에러율 | < 0.01% | 0.01~0.1% | > 0.1% |
| p99 Latency | < 500ms | 500ms~2s | > 2s |
| Replication Lag | 0초 | 1~5초 | > 5초 |
| Nginx 5xx | 0 | 1~10/min | > 10/min |

---

## 6. 롤백 전략

### 6.1 롤백의 현실적 제약

**핵심 원칙**: RDS로 전환 후 write가 단 한 건이라도 발생하면, 원본 EC2 MySQL로의 롤백은 **"전환 이후 RDS에 쓰인 데이터의 유실"을 수반한다.** 역방향 복제(RDS → EC2)를 구성하면 방지할 수 있으나, 복잡도가 과도하므로 이 규모에서는 채택하지 않는다.

따라서 롤백은 **"데이터 유실을 감수하는 긴급 복구"**로 정의한다. 전환 후 심각한 장애 발견 시, 가능한 한 빠르게(수 분 이내) 롤백을 결정해야 유실 범위를 최소화할 수 있다.

### 6.2 롤백 절차

**롤백 가능 조건**: 원본 EC2 MySQL이 살아 있고, 데이터가 보존되어 있을 때.

```bash
# 1. Nginx upstream 복구 (8081 → 8080)
cp /etc/nginx/conf.d/upstream-source.conf /etc/nginx/conf.d/upstream.conf
nginx -s reload
```

```sql
-- 2. EC2 MySQL read_only 해제
SET GLOBAL read_only = OFF;

-- 3. RDS에 쓰인 데이터 범위 확인
SELECT COUNT(*) FROM post WHERE created_at > '전환시각';
```

### 6.3 롤백 판단 기준

| 상황 | 판단 | 근거 |
|------|------|------|
| 전환 후 1분 이내 심각한 장애 | 즉시 롤백 | 최대 ~18,000건 유실 (300 QPS × 60초). 수동 복구 가능. |
| 전환 후 5분 이후 장애 발견 | RDS에서 장애 해결 | 90,000건+ 유실. 수동 복구 비현실적. |
| 정상 운영 중 경미한 이슈 | 롤백하지 않고 RDS에서 해결 | 롤백의 유실 리스크 > 이슈 리스크. |

### 6.4 원본 DB 보존 기간

전환 후 최소 72시간은 원본 EC2 MySQL을 유지한다. 단, 이 기간 동안의 롤백은 72시간분의 데이터 유실을 의미하므로, 실질적으로 롤백이 현실적인 것은 전환 직후(수 분 이내)뿐이다.

### 6.5 롤백 테스트

마이그레이션 테스트 시 의도적으로 롤백을 1회 수행하여 절차를 검증한다.

```
1. 정상 전환 수행 (Phase 3)
2. RDS로 트래픽 유입 확인 (1~2분간)
3. 의도적 롤백 수행 (Nginx를 :8080으로 복귀)
4. 원본 DB에서 정상 응답 확인
5. RDS에만 쓰인 데이터 건수 측정 → 유실 범위 기록
6. 유실 데이터 수동 복구 가능 여부 확인
```

---

## 부록: 테스트 체크리스트

### 사전 준비

- [ ] EC2 MySQL binlog 활성화 (`log_bin`, `binlog_format=ROW`, `server-id`)
- [ ] EC2 MySQL GTID 활성화 (`gtid_mode=ON`, `enforce_gtid_consistency=ON`) - 권장
- [ ] Replication 유저 생성 (`GRANT REPLICATION SLAVE`)
- [ ] 앱 DB 계정 SUPER 권한 여부 확인 (`SHOW GRANTS FOR 'app_user'@'%'`)
- [ ] RDS MySQL 인스턴스 생성 (동일 VPC, 동일 서브넷 그룹)
- [ ] Character set / Collation / Timezone 일치 확인
- [ ] `mysqldump`로 Full Dump 수행 (`--master-data=2` 또는 `--set-gtid-purged=ON`)
- [ ] RDS에 덤프 적재 및 복제 설정 (`mysql.rds_set_external_master`)
- [ ] 복제 시작 및 Lag = 0 확인
- [ ] Spring Boot 앱 이중 포트 배포 (:8080, :8081) 및 커넥션 풀 설정 확인
- [ ] Nginx upstream 설정 준비 (전환/복구 conf 파일)
- [ ] K6 메인 스크립트 + warm-up 스크립트 작성 및 테스트
- [ ] **Warm-up 스크립트가 GET 요청만 수행하는지 확인 (쓰기 요청 없음)**
- [ ] Grafana 대시보드 구성 (원본 MySQL + RDS CloudWatch + Nginx + K6)
- [ ] Baseline 성능 측정 완료

### 전환 시

- [ ] :8081 앱에 warm-up 트래픽 전송 (1~2분, QPS 30~50, **GET만**)
- [ ] Replication Lag = 0 확인
- [ ] `SET GLOBAL read_only = ON` 실행
- [ ] `SHOW PROCESSLIST`로 진행 중인 트랜잭션 없음 확인
- [ ] Lag = 0 + binlog position 일치 재확인
- [ ] Nginx upstream 전환 및 reload
- [ ] K6 에러 멈춤 확인
- [ ] 복제 중단 (`CALL mysql.rds_stop_replication`)

### 전환 후

- [ ] K6 정상 응답 확인 (에러율 < 0.1%)
- [ ] Row count 비교
- [ ] Checksum 비교
- [ ] K6 삽입 데이터 전수 확인 (successCount vs DB count)
- [ ] FK 무결성 검증
- [ ] p95/p99 latency 기준선 대비 확인

### 롤백 테스트

- [ ] 의도적 롤백 1회 수행
- [ ] 롤백 후 원본 DB 정상 응답 확인
- [ ] 유실 데이터 건수 측정
- [ ] 유실 데이터 수동 복구 가능 여부 확인