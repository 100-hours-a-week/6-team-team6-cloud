# Setup Script 문서

EC2 인스턴스 생성 시 자동으로 실행되는 환경 설정 스크립트입니다.

## 개요

| 항목 | 값 |
|------|-----|
| 스크립트 경로 | `scripts/setup.sh` |
| 실행 시점 | EC2 인스턴스 첫 부팅 시 (user_data) |
| 대상 OS | Ubuntu 24.04 LTS ARM64 |
| 실행 사용자 | root |
| 로그 파일 | `/var/log/billage-setup.log` |

---

## 실행 흐름

```
terraform apply
       │
       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    EC2 Instance 생성                            │
└─────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────────┐
│                 user_data 스크립트 실행                          │
│                   (scripts/setup.sh)                            │
└─────────────────────────────────────────────────────────────────┘
       │
       ├── [1/8] 시스템 패키지 업데이트
       │         apt-get update && upgrade
       │
       ├── [2/8] 필수 유틸리티 설치
       │         curl, wget, git, vim, htop, unzip 등
       │
       ├── [3/8] Java 25 설치 (Eclipse Temurin)
       │         Spring Boot 실행용
       │
       ├── [4/8] Node.js 20 LTS 설치
       │         Next.js 실행용 + PM2 설치
       │
       ├── [5/8] Python 3 설치
       │         FastAPI 실행용 + venv, pip (Ubuntu 24.04 기본: 3.12)
       │
       ├── [6/8] MySQL 8.0 설치
       │         데이터베이스 서버
       │
       ├── [7/8] Nginx 설치
       │         Reverse Proxy 서버
       │
       └── [8/8] 디렉토리 구조 생성
                 /opt/billage/*, /var/log/billage/*
       │
       ▼
┌─────────────────────────────────────────────────────────────────┐
│              Nginx 설정 + systemd 서비스 등록                    │
└─────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Setup 완료 (약 5-10분)                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## 설치되는 소프트웨어

### 1. Java 25 (Eclipse Temurin)

| 항목 | 값 |
|------|-----|
| 버전 | 25 (또는 21 fallback) |
| 패키지 | `temurin-25-jdk` |
| 용도 | Spring Boot 애플리케이션 실행 |
| 설치 경로 | `/usr/lib/jvm/temurin-25-jdk-arm64` |

**설치 과정:**
```bash
# Adoptium GPG 키 등록
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | \
  gpg --dearmor | tee /usr/share/keyrings/adoptium.gpg > /dev/null

# APT 저장소 추가
echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] \
  https://packages.adoptium.net/artifactory/deb noble main" | \
  tee /etc/apt/sources.list.d/adoptium.list

# 설치
apt-get update && apt-get install -y temurin-25-jdk
```

**참고:** Java 25가 아직 릴리즈되지 않았거나 ARM64용이 없으면 Java 21로 자동 fallback됩니다.

---

### 2. Node.js 20 LTS

| 항목 | 값 |
|------|-----|
| 버전 | 20.x LTS |
| 패키지 | `nodejs` (NodeSource) |
| 용도 | Next.js 프론트엔드 실행 |
| 추가 설치 | PM2 (프로세스 매니저) |

**설치 과정:**
```bash
# NodeSource 저장소 설정
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

# 설치
apt-get install -y nodejs
npm install -g pm2
```

**PM2 사용 이유:**
- 프로세스 자동 재시작
- 클러스터 모드 지원
- 로그 관리
- systemd 통합

---

### 3. Python 3.12

| 항목 | 값 |
|------|-----|
| 버전 | 3.12 (Ubuntu 24.04 기본) |
| 패키지 | `python3`, `python3-venv`, `python3-pip`, `python3-full` |
| 용도 | FastAPI AI 서비스 실행 |

**설치 과정:**
```bash
apt-get install -y python3 python3-venv python3-pip python3-full
```

**가상환경 생성 (CI/CD에서):**
```bash
cd /opt/billage/ai
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

