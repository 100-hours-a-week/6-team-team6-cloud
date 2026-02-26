# Billage DB 마이그레이션 리허설 Runbook

## 개요
- **서비스**: Billage (렌탈 플랫폼)
- **목표**: Host MySQL → RDS MySQL **무중단** 마이그레이션
- **대상 부하**: 300K MAU (DAU ~10,000, 동시접속 ~1,000, 피크 RPS ~900)
- **마이그레이션 전략**: **MySQL Replication 기반 (Replica Lag 추적 + 최소 Write Freeze)**
- **문서 버전**: v2.0
- **작성일**: 2026-02-12
- **최종 수정**: 2026-02-13

---

## 진행 상황

### 리허설 환경 (2026-02-13 완료)

| 항목 | 상태 | 비고 |
|------|------|------|
| 리허설 EC2 | ✅ 완료 | `3.34.162.89` (Terraform 관리) |
| Host MySQL 시딩 | ✅ 완료 | 1,328만 건, 1.78GB |
| WAS 8080 (Host) | ✅ 구성 완료 | 기본 라우팅 |
| WAS 8081 (RDS) | ✅ 구성 완료 | `.env.rds` 환경변수 |
| Nginx 스위칭 | ✅ 구성 완료 | `/home/ubuntu/switch-backend.sh` |
| RDS 연결 테스트 | ✅ 완료 | `billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com` |

### 시딩 데이터 현황

| 테이블 | 건수 | 크기 |
|--------|------|------|
| chat_message | **12,000,174** | 776 MB |
| users | **600,013** | 67 MB |
| membership | **600,013** | 18.6 MB |
| post | **60,014** | 5.5 MB |
| chatroom | **20,039** | 1.5 MB |
| billage_group | **201** | 0.02 MB |
| **합계** | **~1,328만 건** | **~1.78 GB** |

---

## 마이그레이션 전략: Replica 기반 무중단 전환

### 왜 Replica 방식인가?

기존 "mysqldump → Write Freeze → Delta 이관" 방식은 쓰기 중단 시간이 길어질 수 있다.
Replica 방식은 **실시간 동기화**를 통해 Write Freeze 시간을 **수 초 이내**로 최소화한다.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Replica 기반 무중단 마이그레이션                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Phase 1: 초기 동기화                                                   │
│  ┌─────────────┐    mysqldump         ┌─────────────┐                  │
│  │ Host MySQL  │ ──────────────────── │   RDS       │                  │
│  │ (Source)    │  --single-transaction│ (Replica)   │                  │
│  └─────────────┘  (GTID set 기록)     └─────────────┘                  │
│                                                                          │
│  Phase 2: Replication 시작                                              │
│  ┌─────────────┐    GTID stream       ┌─────────────┐                  │
│  │ Host MySQL  │ ═══════════════════▶ │   RDS       │                  │
│  │ (Source)    │    실시간 동기화     │ (Replica)   │                  │
│  └─────────────┘                      └─────────────┘                  │
│        │                                     │                          │
│        │ Lag 모니터링                        │                          │
│        │ Seconds_Behind_Source = 0          │                          │
│        ▼                                     ▼                          │
│  Phase 3: 전환 (Write Freeze ~5초)                                      │
│  ┌─────────────┐                      ┌─────────────┐                  │
│  │ Host MySQL  │ ── 쓰기 중단 ──────▶ │   RDS       │                  │
│  │ (Source)    │    Lag 0 확인        │ (Primary)   │                  │
│  └─────────────┘                      └─────────────┘                  │
│                                              │                          │
│                                              ▼                          │
│                                       트래픽 전환                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 핵심 포인트

1. **GTID 기준 복제**: `@@GLOBAL.gtid_executed`를 기준으로 auto-position 복제 시작
2. **Replication 설정**: RDS를 Host MySQL의 Replica로 구성
3. **Lag 모니터링**: `SHOW REPLICA STATUS` → `Seconds_Behind_Source`
4. **전환**: Lag=0 확인 후 수 초간 Write Freeze → 트래픽 전환

---

# Part 1: 사전 준비 (D-2 ~ D-1)

## 1.1 리허설 환경 구성

### Step 1.1.1: Prod AMI 생성
**목표**: 현재 Prod 환경의 완전한 스냅샷 생성

**사전 확인**:
- [ ] Prod EC2 인스턴스가 정상 상태인지 확인
  ```bash
  # 리허설 기획자가 Prod EC2에서 실행
  curl http://localhost:8080/actuator/health
  curl http://localhost:3000/api/health
  ```
- [ ] Prod MySQL 정상 여부 확인
  ```bash
  mysql -u root -p -e "SELECT @@version, @@server_id;"
  ```

**실행 단계**:

1. **Prod EC2 스냅샷 생성** (AWS Console 또는 CLI)
   ```bash
   # 스냅샷 생성 (Prod EC2의 모든 EBS 볼륨)
   aws ec2 create-snapshots \
     --source-resources i-{prod-instance-id} \
     --description "Billage Prod Snapshot for Rehearsal - $(date +%Y%m%d-%H%M%S)" \
     --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=billage-prod-rehearsal},{Key=Purpose,Value=migration-rehearsal}]'

   # 스냅샷 ID 기록 (이후 사용)
   SNAPSHOT_ID={출력된_snapshot_id}
   ```
   **소요 시간**: 5-10분 (EBS 크기에 따라)

2. **AMI 생성**
   ```bash
   # EBS 스냅샷 ID 수집 (루트 볼륨 + 데이터 볼륨)
   ROOT_SNAPSHOT=$(aws ec2 describe-snapshots --snapshot-ids $SNAPSHOT_ID \
     --query 'Snapshots[0].SnapshotId' --output text)

   # AMI 생성
   aws ec2 create-image \
     --instance-id i-{prod-instance-id} \
     --name "billage-prod-rehearsal-$(date +%Y%m%d-%H%M%S)" \
     --description "Billage Prod AMI for DB Migration Rehearsal" \
     --tag-specifications 'ResourceType=image,Tags=[{Key=Name,Value=billage-prod-rehearsal},{Key=Purpose,Value=migration-rehearsal}]'

   # AMI ID 기록
   AMI_ID={출력된_ami_id}
   echo "AMI_ID: $AMI_ID" >> /tmp/rehearsal-ids.txt
   ```
   **소요 시간**: 5분 (EBS 스냅샷 복사 포함)

3. **AMI 생성 완료 대기**
   ```bash
   aws ec2 wait image-available --image-ids $AMI_ID
   echo "AMI 생성 완료: $AMI_ID"
   ```

**기록**:
- [ ] AMI ID: ___________________
- [ ] AMI 생성 완료 시각: ___________

---

### Step 1.1.2: 리허설 EC2 인스턴스 시작

**실행**:
```bash
# 보안 그룹 ID 확인 (Prod와 동일하거나 새로 생성)
SG_ID=sg-{rehearsal-sg-id}

# 리허설 EC2 시작
aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t4g.medium \
  --key-name {your-key-name} \
  --security-group-ids $SG_ID \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=billage-rehearsal-ec2},{Key=Purpose,Value=migration-rehearsal}]' \
  --monitoring Enabled=true

REHEARSAL_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=billage-rehearsal-ec2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

echo "REHEARSAL_INSTANCE_ID: $REHEARSAL_INSTANCE_ID" >> /tmp/rehearsal-ids.txt
```

**소요 시간**: 3-5분

**보안 그룹 설정 확인**:
```bash
# 다음 포트가 열려있는지 확인
# 80 (HTTP), 443 (HTTPS), 8080 (WAS-Host), 8081 (WAS-RDS),
# 3306 (MySQL), 22 (SSH)
aws ec2 describe-security-groups --group-ids $SG_ID
```

**기록**:
- [ ] 리허설 EC2 ID: ___________________
- [ ] 리허설 EC2 퍼블릭 IP: ___________________
- [ ] EC2 시작 완료 시각: ___________

---

### Step 1.1.3: Elastic IP 할당 및 부하 테스트 준비

```bash
# 리허설 EC2에 Elastic IP 할당
ELASTIC_IP=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=billage-rehearsal-eip}]' \
  --query 'PublicIp' --output text)

# Elastic IP를 인스턴스에 연결
aws ec2 associate-address \
  --instance-id $REHEARSAL_INSTANCE_ID \
  --public-ip $ELASTIC_IP

echo "ELASTIC_IP: $ELASTIC_IP" >> /tmp/rehearsal-ids.txt
echo "부하 테스트는 다음 주소로 진행: http://$ELASTIC_IP"
```

**기록**:
- [ ] Elastic IP: ___________________

---

### Step 1.1.4: RDS 프로비저닝 확인

**현재 상태 확인**:
```bash
# RDS 인스턴스 존재 여부 확인
aws rds describe-db-instances \
  --db-instance-identifier billage-rds-rehearsal \
  --query 'DBInstances[0].{Endpoint:Endpoint.Address,Port:Endpoint.Port,Status:DBInstanceStatus}'
```

**만약 RDS가 없다면 생성** (Terraform 사용):
```bash
cd /sessions/admiring-laughing-hawking/mnt/terraform/context/migration

# RDS Terraform 파일 확인/수정
cat shared/rds/rehearsal/main.tf

# 적용
terraform apply -target=aws_db_instance.billage_rds_rehearsal

# RDS 생성 완료 대기 (10-15분)
aws rds describe-db-instances \
  --db-instance-identifier billage-rds-rehearsal \
  --query 'DBInstances[0].DBInstanceStatus'
```

**RDS 접근 가능성 테스트** (리허설 EC2에서):
```bash
ssh -i {your-key} ubuntu@$ELASTIC_IP

# EC2 내부에서
mysql -h {RDS_ENDPOINT} -u billage_admin -p -e "SELECT @@version, @@server_id;"
# 암호: AWS Secrets Manager에서 조회
```

**기록**:
- [ ] RDS Endpoint: ___________________
- [ ] RDS 상태: ___________________
- [ ] RDS 접근 가능 확인: Y/N

---

## 1.2 테스트 데이터 시딩 (300K MAU 1개월치 시뮬레이션)

### 왜 시딩이 필요한가?

현재 운영 데이터는 수 MB~수십 MB 수준으로 매우 적다. 이 상태로 리허설을 진행하면 mysqldump가 1초 만에 끝나고, 인덱스 스캔 패턴도 실서비스와 다르게 동작하여 성능 비교에 의미가 없다.

300K MAU 서비스가 1개월간 운영된 상태를 시뮬레이션하여, DB 크기 약 1.5~3GB 수준에서 리허설을 수행한다. 이를 통해:
- mysqldump 소요 시간이 의미 있는 수치(5-10분)로 측정됨
- SELECT 쿼리가 실서비스와 유사한 인덱스 경로를 타게 됨
- Replication Lag 패턴이 현실적으로 나타남

> **참고**: 리허설에서 검증하려는 "delta"는 부하 테스트가 실시간으로 생성한다. 시딩은 Base 데이터(읽기 성능을 현실적으로 만드는 용도)이며, delta는 별도로 넣지 않는다.

### 시딩 데이터 규모 산정

| 테이블 | 산정 근거 | 목표 건수 | 예상 크기 |
|--------|----------|----------|----------|
| users | 300K MAU = 누적 가입자 약 30만 | 300,000건 | ~100MB |
| billage_group | 커뮤니티 그룹 | 100건 | ~1KB |
| membership | 유저-그룹 연결 (1:1) | 300,000건 | ~20MB |
| post | 유저의 10%가 등록 | 30,000건 | ~30MB |
| chatroom | 거래 문의 기반 | 10,000건 | ~5MB |
| chat_message | DAU 1만 × 20msg × 30일 | 6,000,000건 | ~1.5GB |

**총 예상 크기: 약 1.6~2GB**

### Step 1.2.0: 시딩 스크립트 실행

**리허설 EC2에서 실행한다.**

> 주의: 시딩은 리허설 EC2의 Host MySQL에만 수행한다. RDS에는 시딩 후 mysqldump로 이관한다.

