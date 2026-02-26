#!/bin/bash
set -e

# Terraform 변수
LOKI_HOST="${loki_host}"

#==============================================================================
# 1. 패키지 설치 및 초기 설정
#==============================================================================
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y debconf-utils curl jq wireguard iptables-persistent docker.io docker-compose
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
systemctl enable docker && systemctl start docker

# 커널 파라미터 (IP Forwarding & RP Filter)
cat <<EOF > /etc/sysctl.d/99-vpn-server.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.ens5.rp_filter=0
EOF
sysctl --system

#==============================================================================
# 2. iptables 설정 (보안 Whitelist + NAT + 로깅)
#==============================================================================
PUB_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

# 초기화
iptables -F && iptables -t nat -F && iptables -X

# 기본 정책: FORWARD DROP (허용된 것만 통과)
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# [INPUT] 기본 허용
iptables -A INPUT -p udp --dport 51820 -j ACCEPT
# SSH는 모든 곳에서 허용 (관리 편의성)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# [FORWARD] 응답 패킷 허용 (최우선 - 트러블슈팅 1 핵심!)
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# [FORWARD] VPC 내부 -> 인터넷 (NAT Instance 역할 - 트러블슈팅 1 핵심!)
iptables -A FORWARD -i $PUB_IF -s 10.2.0.0/16 -o $PUB_IF -j ACCEPT

# [FORWARD] Dev VPC -> 인터넷 (VPC Peering 경유 NAT - v2 Private Subnet용)
iptables -A FORWARD -s 10.0.0.0/16 -o $PUB_IF -j ACCEPT

# [FORWARD] 역할별 접근 제어 + 로깅 (Whitelist - 트러블슈팅 2 해결책)
# DEVOPS: Full Access
iptables -A FORWARD -s 10.100.0.16/28 -j LOG --log-prefix "[VPN-DEVOPS] " --log-level 4
iptables -A FORWARD -s 10.100.0.16/28 -j ACCEPT

# BACKEND: SSH, DB, Spring
iptables -A FORWARD -s 10.100.0.32/28 -p tcp -m multiport --dports 22,3306,8080 -j LOG --log-prefix "[VPN-BACKEND] " --log-level 4
iptables -A FORWARD -s 10.100.0.32/28 -p tcp -m multiport --dports 22,3306,8080 -j ACCEPT

# FRONTEND: Web Ports
iptables -A FORWARD -s 10.100.0.48/28 -p tcp -m multiport --dports 80,443,3000 -j LOG --log-prefix "[VPN-FRONTEND] " --log-level 4
iptables -A FORWARD -s 10.100.0.48/28 -p tcp -m multiport --dports 80,443,3000 -j ACCEPT

# AIML: GPU, API
iptables -A FORWARD -s 10.100.0.64/28 -p tcp -m multiport --dports 22,8000,8888 -j LOG --log-prefix "[VPN-AIML] " --log-level 4
iptables -A FORWARD -s 10.100.0.64/28 -p tcp -m multiport --dports 22,8000,8888 -j ACCEPT

# [LOGGING] 차단된 패킷 기록 (Promtail 수집용)
iptables -A FORWARD -s 10.100.0.0/24 -j LOG --log-prefix "[VPN-DROP] " --log-level 4

# [NAT] Masquerade (VPC Peering 통신 해결 - 트러블슈팅 1, 2 핵심!)
iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o $PUB_IF -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.2.0.0/16 -o $PUB_IF -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o $PUB_IF -j MASQUERADE

netfilter-persistent save

#==============================================================================
# 3. WireGuard 및 관리 스크립트 설정
#==============================================================================
mkdir -p /etc/wireguard/clients /var/log/wireguard

# 역할 정의
cat <<'EOF' > /etc/wireguard/roles.conf
SYSTEM|10.100.0.0/28|1|1|VPN Server
DEVOPS|10.100.0.16/28|17|30|DevOps Team
BACKEND|10.100.0.32/28|33|46|Backend Team
FRONTEND|10.100.0.48/28|49|62|Frontend Team
AIML|10.100.0.64/28|65|78|AI/ML Team
EOF

# 키 생성 및 설정
cd /etc/wireguard && umask 077
[ ! -f server_private.key ] && wg genkey | tee server_private.key | wg pubkey > server_public.key
SERVER_PRIV=$(cat server_private.key)

cat > /etc/wireguard/wg0.conf <<WGCONF
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV
PostUp = sysctl -w net.ipv4.conf.wg0.rp_filter=0
WGCONF

