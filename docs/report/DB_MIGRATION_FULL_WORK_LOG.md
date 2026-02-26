# DB 마이그레이션 전체 작업 로그

## 문서 정보

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-02-13 |
| 환경 | Dev (리허설) |
| 작성 목적 | 작업 전 과정 상세 기록 (포트폴리오/재현용) |

---

## 1. 환경 정보

### 1.1 서버 정보

| 구성요소 | 상세 |
|----------|------|
| **리허설 EC2** | ubuntu@3.34.162.89 |
| **EC2 Private IP** | 10.0.1.123 |
| **Host MySQL** | EC2 내부, MySQL 8.0.45 |
| **Host MySQL Port** | 3306 |
| **Host MySQL User** | root |

### 1.2 RDS 정보

| 항목 | 값 |
|------|-----|
| **Identifier** | billage-dev-mysql |
| **Engine** | MySQL 8.0.44 |
| **Endpoint** | billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com |
| **Port** | 3306 |
| **Admin User** | billage_admin |
| **Subnet** | Private Subnet (ap-northeast-2a, 2c) |

### 1.3 WAS 구성

| 포트 | 연결 DB | 용도 |
|------|---------|------|
| 8080 | Host MySQL | 현재 운영 |
| 8081 | RDS | 전환 대기 |

---

## 2. Terraform으로 RDS 생성

### 2.1 디렉토리 구조

```
shared/rds/dev/
├── main.tf
├── variables.tf
├── outputs.tf
└── terraform.tfvars (gitignore)
```

### 2.2 주요 리소스

**Private Subnet 생성** (`main.tf`):
```hcl
resource "aws_subnet" "private_a" {
  vpc_id                  = data.aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr_a  # 10.0.10.0/24
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = false
}

resource "aws_subnet" "private_c" {
  vpc_id                  = data.aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr_c  # 10.0.12.0/24
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = false
}
```

**Security Group** (`main.tf`):
```hcl
resource "aws_security_group" "rds" {
  name        = "billage-dev-rds-sg"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "MySQL from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]  # VPC 전체 허용
  }
}
```

**Parameter Group** (`main.tf`):
```hcl
resource "aws_db_parameter_group" "main" {
  name   = "billage-dev-mysql-params"
  family = "mysql8.0"

  # 문자셋
  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  # 타임존
  parameter {
    name  = "time_zone"
    value = "Asia/Seoul"
  }

  # GTID Replication 지원
  parameter {
    name         = "enforce_gtid_consistency"
    value        = "ON"
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "binlog_format"
    value = "ROW"
  }

  # Slow query log
  parameter {
    name  = "slow_query_log"
    value = "1"
  }
  parameter {
    name  = "long_query_time"
    value = "2"
  }
}
```

> **주의**: `gtid_mode`는 RDS에서 직접 수정 불가. 설정하지 않음.

**RDS Instance** (`main.tf`):
```hcl
resource "aws_db_instance" "main" {
  identifier           = "billage-dev-mysql"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t4g.micro"
  allocated_storage    = 20
  max_allocated_storage = 100
  storage_type         = "gp3"
  storage_encrypted    = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  db_name  = "billage"
  username = var.username
  password = var.password

  backup_retention_period = 7
  backup_window           = "18:00-19:00"  # KST 03:00-04:00

  parameter_group_name = aws_db_parameter_group.main.name
}
```

### 2.3 Terraform 적용

```bash
cd shared/rds/dev
terraform init
terraform plan
terraform apply
```

---

## 3. Host MySQL GTID 설정

### 3.1 MySQL 설정 확인

```bash
# EC2 접속
ssh -i ~/.ssh/billage-keypair.pem ubuntu@3.34.162.89

# MySQL 설정 확인
mysql -u root -p -e "SHOW VARIABLES LIKE '%gtid%';"
```

**결과**:
```
+----------------------------------+-------+
| Variable_name                    | Value |
+----------------------------------+-------+
| enforce_gtid_consistency         | ON    |
| gtid_executed                    | ...   |
| gtid_mode                        | ON    |
| gtid_owned                       |       |
| gtid_purged                      |       |
+----------------------------------+-------+
```

### 3.2 Replication 사용자 생성

```sql
-- Host MySQL에서 실행
CREATE USER 'repl_user'@'%' IDENTIFIED BY 'StrongReplicationPassword123!';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
```

### 3.3 인증 플러그인 변경

