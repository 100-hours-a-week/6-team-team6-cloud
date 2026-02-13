# Billage 데이터베이스 마이그레이션 계획서

## 1. 개요

Billage 인프라 현대화의 첫 번째 단계는 **데이터베이스 마이그레이션**입니다. 모든 애플리케이션 서비스(Spring Boot 백엔드, FastAPI 서버)가 데이터베이스에 의존하므로, DB 마이그레이션이 완료되어야 다른 인프라 개선(CI/CD 파이프라인, 컨테이너화, 로드 밸런싱 등)이 안정적으로 진행될 수 있습니다.

현재 상황:
- Host MySQL (EC2 t4g.medium 위 직접 설치)은 자동 백업 부재, 멀티AZ 없음, 수동 운영의 부담
- 대규모 확장 또는 장애 대응에 취약한 구조

마이그레이션 목표:
- AWS RDS MySQL 8.0으로 이전 → 자동 백업, 멀티AZ 지원(향후), 관리 용이
- **무중단 또는 최소 중단 시간**으로 진행
- 데이터 무결성 100% 보장
- 롤백 가능한 구조 유지

---

## 2. 현재 상태 (AS-IS)

### 2.1 호스트 MySQL 설정

| 항목 | 현재 값 |
|------|---------|
| **버전** | MySQL 8.0 |
| **호스트** | EC2 t4g.medium (Ubuntu 24.04 ARM64) |
| **설치 방식** | 직접 설치 (scripts/setup-mysql.sh) |
| **바인드 주소** | 0.0.0.0 (모든 인터페이스) |
| **포트** | 3306 (기본) |
| **데이터베이스** | billage (charset: utf8mb4, collation: utf8mb4_unicode_ci) |
| **사용자** | billage@localhost, billage@% |
| **보안 그룹** | Port 3306 ← VPN CIDR (10.100.0.0/24) + VPC CIDR (10.0.0.0/16) |

### 2.2 데이터 규모 추정

**Scale Information:**
- Current v1 MAU: **500 users** (original capacity)
- Target v2 MAU: **300,000 users** (growth target)
- Corresponding DAU: ~10,000 (3.3% daily active rate from 300K MAU)
- Peak concurrent users: ~1,000
- Current data size: **500MB ~ 1.2GB** (small, v1 running)
- **Target growth data size: 10-30GB** (projected for 300K MAU)

**Current table sizes (500 MAU):**
- `users`: ~500 rows (1-2MB)
- `products`: ~2,000-5,000 rows (10-50MB)
- `messages` / `chat_logs`: ~100,000-500,000 rows (200-800MB) — time-series nature
- `transactions` / `orders`: ~5,000-20,000 rows (50-200MB)
- Other metadata tables: 50-100MB

**Projected for 300K MAU:**
- `users`: ~300,000 rows (100-200MB)
- `messages`: ~50M+ rows (growth for chat system, 5-10GB)

**실제 크기 확인 방법:**
```
SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) as size_mb
FROM information_schema.tables
WHERE table_schema = 'billage';
```

### 2.3 백업 현황

- **자동 백업**: 없음 (수동 운영만 가능)
- **백업 주기**: 불정기 (개발 단계에서 밀도 낮음)
- **복구 방법**: 수동 mysqldump 및 리스토어
- **RTO/RPO**: 정의되지 않음

**리스크**: 의도치 않은 데이터 삭제 또는 장애 발생 시 데이터 유실 위험

### 2.4 연결 구조

| 애플리케이션 | 연결 방식 | 엔드포인트 |
|-------------|---------|-----------|
| **Spring Boot 백엔드** | JDBC | localhost:3306 |
| **FastAPI 서버** | SQLAlchemy | localhost:3306 |
| **개발자 접근** | SSH + mysql CLI | EC2 IP:3306 |

SSM Parameter Store (현재):
- `/billage/dev/db/host` → "localhost" (또는 EC2 IP)
- `/billage/dev/db/port` → "3306"
- `/billage/dev/db/username` → "billage"
- `/billage/dev/db/password` → SecureString

### 2.5 현재 상황의 주요 리스크

1. **SPOF(Single Point of Failure)**: 호스트 MySQL에 문제 발생 시 전체 서비스 마비
2. **자동 백업 없음**: 데이터 유실 위험
3. **네트워크 노출**: bind-address=0.0.0.0 설정이 보안 위험(현재는 Security Group으로 제한)
4. **운영 부담**: 수동 유지보수, 패치 적용, 성능 모니터링 모두 수동
5. **확장성 제약**: 저사양 서버(t4g.medium)에서 동작 중, 성능 저하 시 대응 어려움

---

## 3. 목표 상태 (TO-BE)

### 3.1 RDS MySQL 설정 (Terraform: shared/rds/dev/)

| 항목 | 목표 값 |
|------|---------|
| **엔진** | MySQL 8.0 |
| **인스턴스 타입** | Dev: db.t4g.micro, Prod: db.t4g.medium 이상 (300K MAU 성능 확보) |
| **스토리지** | 20GB gp3 (SSD), 자동 확장 활성화 (최대 100GB for 300K MAU growth to 10-30GB) |
| **다중 AZ** | Dev: 비활성화 (비용 절감), Prod 단계에서 활성화 |
| **퍼블릭 액세스** | 아니오 (Private Subnet만) |
| **자동 백업** | 활성화, 7일 보관 |
| **백업 윈도우** | 18:00-19:00 UTC (KST 03:00-04:00) |
| **유지보수 윈도우** | 월요일 19:00-20:00 UTC (KST 화요일 04:00-05:00) |
| **마스터 사용자** | billage_admin |
| **DB명** | billage |
| **파라미터 그룹** | UTF-8 설정, slow_query_log 활성화 (>2초), timezone=Asia/Seoul, max_connections=300+ (300K MAU calculation: 2-6 backend instances × 50 conn/instance = 100-300 connections) |
| **보안 그룹** | 3306 ← VPC CIDR (10.0.0.0/16)만 허용 |
| **삭제 방지** | Dev: 비활성화 (개발 환경), Prod: 활성화(향후) |
| **최종 스냅샷** | Dev: 생략 (비용 절감), Prod: 활성화(향후) |

### 3.2 네트워크 배치

**VPC: 10.0.0.0/16**

| 서브넷 | CIDR | AZ | 용도 |
|------|------|----|----|
| app-private-a | 10.0.1.0/24 | ap-northeast-2a | 애플리케이션 (EC2/ECS) |
| app-private-c | 10.0.2.0/24 | ap-northeast-2c | 애플리케이션 (스탠바이) |
| **db-private-a** | **10.0.10.0/24** | **ap-northeast-2a** | **RDS (주)** |
| **db-private-c** | **10.0.11.0/24** | **ap-northeast-2c** | **RDS (스탠바이, 향후 멀티AZ 시)** |

### 3.3 파라미터 그룹 주요 설정

```
character_set_server = utf8mb4
collation_server = utf8mb4_unicode_ci
time_zone = 'Asia/Seoul'
slow_query_log = 1
long_query_time = 2
log_queries_not_using_indexes = 0
max_connections = 100
max_allowed_packet = 67108864 (64MB, 호스트 MySQL과 동일)
innodb_buffer_pool_size = {auto}
```

### 3.4 백업 및 복구 전략

| 항목 | 대책 |
|------|-----|
| **자동 백업** | RDS 관리, 7일 보관, 매일 18:00-19:00 UTC 시작 |
| **PITR(Point-in-Time Recovery)** | 백업 보관 기간 내 임의 시점 복구 가능 |
| **테스트 리스토어** | 월 1회 (테스트 RDS 인스턴스에 복구) |
| **Password Rotation** | SSM Parameter Store SecureString 사용, 향후 Secrets Manager 자동 로테이션 |

---

## 4. 마이그레이션 방식 결정

### 4.1 Option A: mysqldump + 짧은 점검 (선택)

**개념:**
1. 호스트 MySQL에서 `mysqldump`로 풀 덤프 생성
2. 마이그레이션 윈도우 동안 애플리케이션 일시 중단 (5-10분)
3. RDS에 덤프 임포트
4. SSM Parameter 업데이트 및 애플리케이션 재시작
5. 검증 후 호스트 MySQL 유지 (2주 롤백 버퍼)

