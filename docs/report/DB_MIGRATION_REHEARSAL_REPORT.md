# DB 마이그레이션 리허설 보고서

## 문서 정보

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-02-13 |
| 최종 수정 | 2026-02-13 17:15 |
| 작성자 | DevOps Team |
| 환경 | Dev (리허설) |
| 상태 | **Cutover 준비 완료** |

---

## 1. 개요

Billage 서비스의 Host MySQL(EC2) → RDS MySQL 8.0 마이그레이션을 위한 리허설을 수행했다.
GTID 기반 Replication을 구성하여 무중단 전환 준비를 완료했다.

### 1.1 마이그레이션 전략

**MySQL Replication 기반 무중단 전환** 채택

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Replication 아키텍처                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐         GTID-based          ┌─────────────┐           │
│  │ Host MySQL  │ ──────── Replication ──────▶│   RDS       │           │
│  │ (Source)    │         auto-position       │ (Replica)   │           │
│  │ 10.0.1.123  │                             │ Private     │           │
│  └─────────────┘                             └─────────────┘           │
│        │                                            │                   │
│        ▼                                            ▼                   │
│   WAS :8080                                   WAS :8081                 │
│   (현재 트래픽)                               (전환 대기)               │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 테스트 환경

| 항목 | 값 |
|------|-----|
| 테스트 도메인 | `http://test.billages.com` |
| API 엔드포인트 | `http://test.billages.com/api/` |
| DNS | Route53 A 레코드 → 3.34.162.89 |

---

## 2. 환경 정보

### 2.1 인프라 구성

| 구성요소 | 상세 |
|----------|------|
| **Host MySQL** | EC2 내부, MySQL 8.0.45, gtid_mode=ON |
| **RDS MySQL** | billage-dev-mysql, MySQL 8.0.44 |
| **리허설 EC2** | ubuntu@3.34.162.89 (Private: 10.0.1.123) |
| **RDS Endpoint** | billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com |

### 2.2 데이터 규모 (시딩 후)

| 테이블 | Row Count | 비고 |
|--------|-----------|------|
| users | 600,014 | 테스트 유저 포함 |
| post | 60,014 | |
| billage_group | 201 | |
| membership | 600,013 | |
| chatroom | 20,039 | |
| chat_message | 12,000,174 | 대용량 |
| post_image | 15 | |
| refresh_token | 12 | |

**총 데이터 크기**: ~1.78GB (dump 압축: 259MB)

---

## 3. 작업 수행 내역

### 3.1 사전 준비

| 단계 | 상태 | 비고 |
|------|------|------|
| 리허설 EC2 구성 | ✅ 완료 | |
| 대용량 시딩 (300K MAU 시뮬레이션) | ✅ 완료 | ~1.78GB |
| WAS 이중 구성 (8080/8081) | ✅ 완료 | |
| Host MySQL GTID 활성화 | ✅ 완료 | gtid_mode=ON |
| RDS 인스턴스 생성 | ✅ 완료 | Terraform |
| test.billages.com DNS 설정 | ✅ 완료 | Route53 |
| Nginx 테스트 환경 설정 | ✅ 완료 | |

### 3.2 Dump & Import

| 단계 | 시작 | 완료 | 소요시간 |
|------|------|------|----------|
| mysqldump (gzip) | 14:38 | - | - |
| Dump 파일 크기 | - | - | 259MB |
| RDS Import | - | - | - |

**Dump 명령어**:
```bash
mysqldump \
  -h localhost \
  -u root \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --set-charset \
  --default-character-set=utf8mb4 \
  billage | gzip -1 > /tmp/billage-gtid.sql.gz
```

**Dump 파일 GTID 정보**:
```
SET @@GLOBAL.GTID_PURGED='fdc65049-f838-11f0-8716-024c10e7ffa9:1';
```

### 3.3 Replication 설정

| 단계 | 명령어 | 결과 |
|------|--------|------|
| GTID baseline 설정 | `rds_set_external_source_gtid_purged` | ✅ |
| Source 연결 | `rds_set_external_master_with_auto_position` | ✅ |
| Replication 시작 | `rds_start_replication` | ✅ |

**Replication 사용자**:
- User: `repl_user@%`
- Plugin: `mysql_native_password`
- Grants: `REPLICATION SLAVE, REPLICATION CLIENT`