```bash
# 시딩 스크립트 생성
cat > /tmp/seed_data.sql << 'SEED_EOF'

-- ============================================
-- Billage 300K MAU 1개월치 시뮬레이션 데이터
-- 대상: 리허설 환경 전용 (Prod에 절대 실행 금지)
-- 실제 테이블 구조 기준 (2026-02-12 확인)
-- ============================================

SET FOREIGN_KEY_CHECKS = 0;
SET AUTOCOMMIT = 0;
SET UNIQUE_CHECKS = 0;

-- ----- 1. billage_group (100건) -----
DELIMITER //
DROP PROCEDURE IF EXISTS seed_groups//
CREATE PROCEDURE seed_groups()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE total INT DEFAULT 100;

    WHILE i <= total DO
        INSERT IGNORE INTO billage_group (group_name, created_at, updated_at)
        VALUES (
            CONCAT('테스트그룹_', i),
            NOW() - INTERVAL FLOOR(RAND() * 60) DAY,
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY
        );
        SET i = i + 1;
    END WHILE;
    COMMIT;
    SELECT 'billage_group: 100건 완료' AS progress;
END//
DELIMITER ;

CALL seed_groups();
DROP PROCEDURE IF EXISTS seed_groups;

-- ----- 2. users (30만건) -----
DELIMITER //
DROP PROCEDURE IF EXISTS seed_users//
CREATE PROCEDURE seed_users()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE total INT DEFAULT 300000;

    WHILE i <= total DO
        INSERT IGNORE INTO users (login_id, password, nickname, avatar_url, created_at, updated_at)
        VALUES (
            CONCAT('user_', i),
            '$2a$10$abcdefghijklmnopqrstuvwxyz012345678901234567890123',
            CONCAT('테스트유저_', i),
            CONCAT('https://avatar.test/', i, '.png'),
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY,
            NOW() - INTERVAL FLOOR(RAND() * 15) DAY
        );

        IF i % 10000 = 0 THEN
            COMMIT;
            SELECT CONCAT('users: ', i, '/', total, ' (', ROUND(i/total*100,1), '%)') AS progress;
        END IF;
        SET i = i + 1;
    END WHILE;
    COMMIT;
END//
DELIMITER ;

CALL seed_users();
DROP PROCEDURE IF EXISTS seed_users;

-- ----- 3. membership (30만건) -----
DELIMITER //
DROP PROCEDURE IF EXISTS seed_membership//
CREATE PROCEDURE seed_membership()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE total INT DEFAULT 300000;

    WHILE i <= total DO
        INSERT IGNORE INTO membership (group_id, user_id, created_at, updated_at)
        VALUES (
            FLOOR(1 + RAND() * 100),
            i,
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY,
            NOW() - INTERVAL FLOOR(RAND() * 15) DAY
        );

        IF i % 10000 = 0 THEN
            COMMIT;
            SELECT CONCAT('membership: ', i, '/', total, ' (', ROUND(i/total*100,1), '%)') AS progress;
        END IF;
        SET i = i + 1;
    END WHILE;
    COMMIT;
END//
DELIMITER ;

CALL seed_membership();
DROP PROCEDURE IF EXISTS seed_membership;

-- ----- 4. post (3만건) -----
DELIMITER //
DROP PROCEDURE IF EXISTS seed_posts//
CREATE PROCEDURE seed_posts()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE total INT DEFAULT 30000;

    WHILE i <= total DO
        INSERT IGNORE INTO post (membership_id, title, content, rental_fee, fee_unit, rental_status, image_count, created_at, updated_at)
        VALUES (
            FLOOR(1 + RAND() * 300000),
            CONCAT('테스트물품_', i),
            CONCAT('리허설용 테스트 물품입니다. ID: ', i),
            FLOOR(1000 + RAND() * 50000),
            ELT(FLOOR(1 + RAND() * 3), 'DAY', 'WEEK', 'MONTH'),
            ELT(FLOOR(1 + RAND() * 3), 'AVAILABLE', 'RENTED', 'COMPLETED'),
            FLOOR(RAND() * 5),
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY,
            NOW() - INTERVAL FLOOR(RAND() * 15) DAY
        );

        IF i % 5000 = 0 THEN
            COMMIT;
            SELECT CONCAT('post: ', i, '/', total, ' (', ROUND(i/total*100,1), '%)') AS progress;
        END IF;
        SET i = i + 1;
    END WHILE;
    COMMIT;
END//
DELIMITER ;

CALL seed_posts();
DROP PROCEDURE IF EXISTS seed_posts;

-- ----- 5. chatroom (1만건) -----
DELIMITER //
DROP PROCEDURE IF EXISTS seed_chatrooms//
CREATE PROCEDURE seed_chatrooms()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE total INT DEFAULT 10000;

    WHILE i <= total DO
        INSERT IGNORE INTO chatroom (post_id, buyer_id, room_status, created_at, updated_at)
        VALUES (
            FLOOR(1 + RAND() * 30000),
            FLOOR(1 + RAND() * 300000),
            ELT(FLOOR(1 + RAND() * 2), 'ACTIVE', 'CLOSED'),
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY,
            NOW() - INTERVAL FLOOR(RAND() * 15) DAY
        );

        IF i % 2000 = 0 THEN
            COMMIT;
            SELECT CONCAT('chatroom: ', i, '/', total, ' (', ROUND(i/total*100,1), '%)') AS progress;
        END IF;
        SET i = i + 1;
    END WHILE;
    COMMIT;
END//
DELIMITER ;

CALL seed_chatrooms();
DROP PROCEDURE IF EXISTS seed_chatrooms;

-- ----- 6. chat_message (600만건) - 가장 큰 테이블 -----
DELIMITER //
DROP PROCEDURE IF EXISTS seed_messages//
CREATE PROCEDURE seed_messages()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE total INT DEFAULT 6000000;

    WHILE i <= total DO
        INSERT INTO chat_message (id, sender_id, chatroom_id, content, created_at, updated_at)
        VALUES (
            i,
            FLOOR(1 + RAND() * 300000),
            FLOOR(1 + RAND() * 10000),
            CONCAT('리허설 메시지 #', i),
            NOW() - INTERVAL FLOOR(RAND() * 30 * 24 * 60) MINUTE,
            NOW() - INTERVAL FLOOR(RAND() * 15 * 24 * 60) MINUTE
        );

        IF i % 100000 = 0 THEN
            COMMIT;
            SELECT CONCAT('chat_message: ', i, '/', total, ' (', ROUND(i/total*100,1), '%)') AS progress;
        END IF;
        SET i = i + 1;
    END WHILE;
    COMMIT;
END//
DELIMITER ;

CALL seed_messages();
DROP PROCEDURE IF EXISTS seed_messages;

-- 복원
SET FOREIGN_KEY_CHECKS = 1;
SET UNIQUE_CHECKS = 1;
SET AUTOCOMMIT = 1;

SELECT '===== 시딩 완료! =====' AS result;

SEED_EOF

echo "시딩 스크립트 생성 완료: /tmp/seed_data.sql"
```

> **참고**: 이 스크립트는 2026-02-12 기준 실제 Billage 테이블 구조(users, billage_group, membership, post, chatroom, chat_message)에 맞춰 작성되었다.

**시딩 실행**:
```bash
# 시딩 시작 시각 기록
SEED_START=$(date '+%Y-%m-%d %H:%M:%S')
echo "시딩 시작: $SEED_START"

# 실행 (소요: 약 20-40분, chat_messages 600만건이 대부분)
mysql -h localhost -u root -p billage < /tmp/seed_data.sql

# 시딩 완료 시각 기록
SEED_END=$(date '+%Y-%m-%d %H:%M:%S')
echo "시딩 완료: $SEED_END"
```

**시딩 결과 확인**:
```bash
mysql -h localhost -u root -p billage -e "
SELECT
    table_name AS '테이블',
    table_rows AS '건수(추정)',
    ROUND(data_length / 1024 / 1024, 2) AS '데이터(MB)',
    ROUND(index_length / 1024 / 1024, 2) AS '인덱스(MB)',
    ROUND((data_length + index_length) / 1024 / 1024, 2) AS '합계(MB)'
FROM information_schema.tables
WHERE table_schema = 'billage'
ORDER BY data_length DESC;
"
```

**기록**:
- [ ] 시딩 시작 시각: ___________
- [ ] 시딩 완료 시각: ___________
- [ ] 총 소요 시간: ___________분
- [ ] DB 전체 크기: ___________GB
- [ ] users 건수: ___________건
- [ ] billage_group 건수: ___________건
- [ ] membership 건수: ___________건
- [ ] post 건수: ___________건
- [ ] chatroom 건수: ___________건
- [ ] chat_message 건수: ___________건

**Go/No-Go**:
- [ ] 전체 DB 크기가 1.5GB 이상인가? → 미달 시 chat_message 건수를 늘려 재시딩
- [ ] 모든 테이블에 데이터가 정상 삽입되었는가?
- [ ] FK 무결성 에러가 없는가? (FOREIGN_KEY_CHECKS=0으로 넣었으므로, 일부 고아 레코드 허용)

---

## 1.3 Replica 기반 데이터 이관 (Host MySQL → RDS)

> **핵심**: Position 기반이 아니라 **GTID(auto-position)** 기준으로 복제를 시작한다.

### Step 1.3.0: Host MySQL GTID 설정 확인

**Replication을 위한 필수 설정 확인**:
```bash
# 리허설 EC2에서 Host MySQL 설정 확인 (GTID 필수)
mysql -h localhost -u root -p -e "
SHOW VARIABLES LIKE 'gtid_mode';
SHOW VARIABLES LIKE 'enforce_gtid_consistency';
SHOW VARIABLES LIKE 'log_bin';
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'server_id';
SELECT @@server_uuid;
SELECT @@GLOBAL.gtid_executed;
"
```

**예상 결과**:
```
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| gtid_mode     | ON    |   ← 필수!
| enforce_gtid_consistency | ON | ← 필수!
| log_bin       | ON    |   ← 필수!
| binlog_format | ROW   |   ← ROW 권장
| server_id     | 1     |   ← 0이 아닌 값
+---------------+-------+
```

**GTID/Replication 설정이 OFF인 경우 활성화** (재시작 필요):
```bash
# /etc/mysql/mysql.conf.d/mysqld.cnf 또는 /etc/my.cnf
[mysqld]
gtid_mode = ON
enforce_gtid_consistency = ON
server-id = 1
log_bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
binlog_expire_logs_seconds = 604800  # 7일
max_binlog_size = 100M
```

```bash
sudo systemctl restart mysql
```

**기록**:
- [ ] gtid_mode: ON / OFF
- [ ] enforce_gtid_consistency: ON / OFF
- [ ] log_bin: ON / OFF
- [ ] binlog_format: ___________
- [ ] server_id: ___________
- [ ] source server_uuid: ___________
- [ ] source gtid_executed: ___________

---

### Step 1.3.1: Host MySQL에서 Dump 생성 (GTID 기준)

**리허설 EC2에 SSH 접속**:
```bash
ssh -i ~/.ssh/billage-keypair.pem ubuntu@3.34.162.89
```

**Dump 생성 (`--single-transaction` + `gzip`)**:
```bash
# 시간 기록 시작
DUMP_START=$(date +%s)
DUMP_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "Dump 시작: $DUMP_START_TIME"

# Host MySQL에서 전체 데이터 추출
mysqldump \
  -h localhost \
  -u root \
  -p \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --set-gtid-purged=OFF \
  --set-charset \
  --default-character-set=utf8mb4 \
  billage | gzip -1 > /tmp/billage-replication.sql.gz

# 완료 시간 기록
DUMP_END=$(date +%s)
DUMP_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
DUMP_DURATION=$((DUMP_END - DUMP_START))

# Dump 파일 크기 확인
DUMP_SIZE=$(du -sh /tmp/billage-replication.sql.gz | cut -f1)
echo "Dump 완료: $DUMP_END_TIME"
echo "Dump 소요 시간: ${DUMP_DURATION}초"
echo "Dump 파일 크기: $DUMP_SIZE"

# GTID 기준점 기록 (auto-position 용)
SOURCE_UUID=$(mysql -h localhost -u root -p -Nse "SELECT @@server_uuid;")
SOURCE_GTID_EXECUTED=$(mysql -h localhost -u root -p -Nse "SELECT @@GLOBAL.gtid_executed;")

echo "SOURCE_UUID: $SOURCE_UUID"
echo "SOURCE_GTID_EXECUTED: $SOURCE_GTID_EXECUTED"

cat > /tmp/source-gtid.txt << EOF
SOURCE_UUID=$SOURCE_UUID
SOURCE_GTID_EXECUTED=$SOURCE_GTID_EXECUTED
EOF

# 기록 파일에 저장
cat >> /tmp/rehearsal-timeline.txt << EOF
=== Phase 1.3.1: Host MySQL Dump (GTID) ===
시작 시각: $DUMP_START_TIME
종료 시각: $DUMP_END_TIME
소요 시간: ${DUMP_DURATION}초
파일 크기: $DUMP_SIZE
SOURCE_UUID: $SOURCE_UUID
SOURCE_GTID_EXECUTED: $SOURCE_GTID_EXECUTED
EOF
```

> 참고: 데이터 10GB+ 구간에서는 스키마/데이터 분리, 인덱스/FK 후생성을 별도 리허설 후 적용 검토.

**대용량 이관 성능 메모 (포트폴리오 기록 권장)**:
- `--single-transaction`: 서비스 중단 없이 일관된 스냅샷 덤프를 보장
- `gzip`: 덤프 파일 크기/전송 시간 절감(대신 CPU 사용량 증가)
- 인덱스/FK 후생성: 대용량에서 유리할 수 있으나 운영 복잡도 증가(사전 리허설 필수)
- GUI 도구(DBeaver 등): 탐색/부분 검증 보조용으로 사용, 운영 컷오버는 CLI 런북 기준

**소요 시간 추정**:
- 500MB: ~2분
- 1GB: ~4분
- 5GB: ~15분

**기록**:
- [ ] Dump 시작 시각: ___________
- [ ] Dump 완료 시각: ___________
- [ ] Dump 파일 크기: ___________
- [ ] Dump 소요 시간: ___________

