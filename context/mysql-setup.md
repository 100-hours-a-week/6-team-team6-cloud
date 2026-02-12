# MySQL 외부 접속 설정 가이드

EC2 인스턴스에 설치된 MySQL에 외부(로컬 PC, CI/CD 등)에서 접속할 수 있도록 설정하는 가이드입니다.

## 빠른 설정 (스크립트 사용)

```bash
# SSH 접속
ssh -i <your-key.pem> ubuntu@<ELASTIC_IP>

# 스크립트 실행
sudo bash /opt/billage/scripts/setup-mysql.sh
```

스크립트가 대화형으로 다음을 설정합니다:
- DB 사용자명/비밀번호
- 데이터베이스 생성
- 외부 접속 허용

---

## 수동 설정 (단계별)

### 1단계: SSH 접속

```bash
ssh -i <your-key.pem> ubuntu@<ELASTIC_IP>
```

### 2단계: MySQL 보안 초기 설정 (선택)

```bash
sudo mysql_secure_installation
```

질문에 대한 권장 답변:
| 질문 | 권장 답변 |
|------|-----------|
| VALIDATE PASSWORD component | N (개발 환경) |
| root 비밀번호 설정 | 원하는 비밀번호 입력 |
| Remove anonymous users | Y |
| Disallow root login remotely | Y |
| Remove test database | Y |
| Reload privilege tables | Y |

### 3단계: 데이터베이스 및 사용자 생성

```bash
# MySQL 접속 (Ubuntu 기본: sudo로 root 접속)
sudo mysql
```

```sql
-- 데이터베이스 생성
CREATE DATABASE billage CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 사용자 생성 (외부 접속용 - '%'는 모든 IP 허용)
CREATE USER 'billage'@'%' IDENTIFIED BY 'your-secure-password';

-- 사용자 생성 (로컬 접속용)
CREATE USER 'billage'@'localhost' IDENTIFIED BY 'your-secure-password';

-- 권한 부여
GRANT ALL PRIVILEGES ON billage.* TO 'billage'@'%';
GRANT ALL PRIVILEGES ON billage.* TO 'billage'@'localhost';

-- 권한 적용
FLUSH PRIVILEGES;

-- 확인
SELECT user, host FROM mysql.user WHERE user = 'billage';

-- 종료
EXIT;
```

### 4단계: 외부 접속 허용 설정

MySQL 기본 설정은 localhost(127.0.0.1)만 접속을 허용합니다. 외부 접속을 위해 변경이 필요합니다.

```bash
# 설정 파일 편집
sudo vim /etc/mysql/mysql.conf.d/mysqld.cnf
```

다음 줄을 찾아서 수정:

```ini
# 변경 전
bind-address = 127.0.0.1

# 변경 후
bind-address = 0.0.0.0
```

### 5단계: MySQL 재시작

```bash
sudo systemctl restart mysql

# 상태 확인
sudo systemctl status mysql
```

### 6단계: 접속 테스트

**서버 내부에서 테스트:**
```bash
mysql -u billage -p billage
```

**로컬 PC에서 테스트:**
```bash
mysql -h <ELASTIC_IP> -P 3306 -u billage -p billage
```

---

## 접속 정보 정리

설정 완료 후 아래 정보를 팀에 공유하세요:

| 항목 | 값 |
|------|-----|
| Host | `<ELASTIC_IP>` 또는 `dev.billages.com` |
| Port | `3306` |
| Database | `billage` |
| Username | `billage` |
| Password | `(설정한 비밀번호)` |

---

## 애플리케이션 연동

### Spring Boot (application.yml)

```yaml
spring:
  datasource:
    url: jdbc:mysql://<ELASTIC_IP>:3306/billage?useSSL=false&serverTimezone=Asia/Seoul&characterEncoding=UTF-8
    username: billage
    password: your-secure-password
    driver-class-name: com.mysql.cj.jdbc.Driver

  jpa:
    hibernate:
      ddl-auto: update
    properties:
      hibernate:
        dialect: org.hibernate.dialect.MySQL8Dialect
        format_sql: true
    show-sql: true
```

### Python (FastAPI/SQLAlchemy)

