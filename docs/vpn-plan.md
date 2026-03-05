# VPN 아키텍처 개선 계획서

## 근본 목적

- 팀원별 VPN 접근 권한을 역할 단위로 분리해 최소 권한 원칙을 강제한다.
- VPN 경유 트래픽을 식별 가능한 로그로 남겨 장애/보안 이슈 대응 속도를 높인다.
- 운영 복잡도를 감당 가능한 수준으로 유지하면서 Dev/Prod 접근 통제를 표준화한다.

## 비목적

- VPC Peering 자체를 Transit Gateway/VPN Gateway 구조로 재설계하지 않는다.
- 애플리케이션 서비스 포트 구조를 전면 변경하지 않는다.
- 문서 범위를 넘어 즉시 전체 인프라 자동화를 완료하는 것을 목표로 하지 않는다.

## 1. 개요

### 1.1 현재 상황

- Management VPC에 WireGuard VPN 서버 운영 중
- Masquerade(SNAT) 방식으로 모든 VPN 트래픽이 VPN 서버 IP로 변환되어 전달
- VPC Peering 구성:
    - Management VPC <-> Dev VPC (양방향 peering)
    - Management VPC <-> Prod VPC (양방향 peering)
- 단일 클라이언트 키로 모든 사용자가 접속
- 로그 추적 불가능 (모든 트래픽이 VPN 서버 IP로 기록됨)

### 1.2 개선 목표

- VPN 클라이언트별 IP 할당으로 역할 구분
- 역할별 키 발급으로 보안 사고 시 개별 대응 가능
- **VPN 서버 레벨에서 역할별 접근 제어 및 로깅**
- Grafana 기반 실시간 모니터링 및 Discord 알람 체계 구축

### 1.3 팀 구성 및 역할

- Backend & DBA: 1-2명
- Frontend: 1명
- DevOps: 1명
- AI/ML: 1명
- 총 4-5명 규모

## 2. 아키텍처 변경 계획

### 2.1 초기 계획: Pure Routing 방식

처음에는 Masquerade를 제거하고 Pure Routing 방식으로 전환하여 VPN 클라이언트의 원본 IP(10.100.0.x)를 Dev/Prod 서버까지 전달하려 했다.

```
의도한 패킷 흐름:
VPN Client (10.100.0.17)
  → VPN Server (라우팅만 수행, IP 변환 없음)
  → VPC Peering
  → Dev/Prod Server (소스 IP: 10.100.0.17 유지)
  → Security Group에서 역할별 필터링
```

### 2.2 Pure Routing 실패 원인

VPC Peering 환경에서 Pure Routing이 불가능한 것으로 확인되었다.

**근본 원인: VPC Peering의 제약**

1. **VPC Peering은 Peer VPC CIDR 범위 내 트래픽만 전달**
   - Dev VPC → Management VPC로 응답을 보낼 때
   - 목적지 10.100.0.17은 Management VPC CIDR(10.2.0.0/16)에 포함되지 않음
   - VPC Peering이 해당 트래픽을 전달하지 않음 → 패킷 드롭

2. **Secondary CIDR 추가 시도도 실패**
   - Management VPC에 10.100.0.0/24를 Secondary CIDR로 추가하면
   - AWS가 자동으로 `local` 라우트를 생성
   - VPN 서버 ENI로 라우팅할 수 없게 됨

```
Pure Routing이 가능하려면:
- VPN 클라이언트 대역이 VPC CIDR에 포함되어야 함
- 하지만 포함시키면 local 라우트가 생겨서 VPN 서버로 라우팅 불가
→ 딜레마
```

### 2.3 최종 결정: Masquerade + VPN 서버 레벨 필터링

Pure Routing을 포기하고 **Masquerade를 유지**하되, **VPN 서버의 iptables에서 역할별 필터링**을 수행하기로 결정했다.

```
최종 패킷 흐름:
VPN Client (BACKEND: 10.100.0.33)
        │
        │ SSH 요청 (dst port 22)
        ▼
VPN Server FORWARD Chain
        │
        │ 규칙: -s 10.100.0.32/28 -p tcp --dport 22 -j ACCEPT ✓
        │ 로깅: [VPN-BACKEND] 로그 기록
        ▼
MASQUERADE (src: 10.100.0.33 → 10.2.1.65)
        │
        ▼
VPC Peering
        │
        ▼
Dev Server (10.0.1.157)
        │
        │ Security Group: 10.2.0.0/16 허용 ✓
        ▼
SSH 연결 성공!
```

**이 방식의 장점:**

1. VPC Peering 라우팅 문제 해결 (Masquerade로 VPN 서버 IP 사용)
2. VPN 서버에서 역할별 접근 권한 제어 가능
3. VPN 서버에서 모든 트래픽 로깅 가능 → Loki로 수집