**소요 시간 (500 MAU 현재 데이터 기준):**
- mysqldump: 2-3분 (네트워크 I/O 포함, 압축 적용 시 1-2분)
- RDS 임포트: 3-5분 (네트워크 전송 + INSERT 성능)
- SSM 업데이트 + 앱 재시작: 2-3분
- **총 소요 시간: 7-11분** (현재 데이터 규모)

**300K MAU 성장 시 재평가:**
- 데이터가 10-30GB로 성장하면:
  - mysqldump: 10-20분 (10-30GB 데이터)
  - RDS 임포트: 20-40분 (DMS 또는 병렬 처리 권장)
  - **총 소요 시간: 30-60분 → DMS (AWS Database Migration Service) 또는 병렬화 필요**

**장점 (현재 적용 가능):**
- 구현 단순, 테스트 용이
- 도구 최소화 (mysql CLI만 필요)
- Runbook 작성 및 리허설이 명확
- 롤백 시간 5분 이내 (SSM 복원 + 재시작)

**단점 및 재평가 기준:**
- 마이그레이션 윈도우 동안 서비스 중단
- **재평가 임계값:** 데이터 10GB 이상 또는 300K MAU 성장 시 DMS 고려

### 4.2 Option B: AWS DMS (CDC 기반)

**개념:**
- AWS Database Migration Service를 이용한 거의 무중단 마이그레이션
- Change Data Capture(CDC)로 마이그레이션 중 신규 데이터 동기화
- 최종 커트오버 시에만 짧은 중단(1-2분)

**소요 시간:**
- 초기 full load: 5-10분
- CDC 설정 및 검증: 2-3분
- 최종 커트오버: 1-2분

**장점:**
- 거의 무중단 마이그레이션
- 대용량 데이터베이스에 적합
- 중간에 애플리케이션 계속 운영 가능

**단점:**
- AWS DMS 별도 설정 필요 (Terraform 추가)
- 비용 발생 (DMS 인스턴스, 데이터 전송)
- 복잡성 증가, 리허설 시간 증가
- 현 단계에서는 오버엔지니어링

### 4.3 의사결정: Option A 선택

**근거:**
1. **데이터 규모 합리적**: 500MB-1.2GB는 mysqldump로 2-3분 내 완료 가능
2. **팀 역량**: DevOps 팀이 이미 mysql CLI 숙련, DMS 학습 곡선 제거
3. **비용 효율**: DMS 비용 절감 (월 $50+ → $0)
4. **리스크 관리**: 단순한 구조 = 문제 발생 시 원인 파악 빠름
5. **롤백 신속성**: 5분 이내 완전 롤백 가능

**재평가 기준:** 다음 조건 충족 시 Option B(DMS) 또는 병렬 마이그레이션 재검토
- 데이터 크기 10GB 이상 (300K MAU로 성장 시 예상 10-30GB)
- 월 활성 사용자 10,000명 이상 (300K MAU 도달 시)
- 마이그레이션 중 무중단 강제 요구사항 발생
- **v2로 성장 단계:** Phase 1 (300 → 10K DAU): mysqldump 가능 / Phase 2 (10K → 100K DAU): DMS 필수

---

## 5. 사전 준비

### 5.1 RDS 프로비저닝

**Terraform 경로:** `shared/rds/dev/`

**체크리스트:**
```
☐ Terraform 코드 검토 (shared/rds/dev/main.tf, rds.tf, networking.tf)
☐ 파라미터 그룹 설정 검증 (UTF-8, timezone=Asia/Seoul)
☐ Security Group 규칙 확인 (3306 ← VPC CIDR만)
☐ 비용 추정 검토 (t4g.micro + 20GB gp3 ≈ $30/월)
☐ terraform plan 실행 및 리뷰
☐ terraform apply (Dev 환경)
☐ RDS 인스턴스 상태 확인 (Available)
```

**예상 소요 시간:** 15-20분

### 5.2 Private Subnet 생성 (기존 VPC 내)

**요구사항:**
- Subnet A: 10.0.10.0/24 (ap-northeast-2a)
- Subnet B: 10.0.11.0/24 (ap-northeast-2c)
- Route Table: 인터넷 게이트웨이 없음 (완전 프라이빗)
- NAT Gateway: 필요 시만 (현재 Dev는 불필요)

**Terraform 코드:**
```
resource "aws_subnet" "db_private_a" {
  vpc_id                  = aws_vpc.billage.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = false
  tags = { Name = "billage-db-private-a" }
}

resource "aws_subnet" "db_private_c" {
  vpc_id                  = aws_vpc.billage.id
  cidr_block              = "10.0.11.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = false
  tags = { Name = "billage-db-private-c" }
}

resource "aws_db_subnet_group" "billage_db" {
  subnet_ids = [aws_subnet.db_private_a.id, aws_subnet.db_private_c.id]
  tags       = { Name = "billage-db-subnet-group" }
}
```

### 5.3 Security Group 설정 (300K MAU 대비)

**RDS Security Group (계획):**
```
Inbound:
  - Type: MySQL/Aurora
    Port: 3306
    Source: Backend ASG (2-6 instances × 50-100 connections each)
           VPC CIDR (10.0.0.0/16) 범위
    Description: "From App Subnet, scaled for 300K MAU"

Outbound:
  - All (기본)

Capacity Planning:
  - Backend pool: 2-6 instances
  - Connections per instance: 50-100
  - Total DB connections: 100-600 (max_connections=300-500 권장)
```

**EC2(호스트 MySQL) Security Group:**
```
Inbound:
  - 유지 (마이그레이션 후 2주 동안)
```

### 5.4 SSM Parameter Store 업데이트 계획

**마이그레이션 전(현재):**
```
/billage/dev/db/host       = "10.0.1.50" (호스트 MySQL EC2 IP)
/billage/dev/db/port       = "3306"
/billage/dev/db/username   = "billage"
/billage/dev/db/password   = "***" (SecureString)
```

**마이그레이션 후(RDS):**
```
/billage/dev/db/host       = "billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com"
/billage/dev/db/port       = "3306"
/billage/dev/db/username   = "billage_admin"
/billage/dev/db/password   = "***" (SecureString, 새로운 마스터 패스워드)
```

**수동 업데이트 불가 — 자동화 스크립트 필수:**
```bash
#!/bin/bash
# update-ssm-db-params.sh
aws ssm put-parameter \
  --name "/billage/dev/db/host" \
  --value "billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com" \
  --type String \
  --overwrite \
  --region ap-northeast-2

aws ssm put-parameter \
  --name "/billage/dev/db/username" \
  --value "billage_admin" \
  --type String \
  --overwrite \
  --region ap-northeast-2
```

### 5.5 연결 테스트

**테스트 1: EC2 → RDS (VPC 내)**
```bash
# EC2 인스턴스에서
mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
       -u billage_admin -p billage -e "SELECT 1;"
```

**예상 결과:** `Query OK, 0 rows affected (0.01 sec)`

**테스트 2: Docker Container → RDS (IMDSv2 + VPC 경로)**
```bash
# Spring Boot Container (10.0.1.0/24 서브넷에서)
docker run -it --rm \
  -e DB_HOST="billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com" \
  -e DB_USER="billage_admin" \
  -e DB_PASS="***" \
  mysql:8.0 \
  mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} -e "SELECT VERSION();"
```

**참고:** Container 내 AWS API 호출 필요 시 IMDSv2 hop_limit=2 필수

---

## 6. 리허설 계획

### 6.1 리허설 개요

마이그레이션을 본격 추진하기 전 **2회 리허설** 수행. Dev 환경의 테스트 RDS 인스턴스를 활용.

| 리허설 | 목적 | 범위 | 예상 소요 시간 |
|------|-----|------|--------------|
| **리허설 1** | 전체 프로세스 실행, Runbook 작성, 타이밍 측정 | 호스트 MySQL → 테스트 RDS | 1-2시간 |
| **리허설 2** | 리허설 1 피드백 적용, "Prod 실전 가능" 판단 | 동일 | 45-60분 |

### 6.2 리허설 1 상세 계획

