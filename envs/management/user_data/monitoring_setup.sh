#!/bin/bash
set -e

#==============================================================================
# 0. Wait for Internet (NAT/VPN Readiness Check)
# VPN 서버의 NAT 설정이 완료될 때까지 대기 (Race Condition 방지)
#==============================================================================
echo ">> Waiting for internet connectivity..."
timeout=300 # 5분 타임아웃
elapsed=0

# 구글 접속 테스트로 인터넷 연결 확인
until curl -I https://www.google.com --max-time 5 >/dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
        echo "Error: Timeout waiting for internet. Check VPN/NAT server status."
        exit 1
    fi
    echo "Internet not reachable yet. Waiting for NAT setup... ($elapsed/$timeout sec)"
    sleep 5
    elapsed=$((elapsed+5))
done
echo ">> Internet connection established."

#==============================================================================
# 1. Swap Memory Setup (4GB)
# t4g.small (2GB RAM) 보완을 위해 4GB 스왑 설정
#==============================================================================
echo ">> Setting up Swap Memory..."
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    echo "Swap created successfully."
else
    echo "Swapfile already exists."
fi

# 메모리/스왑 상태 확인
free -h

#==============================================================================
# 2. Docker Setup
# Ubuntu 공식 Docker 설치 가이드 준수
#==============================================================================
echo ">> Installing Docker..."

# 필수 패키지 설치
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

# Docker 공식 GPG 키 추가
mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi

# Docker 레포지토리 설정
echo \
  "deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker Engine 설치
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ubuntu 유저에게 Docker 권한 부여
usermod -aG docker ubuntu

# Docker 서비스 시작 및 부팅 시 자동 실행 설정
systemctl enable docker
systemctl start docker

echo ">> Docker installation completed."
docker --version
docker compose version
