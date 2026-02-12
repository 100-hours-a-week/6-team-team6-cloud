# 빅뱅 배포 - 인프라 설계

## 들어가며

이 문서는 Billage 프로젝트의 인프라를 설계하고 구축하면서 어떤 고민을 했고, 왜 이런 선택을 했는지를 정리한 글이다. 단순히 "이렇게 만들었다"가 아니라, **"왜 이렇게 만들었는가"** 에 초점을 맞추었다.

---

## 1. 왜 빅뱅 배포인가

Billage는 500 MAU, 동시 접속 50명 규모를 목표로 하는 서비스다. Frontend(Next.js), Backend(Spring Boot), AI Service(FastAPI), Database(MySQL)까지 총 4개의 컴포넌트로 구성된다.

처음에 고민한 선택지는 두 가지였다.

| 방식 | 장점 | 단점 |
|------|------|------|
| 컴포넌트별 분리 배포 | 장애 격리, 독립 스케일링 | 비용 증가, 운영 복잡도 상승 |
| 단일 서버 빅뱅 배포 | 비용 절감, 운영 단순 | 장애 전파 리스크, 스케일 한계 |

500 MAU 규모에서 컴포넌트별로 EC2를 분리하면 월 비용이 3~4배로 뛴다. 이 규모에서는 과잉 설계다. 하나의 EC2 인스턴스에 모든 컴포넌트를 올리고, Nginx가 리버스 프록시로 트래픽을 분배하는 구조를 선택했다.

```
Client → Nginx(:80/:443)
              ├─ /        → Next.js (:3000)
              ├─ /api/    → Spring Boot (:8080)
              ├─ /ai/     → FastAPI (:5000)
              └─ /health  → 200 OK
```

트래픽이 커지면 그때 분리하면 된다. 지금 필요한 건 **동작하는 인프라**다.

---

## 2. 멀티 VPC 아키텍처

### 2.1 왜 3개의 VPC인가

초기에는 Dev/Prod 2개의 VPC만 계획했다. 하지만 다음 요구사항이 생기면서 Management VPC를 추가했다:

1. **중앙 집중식 모니터링**: Dev와 Prod 모두를 한 곳에서 모니터링
2. **VPN 서버**: 개발자 접근을 위한 안전한 진입점
3. **비용 최적화**: 각 환경에 모니터링 서버를 두는 것보다 효율적

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              VPC 구성                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Dev VPC (10.0.0.0/16)         Prod VPC (10.1.0.0/16)                  │
│  ├─ Public: 10.0.1.0/24        ├─ Public: 10.1.1.0/24                  │
│  │   └─ Main Server            │   └─ Main Server                      │
│  │                             │                                        │
│  └─────────────┬───────────────┴──────────────┐                        │
│                │                               │                        │
│                │     VPC Peering               │                        │
│                │                               │                        │
│                ▼                               ▼                        │
│            Management VPC (10.2.0.0/16)                                │
│            ├─ Public: 10.2.1.0/24                                      │
│            │   └─ VPN Server (WireGuard)                               │
│            │                                                            │
│            └─ Private: 10.2.2.0/24                                     │
│                └─ Monitoring Server (Prometheus, Grafana, Loki)        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 네트워크 레벨 분리

Dev와 Prod는 완전히 독립된 VPC를 사용한다. 이건 의도적인 선택이다.

```
Dev  VPC: 10.0.0.0/16
Prod VPC: 10.1.0.0/16
Management VPC: 10.2.0.0/16
```

같은 VPC 안에서 서브넷으로 나누는 방법도 있었지만, 그렇게 하면 Security Group 설정 실수 하나로 Dev 트래픽이 Prod DB에 접근하는 사고가 발생할 수 있다. VPC 자체를 분리하면 네트워크 레벨에서 원천 차단된다.

### 2.3 Terraform State 분리

각 환경의 Terraform 상태 파일도 완전히 분리했다.

| 환경 | S3 Bucket | DynamoDB Lock Table |
|------|-----------|---------------------|
| Dev | `billage-terraform-state-dev` | `billage-terraform-lock-dev` |
| Prod | `billage-terraform-state-prod` | `billage-terraform-lock-prod` |
| Management | `billage-terraform-state-management` | `billage-terraform-lock-management` |

---

## 3. VPC Peering 설계

### 3.1 Hub-and-Spoke 토폴로지

Management VPC를 중심(Hub)으로, Dev와 Prod가 연결되는(Spoke) 구조를 선택했다.

```
         Dev VPC
             │
             │ Peering
             │
    Management VPC (Hub)
             │
             │ Peering
             │
        Prod VPC
```