**목표:** 마이그레이션 프로세스 검증, 예상 시간 측정, 문제점 식별

**사전 준비:**
- 테스트 RDS 인스턴스 2개 생성 (test-v1, test-v2)
- 호스트 MySQL에서 전체 데이터 덤프 백업

**단계별 실행:**

1. **환경 초기화 (5분)**
   ```bash
   # test-v1 RDS 데이터 모두 삭제
   mysql -h test-v1-rds-endpoint -u billage_admin -p billage -e "
     SET FOREIGN_KEY_CHECKS = 0;
     DROP DATABASE billage;
     CREATE DATABASE billage
       CHARACTER SET utf8mb4
       COLLATE utf8mb4_unicode_ci;
     SET FOREIGN_KEY_CHECKS = 1;
   "
   ```

2. **호스트 MySQL 덤프 생성 (2-3분)**
   ```bash
   mysqldump -h 10.0.1.50 -u billage -p \
     --no-tablespaces \
     --single-transaction \
     --quick \
     billage | gzip > /tmp/billage-dump-$(date +%Y%m%d-%H%M%S).sql.gz
   ```

   **주요 옵션 설명:**
   - `--single-transaction`: 트랜잭션 스냅샷으로 일관성 있는 덤프 (InnoDB)
   - `--no-tablespaces`: RDS 호환성 (RDS는 tablespace 설정 제한)
   - `--quick`: 메모리 효율성

3. **RDS 임포트 (3-5분)**
   ```bash
   # 압축 해제 후 임포트
   gunzip < /tmp/billage-dump-*.sql.gz | \
     mysql -h test-v1-rds-endpoint -u billage_admin -p billage
   ```

4. **데이터 검증 (2-3분)** — 상세는 섹션 8 참고
   ```bash
   # Table count
   SELECT COUNT(*) as table_count
   FROM information_schema.tables
   WHERE table_schema = 'billage';

   # Row count 비교 (호스트 vs RDS)
   SELECT table_name, table_rows FROM information_schema.tables
   WHERE table_schema = 'billage'
   ORDER BY table_rows DESC;
   ```

5. **애플리케이션 연결 테스트 (3-5분)**
   - Spring Boot 앱의 db.host = test-v1-rds-endpoint로 임시 변경
   - FastAPI 서버도 동일하게 변경
   - 각 애플리케이션에서 기본 쿼리 수행 (사용자 목록 조회, 상품 조회)
   - 로그 모니터링 (Connection pool warnings, timeout 없음 확인)

**리허설 1 결과:**
- Runbook v1.0 작성 (단계별 명령어, 소요 시간, 담당자, 체크포인트)
- 예상 마이그레이션 윈도우 확정
- 발견된 이슈 리스트 (예: 특정 테이블 character set 불일치, etc.)

### 6.3 리허설 2 상세 계획

**목표:** 리허설 1 피드백 적용, "Prod 실전 가능 여부" 판단

**실행:**
- 리허설 1에서 발견된 모든 이슈 해결
- 동일한 절차를 test-v2로 다시 실행
- 예상 소요 시간 45-60분 (이슈 해결로 단축)

**Go/No-Go 판단 기준:**
```
Go:
  ✓ 전 단계 성공 (0 에러)
  ✓ 검증 데이터 100% 일치
  ✓ 앱 연결 성공, 쿼리 정상
  ✓ 마이그레이션 윈도우 < 15분

No-Go:
  ✗ 데이터 불일치 > 0.1%
  ✗ 마이그레이션 윈도우 > 20분
  ✗ 앱 연결 실패 또는 성능 저하 > 30%
  ✗ 미해결 이슈 존재
```

---

## 7. 실행 계획 (Prod)

### 7.1 마이그레이션 타임라인

| 시점 | 항목 | 담당자 | 예상 소요 |
|------|------|-------|---------|
| **D-7** | 마이그레이션 공지 (팀 내) | DevOps Lead | - |
| **D-7** | 리허설 2 완료 확인 | DevOps Lead | - |
| **D-1** | 최종 호스트 MySQL 백업 | DBA | 3-5분 |
| **D-1** | RDS 연결 테스트 (재검증) | DevOps | 2-3분 |
| **D-Day 02:00** | 점검 공지 (팀 내 Slack) | DevOps Lead | - |
| **D-Day 02:05** | Spring Boot 앱 중지 | SRE | 1-2분 |
| **D-Day 02:07** | FastAPI 서버 중지 | SRE | 1-2분 |
| **D-Day 02:09** | 호스트 MySQL mysqldump 시작 | DBA | 2-3분 |
| **D-Day 02:12** | RDS 임포트 시작 | DBA | 3-5분 |
| **D-Day 02:17** | SSM Parameter 업데이트 | DevOps | 1-2분 |
| **D-Day 02:19** | Spring Boot 앱 재시작 | SRE | 1-2분 |
| **D-Day 02:21** | FastAPI 서버 재시작 | SRE | 1-2분 |
| **D-Day 02:23** | 데이터 검증 시작 | DBA | 3-5분 |
| **D-Day 02:28** | 점검 완료 공지 | DevOps Lead | - |

**총 마이그레이션 윈도우: 02:05 ~ 02:28 (약 23분)**
**최악 시나리오 (+30%): 30분**

### 7.2 점검 윈도우 선정

**권장:** 한국 시간 기준 **화요일 밤 11시 ~ 수요일 새벽 2시**
- 이유: 업무 시간 후, 야간 활동 최소, 글로벌 서비스 아님

**정확한 시간:** AWS 시간대 기준 18:00-19:00 UTC (KST 목요일 03:00-04:00) 피해서 선정
- RDS 백업 윈도우와 충돌 금지

### 7.3 Step-by-Step 실행 절차

#### Phase 1: 사전 체크 (점검 시작 1시간 전)

```bash
# 1. 호스트 MySQL 상태 확인
mysql -h 10.0.1.50 -u billage -p -e "SHOW MASTER STATUS\G"
# ↳ 예상: binlog position, File

# 2. RDS 상태 확인
aws rds describe-db-instances \
  --db-instance-identifier billage-mysql-dev \
  --query 'DBInstances[0].[DBInstanceStatus,AvailabilityZone]'
# ↳ 예상: available, ap-northeast-2a

# 3. RDS 연결 테스트
mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
       -u billage_admin -p -e "SELECT 1;"
# ↳ 예상: 1

# 4. 애플리케이션 상태 (현재 정상 운영 중)
ps aux | grep java | grep -v grep
ps aux | grep uvicorn | grep -v grep
# ↳ 예상: 프로세스 실행 중
```

#### Phase 2: 애플리케이션 중지 (점검 시작)

```bash
# Spring Boot 중지 (docker 기준)
docker-compose -f docker-compose.yml stop spring-app

# FastAPI 중지 (docker 기준)
docker-compose -f docker-compose.yml stop fastapi-app

# 또는 systemd 기준
systemctl stop billage-spring-app
systemctl stop billage-fastapi-app

# 확인
sleep 5
ps aux | grep -E "(java|uvicorn)" | grep -v grep
# ↳ 예상: 프로세스 없음
```

#### Phase 3: 데이터 덤프 및 임포트

```bash
# 호스트 MySQL에서 덤프 생성
echo "=== [T+5min] 호스트 MySQL 덤프 시작 ==="
time mysqldump -h 10.0.1.50 \
  -u billage -p \
  --no-tablespaces \
  --single-transaction \
  --quick \
  --max_allowed_packet=536870912 \
  billage | gzip > /tmp/billage-prod-dump-$(date +%Y%m%d-%H%M%S).sql.gz

echo "=== [T+8min] 덤프 완료, 파일 크기 확인 ==="
ls -lh /tmp/billage-prod-dump-*.sql.gz | tail -1
# ↳ 예상: 300MB-600MB 정도

# RDS에 임포트
echo "=== [T+12min] RDS 임포트 시작 ==="
time gunzip < /tmp/billage-prod-dump-*.sql.gz | \
  mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
        -u billage_admin -p billage

echo "=== [T+17min] RDS 임포트 완료 ==="
```

#### Phase 4: SSM Parameter 업데이트

