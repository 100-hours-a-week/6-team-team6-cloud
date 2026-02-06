# Monitoring Stack

Prometheus + Grafana + Loki 기반 모니터링 시스템

## 구조

```
monitoring/
├── server/          # 모니터링 서버 (Prometheus, Grafana, Loki)
└── target/          # 타겟 서버 (Exporters, Promtail)
    ├── exporters/   # 메트릭 수집 (Node, cAdvisor, MySQL, Redis, Mongo)
    └── promtail/    # 로그 수집
```

## 사전 준비

### 1. EC2 IAM 역할 (모니터링 서버)
Prometheus EC2 Service Discovery를 위한 권한 필요:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeInstances"
    ],
    "Resource": "*"
  }]
}
```

### 2. EC2 태그 설정 (타겟 서버)
모니터링 대상 EC2 인스턴스에 태그 추가:
- `Role`: `monitoring-target`
- `Name`: 인스턴스 식별용 (예: `prod-web-01`)

## 배포

### 모니터링 서버 설정

```bash
# 1. 서버로 파일 전송
scp -r monitoring/server user@monitoring-server:/home/user/

# 2. 환경변수 설정
cd /home/user/server
cp .env.example .env
vim .env
# GRAFANA_ADMIN_PASSWORD=your_secure_password  # 필수 변경
# AWS_REGION=ap-northeast-2
# EC2_DISCOVERY_ROLE_TAG=monitoring-target     # Terraform Role 태그와 일치

# 3. 실행
docker-compose up -d

# 4. 접속 확인
# Grafana: http://monitoring-server:3000
# Prometheus: http://monitoring-server:9090
# Loki: http://monitoring-server:3100
```

### 타겟 서버 설정

```bash
# 1. 서버로 파일 전송
scp -r monitoring/target user@target-server:/home/user/

# 2. Exporters 환경변수 설정
cd /home/user/target/exporters
cp .env.example .env
vim .env
```

**수정 필요 항목:**
```bash
# MySQL (systemd로 실행 중인 서비스 연결)
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL_EXPORTER_USER=exporter         # MySQL 계정 생성 필요
MYSQL_EXPORTER_PASSWORD=your_password

# Redis
REDIS_HOST=localhost
REDIS_PORT=6379

# MongoDB
MONGO_HOST=localhost
MONGO_PORT=27017
```

**MySQL Exporter 계정 생성:**
```bash
# mysql/init_exporter.sql 참고
mysql -u root -p < mysql/init_exporter.sql
# 또는 수동:
# CREATE USER 'exporter'@'localhost' IDENTIFIED BY 'password';
# GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';
```

```bash
# 3. Promtail 환경변수 설정
cd /home/user/target/promtail
cp .env.example .env
vim .env
```

**수정 필요 항목:**
```bash
# Loki 서버 주소 (모니터링 서버의 Private IP)
LOKI_HOST=10.0.1.231  # 모니터링 서버 Private IP

# Environment
ENV=dev

# 로그 디렉토리 경로 (systemd 서비스 로그 위치)
NGINX_LOG_PATH=/var/log/nginx
SPRING_LOG_PATH=/var/log/billage/backend

# 로그 파일 경로
NGINX_LOG_FILE_PATH=/var/log/nginx/access.log
SPRING_LOG_FILE_PATH=/var/log/billage/backend/app.log
```

```bash
# 4. Exporters 실행
cd /home/user/target/exporters
docker-compose up -d

# 5. Promtail 실행
cd /home/user/target/promtail
docker-compose up -d

# 6. 확인
docker ps
curl localhost:9100/metrics  # Node Exporter
curl localhost:8082/metrics  # cAdvisor
curl localhost:9104/metrics  # MySQL Exporter
```

## 포트 목록

### 모니터링 서버
- `3000`: Grafana
- `9090`: Prometheus
- `3100`: Loki

### 타겟 서버
- `9100`: Node Exporter (시스템 메트릭)
- `8082`: cAdvisor (컨테이너 메트릭)
- `9104`: MySQL Exporter

## 보안 그룹 설정

### 모니터링 서버
- Inbound: 3000 (Grafana), 9090 (Prometheus), 3100 (Loki) - 관리자 IP만 허용
- Outbound: All (EC2 Service Discovery용)

### 타겟 서버
- Inbound: 9100, 8082, 9104 - 모니터링 서버 IP만 허용

## 문제 해결

### Prometheus에서 타겟이 안 보일 때
1. EC2 IAM 역할 확인
2. 타겟 서버 EC2 태그 확인 (`Role=monitoring-target`)
3. 보안 그룹 확인 (포트 열림 + 모니터링 서버 IP 허용)

### Promtail 로그가 안 들어올 때
1. `LOKI_HOST` IP 확인 (모니터링 서버 Private IP)
2. 로그 파일 경로 확인 (`NGINX_LOG_PATH`, `SPRING_LOG_FILE_PATH`)
3. 로그 파일 읽기 권한 확인

### MySQL Exporter 연결 실패
1. MySQL exporter 계정 생성 확인
2. `MYSQL_HOST`가 `localhost`인지 확인 (systemd 서비스)
3. MySQL 포트 확인 (`MYSQL_PORT`)