---

## 4. RDS 스펙 변경 및 Replication 복구

### 4.1 RDS 스펙 변경

RDS 인스턴스 클래스 변경(스펙업) 수행.

**결과**: Replication 설정은 유지되었으나, 재시작 후 GTID 트랜잭션 에러 발생.

### 4.2 GTID 트랜잭션 스킵

**에러 발생**:
```
Replica_SQL_Running: No
Last_SQL_Error: Worker 1 failed executing transaction
'fdc65049-f838-11f0-8716-024c10e7ffa9:2'
```

**Binlog 분석 결과**:

| GTID | 내용 | 처리 |
|------|------|------|
| `:1` | `FLUSH TABLES` (덤프 관련) | ✅ 적용됨 |
| `:2` | `ALTER USER 'repl_user' ... caching_sha2_password` | ⏭️ 스킵 |
| `:3` | `FLUSH PRIVILEGES` | ✅ 적용됨 |
| `:4` | `ALTER USER 'repl_user' ... mysql_native_password` | ⏭️ 스킵 |
| `:5` | `FLUSH PRIVILEGES` | ✅ 적용됨 |
| `:6` | `INSERT INTO billage.users` (테스트 유저) | ✅ 적용됨 |

**스킵 사유**:
- 스킵된 트랜잭션은 모두 `ALTER USER` (MySQL 사용자 관리 DDL)
- 애플리케이션 데이터와 무관
- RDS는 사용자를 자체 관리하므로 Host의 ALTER USER 적용 시 충돌 발생

**복구 명령어**:
```sql
CALL mysql.rds_skip_repl_error;  -- 2회 실행
```

**복구 후 상태**:
```
Replica_IO_Running: Yes ✅
Replica_SQL_Running: Yes ✅
Seconds_Behind_Source: 0 ✅
```

---

## 5. Replication 상태 (최종)

```
Source_Host: 10.0.1.123
Replica_IO_Running: Yes ✅
Replica_SQL_Running: Yes ✅
Seconds_Behind_Source: 0 ✅
Executed_Gtid_Set: fdc65049-f838-11f0-8716-024c10e7ffa9:1:3:5-6
Replica_SQL_Running_State: Slave has read all relay log; waiting for more updates
```

---

## 6. 데이터 정합성 검증

### 6.1 Row Count 비교

| 테이블 | Host MySQL | RDS | 일치 |
|--------|------------|-----|------|
| users | 600,014 | 600,014 | ✅ |
| post | 60,014 | 60,014 | ✅ |
| billage_group | 201 | 201 | ✅ |
| membership | 600,013 | 600,013 | ✅ |
| chatroom | 20,039 | 20,039 | ✅ |
| chat_message | 12,000,174 | 12,000,174 | ✅ |
| post_image | 15 | 15 | ✅ |
| refresh_token | 12 | 12 | ✅ |

**결과**: 모든 테이블 Row Count 일치 ✅

### 6.2 실시간 복제 테스트

| 테스트 | 내용 | 결과 |
|--------|------|------|
| INSERT 복제 | Host에 `repl_test_user` 추가 | RDS에 즉시 복제됨 ✅ |
| Lag 확인 | Seconds_Behind_Source | 0초 ✅ |

---

## 7. Cutover 스크립트 (통합)

### 7.1 2단계 Write Freeze 전략

```
┌─────────────────────────────────────────────────────────────┐
│  Soft Freeze (Nginx)        │  Hard Freeze (DB)            │
├─────────────────────────────┼──────────────────────────────┤
│  - POST/PUT/DELETE → 503    │  - read_only=ON              │
│  - 사용자 쓰기 차단         │  - 배치/크론/내부호출 차단   │
│  - UX 보호, DB 부하 감소    │  - 정합성 100% 보장          │
└─────────────────────────────┴──────────────────────────────┘
```

### 7.2 cutover.sh 스크립트

**위치**: `/home/ubuntu/cutover.sh`

**사용법**:
```bash
./cutover.sh run       # Cutover 실행 (Host → RDS)
./cutover.sh rollback  # 롤백 (RDS → Host)
./cutover.sh status    # 현재 상태 확인
```

**Cutover 절차** (`./cutover.sh run`):