```bash
echo "=== [T+19min] SSM Parameter 업데이트 시작 ==="

# 1. 호스트명 변경
aws ssm put-parameter \
  --name "/billage/dev/db/host" \
  --value "billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com" \
  --type String \
  --overwrite \
  --region ap-northeast-2

# 2. 사용자명 변경
aws ssm put-parameter \
  --name "/billage/dev/db/username" \
  --value "billage_admin" \
  --type String \
  --overwrite \
  --region ap-northeast-2

# 3. 비밀번호 변경 (RDS 마스터 패스워드)
aws ssm put-parameter \
  --name "/billage/dev/db/password" \
  --value "${RDS_MASTER_PASSWORD}" \
  --type SecureString \
  --key-id "alias/aws/ssm" \
  --overwrite \
  --region ap-northeast-2

# 4. 확인
aws ssm get-parameters \
  --names "/billage/dev/db/host" "/billage/dev/db/port" "/billage/dev/db/username" \
  --region ap-northeast-2 | jq '.Parameters[] | {Name, Value}'
# ↳ 예상: 호스트는 RDS endpoint, 사용자는 billage_admin, 포트는 3306

echo "=== [T+20min] SSM 업데이트 완료 ==="
```

**※ PNR(Point of No Return) 경계: SSM Parameter 업데이트 완료 시점부터**
- 이 이후 롤백은 호스트 MySQL에서 RDS로의 데이터 동기화 필요
- 신규 데이터는 RDS에만 적용되므로 유실 가능

#### Phase 5: 애플리케이션 재시작

```bash
echo "=== [T+21min] 애플리케이션 재시작 시작 ==="

# Spring Boot 시작
docker-compose -f docker-compose.yml up -d spring-app

# FastAPI 시작
docker-compose -f docker-compose.yml up -d fastapi-app

# 또는 systemd 기준
systemctl start billage-spring-app
systemctl start billage-fastapi-app

# 헬스 체크 (30초 대기 후)
sleep 30
curl -s http://localhost:8080/actuator/health | jq '.status'
# ↳ 예상: "UP"

curl -s http://localhost:8000/health | jq '.status'
# ↳ 예상: "healthy" 또는 유사

echo "=== [T+23min] 애플리케이션 재시작 완료 ==="
```

#### Phase 6: 데이터 검증 (자세한 내용은 섹션 8 참고)

```bash
echo "=== [T+24min] 데이터 검증 시작 ==="

# 1. 테이블 목록 비교
echo "호스트 MySQL 테이블 수:"
mysql -h 10.0.1.50 -u billage -p -se \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'billage';"

echo "RDS MySQL 테이블 수:"
mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
      -u billage_admin -p -se \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'billage';"

# 2. 행 수 비교 (주요 테이블)
for table in users products messages transactions; do
  echo "호스트 MySQL - $table:"
  mysql -h 10.0.1.50 -u billage -p -se \
    "SELECT COUNT(*) FROM ${table};"

  echo "RDS MySQL - $table:"
  mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
        -u billage_admin -p -se \
    "SELECT COUNT(*) FROM ${table};"
done

# 3. 외래키 무결성 검사 (RDS에서)
mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
      -u billage_admin -p billage -e \
  "SELECT TABLE_NAME, CONSTRAINT_NAME FROM information_schema.KEY_COLUMN_USAGE \
   WHERE REFERENCED_TABLE_NAME IS NOT NULL AND TABLE_SCHEMA = 'billage';"

echo "=== [T+28min] 데이터 검증 완료 ==="
```

#### Phase 7: 최종 공지

```bash
echo "=== [T+28min] 마이그레이션 완료 공지 ==="

# Slack 또는 메일로 공지
# 메시지: "Billage DB 마이그레이션 완료. 새 엔드포인트: RDS. 호스트 MySQL 2주 유지."
```

### 7.4 예상 소요 시간 (데이터 규모별)

| 데이터 크기 | 덤프 시간 | 임포트 시간 | 총 점검 윈도우 | 권장 방법 |
|------------|----------|-----------|-------------|---------|
| **500MB-1GB** | 1-3분 | 2-5분 | 15-20분 | mysqldump (현재) |
| **1-5GB** | 3-8분 | 5-15분 | 25-35분 | mysqldump 또는 DMS |
| **5-10GB** | 8-15분 | 15-30분 | 35-50분 | **DMS 권장** |
| **10-30GB** | 15-30분 | 30-60분 | 60-90분 | **DMS 필수** (300K MAU) |

---

## 8. 데이터 검증 방법

마이그레이션 완료 후 데이터 무결성 100% 확인이 필수. 다음 체크리스트를 순차 수행.

### 8.1 테이블 목록 비교

```sql
-- 호스트 MySQL에서
SELECT GROUP_CONCAT(table_name ORDER BY table_name) as table_list
FROM information_schema.tables
WHERE table_schema = 'billage' AND table_type = 'BASE TABLE'
ORDER BY table_name;
```

```sql
-- RDS MySQL에서 동일 쿼리 실행
SELECT GROUP_CONCAT(table_name ORDER BY table_name) as table_list
FROM information_schema.tables
WHERE table_schema = 'billage' AND table_type = 'BASE TABLE'
ORDER BY table_name;
```

**예상:** 결과 완벽 일치

### 8.2 행 수 비교 (모든 테이블)

```sql
-- 호스트 MySQL
SELECT table_name, table_rows
FROM information_schema.tables
WHERE table_schema = 'billage'
ORDER BY table_name;

-- RDS MySQL (동일 쿼리)
SELECT table_name, table_rows
FROM information_schema.tables
WHERE table_schema = 'billage'
ORDER BY table_name;
```

**주의:** `table_rows`는 근사값. 정확한 비교 필요 시:
```sql
SELECT table_name,
       (SELECT COUNT(*) FROM information_schema.key_column_usage
        WHERE table_name = t.table_name) as row_count
FROM information_schema.tables t
WHERE t.table_schema = 'billage'
ORDER BY table_name;
```

### 8.3 외래키 무결성 검사

```sql
-- RDS에서 외래키 제약조건 확인
SELECT CONSTRAINT_NAME, TABLE_NAME, REFERENCED_TABLE_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE REFERENCED_TABLE_NAME IS NOT NULL
AND TABLE_SCHEMA = 'billage'
ORDER BY TABLE_NAME;
```

**예상:** 모든 외래키 활성화 상태

**orphan record 검사 (예: messages → users):**
```sql
SELECT m.id FROM messages m
LEFT JOIN users u ON m.user_id = u.id
WHERE u.id IS NULL AND m.user_id IS NOT NULL;
```

**예상:** 행 0 (orphan 없음)

### 8.4 핵심 데이터 샘플링

```sql
-- 최근 100개 채팅 메시지
SELECT id, user_id, content, created_at
FROM messages
ORDER BY created_at DESC
LIMIT 100;

-- 활성 상품 (category = 'active')
SELECT id, name, price, created_at
FROM products
WHERE status = 'active'
LIMIT 50;

-- 등록된 사용자
SELECT id, username, email, created_at
FROM users
ORDER BY created_at DESC
LIMIT 50;
```

**확인 항목:**
- Timestamp가 예상 범위 (예: created_at > 2024-01-01)
- 텍스트 데이터가 UTF-8 정상 (한글, 이모지 포함)
- 숫자 데이터 범위 정상 (가격 < 10,000,000 같은 비즈니스 로직)

### 8.5 Checksum 비교

```sql
-- 호스트 MySQL (각 테이블별)
CHECKSUM TABLE billage.users;
-- ↳ 예상: | billage.users | 12345678901 |

-- RDS MySQL (동일)
CHECKSUM TABLE billage.users;
-- ↳ 예상: | billage.users | 12345678901 | (같은 값)
```

**주의:** 모든 테이블에 대해 실행. 차이 발생 시 원인 조사 필요.

### 8.6 Auto Increment 값 확인

```sql
-- 호스트 MySQL
SELECT table_name, AUTO_INCREMENT
FROM information_schema.tables
WHERE table_schema = 'billage' AND AUTO_INCREMENT IS NOT NULL
ORDER BY table_name;

-- RDS MySQL (동일)
SELECT table_name, AUTO_INCREMENT
FROM information_schema.tables
WHERE table_schema = 'billage' AND AUTO_INCREMENT IS NOT NULL
ORDER BY table_name;
```