MySQL 8.0 기본 인증 플러그인(`caching_sha2_password`)은 SSL 필수.
SSL 없이 사용하려면 `mysql_native_password`로 변경:

```sql
ALTER USER 'repl_user'@'%'
  IDENTIFIED WITH mysql_native_password BY 'StrongReplicationPassword123!';
FLUSH PRIVILEGES;

-- 확인
SELECT user, host, plugin FROM mysql.user WHERE user='repl_user';
-- 결과: repl_user | % | mysql_native_password
```

---

## 4. 대용량 시딩 (300K MAU 시뮬레이션)

### 4.1 시딩 스크립트 실행

포트폴리오용 부하 테스트를 위해 대용량 데이터 생성:

```bash
# 시딩 스크립트 위치
/home/ubuntu/seed-data.sh

# 실행
./seed-data.sh
```

### 4.2 시딩 결과

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

**총 데이터 크기**: ~1.78GB

---

## 5. mysqldump 수행

### 5.1 Dump 명령어

```bash
mysqldump \
  -h localhost \
  -u root \
  -p \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --set-gtid-purged=ON \
  --set-charset \
  --default-character-set=utf8mb4 \
  billage | gzip -1 > /tmp/billage-gtid.sql.gz
```

**옵션 설명**:

| 옵션 | 설명 |
|------|------|
| `--single-transaction` | 서비스 중단 없이 일관된 스냅샷 |
| `--quick` | 대용량 테이블 메모리 효율화 |
| `--set-gtid-purged=ON` | GTID 정보 포함 (Replication용) |
| `gzip -1` | 빠른 압축 (CPU vs 크기 트레이드오프) |

### 5.2 Dump 결과

- **파일 크기**: 259MB (압축)
- **원본 크기**: ~1.78GB
- **압축률**: 약 85%

### 5.3 GTID 정보 확인

```bash
zcat /tmp/billage-gtid.sql.gz | head -50 | grep GTID
```

**결과**:
```sql
SET @@GLOBAL.GTID_PURGED='fdc65049-f838-11f0-8716-024c10e7ffa9:1';
```

---

## 6. RDS Import

### 6.1 Import 명령어

```bash
zcat /tmp/billage-gtid.sql.gz | mysql \
  -h billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com \
  -u billage_admin \
  -p \
  billage
```

### 6.2 Import 시 주의사항

- `GTID_PURGED` 설정은 Import 시 자동 적용되지 않음
- RDS에서는 `rds_set_external_source_gtid_purged` 프로시저 사용 필요

---

## 7. GTID 기반 Replication 설정

### 7.1 RDS에서 GTID Baseline 설정

```sql
-- RDS에 접속
mysql -h billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com \
  -u billage_admin -p

-- autocommit 활성화 (필수)
SET autocommit = 1;

-- GTID baseline 설정
CALL mysql.rds_set_external_source_gtid_purged('fdc65049-f838-11f0-8716-024c10e7ffa9:1');
```

### 7.2 Source 연결 설정

```sql
CALL mysql.rds_set_external_master_with_auto_position(
  '10.0.1.123',      -- Host MySQL Private IP (Public IP 사용 불가!)
  3306,              -- Port
  'repl_user',       -- Replication User
  'StrongReplicationPassword123!',  -- Password
  0,                 -- SSL 미사용
  0                  -- Delay 없음
);
```

> **중요**: RDS는 Private Subnet에 있어 Host MySQL의 **Private IP**만 연결 가능.
> Public IP(3.34.162.89) 사용 시 연결 실패.

### 7.3 Replication 시작

```sql
CALL mysql.rds_start_replication;
```

### 7.4 Replication 상태 확인

```sql
SHOW REPLICA STATUS\G
```