# 관리 스크립트 생성
cat > /usr/local/bin/create-vpn-user.sh <<'SCRIPT'
#!/bin/bash
set -e
VPN_DIR="/etc/wireguard"
[ $# -ne 2 ] && echo "Usage: $0 <username> <role>" && exit 1
USERNAME="$1"; ROLE=$(echo "$2" | tr '[:lower:]' '[:upper:]')
ROLE_INFO=$(grep "^$ROLE|" "$VPN_DIR/roles.conf") || { echo "Invalid role"; exit 1; }
START_IP=$(echo "$ROLE_INFO" | cut -d'|' -f3); END_IP=$(echo "$ROLE_INFO" | cut -d'|' -f4)
USER_DIR="$VPN_DIR/clients/$ROLE/$USERNAME"; mkdir -p "$USER_DIR"
[ -f "$USER_DIR/private.key" ] && echo "User exists" && exit 0
USED_IPS=$(grep -oE '10\.100\.0\.[0-9]+' "$VPN_DIR/wg0.conf" 2>/dev/null | cut -d'.' -f4 | sort -n || echo "")
for i in $(seq $START_IP $END_IP); do echo "$USED_IPS" | grep -q "^$i$" || { ASSIGNED_IP="10.100.0.$i"; break; }; done
[ -z "$ASSIGNED_IP" ] && echo "No available IP" && exit 1
cd "$USER_DIR" && umask 077 && wg genkey | tee private.key | wg pubkey > public.key
CLIENT_PUB=$(cat public.key); SERVER_PUB=$(cat "$VPN_DIR/server_public.key"); SERVER_IP=$(curl -s http://checkip.amazonaws.com)
cat >> "$VPN_DIR/wg0.conf" <<PEER

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $ASSIGNED_IP/32
PEER
cat > "$USER_DIR/$USERNAME.conf" <<CLIENT
[Interface]
PrivateKey = $(cat private.key)
Address = $ASSIGNED_IP/24
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:51820
AllowedIPs = 10.0.0.0/8, 10.100.0.0/24
PersistentKeepalive = 25
CLIENT
systemctl restart wg-quick@wg0
echo "Created: $USERNAME ($ROLE) - $ASSIGNED_IP"
cat "$USER_DIR/$USERNAME.conf"
SCRIPT

cat > /usr/local/bin/list-vpn-users.sh <<'SCRIPT'
#!/bin/bash
for d in /etc/wireguard/clients/*/*; do [ -d "$d" ] && echo "$(basename $(dirname $d))/$(basename $d)"; done
wg show wg0 2>/dev/null || echo "WireGuard not running"
SCRIPT

cat > /usr/local/bin/revoke-vpn-user.sh <<'SCRIPT'
#!/bin/bash
set -e
[ $# -ne 2 ] && echo "Usage: $0 <username> <role>" && exit 1
USER_DIR="/etc/wireguard/clients/$(echo $2 | tr '[:lower:]' '[:upper:]')/$1"
[ ! -d "$USER_DIR" ] && echo "User not found" && exit 1
PUB_KEY=$(cat "$USER_DIR/public.key")
wg set wg0 peer "$PUB_KEY" remove
sed -i "/PublicKey = $PUB_KEY/,/AllowedIPs/d" /etc/wireguard/wg0.conf
rm -rf "$USER_DIR"
echo "Revoked: $1"
SCRIPT

chmod +x /usr/local/bin/*.sh

#==============================================================================
# 4. 로깅 (Rsyslog + Promtail) - Role Labeling 적용
#==============================================================================
cat <<'EOF' > /etc/rsyslog.d/50-wireguard.conf
:msg, contains, "wireguard" /var/log/wireguard/wg.log
:msg, contains, "[VPN-" /var/log/wireguard/vpn-forward.log
& stop
EOF
touch /var/log/wireguard/{wg.log,vpn-forward.log}
chown syslog:adm /var/log/wireguard/*.log
systemctl restart rsyslog

mkdir -p /opt/promtail/positions
cat > /opt/promtail/promtail-config.yml <<'PROMTAIL'
server:
  http_listen_port: 9080
positions:
  filename: /var/lib/promtail/positions.yaml
clients:
  - url: http://LOKI_HOST_PLACEHOLDER:3100/loki/api/v1/push
scrape_configs:
  - job_name: wireguard
    static_configs:
      - targets: [localhost]
        labels:
          job: wireguard
          env: management
          host: vpn-server
          __path__: /var/log/wireguard/wg.log
  - job_name: vpn-traffic
    static_configs:
      - targets: [localhost]
        labels:
          job: vpn-traffic
          env: management
          host: vpn-server
          __path__: /var/log/wireguard/vpn-forward.log
    pipeline_stages:
      - regex:
          expression: '.*\[(?P<action>VPN-(DEVOPS|BACKEND|FRONTEND|AIML|DROP|FWD))\].*SRC=(?P<src_ip>[\d\.]+).*DST=(?P<dst_ip>[\d\.]+).*PROTO=(?P<protocol>\w+).*DPT=(?P<dst_port>\d+)'
      - labels:
          action:
          src_ip:
          dst_ip:
          protocol:
          dst_port:
      - match:
          selector: '{action=~"VPN-DEVOPS"}'
          stages:
            - static_labels:
                role: devops
      - match:
          selector: '{action=~"VPN-BACKEND"}'
          stages:
            - static_labels:
                role: backend
      - match:
          selector: '{action=~"VPN-FRONTEND"}'
          stages:
            - static_labels:
                role: frontend
      - match:
          selector: '{action=~"VPN-AIML"}'
          stages:
            - static_labels:
                role: aiml
      - match:
          selector: '{role=""}'
          stages:
            - static_labels:
                role: unknown
PROMTAIL

# LOKI_HOST 변수 치환
sed -i "s|LOKI_HOST_PLACEHOLDER|$LOKI_HOST|g" /opt/promtail/promtail-config.yml

cat > /opt/promtail/docker-compose.yml <<'COMPOSE'
version: '3.8'
services:
  promtail:
    image: grafana/promtail:2.9.3
    container_name: promtail-vpn
    restart: unless-stopped
    volumes:
      - /var/log/wireguard:/var/log/wireguard:ro
      - ./promtail-config.yml:/etc/promtail/config.yml:ro
      - ./positions:/var/lib/promtail
    command: -config.file=/etc/promtail/config.yml
    network_mode: host
COMPOSE

cd /opt/promtail && docker-compose up -d

#==============================================================================
# 5. 서비스 시작
#==============================================================================
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "VPN Server Setup Complete (NAT + Role-based Security + Logging)"