**예상:** 모든 값 일치

**만약 차이 발생:**
```sql
-- RDS에서 수동 조정 (테이블: messages, 현재 AUTO_INCREMENT=500001)
ALTER TABLE messages AUTO_INCREMENT = 500001;
```

### 8.7 검증 체크리스트

```
☐ 테이블 목록 100% 일치
☐ 모든 테이블 행 수 100% 일치
☐ 외래키 무결성 확인 (orphan record 0)
☐ 샘플 데이터 시각적 검증 (UTF-8, 타입, 범위)
☐ Checksum 값 모두 일치
☐ Auto Increment 값 모두 일치
☐ 없음: 데이터 검증 완료, 마이그레이션 성공으로 판정
```

---

## 9. Fallback 및 롤백 계획

### 9.1 PNR(Point of No Return) 정의

**PNR 시점:** SSM Parameter Store 업데이트 + 애플리케이션 재시작 완료

**PNR 이전 (롤백 가능):**
- 호스트 MySQL 데이터 그대로 유지
- 애플리케이션은 아직 호스트 MySQL 사용 중
- 롤백 시간: 5분 이내

**PNR 이후 (롤백 어려움):**
- 애플리케이션이 RDS 사용 중
- 신규 데이터는 RDS에만 기록
- 호스트 MySQL로 복귀 시 PNR 이후 신규 데이터 유실 위험

### 9.2 Fallback Procedure (PNR 이전)

**문제 상황:** RDS 임포트 중 에러 발생, 마이그레이션 중단 판단

```bash
echo "=== Fallback 시작 ==="

# 1. RDS 삭제 또는 리셋 (향후 재시도용)
# - AWS Console에서 billage-mysql-dev 인스턴스 삭제
# - 또는 data 전부 DROP (Terraform destroy는 하지 않음)

# 2. 애플리케이션은 이미 중지 상태이므로, 그대로 유지

# 3. 롤백 없음 (PNR 이전이므로 호스트 MySQL 그대로 사용 중)

# 4. 원인 분석 및 Runbook 수정
# - 예: max_allowed_packet 부족, charset 불일치 등

# 5. 재시도 준비
# - 리허설 Runbook 업데이트
# - RDS 재프로비저닝 (Terraform apply)
# - 재시도는 최소 24시간 후

echo "=== Fallback 완료, 호스트 MySQL 운영 계속 ==="
```

### 9.3 롤백 Procedure (PNR 이후)

**문제 상황:** 애플리케이션이 RDS 사용 중이지만, RDS 성능 저하 또는 이상 데이터 발견

```bash
echo "=== 긴급 롤백 시작 ==="

# 1. 호스트 MySQL 상태 확인 (아직 실행 중이어야 함)
mysql -h 10.0.1.50 -u billage -p -e "SHOW MASTER STATUS\G"
# ↳ 호스트 MySQL이 유지되고 있어야 함

# 2. SSM Parameter를 호스트 MySQL로 복원
aws ssm put-parameter \
  --name "/billage/dev/db/host" \
  --value "10.0.1.50" \
  --type String \
  --overwrite \
  --region ap-northeast-2

aws ssm put-parameter \
  --name "/billage/dev/db/username" \
  --value "billage" \
  --type String \
  --overwrite \
  --region ap-northeast-2

# 3. 애플리케이션 재시작
docker-compose -f docker-compose.yml restart spring-app
docker-compose -f docker-compose.yml restart fastapi-app

# 4. 헬스 체크
sleep 30
curl -s http://localhost:8080/actuator/health | jq '.status'
# ↳ 예상: "UP"

# 5. 데이터 검증 (호스트 MySQL이 최신 데이터 있는지 확인)
mysql -h 10.0.1.50 -u billage -p -e \
  "SELECT COUNT(*) FROM messages WHERE created_at > DATE_SUB(NOW(), INTERVAL 2 HOUR);"
# ↳ 예상: 0 이상 (시간대에 따라 다름)

echo "=== 롤백 완료, 호스트 MySQL로 복귀 ==="
```

**⚠️ 주의:** PNR 이후 롤백 시 RDS에 기록된 신규 데이터는 호스트 MySQL에 없음. 이를 수용해야 함.

### 9.4 호스트 MySQL 2주 유지 정책

**목적:** 마이그레이션 후 예기치 못한 문제 발생 시 빠른 롤백 가능

**기간:** 마이그레이션 일로부터 **2주(14일)**

**유지 작업:**
- EC2 인스턴스 계속 운영 (중지하지 않음)
- MySQL 서비스 실행 상태 유지
- 매일 자동 백업 (스크립트로 cron job)
  ```bash
  # /etc/cron.d/billage-mysql-backup
  # 매일 02:00에 백업
  0 2 * * * root mysqldump -u billage -p${BILLAGE_DB_PASS} billage | \
              gzip > /backups/billage-$(date +\%Y\%m\%d).sql.gz
  ```
- 용량 모니터링 (2주치 백업 = 10-15GB 필요)

**2주 후 처리:**
- 호스트 MySQL 데이터 재확인 (정말 필요 없는지)
- 문제 없음 확인 시 MySQL 서비스 중지
- EC2 인스턴스는 별도 용도 있을 시 다른 서비스로 전환, 없으면 종료
- 그 전에 최종 백업 1회 생성 (S3에 보관, 예: 1년)

### 9.5 RDS ↔ 호스트 MySQL 데이터 동기화

**Scenario:** RDS에는 마이그레이션 이후 신규 데이터가 있고, 호스트 MySQL에는 없음. 롤백 이후 이 차이 메우기

**방법 1: 수동 스크립트 (권장, 데이터 작을 때)**
```bash
# RDS에서 PNR 이후 데이터만 추출
# PNR 시점: 2024-02-15 02:19:00

mysql -h rds-endpoint -u billage_admin -p billage -e \
  "SELECT * INTO OUTFILE '/tmp/new-data.sql' \
   FROM messages \
   WHERE created_at > '2024-02-15 02:19:00';"

# 호스트 MySQL에 임포트
mysql -h 10.0.1.50 -u billage -p billage < /tmp/new-data.sql
```

**방법 2: mysqldump + 선택적 복구 (더 정확)**
```bash
# RDS에서 messages 테이블만 덤프 (신규 데이터)
mysqldump -h rds-endpoint -u billage_admin -p \
  --where="created_at > '2024-02-15 02:19:00'" \
  billage messages > /tmp/messages-delta.sql

# 호스트 MySQL에 임포트
mysql -h 10.0.1.50 -u billage -p billage < /tmp/messages-delta.sql
```

**방법 3: AWS DMS로 CDC 재실행 (복잡, 대용량일 때만)**
- 이미 실패한 마이그레이션이므로 재시도 보다는 수동 동기화 권장

---

## 10. 리스크 및 주의사항

### 10.1 Character Set 불일치

**문제:** 호스트 MySQL utf8 vs RDS utf8mb4

**호스트 MySQL 확인:**
```sql
SHOW VARIABLES LIKE 'character_set%';
SHOW VARIABLES LIKE 'collation%';
```

**예상:**
```
character_set_client: utf8mb4 (이미 utf8mb4로 설정됨)
character_set_connection: utf8mb4
character_set_database: utf8mb4
character_set_server: utf8mb4
collation_server: utf8mb4_unicode_ci
```

**만약 utf8이라면:**
```sql
ALTER DATABASE billage CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 각 테이블도 변경
ALTER TABLE users CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE products CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
-- ... (모든 테이블)
```

**위험도:** 중간 (현재는 이미 utf8mb4로 설정되어 있음)

### 10.2 max_allowed_packet 차이

**호스트 MySQL:**
```sql
SHOW VARIABLES LIKE 'max_allowed_packet';
-- 예상: 67108864 (64MB)
```

**RDS:** Terraform parameter group에서 동일하게 설정 필수
```hcl
parameter {
  name  = "max_allowed_packet"
  value = "67108864"
}
```

**문제:** 덤프 파일이 max_allowed_packet을 초과하면 임포트 실패