---

### Step 1.3.2: RDS에 Dump 임포트

**RDS Endpoint 확인**:
```bash
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier billage-rds-rehearsal \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo "RDS Endpoint: $RDS_ENDPOINT"
```

**Dump 임포트**:
```bash
# RDS에 임포트 시작
IMPORT_START=$(date +%s)
IMPORT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "Import 시작: $IMPORT_START_TIME"

mysql \
  -h $RDS_ENDPOINT \
  -u billage_admin \
  -p \
  billage < <(gunzip -c /tmp/billage-replication.sql.gz)

# 완료
IMPORT_END=$(date +%s)
IMPORT_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
IMPORT_DURATION=$((IMPORT_END - IMPORT_START))

echo "Import 완료: $IMPORT_END_TIME"
echo "Import 소요 시간: ${IMPORT_DURATION}초"

# 기록
cat >> /tmp/rehearsal-timeline.txt << EOF
=== Phase 1.3.2: RDS Import ===
시작 시각: $IMPORT_START_TIME
종료 시각: $IMPORT_END_TIME
소요 시간: ${IMPORT_DURATION}초
EOF
```

**소요 시간 추정**: Dump 크기의 1.2배 정도 (네트워크 + 인덱싱)

**기록**:
- [ ] Import 시작 시각: ___________
- [ ] Import 완료 시각: ___________
- [ ] Import 소요 시간: ___________

---

### Step 1.3.3: 데이터 검증

**테이블 목록 비교**:
```bash
# Host MySQL
echo "=== Host MySQL Tables ==="
mysql -h localhost -u root -p{password} billage -e \
  "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='billage' ORDER BY TABLE_NAME;" > /tmp/host-tables.txt

# RDS
echo "=== RDS Tables ==="
mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='billage' ORDER BY TABLE_NAME;" > /tmp/rds-tables.txt

# 비교
diff /tmp/host-tables.txt /tmp/rds-tables.txt
echo "테이블 목록 일치: $?"
```

**Row Count 비교**:
```bash
# 각 테이블별 Row count 비교 스크립트
cat > /tmp/compare-rowcount.sql << 'EOF'
SELECT
  TABLE_NAME,
  TABLE_ROWS,
  'Host' as source
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='billage'
ORDER BY TABLE_NAME;
EOF

echo "=== Host MySQL Row Counts ==="
mysql -h localhost -u root -p{password} < /tmp/compare-rowcount.sql > /tmp/host-rowcount.txt

echo "=== RDS Row Counts ==="
mysql -h $RDS_ENDPOINT -u billage_admin -p < /tmp/compare-rowcount.sql > /tmp/rds-rowcount.txt

echo "Row count 비교:"
diff /tmp/host-rowcount.txt /tmp/rds-rowcount.txt
```

**Checksum 검증**:
```bash
# Host MySQL (주요 테이블만)
echo "=== Host MySQL Checksum ==="
mysql -h localhost -u root -p{password} billage -e \
  "CHECKSUM TABLE users, items, rentals, chats, payments \G" > /tmp/host-checksum.txt

# RDS
echo "=== RDS Checksum ==="
mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "CHECKSUM TABLE users, items, rentals, chats, payments \G" > /tmp/rds-checksum.txt

# 비교
diff /tmp/host-checksum.txt /tmp/rds-checksum.txt
echo "Checksum 일치: $?"
```

**AUTO_INCREMENT 확인**:
```bash
# Host
mysql -h localhost -u root -p{password} billage -e \
  "SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='billage' AND AUTO_INCREMENT IS NOT NULL \G" > /tmp/host-auto-inc.txt

# RDS
mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='billage' AND AUTO_INCREMENT IS NOT NULL \G" > /tmp/rds-auto-inc.txt

diff /tmp/host-auto-inc.txt /tmp/rds-auto-inc.txt
```

**검증 기록**:
- [ ] 테이블 목록 일치: Y/N
- [ ] Row count 일치: Y/N
- [ ] Checksum 일치: Y/N
- [ ] AUTO_INCREMENT 일치: Y/N
- [ ] 모든 검증 통과: Y/N → "N"이면 원인 파악 후 재실행

---

### Step 1.3.4: MySQL Replication 설정 (RDS를 Replica로)

> **목표**: Host MySQL → RDS 실시간 동기화 구성

#### 1.3.4.1: Host MySQL에서 Replication 사용자 생성

```bash
# Host MySQL에 Replication 전용 사용자 생성
mysql -h localhost -u root -p << 'EOF'
-- Replication 사용자 생성
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'StrongReplicationPassword123!';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;

-- 확인
SHOW GRANTS FOR 'repl_user'@'%';
EOF
```

**기록**:
- [ ] repl_user 생성 완료: Y/N

---

#### 1.3.4.2: RDS에서 GTID Auto-Position Replication 시작

```bash
# source GTID 정보 로드
source /tmp/source-gtid.txt

# SOURCE_GTID_EXECUTED 예시: uuid:1-245678
# 단순 케이스(연속 구간 1개) 기준으로 start/end 추출
GTID_RANGE=$(echo "$SOURCE_GTID_EXECUTED" | awk -F':' '{print $2}' | awk -F',' '{print $1}')
GTID_START=$(echo "$GTID_RANGE" | awk -F'-' '{print $1}')
GTID_END=$(echo "$GTID_RANGE" | awk -F'-' '{print $2}')
if [ -z "$GTID_END" ]; then GTID_END="$GTID_START"; fi

# 참고: GTID range가 여러 개인 경우(예: uuid:1-100,150-220)는
# 구간별로 rds_set_external_source_gtid_purged를 반복 호출한다.

echo "SOURCE_UUID=$SOURCE_UUID"
echo "GTID_START=$GTID_START"
echo "GTID_END=$GTID_END"

# RDS에서 GTID purged 설정 + auto-position 복제 시작
mysql -h $RDS_ENDPOINT -u billage_admin -p << EOF

SET autocommit = 1;

-- MySQL 8.0.37+ 에서 GTID baseline 설정
CALL mysql.rds_set_external_source_gtid_purged(
  '${SOURCE_UUID}',
  ${GTID_START},
  ${GTID_END}
);

-- 외부 Source를 GTID auto-position으로 연결
CALL mysql.rds_set_external_master_with_auto_position(
  '3.34.162.89',                    -- Host MySQL IP (Public 또는 Private)
  3306,                              -- Port
  'repl_user',                       -- Replication 사용자
  'StrongReplicationPassword123!',   -- 비밀번호
  0                                  -- SSL 사용 여부 (0=No, 1=Yes)
);

-- Replication 시작
CALL mysql.rds_start_replication;

EOF
```

> **중요**:
> - RDS MySQL 8.0에서는 `mysql.rds_set_external_master_with_auto_position` 사용.
> - RDS MySQL 8.4에서는 용어 변경에 따라 `mysql.rds_set_external_source_with_auto_position` 사용.
> - 일반 `CHANGE MASTER TO`/`CHANGE REPLICATION SOURCE TO` 직접 실행 대신 RDS Stored Procedure를 사용.

**기록**:
- [ ] SOURCE_UUID: ___________
- [ ] SOURCE_GTID_EXECUTED: ___________
- [ ] GTID_START: ___________
- [ ] GTID_END: ___________
- [ ] Replication 시작 시각: ___________

---

#### 1.3.4.3: Replication 상태 확인 및 Lag 모니터링

**Replication 상태 확인**:
```bash
# RDS에서 Replica 상태 확인
mysql -h $RDS_ENDPOINT -u billage_admin -p -e "
SHOW REPLICA STATUS\G
" | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind|Last_Error"
```

**예상 출력**:
```
Replica_IO_Running: Yes      ← 필수!
Replica_SQL_Running: Yes     ← 필수!
Seconds_Behind_Source: 0     ← 0이면 동기화 완료
Last_Error:                  ← 비어있어야 함
```

**Lag 모니터링 스크립트**:
```bash
# 실시간 Lag 모니터링 (1초마다)
cat > /tmp/monitor-lag.sh << 'MONITOR_EOF'
#!/bin/bash
RDS_ENDPOINT="${1:-billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com}"
RDS_USER="billage_admin"
RDS_PASS="${2}"

while true; do
    LAG=$(mysql -h $RDS_ENDPOINT -u $RDS_USER -p$RDS_PASS -N -e \
        "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind" | awk '{print $2}')

    IO_RUNNING=$(mysql -h $RDS_ENDPOINT -u $RDS_USER -p$RDS_PASS -N -e \
        "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_IO_Running" | awk '{print $2}')

    SQL_RUNNING=$(mysql -h $RDS_ENDPOINT -u $RDS_USER -p$RDS_PASS -N -e \
        "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_SQL_Running" | awk '{print $2}')

    TIMESTAMP=$(date '+%H:%M:%S')

    if [ "$LAG" = "0" ]; then
        echo "[$TIMESTAMP] Lag: ${LAG}s ✅ (IO: $IO_RUNNING, SQL: $SQL_RUNNING)"
    else
        echo "[$TIMESTAMP] Lag: ${LAG}s ⏳ (IO: $IO_RUNNING, SQL: $SQL_RUNNING)"
    fi

    sleep 1
done
MONITOR_EOF

chmod +x /tmp/monitor-lag.sh
echo "모니터링 시작: /tmp/monitor-lag.sh RDS_ENDPOINT RDS_PASSWORD"
```

**실행**:
```bash
/tmp/monitor-lag.sh billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com "RDS비밀번호"
```

**기록**:
- [ ] Replica_IO_Running: Yes / No
- [ ] Replica_SQL_Running: Yes / No
- [ ] 초기 Lag: ___________초
- [ ] Lag=0 도달 시각: ___________

---

#### 1.3.4.4: Replication 문제 해결

**일반적인 문제와 해결책**:

| 문제 | 원인 | 해결 |
|------|------|------|
| Replica_IO_Running: No | 네트워크 또는 인증 문제 | Host MySQL 방화벽, Security Group 확인 |
| Replica_SQL_Running: No | SQL 충돌 (Duplicate key 등) | `CALL mysql.rds_skip_repl_error;` |
| Lag 증가 | Write 부하 높음 | RDS 인스턴스 크기 업그레이드 |
| 연결 끊김 | 네트워크 불안정 | `CALL mysql.rds_start_replication;` 재실행 |

**에러 Skip (주의해서 사용)**:
```bash
# 단일 에러 스킵
mysql -h $RDS_ENDPOINT -u billage_admin -p -e "CALL mysql.rds_skip_repl_error;"

# Replication 재시작
mysql -h $RDS_ENDPOINT -u billage_admin -p -e "CALL mysql.rds_start_replication;"
```

**Replication 중지 (전환 완료 후)**:
```bash
mysql -h $RDS_ENDPOINT -u billage_admin -p -e "
CALL mysql.rds_stop_replication;
CALL mysql.rds_reset_external_master;
"
```

---

## 1.4 WAS 2대 구성

### Step 1.3.1: WAS(:8080) 검증 - Host MySQL 연결

```bash
# 리허설 EC2에서 실행
# WAS는 이미 AMI에 포함되어 있음 (기존 8080 포트)

# 상태 확인
curl -s http://localhost:8080/actuator/health | jq '.'

# MySQL 연결 상태 확인
curl -s http://localhost:8080/actuator/db | jq '.'

# 기본 API 테스트
curl -s http://localhost:8080/api/items | jq '.' | head -20
```

**정상 응답 확인**:
- [ ] /actuator/health → UP
- [ ] /actuator/db → 연결 정상
- [ ] /api/items → 200 OK, JSON 응답

---

### Step 1.3.2: WAS(:8081) 구성 - RDS 연결

**별도 WAS 인스턴스 디렉토리 생성**:
```bash
# 리허설 EC2에서
sudo mkdir -p /opt/billage-rds
sudo chown ubuntu:ubuntu /opt/billage-rds
```

**Spring Boot JAR 복사 및 설정**:
```bash
# 기존 8080 WAS의 JAR 파일 위치 확인
EXISTING_JAR=$(find /opt/billage -name "*.jar" -type f)
echo "기존 JAR: $EXISTING_JAR"

# RDS용으로 복사
cp $EXISTING_JAR /opt/billage-rds/billage-backend.jar

# RDS용 application.yml 생성
cat > /opt/billage-rds/application.yml << EOF
spring:
  datasource:
    url: jdbc:mysql://${RDS_ENDPOINT}:3306/billage?useSSL=true&serverTimezone=UTC&characterEncoding=UTF-8
    username: billage_admin
    password: ${RDS_PASSWORD}
    driver-class-name: com.mysql.cj.jdbc.Driver
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
      connection-timeout: 30000
  jpa:
    hibernate:
      ddl-auto: validate
    properties:
      hibernate.dialect: org.hibernate.dialect.MySQL8Dialect

server:
  port: 8081
  servlet:
    context-path: /

logging:
  level:
    root: INFO
    com.billage: DEBUG
    org.hibernate: WARN
EOF

echo "RDS application.yml 생성 완료"
```

