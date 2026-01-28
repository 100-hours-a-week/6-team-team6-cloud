#!/bin/bash
# Billage SSL Setup Script
# Let's Encrypt + Certbot

set -e

DOMAIN="${1:-dev.billages.com}"
EMAIL="${2:-admin@billages.com}"

echo "=========================================="
echo "Billage SSL Setup - $(date)"
echo "Domain: $DOMAIN"
echo "=========================================="

# Certbot 설치
echo "[1/3] Installing Certbot..."
apt-get update
apt-get install -y certbot python3-certbot-nginx

# SSL 인증서 발급
echo "[2/3] Obtaining SSL certificate..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --redirect

# Nginx 설정 업데이트 (HTTPS 최적화)
echo "[3/3] Optimizing Nginx SSL configuration..."
cat > /etc/nginx/sites-available/billage << NGINX_CONF
# HTTP -> HTTPS 리다이렉트 (Certbot이 자동 생성하지만 명시적으로)
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    # SSL 인증서 (Certbot이 생성)
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Frontend (Next.js)
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

    # Backend API (Spring Boot)
    location /api/ {
        proxy_pass http://localhost:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Timeout 설정 (API 요청용)
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # AI Service (FastAPI)
    location /ai/ {
        proxy_pass http://localhost:5000/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # AI 요청은 시간이 오래 걸릴 수 있음
        proxy_connect_timeout 120s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }

    # Health check
    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINX_CONF

nginx -t && systemctl reload nginx

# 자동 갱신 설정 확인
echo "Setting up auto-renewal..."
systemctl enable certbot.timer
systemctl start certbot.timer

echo "=========================================="
echo "SSL Setup completed!"
echo "=========================================="
echo ""
echo "Your site is now available at:"
echo "  https://$DOMAIN"
echo ""
echo "Certificate auto-renewal is enabled."
echo "Test renewal with: sudo certbot renew --dry-run"