**예방:**
```bash
# mysqldump 실행 시 --max_allowed_packet 지정
mysqldump --max_allowed_packet=536870912 ...
# (536MB = 512MB, 충분한 여유)
```

**위험도:** 낮음 (현재 billage 데이터는 이 문제 없음)

### 10.3 DEFINER 이슈 (Stored Procedures, Views, Triggers)

**문제:** 호스트 MySQL의 stored procedure/view에 DEFINER 정보가 포함되어 있으면, RDS 임포트 시 권한 이슈 발생 가능

**확인:**
```sql
SELECT ROUTINE_NAME, ROUTINE_DEFINITION
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'billage';
```

**만약 Stored Procedure 있다면:**
```sql
-- mysqldump에서 DEFINER 제거
mysqldump --skip-definer billage > dump.sql
```

**현재 상황:** Billage는 Stored Procedure/View 거의 없음 (ORM 기반 개발)

**위험도:** 매우 낮음

### 10.4 Timezone 차이

**호스트 MySQL:**
```sql
SHOW VARIABLES LIKE 'time_zone';
-- 예상: SYSTEM 또는 '+00:00'
```

**RDS:** Terraform parameter group에서 Asia/Seoul 설정
```hcl
parameter {
  name  = "time_zone"
  value = "Asia/Seoul"
}
```

**문제:** 날짜/시간 기반 쿼리(created_at, updated_at)에 영향

**해결:**
```sql
-- 호스트 MySQL도 timezone 변경 (마이그레이션 전)
SET GLOBAL time_zone = 'Asia/Seoul';

-- 또는 my.cnf에 추가
default-time-zone = 'Asia/Seoul'
```

**위험도:** 중간 (데이터에는 영향 없지만, 쿼리 결과 다를 수 있음)

### 10.5 Auto Increment Gap

**문제:** AUTO_INCREMENT 값이 덤프/복구 중 손실될 수 있음

**예시:** messages 테이블의 마지막 ID가 500000인데, RDS에서 AUTO_INCREMENT=100001로 설정되면, 신규 메시지 ID는 100002부터 시작 → 충돌 위험

**예방:**
```bash
# mysqldump 후 확인
mysqldump --no-data billage | grep AUTO_INCREMENT

# RDS에 임포트 후 재검증
mysql -h rds-endpoint -u billage_admin -p billage -e \
  "SELECT table_name, AUTO_INCREMENT FROM information_schema.tables \
   WHERE table_schema = 'billage';"

# 차이 발생 시 수동 조정
ALTER TABLE messages AUTO_INCREMENT = 500001;
```

**위험도:** 중간 (데이터 충돌 위험)

### 10.6 Foreign Key 제약조건 순서

**문제:** 외래키가 있는 테이블은 참조 테이블보다 먼저 임포트될 수 없음

**mysqldump 옵션으로 자동 처리:**
```bash
mysqldump --single-transaction --no-tablespaces billage > dump.sql
# ↳ 이미 이 옵션 사용 중이므로 문제 없음
```

**만약 문제 발생하면:**
```sql
-- RDS에서 임포트 시
SET FOREIGN_KEY_CHECKS = 0;
-- [임포트 실행]
SET FOREIGN_KEY_CHECKS = 1;
REPAIR TABLE ... CHECK TABLE ...;
```

**위험도:** 낮음 (mysqldump 옵션이 이미 처리)

### 10.7 InnoDB vs MyISAM

**Billage 현황:** InnoDB (기본)

**확인:**
```sql
SELECT table_name, engine FROM information_schema.tables
WHERE table_schema = 'billage';
-- 예상: 모두 InnoDB
```

**만약 MyISAM이 있다면:** 마이그레이션 전에 InnoDB로 변환 필수
```sql
ALTER TABLE old_table ENGINE = InnoDB;
```

**위험도:** 매우 낮음

### 10.8 바이너리 데이터 (BLOB)

**문제:** 바이너리 데이터가 Character Set 설정에 영향받을 수 있음

**예방:**
```bash
# mysqldump 시 안전한 옵션
mysqldump --hex-blob billage > dump.sql
```

**Billage 현황:** BLOB 사용 최소 (대부분 텍스트, 파일은 S3에)

**위험도:** 매우 낮음

---

## 11. 마이그레이션 후 운영 변경점 (300K MAU 성장 대비)

### 11.1 백업 전략 변경 (데이터 규모별)

**Before (Host MySQL, 500 MAU):**
```
방식: 수동 mysqldump
주기: 불정기 (1-2주 간격)
보관: EC2 로컬 스토리지 (500GB 제한)
복구: 수동 복현, ~30분 이상 소요
```

**After (RDS, 현재 500MB-1.2GB):**
```
방식: RDS 자동 백업 (AWS 관리)
주기: 매일 (18:00-19:00 UTC, KST 03:00-04:00)
보관: AWS S3 (7일 자동 보관)
복구: AWS Console 또는 CLI로 PITR (5분)
```

**300K MAU 성장 시 (데이터 10-30GB):**
```
자동 백업: RDS 유지 (AWS S3 관리, 용량 무제한)
추가 대책:
  - PITR 보관 기간 연장 (7 → 30일 고려)
  - Multi-AZ 스냅샷 자동화 (cross-region DR)
  - Read Replica 백업 (읽기 성능 + 재해복구)
```

**권장 추가 설정:**
```hcl
# Terraform에서 backup_window 명시
backup_window           = "18:00-19:00"
backup_retention_period = 7

# 추가: 월 1회 수동 스냅샷 (장기 보관용)
resource "aws_db_snapshot" "monthly" {
  db_instance_identifier = aws_db_instance.billage.id
  db_snapshot_identifier = "billage-monthly-${formatdate("YYYY-MM", timestamp())}"
  tags = { Retention = "12 months" }
}
```

### 11.2 모니터링 시스템 도입 (300K MAU 성장 대비)

**Before (Host MySQL):**
```
모니터링: 없음
알림: 없음
성능 분석: 불가
```

**After (RDS, 현재):**
```
CloudWatch 메트릭:
  - CPU Utilization (목표: < 60%)
  - Database Connections (목표: < 70% of max_connections)
  - Read/Write IOPS (기본: 3000)
  - Storage Space (경고: > 80% of allocated)
  - Query Performance Insights (선택)

**Slow Query Monitoring:**
  - RDS Parameter Group에서 활성화 (>2초)
  - CloudWatch Logs로 전송
  - 정기적 분석 (쿼리 최적화)

**Dashboard:**
  - Grafana에서 CloudWatch 메트릭 시각화
  - Slack 연동 알림 (CPU > 70%, Connections > 200, 응답시간 > 500ms)

**300K MAU 성장 시 추가 모니터링:**
  - Query Performance Insights (느린 쿼리 자동 탐지)
  - Enhanced Monitoring (OS 레벨: 디스크 I/O, 메모리 사용률)
  - Database Activity Streams (감사 및 성능 추적)
```

**Terraform 설정:**
```hcl
# CloudWatch 로그 그룹
resource "aws_cloudwatch_log_group" "rds_slowquery" {
  name              = "/aws/rds/billage-slowquery"
  retention_in_days = 7
}

# 알람 (CPU > 80%)
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "billage-rds-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "Alert when RDS CPU > 80%"
  alarm_actions       = [aws_sns_topic.billage_alerts.arn]
}
```

### 11.3 접근 방식 변경 (300K MAU 성장 대비)

**Before (Host MySQL):**
```
접근 방법:
  1. VPN 접속 (10.100.0.0/24)
  2. EC2 SSH 접속
  3. mysql CLI로 직접 쿼리
  4. 도구: mysql CLI, sequel-pro (Mac)

보안:
  - Security Group: 3306 ← VPN CIDR
  - 암호화: 없음 (로컬 네트워크)
```

**After (RDS, 현재):**
```
접근 방법 (Dev):
  1. VPN 접속 (선택사항, VPC 내이므로 불필요)
  2. DBeaver / DataGrip (IDE) 사용 권장
  3. mysql CLI도 가능
  4. 도구: DBeaver (무료), DataGrip (유료), mysql CLI

보안:
  - Security Group: 3306 ← VPC CIDR (10.0.0.0/16)
  - 암호화: SSL/TLS (RDS 기본, in-transit)
  - 비밀번호: SSM Parameter Store (SecureString)

**300K MAU 성장 시 (Prod 환경):**
  - VPN 없이 VPC 내부만 접근 (직접 DB 접근 제한)
  - IAM DB Authentication 도입 (임시 토큰 기반)
  - Read Replica 추가 (읽기 전용 쿼리 분산, db.t4g.medium)
  - Database Activity Streams (감사 로깅)
```