**systemd 서비스 파일 생성**:
```bash
# RDS WAS용 systemd 서비스
sudo tee /etc/systemd/system/billage-backend-rds.service > /dev/null << EOF
[Unit]
Description=Billage Backend (RDS)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/billage-rds
ExecStart=/usr/bin/java \
  -Xmx512m \
  -Xms256m \
  -Dspring.config.location=/opt/billage-rds/application.yml \
  -jar /opt/billage-rds/billage-backend.jar

Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 서비스 reload 및 시작
sudo systemctl daemon-reload
sudo systemctl start billage-backend-rds
sudo systemctl enable billage-backend-rds

sleep 10

# 상태 확인
sudo systemctl status billage-backend-rds
```

**WAS(:8081) 시작 확인**:
```bash
# 10초 대기 후 확인
sleep 10

curl -s http://localhost:8081/actuator/health | jq '.'
curl -s http://localhost:8081/actuator/db | jq '.'
curl -s http://localhost:8081/api/items | jq '.' | head -20
```

**정상 응답 확인**:
- [ ] /actuator/health → UP
- [ ] /actuator/db → 연결 정상 (RDS)
- [ ] /api/items → 200 OK

**기록**:
- [ ] WAS(:8080) 정상 확인 시각: ___________
- [ ] WAS(:8081) 시작 시각: ___________
- [ ] WAS(:8081) 정상 확인 시각: ___________

---

### Step 1.3.3: Nginx 설정

**기존 Nginx 설정 백업**:
```bash
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d-%H%M%S)
```

**Nginx Upstream 설정**:
```bash
# Nginx upstream 설정 추가/수정
sudo tee /etc/nginx/conf.d/billage-upstream.conf > /dev/null << 'EOF'
upstream billage_host_db {
    server localhost:8080 max_fails=3 fail_timeout=30s;
}

upstream billage_rds {
    server localhost:8081 max_fails=3 fail_timeout=30s;
}

# 기본값: Host DB로 라우팅
upstream billage_backend {
    server localhost:8080 max_fails=3 fail_timeout=30s;
}
EOF

# Nginx 서버 블록 설정
sudo tee /etc/nginx/conf.d/billage-server.conf > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;

    # 리허설용: 상세 로깅
    access_log /var/log/nginx/billage-access.log combined buffer=32k flush=5s;
    error_log /var/log/nginx/billage-error.log warn;

    # API 라우팅 (billage_backend upstream 사용)
    location /api/ {
        proxy_pass http://billage_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }

    # Health check (양쪽 다 라우팅)
    location /health {
        access_log off;
        return 200 "OK";
    }
}
EOF

# Nginx 문법 검사
sudo nginx -t

# Nginx reload
sudo systemctl reload nginx

echo "Nginx 설정 완료"
```

**라우팅 테스트**:
```bash
# 현재는 8080(Host DB)로 라우팅 중
curl -s http://localhost/api/items | jq '.[] | {id, title}' | head -20

# 응답이 정상인지 확인
curl -i http://localhost/health
```

**기록**:
- [ ] Nginx 설정 완료 시각: ___________
- [ ] 라우팅 테스트 통과: Y/N

---

## 1.4 부하 테스트 도구 준비

### Step 1.4.1: k6 설치

```bash
# 리허설 EC2에서 또는 별도 부하 테스트 머신에서
# k6 설치 (Linux)
sudo yum update -y
sudo yum install -y golang-x86_64

# k6 다운로드 및 설치
curl https://github.com/grafana/k6/releases/download/v0.50.0/k6-v0.50.0-linux-amd64.tar.gz -o k6.tar.gz
tar xzf k6.tar.gz
sudo mv k6-v0.50.0-linux-amd64/k6 /usr/local/bin/
sudo chmod +x /usr/local/bin/k6

# 설치 확인
k6 version
```

---

### Step 1.4.2: k6 스크립트 작성

```bash
# k6 스크립트 생성
cat > /opt/billage-rehearsal/k6-load-test.js << 'EOFK6'
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// 커스텀 메트릭
const errorRate = new Rate('errors');
const responseTime = new Trend('response_time');
const httpDuration = new Trend('http_req_duration');

// 환경 변수
const TARGET_URL = __ENV.TARGET_URL || 'http://localhost';
const VUS = __ENV.VUS || 10;
const DURATION = __ENV.DURATION || '5m';
const RAMP_UP = __ENV.RAMP_UP || '1m';

export const options = {
  stages: [
    // Stage 1: 100 QPS (약 10 VU, 각 VU당 10 req/s)
    { duration: '5m', target: 10 },
    // Stage 2: 300 QPS (약 30 VU)
    { duration: '5m', target: 30 },
    // Stage 3: 900 QPS (약 90 VU)
    { duration: '5m', target: 90 },
    // Cool down
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    'http_req_duration': ['p(95)<2000', 'p(99)<5000'],
    'http_req_failed': ['rate<0.05'],
  },
};

export default function () {
  // 읽기 트래픽 70%
  const readRatio = Math.random() < 0.7;

  if (readRatio) {
    // 읽기: GET /api/items (30%)
    if (Math.random() < 0.30 / 0.70) {
      group('GET /api/items', () => {
        let res = http.get(`${TARGET_URL}/api/items?page=1&size=20`);
        check(res, {
          'status is 200': (r) => r.status === 200,
          'has items': (r) => r.body.includes('id'),
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status !== 200);
      });
    }
    // 읽기: GET /api/items/{id} (15%)
    else if (Math.random() < 0.15 / 0.70) {
      group('GET /api/items/{id}', () => {
        let res = http.get(`${TARGET_URL}/api/items/1`);
        check(res, {
          'status is 200 or 404': (r) => r.status === 200 || r.status === 404,
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status > 299);
      });
    }
    // 읽기: GET /api/users/{id} (10%)
    else if (Math.random() < 0.10 / 0.70) {
      group('GET /api/users/{id}', () => {
        let res = http.get(`${TARGET_URL}/api/users/1`);
        check(res, {
          'status is 200 or 401': (r) => r.status === 200 || r.status === 401,
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status > 299 && res.status !== 401);
      });
    }
    // 읽기: GET /api/chat/rooms/{id}/messages (15%)
    else {
      group('GET /api/chat/rooms/{id}/messages', () => {
        let res = http.get(`${TARGET_URL}/api/chat/rooms/1/messages`);
        check(res, {
          'status is 200 or 401': (r) => r.status === 200 || r.status === 401,
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status > 299 && res.status !== 401);
      });
    }
  } else {
    // 쓰기 트래픽 30%
    // POST /api/chat/messages (15%)
    if (Math.random() < 0.15 / 0.30) {
      group('POST /api/chat/messages', () => {
        let payload = JSON.stringify({
          roomId: 1,
          content: `Message ${new Date().getTime()}`,
        });
        let res = http.post(`${TARGET_URL}/api/chat/messages`, payload, {
          headers: { 'Content-Type': 'application/json' },
        });
        check(res, {
          'status is 201 or 400 or 401': (r) => r.status === 201 || r.status === 400 || r.status === 401,
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status > 299 && res.status !== 400 && res.status !== 401);
      });
    }
    // POST /api/items (5%)
    else if (Math.random() < 0.05 / 0.30) {
      group('POST /api/items', () => {
        let payload = JSON.stringify({
          title: `Item ${new Date().getTime()}`,
          description: 'Test item',
          price: 10000,
        });
        let res = http.post(`${TARGET_URL}/api/items`, payload, {
          headers: { 'Content-Type': 'application/json' },
        });
        check(res, {
          'status is 201 or 400 or 401': (r) => r.status === 201 || r.status === 400 || r.status === 401,
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status > 299 && res.status !== 400 && res.status !== 401);
      });
    }
    // POST /api/auth (5%)
    else if (Math.random() < 0.05 / 0.30) {
      group('POST /api/auth', () => {
        let payload = JSON.stringify({
          email: `user${new Date().getTime()}@test.com`,
          password: 'password123',
        });
        let res = http.post(`${TARGET_URL}/api/auth/login`, payload, {
          headers: { 'Content-Type': 'application/json' },
        });
        check(res, {
          'status is 200 or 400 or 401': (r) => r.status === 200 || r.status === 400 || r.status === 401,
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status > 299 && res.status !== 400 && res.status !== 401);
      });
    }
    // PUT/DELETE 기타 (5%)
    else {
      group('PUT/DELETE operations', () => {
        let res = http.put(`${TARGET_URL}/api/items/1`, JSON.stringify({ status: 'active' }), {
          headers: { 'Content-Type': 'application/json' },
        });
        check(res, {
          'status is 200 or 400 or 401 or 404': (r) => [200, 400, 401, 404].includes(r.status),
        });
        responseTime.add(res.timings.duration);
        errorRate.add(res.status > 299 && ![400, 401, 404].includes(r.status));
      });
    }
  }

  sleep(1);
}
EOFK6

echo "k6 스크립트 생성 완료: /opt/billage-rehearsal/k6-load-test.js"
```

**k6 스크립트 테스트 (Dry Run)**:
```bash
# 스크립트 문법 검사
k6 lint /opt/billage-rehearsal/k6-load-test.js

# 30초 테스트 실행 (1 VU, 실제 부하 없음)
k6 run \
  --vus 1 \
  --duration 30s \
  --env TARGET_URL=http://$ELASTIC_IP \
  /opt/billage-rehearsal/k6-load-test.js

# 정상 응답 확인
# - checks passed > 0
# - http_req_failed 낮음
```

**기록**:
- [ ] k6 설치 완료: Y/N
- [ ] k6 스크립트 생성 완료: Y/N
- [ ] k6 Dry Run 통과: Y/N

---

### Step 1.4.3: 모니터링 도구 확인

**CloudWatch 메트릭 확인**:
```bash
# RDS 메트릭 조회 (CloudWatch)
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=billage-rds-rehearsal \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average,Maximum
```

**Grafana 대시보드 확인**:
```bash
# Grafana에 접근 가능한지 확인
# URL: {your-grafana-url}
# 대시보드: Billage DB Migration
# - Host MySQL CPU, Memory, Connections, QPS
# - RDS CPU, Memory, Connections, QPS, Network I/O
```

**MySQL Slow Query Log 활성화**:
```bash
# Host MySQL
mysql -h localhost -u root -p{password} -e \
  "SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 1;"

# RDS
mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "CALL mysql.rds_set_configuration('binlog retention hours', 24);"

# 또는 RDS 파라미터 그룹에서:
# slow_query_log = 1
# long_query_time = 1
```

**기록**:
- [ ] CloudWatch 메트릭 확인: Y/N
- [ ] Grafana 접근 가능: Y/N
- [ ] Slow Query Log 활성화: Y/N

---

## 1.5 사전 체크리스트

**최종 확인 전 모든 항목 검증**:

```bash
#!/bin/bash
# 리허설-사전-체크.sh

echo "=== Billage DB Migration Rehearsal Pre-Check ==="
echo ""

# 1. Prod AMI
echo "[ ] 1. Prod AMI 생성 여부"
aws ec2 describe-images \
  --filters "Name=tag:Purpose,Values=migration-rehearsal" \
  --query 'Images[0].[ImageId,CreationDate]' --output table

# 2. 리허설 EC2
echo "[ ] 2. 리허설 EC2 인스턴스"
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=billage-rehearsal-ec2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress,State.Name]' --output table

# 3. RDS
echo "[ ] 3. RDS 인스턴스 상태"
aws rds describe-db-instances \
  --db-instance-identifier billage-rds-rehearsal \
  --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Address]' --output table

# 4. EC2에 SSH 접속
echo "[ ] 4. 리허설 EC2 SSH 접속 가능"
ssh -i {your-key} ubuntu@$ELASTIC_IP "echo SSH OK"

# 5. EC2 내부에서 각 서비스 확인
echo "[ ] 5. WAS(:8080) 정상"
ssh -i {your-key} ubuntu@$ELASTIC_IP "curl -s http://localhost:8080/actuator/health | jq '.status'"

echo "[ ] 6. WAS(:8081) 정상"
ssh -i {your-key} ubuntu@$ELASTIC_IP "curl -s http://localhost:8081/actuator/health | jq '.status'"

echo "[ ] 7. Nginx 정상"
ssh -i {your-key} ubuntu@$ELASTIC_IP "curl -s http://localhost/health"

echo "[ ] 8. Host MySQL 접근"
ssh -i {your-key} ubuntu@$ELASTIC_IP "mysql -h localhost -u root -p{password} -e 'SELECT COUNT(*) FROM billage.users;'"

echo "[ ] 9. RDS 접근"
ssh -i {your-key} ubuntu@$ELASTIC_IP "mysql -h $RDS_ENDPOINT -u billage_admin -p -e 'SELECT COUNT(*) FROM billage.users;'"

echo "[ ] 10. 데이터 검증 - Row Count"
ssh -i {your-key} ubuntu@$ELASTIC_IP "bash /tmp/compare-rowcount.sh"

echo "[ ] 11. k6 설치"
ssh -i {your-key} ubuntu@$ELASTIC_IP "k6 version"

echo "[ ] 12. 모니터링 대시보드 접근"
echo "Grafana: {your-grafana-url}"
echo "CloudWatch: https://console.aws.amazon.com/cloudwatch/"

echo ""
echo "=== Pre-Check 완료 ==="
```

