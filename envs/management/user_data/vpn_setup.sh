#!/bin/bash
set -e

#==============================================================================
# 1. WireGuard & Tools Install
#==============================================================================
echo ">> Installing WireGuard..."
apt-get update
apt-get install -y wireguard iptables-persistent

#==============================================================================
# 2. IP Forwarding Enable
# VPN 서버가 트래픽을 라우팅할 수 있도록 설정
#==============================================================================
echo ">> Enabling IP Forwarding..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p
echo "IP Forwarding enabled: $(sysctl net.ipv4.ip_forward)"

#==============================================================================
# 3. NAT (Masquerade) Setup
# Private Subnet -> VPN Server -> Internet 통신을 위한 NAT 설정
#==============================================================================
echo ">> Setting up NAT (Masquerade)..."

# 기본 네트워크 인터페이스 감지 (예: ens5)
PUB_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "Detected public interface: $PUB_IF"

# iptables NAT 규칙 추가
# 이미 규칙이 있는지 확인 후 없으면 추가
if ! iptables -t nat -C POSTROUTING -o $PUB_IF -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o $PUB_IF -j MASQUERADE
    echo "NAT rule added."
else
    echo "NAT rule already exists."
fi

# WireGuard 포트 허용 (UDP 51820)
if ! iptables -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -p udp --dport 51820 -j ACCEPT
    echo "WireGuard port accepted."
fi

# iptables 규칙 영구 저장
netfilter-persistent save

echo ">> VPN Server network setup completed."