**단점:**

1. Dev/Prod 서버 입장에서는 모든 VPN 트래픽이 VPN 서버 IP로 보임
2. Security Group으로 역할별 필터링 불가 (VPN 서버에서 처리)

## 3. VPN 클라이언트 권한 관리

### 3.1 역할별 IP 할당 체계

```
VPN Server:     10.100.0.1
DEVOPS:         10.100.0.16/28  (10.100.0.17-30)  - Full Access
BACKEND:        10.100.0.32/28  (10.100.0.33-46)  - SSH, MySQL, Spring Boot
FRONTEND:       10.100.0.48/28  (10.100.0.49-62)  - Web Ports (80, 443, 3000)
AI/ML:          10.100.0.64/28  (10.100.0.65-78)  - FastAPI, Jupyter (8000, 8888)
```

역할당 /28 서브넷(14개 IP)을 할당하여 향후 팀 확장에 대비한다.

### 3.2 역할별 접근 권한

| 역할 | SSH(22) | MySQL(3306) | Spring(8080) | Web(80,443,3000) | FastAPI(8000) |
|------|---------|-------------|--------------|------------------|---------------|
| DEVOPS | ✓ | ✓ | ✓ | ✓ | ✓ |
| BACKEND | ✓ | ✓ | ✓ | - | - |
| FRONTEND | - | - | - | ✓ | - |
| AI/ML | ✓ | - | - | - | ✓ |

### 3.3 클라이언트 설정 파일 구조

```
/etc/wireguard/
├── wg0.conf                 # WireGuard 설정
└── clients/
    ├── mapping.yml          # 역할-IP 매핑 정보
    ├── devops/
    │   ├── patrick.conf     # 개인별 설정 파일
    │   └── logan.conf
    ├── backend/
    │   └── hooni.conf
    ├── frontend/
    │   └── bluer.conf
    └── aiml/
        └── bina.conf
```

### 3.4 키 발급 및 회수 프로세스

**신규 발급:**

1. 관리자가 서버에 접속하여 새 키 생성
2. `/etc/wireguard/wg0.conf`에 Peer 섹션 추가
3. `mapping.yml`에 역할 정보 기록
4. WireGuard 재시작: `systemctl restart wg-quick@wg0`
5. 클라이언트 설정 파일을 암호화하여 담당자에게 전달

**회수 (퇴사, 키 탈취 의심):**

1. 해당 역할의 Public Key 확인
2. WireGuard에서 Peer 제거: `wg set wg0 peer <PUBLIC_KEY> remove`
3. `/etc/wireguard/wg0.conf`에서 해당 섹션 삭제
4. `mapping.yml`에서 status를 "revoked"로 변경
5. Grafana 대시보드에서 접속 중단 확인
6. 새 키 재발급 후 정상 사용자에게 전달

## 4. VPN 서버 설정

### 4.1 커널 파라미터

NAT Instance로 동작하기 위한 필수 설정:

```bash
# /etc/sysctl.d/99-vpn-server.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0      # NAT instance 필수!
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.ens5.rp_filter=0
```

**rp_filter=0이 필요한 이유:**
- rp_filter(Reverse Path Filtering)는 패킷의 소스 IP가 해당 인터페이스로 도달 가능한지 검증
- NAT instance는 다른 호스트의 패킷을 포워딩하므로 이 검증을 비활성화해야 함

### 4.2 iptables 설정

```bash
# 기본 정책
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP    # Whitelist 방식
iptables -P OUTPUT ACCEPT

# [FORWARD] 응답 패킷 허용 (최우선 - 핵심!)
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# [FORWARD] VPC 내부 → 인터넷 (NAT Instance 역할)
iptables -A FORWARD -i ens5 -s 10.2.0.0/16 -o ens5 -j ACCEPT

# [FORWARD] 역할별 접근 제어 + 로깅
# DEVOPS: Full Access
iptables -A FORWARD -s 10.100.0.16/28 -j LOG --log-prefix "[VPN-DEVOPS] "
iptables -A FORWARD -s 10.100.0.16/28 -j ACCEPT

# BACKEND: SSH, DB, Spring
iptables -A FORWARD -s 10.100.0.32/28 -p tcp -m multiport --dports 22,3306,8080 -j LOG --log-prefix "[VPN-BACKEND] "
iptables -A FORWARD -s 10.100.0.32/28 -p tcp -m multiport --dports 22,3306,8080 -j ACCEPT

# FRONTEND: Web Ports
iptables -A FORWARD -s 10.100.0.48/28 -p tcp -m multiport --dports 80,443,3000 -j LOG --log-prefix "[VPN-FRONTEND] "
iptables -A FORWARD -s 10.100.0.48/28 -p tcp -m multiport --dports 80,443,3000 -j ACCEPT

# AIML: GPU, API
iptables -A FORWARD -s 10.100.0.64/28 -p tcp -m multiport --dports 22,8000,8888 -j LOG --log-prefix "[VPN-AIML] "
iptables -A FORWARD -s 10.100.0.64/28 -p tcp -m multiport --dports 22,8000,8888 -j ACCEPT

# 차단된 패킷 로깅
iptables -A FORWARD -s 10.100.0.0/24 -j LOG --log-prefix "[VPN-DROP] "

# [NAT] Masquerade
iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o ens5 -j MASQUERADE  # VPN 트래픽
iptables -t nat -A POSTROUTING -s 10.2.0.0/16 -o ens5 -j MASQUERADE    # VPC 내부 (NAT Instance)
```