### 4. MySQL 8.0

| 항목 | 값 |
|------|-----|
| 버전 | 8.0 |
| 패키지 | `mysql-server` |
| 포트 | 3306 |
| 데이터 경로 | `/var/lib/mysql` |

**설치 과정:**
```bash
apt-get install -y mysql-server
systemctl enable mysql
systemctl start mysql
```

**초기 설정 (수동 필요):**
```bash
# 보안 설정 (root 비밀번호, 익명 사용자 제거 등)
sudo mysql_secure_installation

# 애플리케이션용 데이터베이스/사용자 생성
sudo mysql -e "CREATE DATABASE billage;"
sudo mysql -e "CREATE USER 'billage'@'localhost' IDENTIFIED BY 'your-password';"
sudo mysql -e "GRANT ALL PRIVILEGES ON billage.* TO 'billage'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"
```

---

### 5. Nginx

| 항목 | 값 |
|------|-----|
| 버전 | Latest (Ubuntu repo) |
| 포트 | 80 (HTTP), 443 (HTTPS) |
| 설정 파일 | `/etc/nginx/sites-available/billage` |

**역할:**
- Reverse Proxy (요청 라우팅)
- SSL/TLS 종료
- 정적 파일 서빙
- 로드 밸런싱 (미래)

---

## 디렉토리 구조

### 애플리케이션 디렉토리

```
/opt/billage/
├── backend/                 # Spring Boot
│   ├── app.jar             # 실행 파일 (CI/CD에서 배포)
│   └── config/             # 설정 파일
│       └── application.yml # Spring 설정 (CI/CD에서 배포)
│
├── frontend/               # Next.js
│   ├── .next/              # 빌드 결과물
│   ├── node_modules/       # 의존성
│   ├── package.json
│   └── ...
│
├── ai/                     # FastAPI
│   ├── venv/               # Python 가상환경
│   ├── main.py             # 엔트리포인트
│   ├── requirements.txt
│   └── ...
│
└── scripts/                # 유틸리티 스크립트
    └── setup-ssl.sh        # SSL 인증서 설정
```

### 로그 디렉토리

```
/var/log/billage/
├── backend/
│   ├── stdout.log          # Spring Boot 표준 출력
│   └── stderr.log          # Spring Boot 에러 로그
│
├── frontend/
│   └── (PM2가 ~/.pm2/logs에 저장)
│
├── ai/
│   ├── stdout.log          # FastAPI 표준 출력
│   └── stderr.log          # FastAPI 에러 로그
│
└── nginx/
    └── (기본: /var/log/nginx/)
```

### 권한

```bash
# 애플리케이션 디렉토리: ubuntu 사용자 소유
chown -R ubuntu:ubuntu /opt/billage
chown -R ubuntu:ubuntu /var/log/billage
```

---

## Nginx 설정

### HTTP 설정 (기본)

파일: `/etc/nginx/sites-available/billage`

```nginx
server {
    listen 80;
    server_name _;

    # Frontend (Next.js) - 기본 라우트
    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    # Backend API (Spring Boot)
    location /api/ {
        proxy_pass http://localhost:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # AI Service (FastAPI)
    location /ai/ {
        proxy_pass http://localhost:5000/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Health check 엔드포인트
    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
```

### 라우팅 규칙

| 경로 | 대상 서비스 | 포트 | 설명 |
|------|-------------|------|------|
| `/` | Next.js | 3000 | 프론트엔드 (기본) |
| `/api/*` | Spring Boot | 8080 | 백엔드 API |
| `/ai/*` | FastAPI | 5000 | AI 서비스 |
| `/health` | Nginx | - | 헬스체크 |

### 요청 흐름