**체크리스트 (수동)**:
- [ ] Prod AMI 생성 완료
- [ ] 리허설 EC2 running 상태
- [ ] Elastic IP 할당
- [ ] RDS 인스턴스 available 상태
- [ ] EC2 → RDS 3306 포트 연결 가능
- [ ] mysqldump 완료, RDS에 데이터 로드 완료
- [ ] 데이터 검증: Row count 일치
- [ ] 데이터 검증: Checksum 일치
- [ ] WAS(:8080) /actuator/health → UP
- [ ] WAS(:8081) /actuator/health → UP
- [ ] Nginx 라우팅 정상 (/health 응답)
- [ ] k6 설치 완료
- [ ] k6 스크립트 dry run 통과
- [ ] Grafana/CloudWatch 접근 가능
- [ ] Slow Query Log 활성화
- [ ] 팀원 준비: 모니터링 담당자, 데이터 검증 담당자, 부하 테스트 담당자

**GO/NO-GO 판단**:
- 모든 항목이 체크되면: **GO → Part 2 시작**
- 미완료 항목이 있으면: **NO-GO → 원인 파악 후 재실행**

---

# Part 2: 리허설 Round 1 — Replica 기반 무중단 전환

## 목표
- **MySQL Replication 기반** 마이그레이션 절차 검증
- **쓰기 중단 시간 최소화** (목표: < 10초)
- Replica Lag 모니터링 및 전환 시점 결정
- 데이터 정합성 확인
- 전환 직후 에러율 측정

## 전환 시나리오

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Replica 기반 전환 타임라인                         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  T-30분   부하 테스트 시작, Replica Lag 모니터링                      │
│     │                                                                 │
│     ▼     Lag = 0 확인 (실시간 동기화 상태)                           │
│  T-5분    전환 준비 완료 선언                                         │
│     │                                                                 │
│     ▼                                                                 │
│  T-0      ┌─────────────────────────────────────────┐                │
│           │ 1. WAS 8080 정지 (Write Freeze 시작)    │  ← 5초        │
│           │ 2. Lag = 0 최종 확인                    │  ← 2초        │
│           │ 3. Nginx → 8081 전환                   │  ← 1초        │
│           │ 4. WAS 8081 트래픽 수신                 │  ← 즉시       │
│           └─────────────────────────────────────────┘                │
│  T+10초   서비스 정상화, 에러율 모니터링                              │
│     │                                                                 │
│     ▼                                                                 │
│  T+5분    Replication 중지, Host MySQL 정리                          │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## 실행 전 준비

**참여자 확인**:
- [ ] 부하 테스트 담당: k6 모니터링, QPS 단계별 진행
- [ ] 데이터 검증 담당: Row count, Checksum 비교
- [ ] 모니터링 담당: Grafana, CloudWatch, 응답시간 추적
- [ ] 시스템 담당: Nginx 전환, WAS 상태 모니터링
- [ ] 기록 담당: 모든 시각/메트릭 기록

**사전 기록 파일 생성**:
```bash
# 리허설 EC2에서
cat > /tmp/round1-timeline.txt << EOF
=== Billage DB Migration Rehearsal - Round 1 ===
부하 레벨: 100 QPS
시작 시각: $(date '+%Y-%m-%d %H:%M:%S')
EOF

cat > /tmp/round1-metrics.csv << EOF
시각,이벤트,WAS-Host-응답시간,WAS-RDS-응답시간,에러율,QPS
EOF
```

---

## Phase 0: 기준선 측정 (10분)

**Step 0.1: 부하 시작**

```bash
# 부하 테스트 머신에서 (또는 리허설 EC2에서)
ELASTIC_IP="{ELASTIC_IP에서_앞서_기록한값}"
START_TIME=$(date +%s)
START_CLOCK=$(date '+%Y-%m-%d %H:%M:%S')

echo "부하 시작: $START_CLOCK"
echo "대상: http://$ELASTIC_IP"
echo "부하 레벨: 100 QPS (약 10 VU)"

# k6 실행 (백그라운드)
nohup k6 run \
  --vus 10 \
  --duration 30m \
  --env TARGET_URL=http://$ELASTIC_IP \
  -o json=./k6-round1-results.json \
  /opt/billage-rehearsal/k6-load-test.js > k6-round1.log 2>&1 &

K6_PID=$!
echo "k6 PID: $K6_PID"

# k6이 준비될 때까지 대기
sleep 5
echo "k6 실행 중... (대기 2분)"
```

**기록**:
- [ ] 부하 시작 시각: $START_CLOCK
- [ ] k6 PID: $K6_PID

---

**Step 0.2: 기준선 메트릭 수집 (5분)**

```bash
# 5분 동안 메트릭 수집
# 1분마다 수집

for i in {1..5}; do
  CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

  # k6 현재 메트릭 (k6 API 또는 로그 파싱)
  echo "[$i분] $CURRENT_TIME - 메트릭 수집"

  # Nginx 접근 로그에서 응답시간 추출
  RESPONSE_TIME=$(tail -1 /var/log/nginx/billage-access.log | awk '{print $NF}')

  # 에러율 계산 (4xx, 5xx)
  ERROR_COUNT=$(tail -100 /var/log/nginx/billage-access.log | awk '$NF != "200" {count++} END {print count+0}')
  ERROR_RATE=$(echo "scale=2; $ERROR_COUNT / 100 * 100" | bc)

  echo "$CURRENT_TIME | 응답시간: ${RESPONSE_TIME}ms | 에러율: ${ERROR_RATE}%" | tee -a /tmp/round1-baseline.txt

  sleep 60
done

echo "기준선 수집 완료"

# 기준선 평균 계산
BASELINE_AVG=$(awk -F'| ' '{gsub(/[^0-9.]/,"",$2); sum+=$2; count++} END {print sum/count}' /tmp/round1-baseline.txt)
BASELINE_ERRORS=$(awk -F'| ' '{gsub(/[^0-9.]/,"",$3); sum+=$3; count++} END {print sum/count}' /tmp/round1-baseline.txt)

echo "기준선 평균 응답시간: ${BASELINE_AVG}ms"
echo "기준선 평균 에러율: ${BASELINE_ERRORS}%"

# 기록
echo "=== Phase 0: 기준선 측정 ===" >> /tmp/round1-timeline.txt
echo "기준선 평균 응답시간: ${BASELINE_AVG}ms" >> /tmp/round1-timeline.txt
echo "기준선 평균 에러율: ${BASELINE_ERRORS}%" >> /tmp/round1-timeline.txt
```

**기록**:
- [ ] 기준선 수집 완료 시각: ___________
- [ ] 기준선 평균 응답시간: ___________ms
- [ ] 기준선 p95: ___________ms (k6 로그에서)
- [ ] 기준선 에러율: ___________%

---

## Phase 1: 사전 데이터 동기화

**Step 1.1: 기준 Dump 생성**

```bash
# Dump 시작 시각
DUMP_START=$(date +%s)
DUMP_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "=== Phase 1: 사전 데이터 동기화 ===" >> /tmp/round1-timeline.txt
echo "Dump 시작: $DUMP_START_TIME" >> /tmp/round1-timeline.txt

# 부하가 있는 상태에서 MySQL dump 수행
mysqldump \
  -h localhost \
  -u root \
  -p{prod-password} \
  --single-transaction \
  --set-gtid-purged=OFF \
  --routines \
  --triggers \
  --events \
  --set-charset \
  billage > /tmp/billage-round1.sql

DUMP_END=$(date +%s)
DUMP_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
DUMP_DURATION=$((DUMP_END - DUMP_START))

echo "Dump 완료: $DUMP_END_TIME (${DUMP_DURATION}초)"
echo "Dump 완료: $DUMP_END_TIME (${DUMP_DURATION}초)" >> /tmp/round1-timeline.txt

# Dump 파일 크기
DUMP_SIZE=$(du -sh /tmp/billage-round1.sql | cut -f1)
echo "Dump 파일 크기: $DUMP_SIZE"
```

**기록**:
- [ ] Dump 시작 시각: $DUMP_START_TIME
- [ ] Dump 완료 시각: $DUMP_END_TIME
- [ ] Dump 소요 시간: ${DUMP_DURATION}초
- [ ] Dump 파일 크기: $DUMP_SIZE

---

**Step 1.2: Delta 지점 기록**

```bash
# Dump가 완료된 후 이 시점의 GTID 기준점 기록
# 이 이후의 변경이 delta가 됨

DELTA_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
DELTA_START_TIMESTAMP=$(date +%s%N | cut -b1-13)  # milliseconds

echo "Delta 기준점: $DELTA_START_TIME"

# GTID 기준점 기록
mysql -h localhost -u root -p{password} -e "SELECT @@GLOBAL.gtid_executed \G" > /tmp/round1-gtid.txt

echo "Delta 기준점: $DELTA_START_TIME" >> /tmp/round1-timeline.txt
```

**기록**:
- [ ] Delta 기준점: $DELTA_START_TIME

---

## Phase 2: Replica Lag 확인 + 최소 Write Freeze 전환 (핵심)

> **핵심**: Replication이 실시간으로 동기화되므로, Lag=0 확인 후 **수 초 이내** Write Freeze로 전환

**Step 2.1: Replica Lag 최종 확인**

```bash
# Replication 상태 확인
echo "====== Replica 상태 확인 ======"

LAG=$(mysql -h $RDS_ENDPOINT -u billage_admin -p$RDS_PASS -N -e \
    "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind" | awk '{print $2}')

IO_RUNNING=$(mysql -h $RDS_ENDPOINT -u billage_admin -p$RDS_PASS -N -e \
    "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_IO_Running" | awk '{print $2}')

SQL_RUNNING=$(mysql -h $RDS_ENDPOINT -u billage_admin -p$RDS_PASS -N -e \
    "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_SQL_Running" | awk '{print $2}')

echo "Replica_IO_Running: $IO_RUNNING"
echo "Replica_SQL_Running: $SQL_RUNNING"
echo "Seconds_Behind_Source: $LAG"

# Lag=0 확인
if [ "$LAG" = "0" ] && [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
    echo "✅ Replica 동기화 완료! 전환 준비 완료"
else
    echo "⚠️ Replica Lag: ${LAG}초 - 대기 필요"
    echo "Lag=0이 될 때까지 대기..."
    while [ "$LAG" != "0" ]; do
        sleep 2
        LAG=$(mysql -h $RDS_ENDPOINT -u billage_admin -p$RDS_PASS -N -e \
            "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind" | awk '{print $2}')
        echo "현재 Lag: ${LAG}초"
    done
    echo "✅ Lag=0 도달!"
fi
```

**기록**:
- [ ] Replica_IO_Running: Yes / No
- [ ] Replica_SQL_Running: Yes / No
- [ ] Seconds_Behind_Source: _____ (0이어야 함)
- [ ] 전환 준비 완료: Y/N

---

**Step 2.2: Write Freeze + 즉시 전환 (목표: 10초 이내)**

```bash
# ⏱️ 전환 시작 - 타이머 시작
T0=$(date +%s)
T0_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "══════════════════════════════════════════════════"
echo "   🚀 T0: 전환 시작 - $T0_TIME"
echo "══════════════════════════════════════════════════"

echo "=== Phase 2: Write Freeze + 전환 ===" >> /tmp/round1-timeline.txt
echo "T0 (전환 시작): $T0_TIME" >> /tmp/round1-timeline.txt

# Step 1: WAS 8080 정지 (Write Freeze)
echo "[T+0s] WAS 8080 정지 중..."
sudo systemctl stop billage-backend

# Step 2: 최종 Lag 확인 (마지막 binlog 적용 대기)
echo "[T+2s] 최종 Lag 확인..."
sleep 2
FINAL_LAG=$(mysql -h $RDS_ENDPOINT -u billage_admin -p$RDS_PASS -N -e \
    "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind" | awk '{print $2}')

if [ "$FINAL_LAG" = "0" ]; then
    echo "✅ 최종 Lag=0 확인"
else
    echo "⚠️ 최종 Lag: ${FINAL_LAG}초 - 잠시 대기"
    sleep 3
fi

# Step 3: Nginx 트래픽 전환 (8080 → 8081)
echo "[T+5s] Nginx 전환: 8080 → 8081"
/home/ubuntu/switch-backend.sh rds   # 또는 아래 명령 직접 실행

# 또는 수동 전환:
# sudo sed -i 's/localhost:8080/localhost:8081/g' /etc/nginx/conf.d/billage-upstream.conf
# sudo nginx -t && sudo systemctl reload nginx

# Step 4: 전환 완료 시각 기록
T1=$(date +%s)
T1_TIME=$(date '+%Y-%m-%d %H:%M:%S')
CUTOVER_DURATION=$((T1 - T0))

echo ""
echo "══════════════════════════════════════════════════"
echo "   ✅ T1: 전환 완료 - $T1_TIME"
echo "   ⏱️  총 소요 시간: ${CUTOVER_DURATION}초"
echo "══════════════════════════════════════════════════"

echo "T1 (전환 완료): $T1_TIME" >> /tmp/round1-timeline.txt
echo "전환 소요 시간: ${CUTOVER_DURATION}초" >> /tmp/round1-timeline.txt

# Step 5: 즉시 검증
echo ""
echo "=== 전환 후 즉시 검증 ==="

# RDS WAS 응답 확인
HEALTH_CHECK=$(curl -s -w "%{http_code}" http://localhost:8081/actuator/health)
echo "WAS 8081 Health: $HEALTH_CHECK"

# API 응답 확인
API_CHECK=$(curl -s -w "%{http_code}" http://localhost/api/health 2>/dev/null || echo "N/A")
echo "API 응답: $API_CHECK"

if [[ "$HEALTH_CHECK" == *"200"* ]]; then
    echo "✅ 전환 성공!"
else
    echo "❌ 전환 실패 - 롤백 필요"
    echo "롤백: /home/ubuntu/switch-backend.sh host"
fi
```

