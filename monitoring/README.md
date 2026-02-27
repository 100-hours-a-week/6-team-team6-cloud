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
# MySQL Exporter 계정 비밀번호와 exporter.cnf를 동일하게 맞춰야 함
MYSQL_EXPORTER_USER=exporter
MYSQL_EXPORTER_PASSWORD=your_password

# Nginx Exporter scrape URI
# 기본: dev 환경 (/nginx_status)
NGINX_SCRAPE_URI=http://127.0.0.1/nginx_status
# prod 로컬 전용 status 포트 예시
# NGINX_SCRAPE_URI=http://127.0.0.1:18080/nginx_status
```

**MySQL Exporter 계정 생성:**
```bash
# mysql/init_exporter.sql 참고
mysql -u root -p < mysql/init_exporter.sql
# 또는 수동:
# CREATE USER 'exporter'@'localhost' IDENTIFIED BY 'password';
# CREATE USER 'exporter'@'127.0.0.1' IDENTIFIED BY 'password';
# GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';
# GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'127.0.0.1';
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
curl localhost:9113/metrics  # Nginx Exporter
curl localhost:9104/metrics | grep '^mysql_up'   # mysql_up 1 확인
curl localhost:9113/metrics | grep '^nginx_up'   # nginx_up 1 확인
```

### Prod에서 로컬 전용 Nginx status 엔드포인트를 쓰는 경우
```nginx
# /etc/nginx/conf.d/monitoring-status.conf
server {
    listen 127.0.0.1:18080;
    server_name localhost;

    location = /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
}
```

```bash
sudo nginx -t
sudo systemctl reload nginx   # restart 금지 (무중단)
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
- `9113`: Nginx Exporter

## 보안 그룹 설정

### 모니터링 서버
- Inbound: 3000 (Grafana), 9090 (Prometheus), 3100 (Loki) - 관리자 IP만 허용
- Outbound: All (EC2 Service Discovery용)

### 타겟 서버
- Inbound: 9100, 8082, 9104, 9113 - 모니터링 서버 IP만 허용

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
2. `mysql/exporter.cnf`의 `host`가 `127.0.0.1`인지 확인
3. 계정 권한과 비밀번호 일치 확인 (`Access denied` 여부)

### Nginx Exporter 연결 실패
1. 타겟 서버에서 `curl localhost:9113/metrics` 확인 (`nginx_up 1`)
2. `NGINX_SCRAPE_URI`가 실제 status 엔드포인트와 일치하는지 확인
3. 보안 그룹에 `9113/tcp` 인바운드 허용 여부 확인

### Grafana dev/prod 분리 보기
1. `Billage App Observability` 대시보드 열기
2. 상단 `Environment` 변수에서 `dev`, `prod`, `All` 선택