```
Client Request
      │
      ▼
┌─────────────────┐
│  Nginx (:80)    │
└────────┬────────┘
         │
    ┌────┴────┬─────────────┐
    │         │             │
    ▼         ▼             ▼
 /api/*      /ai/*          /*
    │         │             │
    ▼         ▼             ▼
┌────────┐ ┌────────┐ ┌────────┐
│ Spring │ │FastAPI │ │Next.js │
│ :8080  │ │ :5000  │ │ :3000  │
└────────┘ └────────┘ └────────┘
```

---

## systemd 서비스

### Backend (Spring Boot)

파일: `/etc/systemd/system/billage-backend.service`

```ini
[Unit]
Description=Billage Backend (Spring Boot)
After=network.target mysql.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/billage/backend
ExecStart=/usr/bin/java -jar -Dspring.profiles.active=dev /opt/billage/backend/app.jar
Restart=always
RestartSec=10
StandardOutput=append:/var/log/billage/backend/stdout.log
StandardError=append:/var/log/billage/backend/stderr.log

[Install]
WantedBy=multi-user.target
```

**명령어:**
```bash
# 시작/중지/재시작
sudo systemctl start billage-backend
sudo systemctl stop billage-backend
sudo systemctl restart billage-backend

# 상태 확인
sudo systemctl status billage-backend

# 로그 확인
sudo journalctl -u billage-backend -f
tail -f /var/log/billage/backend/stdout.log
```

---

### Frontend (Next.js)

파일: `/etc/systemd/system/billage-frontend.service`

```ini
[Unit]
Description=Billage Frontend (Next.js)
After=network.target

[Service]
Type=forking
User=ubuntu
WorkingDirectory=/opt/billage/frontend
ExecStart=/usr/bin/pm2 start npm --name billage-frontend -- start
ExecReload=/usr/bin/pm2 reload billage-frontend
ExecStop=/usr/bin/pm2 stop billage-frontend
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**명령어:**
```bash
# systemctl 사용
sudo systemctl start billage-frontend
sudo systemctl restart billage-frontend

# PM2 직접 사용 (ubuntu 사용자로)
pm2 status
pm2 logs billage-frontend
pm2 restart billage-frontend
```

---

### AI Service (FastAPI)

파일: `/etc/systemd/system/billage-ai.service`

```ini
[Unit]
Description=Billage AI Service (FastAPI)
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/billage/ai
ExecStart=/opt/billage/ai/venv/bin/uvicorn main:app --host 0.0.0.0 --port 5000
Restart=always
RestartSec=10
StandardOutput=append:/var/log/billage/ai/stdout.log
StandardError=append:/var/log/billage/ai/stderr.log

[Install]
WantedBy=multi-user.target
```

**명령어:**
```bash
sudo systemctl start billage-ai
sudo systemctl restart billage-ai
tail -f /var/log/billage/ai/stdout.log
```

---

## SSL 설정 (setup-ssl.sh)

### 개요

Let's Encrypt + Certbot을 사용한 무료 SSL 인증서 설정 스크립트입니다.

파일 위치: `/opt/billage/scripts/setup-ssl.sh`

### 실행 방법

```bash
# 기본 (dev.billages.com)
sudo /opt/billage/scripts/setup-ssl.sh