**기록**:
- [ ] T0 (전환 시작): $T0_TIME
- [ ] T1 (전환 완료): $T1_TIME
- [ ] **총 Write Freeze 시간**: ${CUTOVER_DURATION}초 (목표: <10초)
- [ ] WAS 8081 Health: ✓/✗
- [ ] API 응답: ✓/✗

---

**Step 2.3: Replication 정리**

```bash
# 전환 완료 후 Replication 중지
echo "Replication 정리 중..."

mysql -h $RDS_ENDPOINT -u billage_admin -p$RDS_PASS << 'EOF'
-- Replication 중지
CALL mysql.rds_stop_replication;

-- 외부 Master 설정 제거
CALL mysql.rds_reset_external_master;

-- 확인
SHOW REPLICA STATUS\G
EOF

echo "✅ Replication 정리 완료 - RDS가 이제 Primary로 독립 운영"

echo "Delta 추출 완료: 소요 시간 ${DELTA_EXTRACT_DURATION}초"
echo "Delta 추출 완료: 소요 시간 ${DELTA_EXTRACT_DURATION}초" >> /tmp/round1-timeline.txt
```

**기록**:
- [ ] Delta 추출 시작: $DELTA_EXTRACT_START_TIME
- [ ] Delta 추출 완료: ___________
- [ ] Delta 추출 소요 시간: ${DELTA_EXTRACT_DURATION}초

---

**Step 2.3: 데이터 검증 (빠르게)**

```bash
# T2 이전에 빠른 검증 수행

VALIDATION_START=$(date +%s)
VALIDATION_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "데이터 검증 시작: $VALIDATION_START_TIME"

# 핵심 테이블 Row count 비교
echo "Row count 비교..."

# Host MySQL
HOST_USERS=$(mysql -h localhost -u root -p{password} billage -e \
  "SELECT COUNT(*) as count FROM users;" -N | awk '{print $1}')

HOST_ITEMS=$(mysql -h localhost -u root -p{password} billage -e \
  "SELECT COUNT(*) as count FROM items;" -N | awk '{print $1}')

HOST_RENTALS=$(mysql -h localhost -u root -p{password} billage -e \
  "SELECT COUNT(*) as count FROM rentals;" -N | awk '{print $1}')

# RDS
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier billage-rds-rehearsal \
  --query 'DBInstances[0].Endpoint.Address' --output text)

RDS_USERS=$(mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "SELECT COUNT(*) as count FROM users;" -N | awk '{print $1}')

RDS_ITEMS=$(mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "SELECT COUNT(*) as count FROM items;" -N | awk '{print $1}')

RDS_RENTALS=$(mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "SELECT COUNT(*) as count FROM rentals;" -N | awk '{print $1}')

# 비교
echo "users: Host=$HOST_USERS, RDS=$RDS_USERS"
echo "items: Host=$HOST_ITEMS, RDS=$RDS_ITEMS"
echo "rentals: Host=$HOST_RENTALS, RDS=$RDS_RENTALS"

if [ "$HOST_USERS" = "$RDS_USERS" ] && [ "$HOST_ITEMS" = "$RDS_ITEMS" ] && [ "$HOST_RENTALS" = "$RDS_RENTALS" ]; then
  echo "✓ Row count 일치"
  VALIDATION_PASS=1
else
  echo "✗ Row count 불일치!"
  VALIDATION_PASS=0
fi

VALIDATION_END=$(date +%s)
VALIDATION_DURATION=$((VALIDATION_END - VALIDATION_START))

T2=$(date +%s)
T2_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "T2 (검증 완료): $T2_TIME (검증 소요: ${VALIDATION_DURATION}초)"
echo "T2 (검증 완료): $T2_TIME" >> /tmp/round1-timeline.txt

PHASE2_TOTAL=$((T2 - T0))
echo "Phase 2 총 소요 시간: ${PHASE2_TOTAL}초"
echo "Phase 2 총 소요 시간: ${PHASE2_TOTAL}초" >> /tmp/round1-timeline.txt
```

**기록**:
- [ ] 검증 시작: $VALIDATION_START_TIME
- [ ] users Row count 일치: $HOST_USERS = $RDS_USERS?
- [ ] items Row count 일치: $HOST_ITEMS = $RDS_ITEMS?
- [ ] rentals Row count 일치: $HOST_RENTALS = $RDS_RENTALS?
- [ ] T2 (검증 완료): $T2_TIME
- [ ] 검증 소요 시간: ${VALIDATION_DURATION}초
- [ ] Phase 2 총 소요 시간: ${PHASE2_TOTAL}초 (목표: < 300초)

---

## Phase 3: 트래픽 전환

**Step 3.1: Nginx Upstream 전환**

```bash
# T3: Nginx upstream 변경

T3=$(date +%s)
T3_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "====== T3: Nginx 전환 시작 ======"
echo "T3: $T3_TIME"

echo "=== Phase 3: 트래픽 전환 ===" >> /tmp/round1-timeline.txt
echo "T3 (Nginx 전환 시작): $T3_TIME" >> /tmp/round1-timeline.txt

# Nginx 설정: upstream을 8081(RDS)로 변경
# 방법: 새 설정 파일로 대체

cat > /etc/nginx/conf.d/billage-server.conf << 'EOF'
upstream billage_backend {
    server localhost:8081 max_fails=3 fail_timeout=30s;
}

server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/billage-access.log combined buffer=32k flush=5s;
    error_log /var/log/nginx/billage-error.log warn;

    location /api/ {
        proxy_pass http://billage_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }

    location /health {
        access_log off;
        return 200 "OK";
    }
}
EOF

# Nginx 문법 검사
sudo nginx -t

# Hot reload (요청 드롭 없음)
sudo systemctl reload nginx

# 전환 확인
sleep 2

# WAS(:8081)로 라우팅되는지 테스트
ROUTE_TEST=$(curl -s -v http://localhost/api/items 2>&1 | grep "8081")

if [ -n "$ROUTE_TEST" ]; then
  echo "✓ Nginx 전환 성공 (8081로 라우팅)"
else
  echo "⚠ Nginx 전환 확인 불가 (상태 코드 확인)"
  curl -s -w "\n상태: %{http_code}\n" http://localhost/api/items
fi

T3_END=$(date +%s)
T3_DURATION=$((T3_END - T3))

echo "T3 완료: ${T3_DURATION}초"
echo "T3 완료: ${T3_DURATION}초" >> /tmp/round1-timeline.txt
```

**기록**:
- [ ] T3 (Nginx 전환 시작): $T3_TIME
- [ ] T3 (Nginx 전환 완료): ___________
- [ ] Nginx 전환 소요 시간: ${T3_DURATION}초 (목표: < 5초)
- [ ] 라우팅 테스트: ✓/✗

---

**Step 3.2: 쓰기 차단 해제**

```bash
# 쓰기 차단을 해제하여 RDS에 정상적으로 쓰기 시작

# 기존의 쓰기 차단 설정 제거
rm /etc/nginx/conf.d/billage-write-block.conf

# 정상 설정으로 복원 (이미 위의 billage-server.conf가 정상 설정)
sudo nginx -t
sudo systemctl reload nginx

T4=$(date +%s)
T4_TIME=$(date '+%Y-%m-%d %H:%M:%S')

T4_MINUS_T0=$((T4 - T0))

echo ""
echo "====== T4: 쓰기 재개 ======"
echo "T4: $T4_TIME"
echo "총 쓰기 중단 시간: ${T4_MINUS_T0}초"

echo "T4 (쓰기 재개): $T4_TIME" >> /tmp/round1-timeline.txt
echo "총 쓰기 중단 시간 (T4-T0): ${T4_MINUS_T0}초" >> /tmp/round1-timeline.txt

# 쓰기 재개 테스트
sleep 2

WRITE_TEST=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"test": "write"}' \
  http://localhost/api/test)

if [[ "$WRITE_TEST" =~ ^(201|400|401)$ ]]; then
  echo "✓ 쓰기 재개 정상 (상태: $WRITE_TEST)"
else
  echo "⚠ 쓰기 응답 확인: $WRITE_TEST"
fi
```

**기록**:
- [ ] T4 (쓰기 재개): $T4_TIME
- [ ] 총 쓰기 중단 시간: ${T4_MINUS_T0}초 (목표: < 300초)
- [ ] 쓰기 재개 테스트: ✓/✗

---

## Phase 4: 전환 후 모니터링 (5분)

```bash
# 전환 직후 5분간 모니터링

echo ""
echo "=== Phase 4: 전환 후 모니터링 ==="
echo "=== Phase 4: 전환 후 모니터링 ===" >> /tmp/round1-timeline.txt

MONITOR_START=$(date +%s)
MONITOR_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "모니터링 시작: $MONITOR_START_TIME"

# 부하는 계속 진행 중
# Nginx 로그에서 에러 건수 수집

for i in {1..5}; do
  CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

  # 최근 로그에서 에러 건수
  ERROR_COUNT=$(tail -100 /var/log/nginx/billage-access.log | awk '$9 !~ /^2[0-9][0-9]$/ {count++} END {print count+0}')

  # 응답시간 (마지막 줄)
  RESPONSE_TIME=$(tail -1 /var/log/nginx/billage-access.log | awk '{print $NF}')

  echo "[$i분] $CURRENT_TIME | 에러 건수: $ERROR_COUNT | 응답시간: ${RESPONSE_TIME}ms"

  sleep 60
done

MONITOR_END=$(date +%s)
MONITOR_DURATION=$((MONITOR_END - MONITOR_START))

echo ""
echo "모니터링 완료: 소요 시간 ${MONITOR_DURATION}초"
echo "모니터링 완료: 소요 시간 ${MONITOR_DURATION}초" >> /tmp/round1-timeline.txt

# 전환 직후 에러율
POSTSWITCH_ERRORS=$(tail -200 /var/log/nginx/billage-access.log | awk '$9 !~ /^2[0-9][0-9]$/ {count++} END {print count+0}')
POSTSWITCH_ERROR_RATE=$(echo "scale=2; $POSTSWITCH_ERRORS / 200 * 100" | bc)

echo "전환 직후 에러율: ${POSTSWITCH_ERROR_RATE}%"
```

**기록**:
- [ ] 모니터링 시작: $MONITOR_START_TIME
- [ ] 모니터링 완료: ___________
- [ ] 전환 직후 에러 건수: $POSTSWITCH_ERRORS
- [ ] 전환 직후 에러율: ${POSTSWITCH_ERROR_RATE}%
- [ ] 평균 응답시간 (전환 후): ___________ms

---

## Phase 5: 데이터 정합성 검증

```bash
echo ""
echo "=== Phase 5: 데이터 정합성 검증 ==="
echo "=== Phase 5: 데이터 정합성 검증 ===" >> /tmp/round1-timeline.txt

INTEGRITY_START=$(date +%s)
INTEGRITY_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "정합성 검증 시작: $INTEGRITY_START_TIME"

# 전체 테이블 Row count 비교
echo "Row count 최종 검증..."

FINAL_ROWCOUNT=$(cat > /tmp/final-rowcount.sql << 'EOF'
SELECT TABLE_NAME, TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='billage'
ORDER BY TABLE_NAME;
EOF

mysql -h localhost -u root -p{password} < /tmp/final-rowcount.sql > /tmp/host-final-rowcount.txt
mysql -h $RDS_ENDPOINT -u billage_admin -p billage < /tmp/final-rowcount.sql > /tmp/rds-final-rowcount.txt

echo "Host MySQL:"
head -10 /tmp/host-final-rowcount.txt

echo ""
echo "RDS:"
head -10 /tmp/rds-final-rowcount.txt

# 비교
ROWCOUNT_DIFF=$(diff /tmp/host-final-rowcount.txt /tmp/rds-final-rowcount.txt | wc -l)

if [ "$ROWCOUNT_DIFF" -eq 0 ]; then
  echo "✓ Row count 완벽 일치"
  INTEGRITY_PASS=1
else
  echo "⚠ Row count 차이 있음 (diff 라인 수: $ROWCOUNT_DIFF)"
  INTEGRITY_PASS=0
fi

# Checksum 검증 (주요 테이블)
echo ""
echo "Checksum 검증..."

mysql -h localhost -u root -p{password} billage -e \
  "CHECKSUM TABLE users, items, rentals, chats, payments;" > /tmp/host-final-checksum.txt

mysql -h $RDS_ENDPOINT -u billage_admin -p billage -e \
  "CHECKSUM TABLE users, items, rentals, chats, payments;" > /tmp/rds-final-checksum.txt

echo "Host MySQL:"
cat /tmp/host-final-checksum.txt

echo ""
echo "RDS:"
cat /tmp/rds-final-checksum.txt

INTEGRITY_END=$(date +%s)
INTEGRITY_DURATION=$((INTEGRITY_END - INTEGRITY_START))

echo "정합성 검증 완료: 소요 시간 ${INTEGRITY_DURATION}초"

# 최종 판정
if [ "$INTEGRITY_PASS" -eq 1 ]; then
  echo ""
  echo "✓✓✓ 데이터 정합성 검증 완료 ✓✓✓"
  FINAL_INTEGRITY="PASS"
else
  echo ""
  echo "✗ 데이터 정합성 검증 실패 - 확인 필요"
  FINAL_INTEGRITY="FAIL"
fi
```