**ESTABLISHED,RELATED 규칙이 필요한 이유:**
- 요청 패킷은 역할별 규칙으로 허용됨
- 응답 패킷은 소스 IP가 외부(예: 52.95.193.73)이므로 역할별 규칙에 매칭되지 않음
- conntrack으로 이미 수립된 연결의 응답 패킷을 허용해야 함

### 4.3 NAT Instance 역할 (Private Subnet 지원)

VPN 서버는 WireGuard VPN 외에도 **NAT Instance** 역할을 수행한다.
Management VPC의 Private Subnet(모니터링 서버 등)이 인터넷에 접근할 수 있도록 한다.

```
[모니터링 서버 10.2.2.42]
        │
        │ AWS API 요청 (EC2 Service Discovery)
        ▼
[VPN 서버 FORWARD] ──── 규칙: -s 10.2.0.0/16 -j ACCEPT ✓
        │
        │ MASQUERADE (src=10.2.1.65)
        ▼
    [Internet]
        │
        │ 응답
        ▼
[VPN 서버 FORWARD] ──── 규칙: --ctstate ESTABLISHED,RELATED -j ACCEPT ✓
        │
        │ de-NAT
        ▼
[모니터링 서버 10.2.2.42]
```

## 5. 모니터링 및 로깅 체계

### 5.1 로깅 아키텍처

```
[VPN Server]
  ├─ WireGuard (연결/해제 로그)
  ├─ iptables (역할별 트래픽 로그)
  │     [VPN-DEVOPS] SRC=10.100.0.17 DST=10.0.1.157 DPT=22
  │     [VPN-BACKEND] SRC=10.100.0.33 DST=10.0.1.157 DPT=3306
  │     [VPN-DROP] SRC=10.100.0.49 DST=10.0.1.157 DPT=22
  └─ Promtail
       ↓
[Loki Server] (Management VPC)
  ├─ 로그 수집 및 인덱싱
  ├─ 장기 보관 (90일 retention)
  └─ 라벨 추출 (role, src_ip, dst_ip, dst_port)
       ↓
[Grafana] (Management VPC)
  ├─ VPN 모니터링 대시보드
  ├─ 보안 알람 규칙
  └─ Alert Manager
       ↓
  [Discord Webhook]
```

### 5.2 수집되는 로그 정보

**iptables 로그 예시:**
```
[VPN-DEVOPS] IN=wg0 OUT=ens5 SRC=10.100.0.17 DST=10.0.1.157 PROTO=TCP DPT=22
[VPN-BACKEND] IN=wg0 OUT=ens5 SRC=10.100.0.33 DST=10.0.1.157 PROTO=TCP DPT=3306
[VPN-DROP] IN=wg0 OUT=ens5 SRC=10.100.0.49 DST=10.0.1.157 PROTO=TCP DPT=22
```

**추출 가능한 정보:**
- 역할 (log prefix로 구분)
- 소스 IP (VPN 클라이언트)
- 목적지 IP (Dev/Prod 서버)
- 목적지 포트
- 허용/차단 여부

### 5.3 Grafana 대시보드

**VPN Monitoring Dashboard 패널 구성:**

1. **Active VPN Connections (5m)** - 최근 5분간 활성 연결 수
2. **Traffic by Role** - 역할별 트래픽 분포
3. **Dropped Connections** - 차단된 연결 시도
4. **Recent VPN Traffic Logs** - 실시간 로그 스트림

### 5.4 보안 알람 규칙

| 알람 | 조건 | 심각도 |
|------|------|--------|
| Unauthorized SSH Access | DevOps 외 역할에서 SSH(22) 접근 시도 | high |
| Unauthorized DB Access | Backend/DevOps 외 역할에서 MySQL(3306) 접근 시도 | critical |
| Unknown VPN Source IP | 미등록 IP 대역(role=unknown)에서 트래픽 발생 | critical |
| High Traffic Volume | 1분 내 100건 이상 대량 트래픽 | warning |