# 도메인 지정
sudo /opt/billage/scripts/setup-ssl.sh dev.billages.com admin@billages.com
```

### 사전 조건

1. **DNS 레코드 설정 완료**
   - `dev.billages.com` A 레코드 → EC2 Elastic IP
   - Terraform이 자동으로 생성 (Route 53)

2. **포트 80 접근 가능**
   - Certbot이 HTTP-01 챌린지 사용
   - Security Group에서 80 포트 오픈 필요 (기본 설정됨)

### 스크립트 동작

```
setup-ssl.sh 실행
       │
       ├── Certbot 설치
       │
       ├── SSL 인증서 발급 (Let's Encrypt)
       │     certbot --nginx -d dev.billages.com
       │
       ├── Nginx 설정 업데이트
       │     - HTTP → HTTPS 리다이렉트
       │     - SSL 인증서 적용
       │     - 보안 헤더 추가
       │
       └── 자동 갱신 설정
             certbot.timer 활성화
```

### SSL 적용 후 Nginx 설정

```nginx
# HTTP → HTTPS 리다이렉트
server {
    listen 80;
    server_name dev.billages.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name dev.billages.com;

    # SSL 인증서
    ssl_certificate /etc/letsencrypt/live/dev.billages.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dev.billages.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # 보안 헤더
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # ... 기존 라우팅 설정 ...
}
```

### 인증서 갱신

Let's Encrypt 인증서는 90일 유효합니다. Certbot timer가 자동으로 갱신합니다.

```bash
# 자동 갱신 상태 확인
sudo systemctl status certbot.timer

# 수동 갱신 테스트
sudo certbot renew --dry-run

# 수동 갱신
sudo certbot renew
```

---

## 트러블슈팅

### 1. 스크립트 실행 확인

```bash
# 로그 확인
cat /var/log/billage-setup.log

# cloud-init 로그 (user_data 실행 로그)
cat /var/log/cloud-init-output.log
```

### 2. 서비스 상태 확인

```bash
# 모든 서비스 상태
sudo systemctl status billage-backend billage-frontend billage-ai nginx mysql

# 포트 확인
sudo ss -tlnp | grep -E '(3000|5000|8080|3306|80|443)'
```

### 3. Java 버전 문제

```bash
# 설치된 Java 확인
java -version

# Java 21로 fallback된 경우 정상 동작
# Spring Boot 3.x는 Java 17+ 지원
```

### 4. Nginx 설정 오류

```bash
# 설정 테스트
sudo nginx -t

# 설정 리로드
sudo systemctl reload nginx

# 에러 로그
tail -f /var/log/nginx/error.log
```

### 5. MySQL 접속 문제

```bash
# MySQL 상태
sudo systemctl status mysql

# 로컬 접속 테스트
sudo mysql -u root -p

# 소켓 파일 확인
ls -la /var/run/mysqld/mysqld.sock
```

### 6. PM2 문제 (Next.js)

```bash
# PM2 상태 (ubuntu 사용자로)
pm2 status
pm2 logs

# PM2 재설정
pm2 delete all
pm2 start npm --name billage-frontend -- start
pm2 save
```

---

## CI/CD 연동 가이드

### Backend 배포 (Spring Boot)

```bash
# 1. JAR 파일 업로드
scp -i key.pem target/app.jar ubuntu@<IP>:/opt/billage/backend/

# 2. 서비스 재시작
ssh -i key.pem ubuntu@<IP> "sudo systemctl restart billage-backend"
```

### Frontend 배포 (Next.js)

```bash
# 1. 빌드 파일 업로드
rsync -avz -e "ssh -i key.pem" .next/ ubuntu@<IP>:/opt/billage/frontend/.next/

# 2. 서비스 재시작
ssh -i key.pem ubuntu@<IP> "sudo systemctl restart billage-frontend"
```

### AI 배포 (FastAPI)

```bash
# 1. 소스 업로드
rsync -avz -e "ssh -i key.pem" ./ ubuntu@<IP>:/opt/billage/ai/

# 2. 의존성 설치 + 재시작
ssh -i key.pem ubuntu@<IP> << 'EOF'
cd /opt/billage/ai
source venv/bin/activate
pip install -r requirements.txt
sudo systemctl restart billage-ai
EOF
```

---

## 요약

| 단계 | 자동/수동 | 설명 |
|------|-----------|------|
| EC2 생성 | 자동 | `terraform apply` |
| 소프트웨어 설치 | 자동 | user_data (setup.sh) |
| DNS 레코드 | 자동 | Route 53 A 레코드 |
| MySQL 초기 설정 | **수동** | `mysql_secure_installation` |
| SSL 인증서 | **수동** | `setup-ssl.sh` 실행 |
| 애플리케이션 배포 | **수동** | 각 레포지토리 CI/CD |