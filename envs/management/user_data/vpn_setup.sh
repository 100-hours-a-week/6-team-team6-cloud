#!/bin/bash
set -e

#==============================================================================
# 1. WireGuard & Tools Install
#==============================================================================
echo ">> Installing WireGuard..."
apt-get update

# debconf-utils 설치 (debconf-set-selections 명령어를 위해 필요)
DEBIAN_FRONTEND=noninteractive apt-get install -y debconf-utils curl

# iptables-persistent 대화형 질문 차단
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables-persistent

#==============================================================================
# 2. IP Forwarding Enable
#==============================================================================
echo ">> Enabling IP Forwarding..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p
echo "IP Forwarding enabled: $(sysctl net.ipv4.ip_forward)"

#==============================================================================
# 3. NAT (Masquerade) Setup
#==============================================================================
echo ">> Setting up NAT (Masquerade)..."
PUB_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

# NAT 규칙
if ! iptables -t nat -C POSTROUTING -o $PUB_IF -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o $PUB_IF -j MASQUERADE
fi

# WireGuard 포트 허용
if ! iptables -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -p udp --dport 51820 -j ACCEPT
fi

netfilter-persistent save

#==============================================================================
# 4. WireGuard Key Generation & Configuration (★ 여기가 추가된 부분 ★)
#==============================================================================
echo ">> Configuring WireGuard..."

# 키 생성 (이미 있으면 생성 안 함 - 재부팅 대비)
if [ ! -f /etc/wireguard/server_private.key ]; then
    umask 077
    wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
    wg genkey | tee /etc/wireguard/client_private.key | wg pubkey > /etc/wireguard/client_public.key
fi

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)
SERVER_PUB=$(cat /etc/wireguard/server_public.key)
CLIENT_PRIV=$(cat /etc/wireguard/client_private.key)
CLIENT_PUB=$(cat /etc/wireguard/client_public.key)
SERVER_IP=$(curl -s http://checkip.amazonaws.com)

# wg0.conf 생성
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV
# VPN 통과 시 NAT 적용 (확실하게 하기 위해 중복 적용)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $PUB_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $PUB_IF -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.100.0.2/32
EOF

# 서비스 시작
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

#==============================================================================
# 5. Print Client Config to Log (★ 중요: 로그 보고 복사하려고 ★)
#==============================================================================
echo ""
echo "========================================================"
echo "   WireGuard Client Configuration (Copy this!)"
echo "========================================================"
echo "[Interface]"
echo "PrivateKey = $CLIENT_PRIV"
echo "Address = 10.100.0.2/24"
echo "DNS = 8.8.8.8"
echo ""
echo "[Peer]"
echo "PublicKey = $SERVER_PUB"
echo "Endpoint = $SERVER_IP:51820"
echo "AllowedIPs = 10.0.0.0/8, 10.100.0.0/24"
echo "PersistentKeepalive = 25"
echo "========================================================"
echo ">> VPN Server setup completed successfully."