**정상 상태**:
```
Replica_IO_State: Waiting for master to send event
Source_Host: 10.0.1.123
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

---

## 8. GTID 트랜잭션 에러 처리

### 8.1 에러 발생

Replication 시작 후 다음 에러 발생:

```
Replica_SQL_Running: No
Last_SQL_Error: Worker 1 failed executing transaction
'fdc65049-f838-11f0-8716-024c10e7ffa9:2' at source log binlog.000052
```

### 8.2 원인 분석

Binlog 확인:
```bash
mysql -u root -p -e "SHOW BINLOG EVENTS IN 'binlog.000052' LIMIT 20;"
```

**결과**:
| GTID | 내용 |
|------|------|
| `:1` | `FLUSH TABLES` (덤프 관련) |
| `:2` | `ALTER USER 'repl_user' ... caching_sha2_password` |
| `:3` | `FLUSH PRIVILEGES` |
| `:4` | `ALTER USER 'repl_user' ... mysql_native_password` |
| `:5` | `FLUSH PRIVILEGES` |
| `:6` | `INSERT INTO billage.users` (테스트 데이터) |

`:2`와 `:4`는 `ALTER USER` DDL로, RDS에서 실행 불가능하거나 충돌 발생.

### 8.3 에러 스킵

```sql
-- 에러 스킵 (필요한 만큼 반복)
CALL mysql.rds_skip_repl_error;
CALL mysql.rds_skip_repl_error;

-- 정상 메시지 확인
-- "Slave is running normally. No errors detected to skip."
```

### 8.4 스킵 안전성

- 스킵된 트랜잭션: `ALTER USER` (MySQL 사용자 관리 DDL)
- 애플리케이션 데이터: 영향 없음
- 실제 데이터 트랜잭션 (`:1`, `:3`, `:5-6`)은 정상 적용됨

---

## 9. 데이터 정합성 검증

### 9.1 Row Count 비교

```sql
-- Host MySQL
SELECT
  (SELECT COUNT(*) FROM users) as users,
  (SELECT COUNT(*) FROM post) as post,
  (SELECT COUNT(*) FROM chat_message) as chat_message;

-- RDS
SELECT
  (SELECT COUNT(*) FROM users) as users,
  (SELECT COUNT(*) FROM post) as post,
  (SELECT COUNT(*) FROM chat_message) as chat_message;
```

**결과**:
| 테이블 | Host | RDS | 일치 |
|--------|------|-----|------|
| users | 600,014 | 600,014 | ✅ |
| chat_message | 12,000,174 | 12,000,174 | ✅ |

### 9.2 실시간 복제 테스트

```sql
-- Host MySQL에서 INSERT
INSERT INTO users (email, name) VALUES ('repl_test@test.com', 'Repl Test');

-- RDS에서 확인
SELECT * FROM users WHERE email = 'repl_test@test.com';
-- 즉시 복제 확인 ✅
```

---

## 10. RDS 스펙 변경 및 복구

### 10.1 스펙 변경

AWS Console에서 RDS 인스턴스 클래스 변경 (스펙업).

### 10.2 변경 후 Replication 에러

스펙 변경으로 RDS 재시작 → Replication 자동 재연결 → 이전에 스킵했던 GTID 재시도 → 에러 발생

```
Replica_SQL_Running: No
Last_SQL_Error: ... transaction 'fdc65049-f838-11f0-8716-024c10e7ffa9:2'
```

### 10.3 복구

```sql
CALL mysql.rds_skip_repl_error;
CALL mysql.rds_skip_repl_error;
```

### 10.4 스펙 변경 시 유지되는 것들

| 항목 | 유지 |
|------|------|
| Replication 설정 | ✅ |
| GTID purged | ✅ |
| 데이터 | ✅ |
| Replication 스레드 상태 | ❌ (재시작됨) |

---

## 11. WAS 이중 구성

### 11.1 WAS 8080 (Host MySQL)

```bash
# systemd 서비스
/etc/systemd/system/billage-backend.service

# DB 연결 설정
spring.datasource.url=jdbc:mysql://localhost:3306/billage
```

### 11.2 WAS 8081 (RDS)

```bash
# systemd 서비스
/etc/systemd/system/billage-backend-rds.service

# DB 연결 설정
spring.datasource.url=jdbc:mysql://billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com:3306/billage
```

### 11.3 헬스체크

```bash
curl http://localhost:8080/actuator/health
# {"groups":["liveness","readiness"],"status":"UP"}

curl http://localhost:8081/actuator/health
# {"groups":["liveness","readiness"],"status":"UP"}
```

---

## 12. Nginx upstream 설정

### 12.1 upstream.conf

**파일**: `/etc/nginx/conf.d/upstream.conf`

```nginx
# Backend - Host MySQL (8080)
upstream backend_host {
    server localhost:8080 max_fails=3 fail_timeout=30s;
}

# Backend - RDS (8081)
upstream backend_rds {
    server localhost:8081 max_fails=3 fail_timeout=30s;
}

# 현재 활성 Backend (스위칭 대상)
upstream backend {
    server localhost:8080 max_fails=3 fail_timeout=30s;
}