```python
from sqlalchemy import create_engine

DATABASE_URL = "mysql+pymysql://billage:your-secure-password@<ELASTIC_IP>:3306/billage?charset=utf8mb4"
engine = create_engine(DATABASE_URL)
```

### Node.js (mysql2)

```javascript
const mysql = require('mysql2');

const connection = mysql.createConnection({
  host: '<ELASTIC_IP>',
  port: 3306,
  user: 'billage',
  password: 'your-secure-password',
  database: 'billage'
});
```

---

## GUI 클라이언트 연결

### DBeaver

1. 새 연결 → MySQL 선택
2. 연결 정보 입력:
   - Host: `<ELASTIC_IP>`
   - Port: `3306`
   - Database: `billage`
   - Username: `billage`
   - Password: `(비밀번호)`
3. Driver properties에서 `allowPublicKeyRetrieval` → `true` 설정
4. Test Connection → Finish

### MySQL Workbench

1. MySQL Connections → (+) 추가
2. Connection Name: `Billage Dev`
3. Hostname: `<ELASTIC_IP>`
4. Port: `3306`
5. Username: `billage`
6. Test Connection → 비밀번호 입력

### DataGrip / IntelliJ

1. Database 탭 → (+) → Data Source → MySQL
2. Host: `<ELASTIC_IP>`
3. Port: `3306`
4. User: `billage`
5. Password: `(비밀번호)`
6. Database: `billage`
7. Test Connection

---

## 보안 고려사항

### 현재 설정 (개발 환경)

| 항목 | 설정 | 위험도 |
|------|------|--------|
| 접속 허용 IP | 모든 IP (`'%'`) | 높음 |
| Security Group | 3306 전체 오픈 | 높음 |
| SSL | 미사용 | 중간 |

### 프로덕션 권장 설정

```sql
-- 특정 IP만 허용
CREATE USER 'billage'@'123.123.123.123' IDENTIFIED BY 'password';

-- 또는 VPC 내부만 허용
CREATE USER 'billage'@'10.0.%' IDENTIFIED BY 'password';
```

```hcl
# terraform - Security Group에서 특정 IP만 허용
db_allowed_cidr = ["123.123.123.123/32"]  # 개발자 IP
# 또는
db_allowed_cidr = ["10.0.0.0/16"]  # VPC 내부만
```

---

## 트러블슈팅

### 1. 접속 거부 (Access denied)

```
ERROR 1045 (28000): Access denied for user 'billage'@'...'
```

**해결:**
```sql
-- 사용자 확인
SELECT user, host FROM mysql.user;

-- 권한 다시 부여
GRANT ALL PRIVILEGES ON billage.* TO 'billage'@'%';
FLUSH PRIVILEGES;
```

### 2. 연결 타임아웃

```
Can't connect to MySQL server on '<IP>' (110)
```

**확인사항:**
```bash
# 1. MySQL 실행 중인지 확인
sudo systemctl status mysql

# 2. 포트 리스닝 확인
sudo ss -tlnp | grep 3306

# 3. bind-address 확인
grep bind-address /etc/mysql/mysql.conf.d/mysqld.cnf
```

### 3. Public Key Retrieval 오류

```
Public Key Retrieval is not allowed
```

**해결 (JDBC URL):**
```
jdbc:mysql://host:3306/db?allowPublicKeyRetrieval=true&useSSL=false
```

### 4. 문자셋 문제 (한글 깨짐)

```sql
-- 데이터베이스 문자셋 확인
SHOW CREATE DATABASE billage;

-- 테이블 문자셋 확인
SHOW CREATE TABLE your_table;

-- 문자셋 변경
ALTER DATABASE billage CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

---

## 유용한 명령어

```bash
# MySQL 상태 확인
sudo systemctl status mysql

# MySQL 로그 확인
sudo tail -f /var/log/mysql/error.log

# 현재 연결 확인
sudo mysql -e "SHOW PROCESSLIST;"

# 데이터베이스 목록
sudo mysql -e "SHOW DATABASES;"

# 사용자 목록
sudo mysql -e "SELECT user, host FROM mysql.user;"
```