| 단계 | 내용 |
|------|------|
| 1. Soft Freeze | Nginx에서 POST/PUT/DELETE/PATCH → 503 반환 |
| 2. Hard Freeze | Host MySQL `read_only=ON` |
| 3. Lag 확인 | `Seconds_Behind_Source=0` 될 때까지 대기 |
| 4. Nginx 스위칭 | `upstream backend` → 8081 (RDS) + Soft Freeze 해제 |

**Rollback 절차** (`./cutover.sh rollback`):

| 단계 | 내용 |
|------|------|
| 1. Nginx 복귀 | `upstream backend` → 8080 (Host) |
| 2. Soft Freeze 해제 | write-block.conf 삭제 |
| 3. Hard Freeze 해제 | Host MySQL `read_only=OFF` |

### 7.3 Nginx 구성

**upstream.conf** (`/etc/nginx/conf.d/upstream.conf`):
```nginx
upstream backend_host { server localhost:8080; }  # Host MySQL WAS
upstream backend_rds  { server localhost:8081; }  # RDS WAS
upstream backend      { server localhost:8080; }  # 활성 (스위칭 대상)
```

**test.conf** (`/etc/nginx/sites-available/test.conf`):
```nginx
server {
    listen 80;
    server_name test.billages.com;

    location /api/ {
        proxy_pass http://backend/;
        ...
    }

    location / {
        proxy_pass http://frontend;
        ...
    }
}
```

---

## 8. 테스트 환경 설정

### 8.1 Route53 DNS

| 레코드 | 타입 | 값 | TTL |
|--------|------|-----|-----|
| test.billages.com | A | 3.34.162.89 | 300 |

### 8.2 테스트 URL

| URL | 용도 | 현재 상태 |
|-----|------|-----------|
| `http://test.billages.com/api/actuator/health` | Backend 헬스체크 | ✅ UP |
| `http://test.billages.com/` | Frontend | - |

### 8.3 테스트 결과

```bash
$ curl http://test.billages.com/api/actuator/health
{"groups":["liveness","readiness"],"status":"UP"}
```

---

## 9. RDS Parameter Group 설정

### 9.1 적용된 파라미터

| 파라미터 | 값 | 용도 |
|----------|-----|------|
| `binlog_format` | ROW | Replication 안정성 |
| `enforce_gtid_consistency` | ON | GTID 기반 복제 지원 |
| `character_set_server` | utf8mb4 | 한글 지원 |
| `collation_server` | utf8mb4_unicode_ci | |
| `time_zone` | Asia/Seoul | |
| `slow_query_log` | 1 | 성능 모니터링 |
| `long_query_time` | 2 | |

### 9.2 GTID 설정 (참고)

RDS MySQL에서 `gtid_mode`는 직접 수정 불가능하며, `OFF_PERMISSIVE` 상태로 유지됨.
단, Host MySQL이 GTID 기반(gtid_mode=ON)이면 RDS는 GTID 트랜잭션을 수신 가능함.

---

## 10. 롤백 기준

| 지표 | 임계값 | 조치 |
|------|--------|------|
| 5xx 에러율 | > 1% | 롤백 |
| API p95 응답시간 | > 2초 | 롤백 |
| 데이터 불일치 | 감지 시 | 롤백 |

---

## 11. 결론

| 항목 | 상태 |
|------|------|
| Replication 설정 | ✅ 완료 |
| 데이터 정합성 | ✅ 검증 완료 |
| 실시간 복제 | ✅ 동작 확인 |
| Lag | ✅ 0초 |
| RDS 스펙 변경 후 복구 | ✅ 완료 |
| Cutover 스크립트 | ✅ 준비 완료 |
| 테스트 환경 (test.billages.com) | ✅ 설정 완료 |
| 본 마이그레이션 준비 | ✅ Ready |

**리허설 결과**: 성공. 본 마이그레이션 진행 가능.

---

## 12. 관련 문서

- 실행 런북: `context/migration/db-migration-runbook.md`
- 컷오버 런북: `context/migration/08-cutover-runbook.md`
- 계획서: `context/migration/01-db-migration.md`
- 롤백 런북: `context/migration/07-rollback-runbook.md`
- 트러블슈팅: `docs/troubleshooting/DB_MIGRATION_TROUBLESHOOTING.md`