**기록**:
- [ ] 정합성 검증 시작: $INTEGRITY_START_TIME
- [ ] Row count 최종 일치: Y/N
- [ ] Checksum 일치: Y/N
- [ ] 최종 데이터 정합성: $FINAL_INTEGRITY

---

## Phase 6: 롤백 테스트

```bash
echo ""
echo "=== Phase 6: 롤백 테스트 ==="
echo "=== Phase 6: 롤백 테스트 ===" >> /tmp/round1-timeline.txt

ROLLBACK_START=$(date +%s)
ROLLBACK_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "롤백 시작: $ROLLBACK_START_TIME"

# 부하는 계속 유지 상태에서 Nginx를 8080(Host DB)으로 복원

cat > /etc/nginx/conf.d/billage-server.conf << 'EOF'
upstream billage_backend {
    server localhost:8080 max_fails=3 fail_timeout=30s;
}

server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/billage-access.log combined buffer=32k flush=5s;
    error_log /var/log/nginx/billage-error.log warn;

    location /api/ {
        proxy_pass http://billage_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }

    location /health {
        access_log off;
        return 200 "OK";
    }
}
EOF

sudo nginx -t
sudo systemctl reload nginx

ROLLBACK_END=$(date +%s)
ROLLBACK_DURATION=$((ROLLBACK_END - ROLLBACK_START))

ROLLBACK_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "롤백 완료: $ROLLBACK_TIME (소요: ${ROLLBACK_DURATION}초)"
echo "롤백 완료: $ROLLBACK_TIME (소요: ${ROLLBACK_DURATION}초)" >> /tmp/round1-timeline.txt

# 롤백 후 테스트
sleep 3

ROLLBACK_TEST=$(curl -s -w "%{http_code}" http://localhost/api/items)

if [[ "$ROLLBACK_TEST" == *"200"* ]]; then
  echo "✓ 롤백 완료, Host DB 연결 정상"
else
  echo "✗ 롤백 테스트 실패: $ROLLBACK_TEST"
fi

# 주의: 롤백 후 Host DB와 RDS에 불일치 발생
# (롤백 후 RDS에만 쓰인 데이터)

ROLLBACK_DATA_LOSS=$(cat > /tmp/check-divergence.sql << 'EOF'
SELECT TABLE_NAME, COUNT(*) as host_count
FROM information_schema.TABLES t
JOIN (
  SELECT TABLE_NAME, COUNT(*) as count
  FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA='billage'
  GROUP BY TABLE_NAME
) AS counts USING (TABLE_NAME)
WHERE t.TABLE_SCHEMA='billage'
GROUP BY TABLE_NAME;
EOF

mysql -h localhost -u root -p{password} < /tmp/check-divergence.sql > /tmp/rollback-divergence.txt

echo ""
echo "롤백 후 Host DB 상태:"
head -10 /tmp/rollback-divergence.txt
```

**기록**:
- [ ] 롤백 시작: $ROLLBACK_START_TIME
- [ ] 롤백 완료: $ROLLBACK_TIME
- [ ] 롤백 소요 시간: ${ROLLBACK_DURATION}초 (목표: < 5초)
- [ ] 롤백 후 테스트: ✓/✗
- [ ] 주의: 롤백 후 Host DB와 RDS 데이터 불일치 발생

---

## 측정 기록 - Round 1 최종 표

**다음 표를 작성하여 기록**:

```
| 항목 | 시각 또는 값 | 비고 |
|------|-----------|------|
| 부하 시작 | T0_TIME | 100 QPS |
| 기준선 평균 응답시간 | ms | Host DB |
| 기준선 p95 | ms | |
| 기준선 에러율 | % | |
| T0: 쓰기 중단 시작 | $T0_TIME | |
| T1: 쓰기 차단 완료 | $T1_TIME | ${WRITE_BLOCK_TIME}초 소요 |
| Delta 추출 시작 | DELTA_EXTRACT_START_TIME | |
| Delta 추출 완료 | DELTA_EXTRACT_END | ${DELTA_EXTRACT_DURATION}초 소요 |
| T2: 검증 완료 | $T2_TIME | Phase 2 총 ${PHASE2_TOTAL}초 |
| T3: Nginx 전환 완료 | T3_END | ${T3_DURATION}초 소요 |
| T4: 쓰기 재개 | $T4_TIME | 총 중단 ${T4_MINUS_T0}초 |
| 전환 후 평균 응답시간 | ms | RDS로 전환 후 |
| 전환 후 p95 | ms | |
| 전환 후 에러율 | % | |
| 전환 직후 에러 건수 | 건 | 2분 내 |
| 총 쓰기 중단 시간 (T4-T0) | 초 | 목표: < 300초 |
| 총 다운타임 (읽기 포함) | 초 | Phase 2 + Phase 3 |
| Row count 일치 | Y/N | 최종 검증 |
| Checksum 일치 | Y/N | 최종 검증 |
| 롤백 소요 시간 | ${ROLLBACK_DURATION}초 | |
```

---

# Part 3: 리허설 Round 2 — 전략 A (300 QPS 중부하)

**Round 1과 동일한 절차 반복**:
- 부하 레벨만: 300 QPS (약 30 VU)
- Delta 데이터가 더 많을 수 있음 (쓰기 ~90 QPS × 5분 = ~27,000건)
- 모든 Phase 반복, 동일한 기록 수행
- Round 1보다 Response Time 저하 관찰 가능

**사전 준비**:
```bash
# k6 부하 단계 조정
# 또는 새로운 k6 설정 파일 생성

# Round 1 완료 후 부하 테스트 중단
kill $K6_PID

# 대기 5분 (시스템 안정화)
sleep 300

# Round 2 k6 실행
nohup k6 run \
  --vus 30 \
  --duration 35m \
  --env TARGET_URL=http://$ELASTIC_IP \
  -o json=./k6-round2-results.json \
  /opt/billage-rehearsal/k6-load-test.js > k6-round2.log 2>&1 &
```

**기록**:
```
=== Round 2 - 300 QPS ===
기준선 평균 응답시간: ___ms
Phase 2 총 소요 시간: ___초
T4-T0 쓰기 중단: ___초
에러율: ___%
Row count 일치: Y/N
```

---

# Part 4: 리허설 Round 3 — 전략 A (900 QPS 피크 부하)

**Round 1과 동일한 절차, 부하 900 QPS**:
- 동시접속 ~90 VU
- 쓰기 ~270 QPS → delta 상당할 수 있음
- mysqldump --single-transaction이 부하에서의 영향 관찰
- RDS 성능 한계 테스트

**기록**:
```
=== Round 3 - 900 QPS (피크) ===
기준선 평균 응답시간: ___ms
기준선 p95: ___ms
Phase 2 총 소요 시간: ___초
T4-T0 쓰기 중단: ___초 (목표: < 300초)
에러율: ___%
RDS CPU: ___%
RDS Connections: ___
전환 후 응답시간 증가율: ___%
```

---

# Part 5: 리허설 Round 4 — 전략 B (MySQL Replication, 선택)

이 부분은 선택사항입니다. 필요시 실행합니다.

## 사전 준비

### Step 5.0: Host MySQL Replication 설정

```bash
# Host MySQL (리허설 EC2)에서
# my.cnf 수정 (이미 실행 중인 MySQL이므로 신중하게)

# 현재 설정 확인
mysql -u root -p{password} -e "SHOW VARIABLES LIKE 'log_bin%';"

# my.cnf 백업
sudo cp /etc/my.cnf /etc/my.cnf.backup.replication

# Replication 설정 추가
sudo tee -a /etc/my.cnf << 'EOF'

[mysqld]
gtid_mode=ON
enforce_gtid_consistency=ON
log-bin=mysql-bin
server-id=1
binlog-format=ROW
binlog-expire-logs-seconds=604800
EOF

# MySQL 재시작 (리허설 환경이므로 OK, 하지만 데이터 안정성 확인)
sudo systemctl restart mysql

# 확인
mysql -u root -p{password} -e "SHOW VARIABLES LIKE 'gtid_mode'; SHOW VARIABLES LIKE 'enforce_gtid_consistency'; SHOW VARIABLES LIKE 'server_id'; SHOW VARIABLES LIKE 'log_bin%';"
```

### Step 5.1: Replication 사용자 생성

```bash
# Host MySQL에서
mysql -u root -p{password} -e \
  "CREATE USER 'repl_user'@'{RDS_SUBNET_IP_RANGE}' IDENTIFIED BY 'repl_password';
   GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'{RDS_SUBNET_IP_RANGE}';
   FLUSH PRIVILEGES;"

# GTID 기준점 기록
mysql -u root -p{password} -e "SELECT @@server_uuid, @@GLOBAL.gtid_executed \G" > /tmp/repl-gtid-status.txt
cat /tmp/repl-gtid-status.txt
```

### Step 5.2: RDS에서 Replication 설정

```bash
# RDS에서 (리허설 EC2에서 원격 실행)

# GTID 정보 확인
SOURCE_UUID=$(grep "server_uuid" /tmp/repl-gtid-status.txt | awk '{print $2}')
SOURCE_GTID_EXECUTED=$(grep "gtid_executed" /tmp/repl-gtid-status.txt | awk '{print $2}')
GTID_RANGE=$(echo "$SOURCE_GTID_EXECUTED" | awk -F':' '{print $2}' | awk -F',' '{print $1}')
GTID_START=$(echo "$GTID_RANGE" | awk -F'-' '{print $1}')
GTID_END=$(echo "$GTID_RANGE" | awk -F'-' '{print $2}')
if [ -z "$GTID_END" ]; then GTID_END="$GTID_START"; fi

# RDS에서 GTID baseline + auto-position 설정
mysql -h $RDS_ENDPOINT -u billage_admin -p -e \
  "SET autocommit = 1;
   CALL mysql.rds_set_external_source_gtid_purged(
    '$SOURCE_UUID',
    $GTID_START,
    $GTID_END
  );"

mysql -h $RDS_ENDPOINT -u billage_admin -p -e \
  "CALL mysql.rds_set_external_master_with_auto_position(
    '{HOST_MYSQL_IP}',
    3306,
    'repl_user',
    'repl_password',
    0
  );"

# Replication 시작
mysql -h $RDS_ENDPOINT -u billage_admin -p -e \
  "CALL mysql.rds_start_replication;"

# 상태 확인
mysql -h $RDS_ENDPOINT -u billage_admin -p -e \
  "SHOW REPLICA STATUS \G"
```

## Phase 1-4: Replication 기반 마이그레이션

### Phase 1: Replication 동기화 확인

```bash
echo "=== Round 4: Replication 기반 마이그레이션 ===" >> /tmp/round4-timeline.txt

# Replica Lag 모니터링
for i in {1..60}; do
  CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

  LAG=$(mysql -h $RDS_ENDPOINT -u billage_admin -p -N -e \
    "SHOW REPLICA STATUS \G" | grep "Seconds_Behind_Source" | awk '{print $2}')

  echo "[$i초] $CURRENT_TIME - Replica Lag: ${LAG}초"

  if [ "$LAG" = "0" ] || [ "$LAG" = "NULL" ]; then
    echo "✓ Replication 동기화 완료"
    REPL_SYNC_TIME=$CURRENT_TIME
    break
  fi

  sleep 1
done

echo "Replication 동기화 완료: $REPL_SYNC_TIME" >> /tmp/round4-timeline.txt
```

### Phase 2: 부하 시작 + Lag 모니터링