**예시: DBeaver 접속 설정**
```
Host: billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com
Port: 3306
Database: billage
Username: billage_admin
Password: [SSM Parameter Store에서 복사]
SSL: Required
```

### 11.4 암호 로테이션 정책

**Before (Host MySQL):**
```
변경: 수동 (비정기적)
기록: 없음 (보안 위험)
```

**After (RDS):**
```
현재: SSM Parameter Store (SecureString)로 수동 관리

향후(3개월 후):
  - AWS Secrets Manager로 마이그레이션
  - 자동 로테이션 활성화 (30일마다)
  - Lambda 함수로 RDS 마스터 패스워드 자동 변경
  - 버전 관리 (최대 6개 버전 유지)
```

**Terraform 설정 (향후):**
```hcl
resource "aws_secretsmanager_secret" "db_password" {
  name = "billage/dev/db/password"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = aws_db_instance.billage.master_user_password
}

# 자동 로테이션 (30일마다)
resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_rules {
    automatically_after_days = 30
  }
}
```

### 11.5 데이터베이스 업그레이드 전략

**Before (Host MySQL):**
```
MySQL 버전 관리: 수동
업그레이드: 거의 하지 않음 (위험)
```

**After (RDS):**
```
MySQL 버전: 8.0 (고정)
마이너 버전 업데이트: RDS 자동 (유지보수 윈도우)
메이저 버전 업그레이드(예: 8.0 → 9.0): 수동 (향후)

정책:
  - 메이저 버전은 2년 지원 기간 후 업그레이드
  - 현재: MySQL 8.0 (2026년까지 지원)
  - 마이너 버전은 자동 업데이트 (유지보수 윈도우: 월 19:00-20:00 UTC)
```

### 11.6 읽기 복제본(Read Replica) 계획 (300K MAU 성장 대비)

**현재(Dev, 500 MAU):** 필요 없음

**300K MAU 성장 시 (Prod):**
```
목표:
  - 읽기 성능 향상 (특히 통계, 리포팅, Analytics 쿼리)
  - 재해 복구 (다른 리전)
  - 읽기 부하 분산 (Primary: 쓰기, Replica: 읽기)

구성:
  Phase 1 (10K DAU):
    - Primary: ap-northeast-2a (Seoul, db.t4g.medium)
    - Read Replica 1: ap-northeast-2c (Cross-AZ for HA)

  Phase 2 (100K+ DAU):
    - Primary: ap-northeast-2a (db.t4g.large 이상)
    - Read Replica 1: ap-northeast-2c (db.t4g.medium)
    - Read Replica 2: ap-southeast-1 (Singapore, DR용, db.t4g.medium)

성능 모델 (300K MAU):
  - Primary write throughput: ~900 RPS
  - Read Replica 처리: 보고서 조회, 분석 쿼리 (별도 커넥션)
  - Replication lag: < 1초 (거의 실시간)

Terraform:
  resource "aws_db_instance" "read_replica" {
    replicate_source_db      = aws_db_instance.billage.identifier
    instance_class          = "db.t4g.medium"
    publicly_accessible     = false
    skip_final_snapshot     = false
    storage_encrypted       = true
    backup_retention_period = 7
  }
```

---

## 12. 요약 및 의사결정 기록

### 12.1 마이그레이션 개요 (v1 500 MAU → v2 300K MAU 성장 전략)

| 항목 | 현재 (v1, 500 MAU) | 300K MAU 성장 시 | 비고 |
|------|------------------|-----------------|------|
| **방식** | mysqldump + 점검 윈도우 (Option A) | DMS 또는 병렬화 필요 | 데이터 크기에 따라 변동 |
| **예상 점검 시간** | 20-25분 | 30-90분 | 10-30GB 데이터 대비 |
| **다운타임** | 약 20분 (수용 가능) | 무중단 마이그레이션 (DMS) | 비즈니스 요구 상향 |
| **롤백 시간** | 5분 이내 | 15-30분 | RDS 스냅샷 복구 |
| **호스트 MySQL 유지** | 2주 (롤백 버퍼) | 1개월 (검증 기간 연장) | v2 안정화 확인 |
| **리허설** | 2회 (Go/No-Go 판단) | 3-4회 (각 Phase별) | 복잡도 증가 |
| **Database 크기** | 현재 500MB-1.2GB | 목표 10-30GB | 성장 단계별 대비 |
| **Max Connections** | 100 | 300-500 | 동시 사용자 증가 |
| **RDS Instance** | db.t4g.micro (Dev) | db.t4g.medium (Prod) | 성능 확보 |
| **Storage Auto-scale** | 20 → 50GB | 20 → 100GB | 성장량 수용 |

### 12.2 위험도 평가 (300K MAU 성장 단계별)

| 위험 요소 | 발생 확률 | 영향도 | v1→v2 대책 | 300K MAU 대책 |
|---------|---------|-------|-----------|-------------|
| Character Set 불일치 | 낮음 | 중간 | 사전 검증 | 자동 변환 스크립트 |
| Foreign Key 제약 위반 | 낮음 | 높음 | --single-transaction | DMS CDC 기반 검증 |
| 데이터 손실 | 매우 낮음 | 매우 높음 | 검증 프로세스, 호스트 유지 | Read Replica PITR |
| 마이그레이션 실패 | 낮음 | 높음 | 리허설 2회 | 리허설 3-4회, Phase별 |
| 애플리케이션 연결 오류 | 낮음 | 높음 | SSM Parameter 사전 검증 | 커넥션 풀 모니터링 |
| 데이터 불일치 (증분 데이터) | 중간 | 높음 | 2주 호스트 유지 | DMS CDC 기반 동기화 |
| RDS 성능 부족 | 중간 | 높음 | t4g.micro 초기 | 단계적 업그레이드 + Read Replica |
| 롤백 비용/시간 | 낮음 | 중간 | SSM 복원 (5분) | RDS 스냅샷 (15-30분) |

### 12.3 성공 기준

```
마이그레이션 성공 = 다음 모두 만족

1. ✓ 모든 데이터 무결성 검증 통과 (테이블 수, 행 수, Checksum)
2. ✓ 애플리케이션 정상 운영 (에러 로그 0)
3. ✓ 응답 시간 이전과 같거나 빠름 (p95 < 100ms)
4. ✓ RDS 자동 백업 정상 작동
5. ✓ 모니터링 대시보드 연동
```

### 12.4 다음 단계 (v2 성장 로드맵)

**마이그레이션 후:**
```
[Phase 0: 현재, 500 MAU]
  1. [즉시] 호스트 MySQL 2주 유지, 모니터링
  2. [1주일] 슬로우 쿼리 로그 분석, 필요 시 인덱스 추가
  3. [2주일] 호스트 MySQL 역할 완료, 서비스 중지
  4. [1개월] Prod 데이터베이스 마이그레이션 추진

[Phase 1: 500 → 5K DAU (1.5K MAU 성장)]
  - 데이터 규모: 1-2GB (mysqldump 여전히 가능)
  - RDS 인스턴스: db.t4g.micro → db.t4g.small로 업그레이드
  - Max connections: 100 → 200
  - 모니터링: CloudWatch 강화 (CPU, 커넥션, IOPS)

[Phase 2: 5K → 10K DAU (10K-50K MAU 성장)]
  - 데이터 규모: 5-10GB (DMS 고려)
  - RDS 인스턴스: db.t4g.medium 필수
  - Max connections: 300
  - 추가 조치: Read Replica 추가 (읽기 분산)
  - 마이그레이션 전략: DMS 또는 병렬 mysqldump

[Phase 3: 10K → 100K DAU (100K-300K MAU)]
  - 데이터 규모: 10-30GB (DMS 필수, 무중단)
  - RDS 인스턴스: db.t4g.large 이상, Multi-AZ 활성화
  - Max connections: 500+
  - 추가 조치: Read Replica x2-3 (cross-region)
  - IAM DB Authentication, Query Performance Insights
  - 샤딩 고려 (특정 테이블, 예: messages)

[3개월] Secrets Manager 자동 로테이션 도입, Read Replica 추가
```