## 6. 트러블슈팅 히스토리

### 6.1 NAT Instance 인터넷 연결 문제

**증상:** Private Subnet의 모니터링 서버에서 인터넷 연결 불가

**원인:**
1. `rp_filter=2` (loose mode) → NAT instance는 `rp_filter=0` 필요
2. FORWARD chain에 VPC 내부 트래픽 허용 규칙 없음
3. **ESTABLISHED,RELATED 규칙 누락** (핵심) - 응답 패킷이 DROP됨

**해결:**
```bash
sysctl -w net.ipv4.conf.all.rp_filter=0
iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i ens5 -s 10.2.0.0/16 -o ens5 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.2.0.0/16 -o ens5 -j MASQUERADE
```

### 6.2 VPC Peering Pure Routing 실패

**증상:** VPN 클라이언트에서 Dev 서버로 요청 시 타임아웃

**원인:** VPC Peering은 Peer VPC CIDR 범위 내 트래픽만 전달
- VPN 클라이언트 대역(10.100.0.0/24)은 Management VPC CIDR(10.2.0.0/16)에 포함되지 않음
- 응답 패킷이 VPC Peering을 통과하지 못함

**해결:** Pure Routing 포기, Masquerade 유지 + VPN 서버 iptables 필터링

## 7. 구현 결과 요약

### 7.1 달성한 것

- 역할별 VPN IP 할당 (DEVOPS, BACKEND, FRONTEND, AIML)
- VPN 서버 iptables로 역할별 접근 제어
- VPN 트래픽 로깅 → Loki → Grafana 대시보드
- 보안 알람 (비인가 접근, 미등록 IP 등)
- NAT Instance 기능 (Private Subnet 인터넷 연결)

### 7.2 초기 계획 대비 변경점

| 항목 | 초기 계획 | 최종 구현 |
|------|-----------|-----------|
| 라우팅 방식 | Pure Routing | Masquerade 유지 |
| 접근 제어 | Security Group | VPN 서버 iptables |
| IP 추적 | Dev/Prod에서 원본 IP 확인 | VPN 서버 로그에서만 확인 |
| 필터링 위치 | Dev/Prod Security Group | VPN 서버 FORWARD chain |

### 7.3 아키텍처 다이어그램 (최종)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              AWS Infrastructure                               │
│                                                                              │
│  ┌─────────────────────────────┐                                             │
│  │     Management VPC          │                                             │
│  │     10.2.0.0/16             │                                             │
│  │                             │                                             │
│  │  ┌─────────────────────┐    │     VPC Peering     ┌─────────────────┐    │
│  │  │  VPN Server         │    │◄───────────────────►│    Dev VPC      │    │
│  │  │  10.2.1.65          │    │                     │  10.0.0.0/16    │    │
│  │  │                     │    │                     │                 │    │
│  │  │  - WireGuard        │    │                     │  Dev Servers    │    │
│  │  │  - iptables 필터링   │    │                     │                 │    │
│  │  │  - NAT (Masquerade) │    │                     └─────────────────┘    │
│  │  │  - 트래픽 로깅       │    │                                            │
│  │  └─────────┬───────────┘    │     VPC Peering     ┌─────────────────┐    │
│  │            │                │◄───────────────────►│    Prod VPC     │    │
│  │       WireGuard             │                     │  10.1.0.0/16    │    │
│  │       (wg0: 10.100.0.1)     │                     │                 │    │
│  │            │                │                     │  Prod Servers   │    │
│  └────────────┼────────────────┘                     └─────────────────┘    │
│               │                                                              │
│  ┌────────────┴────────────┐                                                │
│  │  VPN Clients            │                                                │
│  │  10.100.0.0/24          │                                                │
│  │                         │                                                │
│  │  DEVOPS:   10.100.0.16/28 → Full Access                                  │
│  │  BACKEND:  10.100.0.32/28 → SSH, MySQL, Spring                           │
│  │  FRONTEND: 10.100.0.48/28 → Web Ports                                    │
│  │  AIML:     10.100.0.64/28 → FastAPI, Jupyter                             │
│  └─────────────────────────┘                                                │
└──────────────────────────────────────────────────────────────────────────────┘
```

## 8. 향후 개선 사항

1. **VPN 키 자동 발급 시스템**: 현재 수동 발급 → 자동화 스크립트
2. **Discord 알람 고도화**: 역할별 채널 분리, 대응 가이드 포함
3. **S3 로그 아카이빙**: 90일 이상 장기 보관 필요 시
4. **Transit Gateway 검토**: VPC 수 증가 시 VPC Peering 대체 고려 