```bash
# 부하 시작 (100 QPS → 300 QPS → 900 QPS)
# Lag 모니터링은 1초 단위로 수행

k6 run \
  --stage "5m:10 vus" \
  --stage "5m:30 vus" \
  --stage "5m:90 vus" \
  --stage "2m:0 vus" \
  --env TARGET_URL=http://$ELASTIC_IP \
  /opt/billage-rehearsal/k6-load-test.js &

K6_REPL_PID=$!

# Lag 모니터링 (병렬 실행)
for i in {1..1200}; do
  CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  CURRENT_SECONDS=$(date +%s)

  LAG=$(mysql -h $RDS_ENDPOINT -u billage_admin -p -N -e \
    "SHOW REPLICA STATUS \G" | grep "Seconds_Behind_Source" | awk '{print $2}')

  if [ $((i % 60)) -eq 0 ]; then
    echo "$CURRENT_TIME - Lag: ${LAG}초"
  fi

  # Lag=0 감지 시 시각 기록
  if [ "$LAG" = "0" ]; then
    ZERO_LAG_TIME=$CURRENT_TIME
    ZERO_LAG_SECONDS=$CURRENT_SECONDS
  fi

  sleep 1
done

wait $K6_REPL_PID
```

### Phase 3: Lag=0에서 전환

```bash
# RDS Replication이 따라잡은 시점 (Lag=0)에서 전환 수행

echo ""
echo "Lag=0 감지 시각: $ZERO_LAG_TIME"

# Nginx 전환
cat > /etc/nginx/conf.d/billage-server.conf << 'EOF'
upstream billage_backend {
    server localhost:8081 max_fails=3 fail_timeout=30s;
}

server {
    listen 80;
    server_name _;

    location /api/ {
        proxy_pass http://billage_backend;
        ...
    }
}
EOF

sudo nginx -t
sudo systemctl reload nginx

REPL_CUTOVER_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "Replication 기반 전환 완료: $REPL_CUTOVER_TIME"

# Replication 중단
mysql -h $RDS_ENDPOINT -u billage_admin -p -e \
  "CALL mysql.rds_stop_replication;"

mysql -h $RDS_ENDPOINT -u billage_admin -p -e \
  "CALL mysql.rds_reset_external_master;"
```

## 측정 기록 - Round 4 (Replication)

```
| 항목 | 값 |
|------|-----|
| Replication 시작 시각 | |
| 초기 동기화 완료 | |
| 부하 100 QPS 중 Lag (min/max/avg) | |
| 부하 300 QPS 중 Lag (min/max/avg) | |
| 부하 900 QPS 중 Lag (min/max/avg) | |
| Lag=0 감지 시각 | |
| Nginx 전환 시각 | |
| 전환 중 에러 건수 | |
| 총 다운타임 | |
| 데이터 정합성 | Y/N |
```

---

# Part 6: 결과 비교 및 최종 리포트

## 6.1 전체 결과 수집

```bash
# Round 1, 2, 3, 4의 모든 기록 파일 수집

echo "=== Billage DB Migration Rehearsal - 최종 리포트 ===" > /tmp/final-report.txt

echo ""
echo "=== Round 1 결과 (100 QPS) ===" >> /tmp/final-report.txt
cat /tmp/round1-timeline.txt >> /tmp/final-report.txt

echo ""
echo "=== Round 2 결과 (300 QPS) ===" >> /tmp/final-report.txt
cat /tmp/round2-timeline.txt >> /tmp/final-report.txt

echo ""
echo "=== Round 3 결과 (900 QPS) ===" >> /tmp/final-report.txt
cat /tmp/round3-timeline.txt >> /tmp/final-report.txt

# k6 결과 분석
echo ""
echo "=== k6 성능 분석 ===" >> /tmp/final-report.txt

# Round별 k6 결과 요약
for round in 1 2 3; do
  echo ""
  echo "Round $round k6 결과:"
  # jq를 이용한 결과 분석
  jq '.metrics | {
    "http_req_duration": .http_req_duration.values,
    "http_req_failed": .http_req_failed.values,
    "checks": .checks.values
  }' k6-round${round}-results.json >> /tmp/final-report.txt 2>/dev/null || echo "결과 파일 분석 실패"
done

cat /tmp/final-report.txt
```

## 6.2 전략 비교표 작성

```bash
cat > /tmp/strategy-comparison.txt << 'EOF'
=== 마이그레이션 전략 비교 ===

| 항목 | mysqldump (전략 A) | Replication (전략 B) |
|------|------------------|-------------------|
| 총 다운타임 | | |
| 쓰기 중단 시간 | | |
| 읽기 중단 시간 | | |
| 설정 복잡도 | 낮음 | 높음 |
| 구현 시간 | 빠름 | 느림 |
| 롤백 용이성 | 어려움 | 쉬움 |
| 100 QPS 다운타임 | | |
| 300 QPS 다운타임 | | |
| 900 QPS 다운타임 | | |
| 권장 사항 | | |

EOF

cat /tmp/strategy-comparison.txt
```

## 6.3 성능 비교표

```bash
cat > /tmp/performance-comparison.txt << 'EOF'
=== Host MySQL vs RDS 성능 비교 ===

| 메트릭 | Host MySQL | RDS | 차이 |
|--------|-----------|-----|------|
| 평균 응답시간 (100 QPS) | ms | ms | |
| p95 (100 QPS) | ms | ms | |
| p99 (100 QPS) | ms | ms | |
| 평균 응답시간 (300 QPS) | ms | ms | |
| p95 (300 QPS) | ms | ms | |
| 평균 응답시간 (900 QPS) | ms | ms | |
| p95 (900 QPS) | ms | ms | |
| 에러율 (100 QPS) | % | % | |
| 에러율 (300 QPS) | % | % | |
| 에러율 (900 QPS) | % | % | |
| Connection count (피크) | | | |
| QPS (피크) | | | |

EOF

cat /tmp/performance-comparison.txt
```

## 6.4 발견된 이슈 및 개선 사항

```bash
cat > /tmp/issues-and-improvements.txt << 'EOF'
=== 발견된 이슈 ===

1. [심각도: 높음/중간/낮음] 이슈 제목
   - 현상:
   - 원인:
   - 개선 방안:
   - 영향: Prod 마이그레이션에 미치는 영향 설명

2. [심각도] 두 번째 이슈
   ...

=== 개선 사항 ===

1. Prod 마이그레이션 전 고려사항
   - 부하 테스트 시간 연장 필요 여부
   - Replication 설정 추가 검증 필요 여부
   - 모니터링 대시보드 개선 필요 사항

2. 롤백 전략 개선
   - 현재 절차의 문제점
   - 개선된 절차

3. 데이터 검증 자동화
   - 현재: 수동 검증
   - 개선: 스크립트화된 검증

EOF

cat /tmp/issues-and-improvements.txt
```

## 6.5 최종 권장 사항

```bash
cat > /tmp/final-recommendation.txt << 'EOF'
=== Prod 마이그레이션 최종 권장 사항 ===

선택된 전략: [전략 A: mysqldump / 전략 B: Replication]

선택 이유:
-

Prod 실행 계획:
- 실행 일정: YYYY-MM-DD (평일 새벽 2-4시)
- 예상 다운타임: ~~분 (읽기), ~~분 (쓰기)
- 권장 커뮤니케이션: 30분 전 공지
- 실패 시 롤백 시간: ~분

위험 요소 및 완화 방안:
1. 쓰기 중단 시 사용자 영향
   - 완화: 사전 공지, 정확한 시간 예측

2. 데이터 불일치 위험
   - 완화: 3중 검증 (Row count, Checksum, 신규 데이터 확인)

3. Nginx 전환 중 요청 드롭
   - 완화: hot reload 사용, 최소화된 전환 시간

모니터링 대시보드:
- Grafana URL:
- 주요 메트릭: CPU, Memory, Connections, QPS, 응답시간
- 알림 임계값:
  - CPU > 80%
  - 에러율 > 5%
  - 응답시간 p95 > 2000ms

Post-Prod 작업:
1. 24시간 모니터링 (24/7)
2. 1주일 후 Host MySQL 제거 (백업 보관)
3. RDS 자동 백업 설정 확인
4. 성능 베이스라인 기록

EOF

cat /tmp/final-recommendation.txt
```

---

# Part 7: Prod 실행 Runbook (리허설 결과 반영 후)

이 섹션은 리허설 완료 후 실제 결과를 바탕으로 작성합니다.

## 7.1 사전 공지 (D-7)

```
대상: 모든 팀원, 외부 이해관계자

제목: Billage DB 마이그레이션 안내
내용:
- 예정 날짜/시간
- 예상 다운타임
- 대응 계획
- 문의처
```

## 7.2 최종 준비 (D-1)

```bash
# 체크리스트

- [ ] Host MySQL 최종 백업 생성
- [ ] RDS 자동 백업 설정 확인
- [ ] Nginx 설정 최종 검토
- [ ] WAS 설정 최종 검토
- [ ] 부하 테스트 도구 준비 (K6 스크립트)
- [ ] 모니터링 대시보드 준비
- [ ] 롤백 절차 검증
- [ ] 팀원 역할 배정 최종 확인
- [ ] 긴급 연락처 확인
```

## 7.3 마이그레이션 실행 (D-Day, 새벽 2시 시작)

### Pre-Migration (실행 30분 전)

```bash
# 최종 헬스 체크
curl http://prod-instance:8080/actuator/health
curl http://prod-rds-endpoint:3306 (TCP 연결 확인)

# 최종 데이터 백업
mysqldump ... > /backup/final-backup-$(date +%Y%m%d-%H%M%S).sql

# 팀원 준비 상태 확인
# - 모니터링 담당자: Grafana 대시보드 오픈
# - 시스템 담당자: Nginx, WAS 준비
# - 데이터 담당자: 검증 스크립트 준비
# - 기록 담당자: 기록 파일 준비
```

### Execution (Phase별 상세 절차)

**리허설에서 측정된 시간을 바탕으로 실제 시간대 입력**

```
T0: 2:00 AM - 마이그레이션 시작
T0-T1: 2:00-2:XX - 쓰기 중단
T1-T2: 2:XX-2:YY - Delta 적용 + 검증
T2-T3: 2:YY-2:ZZ - Nginx 전환
T3-T4: 2:ZZ-3:00 - 쓰기 재개
T4+: 3:00 AM - 모니터링 (최소 1시간)
```

### Post-Migration (실행 후)

```bash
# 즉시 조치
- [ ] 기본 헬스 체크
- [ ] 데이터 정합성 검증
- [ ] 에러로그 확인
- [ ] 성능 기준선 대비 비교

# 1시간 후
- [ ] Slow query log 확인
- [ ] Connection 안정성
- [ ] 에러율 추이

# 24시간 후
- [ ] 시스템 안정성 최종 판단
- [ ] 모니터링 알림 확인

# 1주일 후
- [ ] RDS 성능 안정화 확인
- [ ] Host MySQL 제거 판단
```

---

# 부록 A: 명령어 레퍼런스

## MySQL 검증 명령어

```bash
# Row count 비교
mysql -h {host} -u {user} -p {db} -e \
  "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='{db}' ORDER BY TABLE_NAME;"

# Checksum
mysql -h {host} -u {user} -p {db} -e \
  "CHECKSUM TABLE {table1}, {table2}, {table3};"

# AUTO_INCREMENT 확인
mysql -h {host} -u {user} -p {db} -e \
  "SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='{db}' AND AUTO_INCREMENT IS NOT NULL;"
```

## Nginx 제어

```bash
# 설정 문법 검사
sudo nginx -t

# Reload (무중단)
sudo systemctl reload nginx

# 재시작 (중단 발생)
sudo systemctl restart nginx

# 로그 확인
tail -f /var/log/nginx/billage-access.log
tail -f /var/log/nginx/billage-error.log
```

## 시스템 모니터링

```bash
# CPU, Memory
top -b -n 1

# 디스크 I/O
iostat -x 1 5

# 네트워크
netstat -an | grep ESTABLISHED | wc -l

# 프로세스별 메모리
ps aux --sort=-%mem | head -10
```

---

# 부록 B: 리허설 안전 체크리스트

```bash
# 마이그레이션 시작 전 필수 확인 사항

기술적 준비:
- [ ] Prod 백업 존재 및 복구 가능성 검증
- [ ] RDS 자동 백업 활성화 확인
- [ ] Nginx 핫 리로드 동작 확인
- [ ] 롤백 절차 최소 1회 이상 검증
- [ ] 모니터링 대시보드 접근 확인

운영 준비:
- [ ] 모든 참여자가 각자의 역할 이해
- [ ] 긴급 상황 연락망 확인
- [ ] 스케일레이션 절차 정의
- [ ] 고객 공지 준비

데이터 안전:
- [ ] 최종 데이터 정합성 검증
- [ ] 백업 복구 가능성 검증
- [ ] Dump 파일 완결성 확인

Go/No-Go 판단:
- 모든 항목 체크: GO → 마이그레이션 진행
- 미확인 항목: NO-GO → 재검증 후 진행
```

---

**문서 작성 완료**

이 Runbook은 Billage 팀이 DB 마이그레이션 리허설을 체계적으로 실행할 수 있도록 설계되었습니다. 모든 Step은 실행 가능한 명령어를 포함하며, 명확한 기록 지점을 제시하여 운영 성숙도를 높입니다.