---

## 부록: Runbook 템플릿

### 마이그레이션 Runbook v1.0

```
=============================================================================
Billage Database Migration Runbook
=============================================================================
일시: 2024-02-15 02:00 UTC (2024-02-15 11:00 KST)
담당자: DevOps Lead, DBA, SRE
=============================================================================

[ PRE-CHECK: 점검 시작 1시간 전 ]

☐ 호스트 MySQL 상태 확인
  $ mysql -h 10.0.1.50 -u billage -p -e "SHOW MASTER STATUS\G"
  예상: binlog position, File 정상

☐ RDS 상태 확인
  $ aws rds describe-db-instances --db-instance-identifier billage-mysql-dev
  예상: Status = available

☐ RDS 연결 테스트
  $ mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
          -u billage_admin -p -e "SELECT 1;"
  예상: OK

☐ 애플리케이션 상태 확인
  $ ps aux | grep -E "(java|uvicorn)" | grep -v grep
  예상: 프로세스 2개 이상 실행 중

=============================================================================

[ PHASE 1: 애플리케이션 중지 | 예상 소요: 2-3분 ]

T+0min: 점검 공지 (Slack)
  메시지: "Billage DB 마이그레이션 시작. 약 20분 소요. 서비스 이용 불가."

T+5min: Spring Boot 중지
  $ docker-compose -f docker-compose.yml stop spring-app
  또는
  $ systemctl stop billage-spring-app

  확인: $ ps aux | grep java | grep -v grep
  예상: 출력 없음

T+7min: FastAPI 중지
  $ docker-compose -f docker-compose.yml stop fastapi-app
  또는
  $ systemctl stop billage-fastapi-app

  확인: $ ps aux | grep uvicorn | grep -v grep
  예상: 출력 없음

=============================================================================

[ PHASE 2: 데이터 덤프 및 임포트 | 예상 소요: 5-8분 ]

T+9min: 호스트 MySQL 덤프 생성
  $ time mysqldump -h 10.0.1.50 \
      -u billage -p \
      --no-tablespaces \
      --single-transaction \
      --quick \
      billage | gzip > /tmp/billage-dump-$(date +%Y%m%d-%H%M%S).sql.gz

  예상 소요: 2-3분
  예상 파일 크기: 300-600MB

  확인: $ ls -lh /tmp/billage-dump-*.sql.gz | tail -1

T+12min: RDS 임포트 시작
  $ gunzip < /tmp/billage-dump-*.sql.gz | \
    mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
          -u billage_admin -p billage

  예상 소요: 3-5분
  모니터링: AWS Console에서 RDS 데이터베이스 이벤트 확인

T+17min: 임포트 완료 확인
  $ mysql -h billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com \
          -u billage_admin -p billage -e "SELECT COUNT(*) FROM messages;"
  예상: 숫자 반환 (0 이상)

=============================================================================

[ PHASE 3: SSM Parameter 업데이트 | 예상 소요: 1-2분 ] ⚠️ PNR 경계

T+19min: SSM Parameter 업데이트

  $ aws ssm put-parameter \
      --name "/billage/dev/db/host" \
      --value "billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com" \
      --type String \
      --overwrite \
      --region ap-northeast-2

  $ aws ssm put-parameter \
      --name "/billage/dev/db/username" \
      --value "billage_admin" \
      --type String \
      --overwrite \
      --region ap-northeast-2

  확인: $ aws ssm get-parameter --name "/billage/dev/db/host" \
          --query "Parameter.Value"
  예상: billage-mysql-dev.c9akciq32.ap-northeast-2.rds.amazonaws.com

  ⚠️ 이 시점부터 롤백 시 RDS 신규 데이터 유실 가능

=============================================================================

[ PHASE 4: 애플리케이션 재시작 | 예상 소요: 2-3분 ]

T+21min: Spring Boot 재시작
  $ docker-compose -f docker-compose.yml up -d spring-app
  또는
  $ systemctl start billage-spring-app

  대기: 30초

  헬스 체크: $ curl -s http://localhost:8080/actuator/health | jq '.status'
  예상: "UP"

T+23min: FastAPI 재시작
  $ docker-compose -f docker-compose.yml up -d fastapi-app
  또는
  $ systemctl start billage-fastapi-app

  대기: 30초

  헬스 체크: $ curl -s http://localhost:8000/health
  예상: 200 OK 또는 유사 응답

=============================================================================

[ PHASE 5: 데이터 검증 | 예상 소요: 3-5분 ]

T+24min: 데이터 검증

  1) 테이블 수 비교
     RDS: $ mysql -h billage-mysql-dev... -u billage_admin -p -se \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='billage';"

  2) Row count 비교 (주요 테이블)
     $ mysql -h billage-mysql-dev... -u billage_admin -p -se \
       "SELECT table_name, table_rows FROM information_schema.tables \
        WHERE table_schema='billage' ORDER BY table_rows DESC;"

  3) 샘플 데이터 확인
     $ mysql -h billage-mysql-dev... -u billage_admin -p billage -e \
       "SELECT id, created_at FROM messages ORDER BY created_at DESC LIMIT 10;"
     예상: 최근 데이터 보임

  4) Checksum 확인
     $ mysql -h billage-mysql-dev... -u billage_admin -p billage -e \
       "CHECKSUM TABLE messages, users, products;"

T+28min: 검증 완료

  ✓ 모든 검증 통과 → 마이그레이션 성공
  ✗ 데이터 불일치 → 긴급 롤백 시작 (섹션 9.3 참고)

=============================================================================

[ POST-MIGRATION ]

T+30min: 공지 (Slack)
  메시지: "Billage DB 마이그레이션 완료. 서비스 정상화.
           호스트 MySQL은 2주 유지됩니다."

이후: 모니터링 및 로그 분석
  - 애플리케이션 에러 로그 확인
  - RDS 성능 메트릭 모니터링
  - 사용자 피드백 수집

이후: 호스트 MySQL 유지
  - 2주 동안 매일 자동 백업
  - 용량 모니터링
  - 필요 시 언제든 롤백 가능

=============================================================================
```

---

## 최종 체크리스트

마이그레이션 실행 전 다음을 모두 확인하세요:

```
준비 단계
  ☐ Terraform 코드 검토 및 apply 완료 (shared/rds/dev/)
  ☐ Private Subnet 생성 (10.0.10.0/24, 10.0.11.0/24)
  ☐ Security Group 설정 (3306 ← VPC CIDR)
  ☐ 리허설 2회 완료, Go 판단
  ☐ Runbook v1.0 최종 검토

점검 윈도우 (D-Day)
  ☐ 애플리케이션 중지 (Spring Boot, FastAPI)
  ☐ 호스트 MySQL 덤프 생성 (--single-transaction, --no-tablespaces)
  ☐ RDS 임포트 완료
  ☐ SSM Parameter 업데이트 (host, username) ⚠️ PNR
  ☐ 애플리케이션 재시작
  ☐ 헬스 체크 (Spring Boot, FastAPI)
  ☐ 데이터 검증 (테이블 수, 행 수, Checksum, 샘플 데이터)

점검 후
  ☐ 공지 (팀 내 Slack)
  ☐ 호스트 MySQL 2주 유지 (자동 백업 설정)
  ☐ 모니터링 대시보드 점검 (CloudWatch, Grafana)
  ☐ 슬로우 쿼리 로그 모니터링 시작

롤백 준비
  ☐ 호스트 MySQL 데이터 그대로 유지 (PNR 이전)
  ☐ PNR 이후 롤백 필요 시 SSM을 호스트로 복원 + 앱 재시작 (5분)
  ☐ 2주 후 호스트 MySQL 최종 확인 후 서비스 중지
```

---

**문서 작성일:** 2024-02-10
**버전:** 1.0
**마지막 검토:** DevOps Lead, DBA
**유효 기간:** 마이그레이션 완료 시까지

