#!/bin/bash
# Billage Dev Server Setup Script
# Ubuntu 24.04 LTS ARM64용

set -e

LOG_FILE="/var/log/billage-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Billage Dev Server Setup - $(date)"
echo "=========================================="

# 기본 패키지 업데이트
echo "[1/8] Updating system packages..."
apt-get update && apt-get upgrade -y

# 필수 유틸리티 설치
echo "[2/8] Installing essential utilities..."
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    unzip \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

# Java 25 (Eclipse Temurin) 설치
echo "[3/8] Installing Java 25 (Eclipse Temurin)..."
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor | tee /usr/share/keyrings/adoptium.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/adoptium.list
apt-get update
apt-get install -y temurin-25-jdk || {
    echo "Java 25 not available, installing Java 21 as fallback..."
    apt-get install -y temurin-21-jdk
}
java -version

# Node.js 20 LTS 설치
echo "[4/8] Installing Node.js 20 LTS..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g pm2
node -v && npm -v

# Python 3 + pip 설치 (Ubuntu 24.04 기본: Python 3.12)
echo "[5/8] Installing Python 3..."
apt-get install -y python3 python3-venv python3-pip python3-full
python3 --version

# MySQL 8.0 설치
echo "[6/8] Installing MySQL 8.0..."
apt-get install -y mysql-server
systemctl enable mysql
systemctl start mysql

# Nginx 설치
echo "[7/8] Installing Nginx..."
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx

# 디렉토리 구조 생성
echo "[8/8] Creating directory structure..."
mkdir -p /opt/billage/{backend,frontend,ai,scripts}
mkdir -p /opt/billage/backend/config
mkdir -p /var/log/billage/{backend,frontend,ai,nginx}

# 권한 설정 (ubuntu 사용자)
chown -R ubuntu:ubuntu /opt/billage
chown -R ubuntu:ubuntu /var/log/billage

# Nginx 기본 설정 (SSL은 별도 스크립트)
cat > /etc/nginx/sites-available/billage << 'NGINX_CONF'
server {
    listen 80;
    server_name _;

    # Frontend (Next.js)
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

    # Health check
    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/billage /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# systemd 서비스 파일 생성
# Backend (Spring Boot)
cat > /etc/systemd/system/billage-backend.service << 'SERVICE'
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
SERVICE

# Frontend (Next.js with PM2)
cat > /etc/systemd/system/billage-frontend.service << 'SERVICE'
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
SERVICE

# AI Service (FastAPI with uvicorn)
cat > /etc/systemd/system/billage-ai.service << 'SERVICE'
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
SERVICE

systemctl daemon-reload

# SSL 설정 스크립트 생성
cat > /opt/billage/scripts/setup-ssl.sh << 'SSL_SCRIPT'
#!/bin/bash
# Billage SSL Setup Script
set -e

DOMAIN="${1:-dev.billages.com}"
EMAIL="${2:-admin@billages.com}"

echo "Setting up SSL for $DOMAIN..."

apt-get update
apt-get install -y certbot python3-certbot-nginx

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --redirect

# Nginx 설정 업데이트
cat > /etc/nginx/sites-available/billage << NGINX_CONF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    location /api/ {
        proxy_pass http://localhost:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location /ai/ {
        proxy_pass http://localhost:5000/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 120s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }

    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINX_CONF

nginx -t && systemctl reload nginx
systemctl enable certbot.timer
systemctl start certbot.timer

echo "SSL setup completed! https://$DOMAIN"
SSL_SCRIPT

chmod +x /opt/billage/scripts/setup-ssl.sh

# MySQL 설정 스크립트 생성
cat > /opt/billage/scripts/setup-mysql.sh << 'MYSQL_SCRIPT'
#!/bin/bash
# Billage MySQL Setup Script
set -e

echo "=========================================="
echo "Billage MySQL Setup"
echo "=========================================="
echo ""

read -p "DB 사용자명 (기본: billage): " DB_USER
DB_USER=${DB_USER:-billage}

read -p "DB 이름 (기본: billage): " DB_NAME
DB_NAME=${DB_NAME:-billage}

read -sp "DB 비밀번호: " DB_PASSWORD
echo ""

if [ -z "$DB_PASSWORD" ]; then
    echo "Error: 비밀번호를 입력해주세요."
    exit 1
fi

read -sp "DB 비밀번호 확인: " DB_PASSWORD_CONFIRM
echo ""

if [ "$DB_PASSWORD" != "$DB_PASSWORD_CONFIRM" ]; then
    echo "Error: 비밀번호가 일치하지 않습니다."
    exit 1
fi

echo ""
echo "설정: DB=$DB_NAME, User=$DB_USER, 외부접속=허용"
read -p "진행하시겠습니까? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "취소되었습니다."
    exit 0
fi

echo ""
echo "[1/4] MySQL 접속 확인..."
if sudo mysql -e "SELECT 1" 2>/dev/null; then
    MYSQL_CMD="sudo mysql"
else
    read -sp "MySQL root 비밀번호: " MYSQL_ROOT_PASSWORD
    echo ""
    MYSQL_CMD="mysql -u root -p$MYSQL_ROOT_PASSWORD"
fi

echo "[2/4] 데이터베이스 생성..."
$MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

echo "[3/4] 사용자 생성 및 권한 부여..."
$MYSQL_CMD -e "DROP USER IF EXISTS '$DB_USER'@'%';"
$MYSQL_CMD -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
$MYSQL_CMD -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';"
$MYSQL_CMD -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';"
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
$MYSQL_CMD -e "FLUSH PRIVILEGES;"

echo "[4/4] 외부 접속 허용..."
MYSQL_CONF="/etc/mysql/mysql.conf.d/mysqld.cnf"
if grep -q "^bind-address" $MYSQL_CONF; then
    sudo sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' $MYSQL_CONF
else
    echo "bind-address = 0.0.0.0" | sudo tee -a $MYSQL_CONF > /dev/null
fi
sudo systemctl restart mysql

echo ""
echo "=========================================="
echo "MySQL 설정 완료!"
echo "=========================================="
echo ""
echo "접속 정보:"
echo "  Host: $(curl -s ifconfig.me 2>/dev/null || echo '<서버IP>')"
echo "  Port: 3306"
echo "  Database: $DB_NAME"
echo "  Username: $DB_USER"
echo ""
echo "JDBC URL 예시:"
echo "  jdbc:mysql://<IP>:3306/$DB_NAME?useSSL=false&serverTimezone=Asia/Seoul"
MYSQL_SCRIPT

chmod +x /opt/billage/scripts/setup-mysql.sh

# 완료 메시지
echo "=========================================="
echo "Setup completed successfully!"
echo "=========================================="
echo ""
echo "Installed versions:"
echo "  - Java: $(java -version 2>&1 | head -1)"
echo "  - Node.js: $(node -v)"
echo "  - npm: $(npm -v)"
echo "  - Python: $(python3 --version)"
echo "  - MySQL: $(mysql --version)"
echo "  - Nginx: $(nginx -v 2>&1)"
echo ""
echo "Directory structure:"
echo "  /opt/billage/backend  - Spring Boot JAR"
echo "  /opt/billage/frontend - Next.js build"
echo "  /opt/billage/ai       - FastAPI + venv"
echo ""
echo "Next steps:"
echo "  1. Setup MySQL (외부 접속): sudo /opt/billage/scripts/setup-mysql.sh"
echo "  2. Setup SSL: sudo /opt/billage/scripts/setup-ssl.sh dev.billages.com"
echo ""
echo "Log file: $LOG_FILE"