upstream frontend {
    server localhost:3001 max_fails=3 fail_timeout=30s;
}

upstream ai {
    server localhost:5000 max_fails=3 fail_timeout=30s;
}
```

### 12.2 스위칭 방식

`upstream backend` 블록의 포트만 변경:
- Host: `server localhost:8080`
- RDS: `server localhost:8081`

---

## 13. test.billages.com 설정

### 13.1 Route53 DNS 레코드 생성

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z00048363AHGKAIPSRTJT \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "test.billages.com",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "3.34.162.89"}]
      }
    }]
  }'
```

### 13.2 Nginx 설정

**파일**: `/etc/nginx/sites-available/test.conf`

```nginx
server {
    listen 80;
    server_name test.billages.com;

    client_max_body_size 20M;

    location /api/ {
        proxy_pass http://backend/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 180s;
        proxy_send_timeout 180s;
        proxy_read_timeout 180s;
    }

    location / {
        proxy_pass http://frontend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /health {
        return 200 "ok";
    }
}
```

### 13.3 Symlink 생성

```bash
sudo ln -sf /etc/nginx/sites-available/test.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

### 13.4 테스트

```bash
curl http://test.billages.com/api/actuator/health
# {"groups":["liveness","readiness"],"status":"UP"}
```

---

## 14. Cutover 스크립트 (cutover.sh)

### 14.1 2단계 Write Freeze 전략

```
┌─────────────────────────────────────────────────────────────┐
│  Soft Freeze (Nginx)        │  Hard Freeze (DB)            │
├─────────────────────────────┼──────────────────────────────┤
│  - POST/PUT/DELETE → 503    │  - read_only=ON              │
│  - 사용자 쓰기 차단         │  - 배치/크론/내부호출 차단   │
│  - UX 보호                  │  - 정합성 100% 보장          │
└─────────────────────────────┴──────────────────────────────┘
```

### 14.2 스크립트 위치

`/home/ubuntu/cutover.sh`

### 14.3 사용법

```bash
./cutover.sh run       # Cutover 실행
./cutover.sh rollback  # 롤백
./cutover.sh status    # 상태 확인
```

### 14.4 Cutover 절차

1. **Soft Freeze**: Nginx에서 POST/PUT/DELETE/PATCH → 503 반환
   - `/etc/nginx/conf.d/write-block.conf` 생성
   - `$write_block` map 변수 활용

2. **Hard Freeze**: Host MySQL `read_only=ON`
   ```sql
   SET GLOBAL read_only = ON;
   ```

3. **Lag 확인**: `Seconds_Behind_Source=0` 대기

4. **Nginx 스위칭**: `upstream backend` → 8081

5. **Soft Freeze 해제**: write-block.conf 삭제

### 14.5 Rollback 절차

1. Nginx → 8080
2. Soft Freeze 해제
3. Host MySQL `read_only=OFF`

---

## 15. 현재 상태 요약

| 항목 | 상태 |
|------|------|
| RDS 생성 | ✅ 완료 |
| GTID Replication | ✅ 동작 중 (Lag=0) |
| 데이터 정합성 | ✅ 검증 완료 |
| WAS 이중 구성 | ✅ 8080/8081 모두 UP |
| Nginx upstream | ✅ 설정 완료 |
| test.billages.com | ✅ 접속 가능 |
| cutover.sh | ✅ 준비 완료 |
| 문서화 | ✅ 완료 |

---

## 16. 관련 파일 경로

| 파일 | 경로 |
|------|------|
| Terraform (RDS) | `shared/rds/dev/main.tf` |
| Cutover Script | `/home/ubuntu/cutover.sh` |
| Nginx upstream | `/etc/nginx/conf.d/upstream.conf` |
| Nginx test.conf | `/etc/nginx/sites-available/test.conf` |
| 리허설 보고서 | `docs/report/DB_MIGRATION_REHEARSAL_REPORT.md` |
| 트러블슈팅 | `docs/troubleshooting/DB_MIGRATION_TROUBLESHOOTING.md` |
| 실행 런북 | `context/migration/db-migration-runbook.md` |

---

## 17. 다음 단계

1. `./cutover.sh run` 으로 Cutover 테스트
2. `http://test.billages.com/api/` 로 전환 확인
3. 문제 발생 시 `./cutover.sh rollback`
4. 본 마이그레이션 일정 확정