**Dev ↔ Prod 직접 연결을 하지 않는 이유:**
- 환경 간 격리 유지
- 실수로 Dev에서 Prod DB 접근 방지
- 모든 관리 트래픽은 Management를 경유

### 3.2 VPC Peering의 제약사항

VPC Peering은 다음 제약이 있다:

1. **Transitive Routing 불가**: Dev → Management → Prod 경로 불가능
2. **CIDR 검증**: Peering을 통한 트래픽은 상대 VPC CIDR 내 목적지만 허용

**중요**: VPN 터널 IP(10.100.0.0/24)는 Management VPC CIDR(10.2.0.0/16)에 포함되지 않으므로, Dev/Prod에서 VPN 클라이언트로 직접 응답 불가능. 이 문제는 VPN 서버에서 SNAT(Masquerade)로 해결.

---

## 4. WireGuard VPN 설계

### 4.1 왜 WireGuard인가

| 솔루션 | 설치 복잡도 | 비용 | 관리 부담 |
|--------|-----------|------|----------|
| Tailscale | 매우 쉬움 | 무료 (100기기) | 낮음 (SaaS 의존) |
| WireGuard | 보통 | 무료 | 중간 |
| OpenVPN | 복잡 | 무료 | 높음 |
| AWS Client VPN | 보통 | $72+/월 | 낮음 |

WireGuard를 선택한 이유:
- **비용**: 무료
- **성능**: 커널 레벨 구현으로 최고 성능
- **자체 운영**: SaaS 의존성 없음
- **세밀한 제어**: 역할별 접근 제어 가능

### 4.2 역할 기반 IP 할당

VPN 사용자에게 역할에 따라 IP 대역을 할당하여 iptables로 접근 제어:

```
VPN 터널: 10.100.0.0/24

IP 할당 정책:
├─ 10.100.0.1       → VPN Server
├─ 10.100.0.16/28   → DEVOPS (17-30): Full Access
├─ 10.100.0.32/28   → BACKEND (33-46): SSH, MySQL, Spring Boot
├─ 10.100.0.48/28   → FRONTEND (49-62): Web Ports
└─ 10.100.0.64/28   → AIML (65-78): FastAPI, SSH
```

### 4.3 VPN과 VPC Peering 통합 문제

**문제 상황:**
```
VPN Client (10.100.0.17) → Dev Server (10.0.1.x) 요청
  ↓
Dev Server → 10.100.0.17로 응답 시도
  ↓
Dev Route Table: 10.100.0.0/24 → Peering (Management)
  ↓
VPC Peering 검증: 10.100.0.17 ∈ 10.2.0.0/16? → NO!
  ↓
패킷 DROP
```

**해결책:**
VPN 서버에서 Masquerade(SNAT) 적용:
```bash
iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
```

VPN 클라이언트 트래픽이 VPN 서버 IP(10.2.1.x)로 변환되어 Dev/Prod에서 응답 가능.

---

## 5. 모니터링 설계

### 5.1 중앙 집중식 모니터링

Management VPC의 Private Subnet에 모니터링 서버를 배치:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Monitoring Architecture                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Dev Server (10.0.1.x)          Prod Server (10.1.1.x)         │
│  ├─ Node Exporter (:9100)       ├─ Node Exporter (:9100)       │
│  ├─ cAdvisor (:8088)            ├─ cAdvisor (:8088)            │
│  └─ Promtail → Loki             └─ Promtail → Loki             │
│           │                              │                      │
│           │        VPC Peering           │                      │
│           └──────────────┬───────────────┘                      │
│                          │                                      │
│                          ▼                                      │
│           Management VPC Private Subnet (10.2.2.x)             │
│           ├─ Prometheus (:9090) - 메트릭 수집                  │
│           ├─ Loki (:3100) - 로그 수집                          │
│           └─ Grafana (:3000) - 대시보드                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Private Subnet 선택 이유

모니터링 서버를 Private Subnet에 배치한 이유:
- 외부 직접 접근 차단
- VPN을 통해서만 접근 가능
- Prometheus/Grafana UI 보호

---

## 6. Security Group 설계

### 6.1 환경별 Security Group

**Dev Main Server:**
```
인바운드:
├─ 22 (SSH)        ← VPN CIDR (10.100.0.0/24)
├─ 80 (HTTP)       ← 0.0.0.0/0
├─ 443 (HTTPS)     ← 0.0.0.0/0
├─ 3306 (MySQL)    ← VPN CIDR + VPC CIDR
├─ 9100 (Node Exp) ← Management VPC (Prometheus scrape)
└─ 8088 (cAdvisor) ← Management VPC
```

