# DB 마이그레이션 트러블슈팅 가이드

## 문서 정보

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-02-13 |
| 대상 | DB 마이그레이션 리허설 중 발생한 이슈 |
| 환경 | Dev (Host MySQL → RDS MySQL 8.0) |

---

## 목차

1. [RDS Parameter Group - gtid_mode 수정 불가](#1-rds-parameter-group---gtid_mode-수정-불가)
2. [Replication 연결 실패 - Public IP 사용](#2-replication-연결-실패---public-ip-사용)
3. [caching_sha2_password 인증 오류](#3-caching_sha2_password-인증-오류)
4. [SSL 인증서 검증 실패](#4-ssl-인증서-검증-실패)
5. [GTID 트랜잭션 충돌 - SQL 에러](#5-gtid-트랜잭션-충돌---sql-에러)
6. [Parameter Group 수정 중 상태 충돌](#6-parameter-group-수정-중-상태-충돌)
7. [Nginx upstream 설정 오류](#7-nginx-upstream-설정-오류)
8. [RDS 스펙 변경 후 Replication 에러](#8-rds-스펙-변경-후-replication-에러)

---

## 1. RDS Parameter Group - gtid_mode 수정 불가

### 증상

```
Error: modifying RDS DB Parameter Group: api error InvalidParameterValue:
The parameter gtid_mode cannot be modified.
```

### 원인

- RDS MySQL에서 `gtid_mode`는 **직접 수정 불가능한 파라미터**
- AWS에서 관리되는 시스템 파라미터로 분류됨
- Terraform이나 AWS CLI로 직접 변경 시도 시 에러 발생

### 해결 방법

**gtid_mode를 직접 변경할 필요 없음!**

RDS가 `OFF_PERMISSIVE` 모드라도 Host MySQL이 GTID 기반(gtid_mode=ON)이면:
- RDS는 GTID 트랜잭션을 **수신 가능**
- `rds_set_external_master_with_auto_position` 사용 가능
- 정상적으로 GTID 기반 Replication 동작

### 조치

1. Terraform에서 `gtid_mode` 파라미터 제거
2. `enforce_gtid_consistency = ON`만 설정 (이건 변경 가능)
3. `binlog_format = ROW` 설정

```hcl
# main.tf - Parameter Group
parameter {
  name         = "enforce_gtid_consistency"
  value        = "ON"
  apply_method = "pending-reboot"
}

parameter {
  name  = "binlog_format"
  value = "ROW"
}

# gtid_mode는 설정하지 않음!
```

---

## 2. Replication 연결 실패 - Public IP 사용

### 증상

```
Replica_IO_State: Connecting to master
Replica_IO_Running: Connecting
Last_IO_Error: (60초마다 재시도 중)
```

`SHOW REPLICA STATUS`에서 계속 "Connecting" 상태 유지

### 원인

```
┌─────────────────────────────────────────────────────────────────────┐
│  RDS (Private Subnet) ──X──▶ EC2 Public IP (3.34.162.89)           │
│                                                                     │
│  RDS는 Private Subnet에 있어 Public IP로 직접 연결 불가!           │
│  NAT Gateway 없이는 인터넷으로 나갈 수 없음                         │
└─────────────────────────────────────────────────────────────────────┘
```

### 해결 방법

**Private IP 사용**

```sql
-- 잘못된 설정 (Public IP)
CALL mysql.rds_set_external_master_with_auto_position(
  '3.34.162.89',  -- ❌ Public IP
  3306, 'repl_user', 'password', 0, 0
);

-- 올바른 설정 (Private IP)
CALL mysql.rds_set_external_master_with_auto_position(
  '10.0.1.123',   -- ✅ Private IP
  3306, 'repl_user', 'password', 0, 0
);
```

### Private IP 확인 방법

```bash
# EC2에서 Private IP 확인
hostname -I
# 출력: 10.0.1.123 172.19.0.1 ...
```

---

## 3. caching_sha2_password 인증 오류

### 증상

```
Last_IO_Error: Authentication plugin 'caching_sha2_password' reported error:
Authentication requires secure connection.
```

### 원인

- MySQL 8.0 기본 인증 플러그인: `caching_sha2_password`
- 이 플러그인은 **SSL 연결 필수**
- Replication 설정에서 SSL=0으로 했으나, 인증 플러그인이 SSL 요구

### 해결 방법

**repl_user의 인증 플러그인을 mysql_native_password로 변경**

```sql
-- Host MySQL에서 실행
ALTER USER 'repl_user'@'%'
  IDENTIFIED WITH mysql_native_password BY 'StrongReplicationPassword123!';
FLUSH PRIVILEGES;

-- 확인
SELECT user, host, plugin FROM mysql.user WHERE user='repl_user';
-- 결과: repl_user | % | mysql_native_password
```

### 주의사항

- `mysql_native_password`는 보안 수준이 낮음
- 프로덕션에서는 SSL 사용 권장 (ssl_encryption=1)
- 리허설/내부 네트워크에서는 mysql_native_password로 충분

---

## 4. SSL 인증서 검증 실패

### 증상

```
Last_IO_Error: SSL connection error: error:1416F086:SSL routines:
tls_process_server_certificate:certificate verify failed
```

### 원인

- 이전 설정에서 SSL 관련 캐시가 남아있음
- `caching_sha2_password` 에서 `mysql_native_password`로 변경 후에도 SSL 시도

### 해결 방법

**Replication 완전 초기화 후 재설정**

```sql
-- RDS에서 실행
CALL mysql.rds_stop_replication;
CALL mysql.rds_reset_external_master;

-- 재설정 (SSL=0 명시)
CALL mysql.rds_set_external_master_with_auto_position(
  '10.0.1.123',
  3306,
  'repl_user',
  'StrongReplicationPassword123!',
  0,  -- ssl_encryption = 0 (SSL 미사용)
  0   -- delay = 0
);

CALL mysql.rds_start_replication;
```

---

## 5. GTID 트랜잭션 충돌 - SQL 에러

### 증상

```
Replica_IO_Running: Yes
Replica_SQL_Running: No
Last_SQL_Error: Worker 1 failed executing transaction
'fdc65049-f838-11f0-8716-024c10e7ffa9:2' at source log binlog.000052
```

### 원인

Dump 이후 Host MySQL에서 실행된 트랜잭션이 RDS에 복제되면서 충돌:
- GTID :2 - `ALTER USER 'repl_user'` (비밀번호 변경)
- GTID :4 - `ALTER USER 'repl_user'` (플러그인 변경)

이 트랜잭션들은 RDS에서 실행 불가능하거나 중복됨.

### 해결 방법

**에러 Skip**

```sql
-- 에러 발생한 트랜잭션 건너뛰기
CALL mysql.rds_skip_repl_error;

-- 여러 에러가 있으면 반복
CALL mysql.rds_skip_repl_error;
CALL mysql.rds_skip_repl_error;

-- 정상 상태 확인
-- "Slave is running normally. No errors detected to skip." 메시지가 나오면 완료
```

### 예방 방법

1. Dump 후 Host MySQL에서 불필요한 쿼리 실행 자제
2. 시스템 관련 쿼리(CREATE USER, ALTER USER, GRANT 등)는 Dump 전에 완료
3. Replication 설정 중에는 Host MySQL 변경 최소화

---

## 6. Parameter Group 수정 중 상태 충돌

### 증상

```
Error: InvalidDBParameterGroupState: This parameter group billage-dev-mysql-params
cannot be modified because it is currently being applied to DB Instance billage-dev-mysql
```

### 원인

- 이전 Parameter Group 변경이 아직 적용 중
- RDS 상태: `modifying` 또는 `ParameterApplyStatus: applying`

### 해결 방법

**RDS 상태가 안정화될 때까지 대기**

```bash
# 상태 모니터링
aws rds describe-db-instances \
  --db-instance-identifier billage-dev-mysql \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Params:DBParameterGroups[0].ParameterApplyStatus}'

# 정상 상태
# Status: available
# Params: in-sync
```

```bash
# 모니터링 스크립트
while true; do
  STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier billage-dev-mysql \
    --query 'DBInstances[0].DBInstanceStatus' --output text)

  PARAM=$(aws rds describe-db-instances \
    --db-instance-identifier billage-dev-mysql \
    --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' --output text)

  echo "[$(date '+%H:%M:%S')] Status: $STATUS, Params: $PARAM"

  if [ "$STATUS" = "available" ] && [ "$PARAM" = "in-sync" ]; then
    echo "✅ RDS 준비 완료"
    break
  fi

  sleep 10
done
```

### pending-reboot 상태 처리

Static 파라미터(enforce_gtid_consistency 등)는 재부팅 필요:

```bash
# RDS 재부팅
aws rds reboot-db-instance --db-instance-identifier billage-dev-mysql
```

---

## 7. Nginx upstream 설정 오류

### 증상

스위칭 스크립트 실행 후에도 트래픽이 올바른 WAS로 가지 않음.
또는 `backend_rds`가 8081이 아닌 8080을 가리키고 있음.

### 원인

**잘못된 upstream.conf 설정:**

```nginx
# 잘못된 설정
upstream backend_rds {
    server localhost:8080;  # ❌ 8081이어야 함
}
```

**스위칭 스크립트 문제:**
- sed 명령이 모든 upstream의 포트를 변경함
- `backend_host`, `backend_rds`, `backend` 모두 영향 받음

### 해결 방법

**1. upstream.conf 올바르게 설정**

```nginx
# /etc/nginx/conf.d/upstream.conf

# Backend - Host MySQL (8080)
upstream backend_host {
    server localhost:8080 max_fails=3 fail_timeout=30s;
}

# Backend - RDS (8081)
upstream backend_rds {
    server localhost:8081 max_fails=3 fail_timeout=30s;  # ✅ 8081
}

# 현재 활성 Backend (전환 대상)
upstream backend {
    server localhost:8080 max_fails=3 fail_timeout=30s;  # 스위칭 대상
}
```

**2. 스위칭 스크립트 개선**

`backend` upstream만 변경하도록 sed 명령 수정:

```bash
# 잘못된 방식 (모든 포트 변경)
sudo sed -i "s/server localhost:808[01]/server localhost:$PORT/" $UPSTREAM_CONF

# 올바른 방식 (backend 블록만 변경)
sudo sed -i "/upstream backend {/,/^}/ s/server localhost:[0-9]*/server localhost:$PORT/" $UPSTREAM_CONF
```

### 스위칭 스크립트 사용법

```bash
# 위치: /home/ubuntu/switch-backend.sh

# Host MySQL로 전환 (8080)
./switch-backend.sh host

# RDS로 전환 (8081)
./switch-backend.sh rds
```

### 스위칭 후 확인

```bash
# 현재 backend 포트 확인
grep -A2 'upstream backend {' /etc/nginx/conf.d/upstream.conf

# 헬스체크
curl -s http://localhost:8080/actuator/health  # Host WAS
curl -s http://localhost:8081/actuator/health  # RDS WAS
```

---

## 부록: Cutover 절차 (2단계 Write Freeze)

### 2단계 Write Freeze 전략

```
┌─────────────────────────────────────────────────────────────┐
│  Soft Freeze (Nginx)        │  Hard Freeze (DB)            │
├─────────────────────────────┼──────────────────────────────┤
│  - POST/PUT/DELETE → 503    │  - read_only=ON              │
│  - 사용자 쓰기 차단         │  - 배치/크론/내부호출 차단   │
│  - UX 보호, DB 부하 감소    │  - 정합성 100% 보장          │
└─────────────────────────────┴──────────────────────────────┘
```

### 통합 스크립트 사용 (권장)

```bash
# 위치: /home/ubuntu/cutover.sh

# 전환 실행 (Host → RDS)
./cutover.sh run

# 롤백 (RDS → Host)
./cutover.sh rollback

# 상태 확인
./cutover.sh status
```

### 전환 절차 (Host → RDS)

```bash
# 1. Soft Freeze - Nginx에서 POST/PUT/DELETE 차단
# (write-block.conf 생성, 503 반환)

# 2. Hard Freeze - Host MySQL read_only=ON
mysql -u root -p -e "SET GLOBAL read_only = ON;"

# 3. 최종 Lag 확인 (0초 확인)
mysql -h RDS_ENDPOINT -u admin -p -e "SHOW REPLICA STATUS\G" | grep Seconds_Behind

# 4. Nginx 스위칭 (backend → 8081)
sudo sed -i '/upstream backend {/,/^}/ s/server localhost:[0-9]*/server localhost:8081/' /etc/nginx/conf.d/upstream.conf
sudo nginx -t && sudo systemctl reload nginx

# 5. Soft Freeze 해제 (RDS로 전환 완료)
sudo rm -f /etc/nginx/conf.d/write-block.conf
sudo systemctl reload nginx

# 6. 헬스체크
curl -s http://test.billages.com/api/actuator/health
```

### 롤백 절차 (RDS → Host)

```bash
# 1. Nginx 롤백 (backend → 8080)
sudo sed -i '/upstream backend {/,/^}/ s/server localhost:[0-9]*/server localhost:8080/' /etc/nginx/conf.d/upstream.conf
sudo nginx -t && sudo systemctl reload nginx

# 2. Soft Freeze 해제
sudo rm -f /etc/nginx/conf.d/write-block.conf
sudo systemctl reload nginx

# 3. Host MySQL read_only=OFF
mysql -u root -p -e "SET GLOBAL read_only = OFF;"

# 4. 헬스체크
curl -s http://test.billages.com/api/actuator/health
```

---

## 부록: 유용한 진단 명령어

### Host MySQL 상태 확인

```bash
# GTID 상태
mysql -e "SELECT @@server_uuid, @@GLOBAL.gtid_executed;"

# Binlog 상태
mysql -e "SHOW MASTER STATUS\G"

# 사용자 권한
mysql -e "SHOW GRANTS FOR 'repl_user'@'%';"

# MySQL 설정
mysql -e "SHOW VARIABLES LIKE '%gtid%';"
```

### RDS Replica 상태 확인

```sql
-- 전체 상태
SHOW REPLICA STATUS\G

-- 핵심 항목만
SHOW REPLICA STATUS\G | grep -E "Running|Behind|Error|State"

-- GTID 확인
SELECT @@GLOBAL.gtid_executed, @@GLOBAL.gtid_purged;
```

### 네트워크 연결 테스트

```bash
# RDS에서 Host로 연결 테스트 (EC2에서 실행)
mysql -h billage-dev-mysql.xxx.rds.amazonaws.com -u billage_admin -p \
  -e "SELECT 1;"

# Host MySQL 포트 확인
sudo ss -tlnp | grep 3306
```

---

## 8. RDS 스펙 변경 후 Replication 에러

### 증상

RDS 인스턴스 클래스(스펙) 변경 후 Replication이 멈춤:

```
Replica_IO_Running: Yes
Replica_SQL_Running: No
Last_SQL_Error: Worker 1 failed executing transaction
'fdc65049-f838-11f0-8716-024c10e7ffa9:2' at source log binlog.000052
```

### 원인

- RDS 스펙 변경 시 인스턴스가 재시작됨
- 재시작 후 Replication이 자동 재연결됨
- 이전에 스킵했던 GTID 트랜잭션을 다시 시도하면서 에러 발생

### 스펙 변경 시 Replication 동작

| 항목 | 유지 여부 |
|------|----------|
| Replication 설정 (Source 연결 정보) | ✅ 유지됨 |
| GTID purged 설정 | ✅ 유지됨 |
| 데이터 | ✅ 유지됨 |
| Replication 스레드 | ❌ 재시작 필요 |

### 해결 방법

**이전과 동일하게 에러 스킵**:

```sql
-- RDS에서 실행
CALL mysql.rds_skip_repl_error;

-- 여러 에러가 있으면 반복
CALL mysql.rds_skip_repl_error;

-- "Slave is running normally" 메시지가 나올 때까지 반복
```

### 스킵해도 안전한 이유

Binlog 분석 결과:

| GTID | 내용 | 데이터 영향 |
|------|------|------------|
| `:2` | `ALTER USER 'repl_user' ... caching_sha2_password` | 없음 (DDL) |
| `:4` | `ALTER USER 'repl_user' ... mysql_native_password` | 없음 (DDL) |

- 스킵되는 트랜잭션은 `ALTER USER` (MySQL 사용자 관리 DDL)
- 애플리케이션 데이터와 무관
- 실제 데이터 변경 트랜잭션 (`:1`, `:3`, `:5-6`)은 정상 적용됨

### Binlog 확인 명령어

```bash
# Host MySQL에서 실행
mysql -u root -p -e "SHOW BINLOG EVENTS IN 'binlog.000052' LIMIT 20;"
```

### 예방 방법

1. 스펙 변경 전 현재 Replication 상태 기록
2. 스펙 변경 후 `SHOW REPLICA STATUS\G` 확인
3. 에러 발생 시 `rds_skip_repl_error` 실행
4. `Seconds_Behind_Source: 0` 확인

---

## 관련 문서

- [AWS RDS MySQL Replication](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Procedural.Importing.External.Repl.html)
- [RDS Stored Procedures](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/mysql_rds_set_external_master_with_auto_position.html)
- 리허설 보고서: `docs/report/DB_MIGRATION_REHEARSAL_REPORT.md`
- 실행 런북: `context/migration/db-migration-runbook.md`