**Management VPN Server:**
```
인바운드:
├─ 22 (SSH)        ← VPN CIDR
├─ 51820 (WireGuard UDP) ← 0.0.0.0/0
└─ All traffic     ← VPC CIDR (10.2.0.0/16)
```

**Management Monitoring Server:**
```
인바운드:
├─ 22 (SSH)        ← VPN CIDR
├─ 3000 (Grafana)  ← VPN CIDR
├─ 9090 (Prometheus) ← VPN CIDR
└─ 3100 (Loki)     ← Dev/Prod VPC CIDRs (로그 수신)
```

---

## 7. 전체 아키텍처 요약

### Dev 환경

```
                    Internet
                       │
              ┌────────┴────────┐
              │  Internet GW    │
              └────────┬────────┘
                       │
         VPC: 10.0.0.0/16
         ┌─────────────┴──────────────┐
         │  Public Subnet: 10.0.1.0/24│
         │  ┌───────────────────────┐ │
         │  │   EC2 (t4g.medium)    │ │
         │  │   EIP 할당             │ │
         │  │                       │ │
         │  │   Nginx (:80/:443)    │ │
         │  │    ├ Next.js (:3000)  │ │
         │  │    ├ Spring  (:8080)  │ │
         │  │    ├ FastAPI (:5000)  │ │
         │  │    └ MySQL   (:3306)  │ │
         │  └───────────────────────┘ │
         │                            │
         │  ← VPC Peering to Management
         └────────────────────────────┘
```

### Management 환경

```
         VPC: 10.2.0.0/16
         ┌─────────────────────────────────────────┐
         │                                          │
         │  Public Subnet: 10.2.1.0/24             │
         │  ┌─────────────────────────────────────┐│
         │  │  VPN Server (t4g.micro)              ││
         │  │  ├─ WireGuard (:51820 UDP)          ││
         │  │  ├─ NAT Instance                    ││
         │  │  └─ EIP 할당                         ││
         │  └─────────────────────────────────────┘│
         │                    │                     │
         │                    │ 내부 라우팅         │
         │                    ↓                     │
         │  Private Subnet: 10.2.2.0/24            │
         │  ┌─────────────────────────────────────┐│
         │  │  Monitoring Server (t4g.small)       ││
         │  │  ├─ Prometheus (:9090)              ││
         │  │  ├─ Grafana   (:3000)               ││
         │  │  └─ Loki      (:3100)               ││
         │  └─────────────────────────────────────┘│
         │                                          │
         │  VPC Peering ↔ Dev VPC                  │
         │  VPC Peering ↔ Prod VPC                 │
         └─────────────────────────────────────────┘
```

---

## 8. 비용 구조

| 리소스 | Dev | Prod | Management | 합계 |
|--------|-----|------|------------|------|
| EC2 Main (t4g.medium) | $30 | $30 | - | $60 |
| EC2 VPN (t4g.micro) | - | - | $5 | $5 |
| EC2 Monitoring (t4g.small) | - | - | $15 | $15 |
| EBS gp3 | $3 | $3 | $4 | $10 |
| Elastic IP | $0 | $0 | $0 | $0 |
| 데이터 전송 | ~$5 | ~$5 | ~$2 | ~$12 |
| **합계** | | | | **~$100/월** |

---

## 9. 향후 개선 포인트

1. **Private Subnet 도입 (Dev/Prod)**: 애플리케이션 서버를 Private Subnet으로 이동
2. **ALB 도입**: 트래픽 증가 시 Load Balancer 추가
3. **RDS 마이그레이션**: MySQL을 RDS로 이전 (자동 백업, 자동 로테이션)
4. **Multi-AZ**: 가용성 향상을 위한 다중 가용 영역 배포
5. **WAF 도입**: 웹 애플리케이션 공격 방어

---

## 마치며

이 인프라는 "완벽한 아키텍처"가 아니라 "현재 규모에 적합한 아키텍처"를 목표로 설계했다. 모든 설계 결정에는 트레이드오프가 있었고, 500 MAU라는 규모와 제한된 예산이라는 제약 조건 안에서 최선의 선택을 했다.

Terraform 모듈 구조를 잘 잡아두었기 때문에, 나중에 규모가 커지더라도 모듈을 교체하거나 확장하는 방식으로 점진적인 개선이 가능하다.

---

*문서 작성일: 2026-02-09*
*작성자: Billage 인프라팀*
