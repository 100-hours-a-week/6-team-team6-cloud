# Billage 보안 강화 단계별 체크리스트 (V2)

> 이 문서는 현재 시스템에 영향을 주지 않으면서 단계적으로 보안을 강화하기 위한 실행 체크리스트입니다.
> 각 단계는 독립적으로 실행 가능하며, 롤백 방법이 포함되어 있습니다.

---

## 현재 인프라 구조

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Billage 인프라 구조                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐ │
│  │   Dev VPC       │  │   Prod VPC      │  │   Management VPC        │ │
│  │  10.0.0.0/16    │  │  10.1.0.0/16    │  │  10.2.0.0/16            │ │
│  │                 │  │                 │  │                         │ │
│  │ ┌─────────────┐ │  │ ┌─────────────┐ │  │ [Public: 10.2.1.0/24]  │ │
│  │ │Main Server  │ │  │ │Main Server  │ │  │  ┌─────────────────┐   │ │
│  │ │FE+BE+DB+AI  │ │  │ │FE+BE+DB+AI  │ │  │  │ VPN Server      │   │ │
│  │ │t4g.medium   │ │  │ │t4g.medium   │ │  │  │ WireGuard+NAT   │   │ │
│  │ └─────────────┘ │  │ └─────────────┘ │  │  │ t4g.micro       │   │ │
│  │                 │  │                 │  │  └─────────────────┘   │ │
│  └────────┬────────┘  └────────┬────────┘  │                         │ │
│           │                    │           │ [Private: 10.2.2.0/24] │ │
│           │    VPC Peering     │           │  ┌─────────────────┐   │ │
│           └────────────────────┴───────────┤  │ Monitoring      │   │ │
│                                            │  │ Prometheus      │   │ │
│                                            │  │ Grafana, Loki   │   │ │
│                                            │  │ t4g.small       │   │ │
│                                            │  └─────────────────┘   │ │
│                                            └─────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### 서버 목록

| 환경 | 서버 | IP 대역 | 역할 | 인스턴스 |
|------|------|---------|------|----------|
| Dev | Main Server | 10.0.1.x | FE+BE+DB+AI | t4g.medium |
| Prod | Main Server | 10.1.1.x | FE+BE+DB+AI | t4g.medium |
| Management | VPN Server | 10.2.1.x (Public) | WireGuard + NAT | t4g.micro |
| Management | Monitoring | 10.2.2.x (Private) | 중앙 모니터링 | t4g.small |

---

## 현재 보안 상태 요약

| 항목 | Dev | Prod | Management | 상태 |
|------|-----|------|------------|------|
| SSH (22) | VPN만 | VPN만 | VPN만 | ✅ 완료 |
| MySQL (3306) | VPN+VPC | VPN+VPC | - | ✅ 완료 |
| Spring Boot (8080) | 0.0.0.0/0 | 0.0.0.0/0 | - | 🟠 개선 예정 |
| Next.js (3000) | 0.0.0.0/0 | 0.0.0.0/0 | - | 🟠 개선 예정 |
| FastAPI (5000) | 0.0.0.0/0 | 0.0.0.0/0 | - | 🟠 개선 예정 |
| Grafana (3000) | - | - | VPN만 | ✅ 완료 |
| Prometheus (9090) | - | - | VPN만 | ✅ 완료 |
| WireGuard (51820) | - | - | 0.0.0.0/0 | ✅ 정상 (VPN) |

---

## VPN 전략: WireGuard 기반 역할별 접근 제어

### 구축 완료 ✅

```
┌─────────────────────────────────────────────────────────────────┐
│                      WireGuard VPN 구성                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  VPN Server: Management VPC Public Subnet (10.2.1.x)            │
│  VPN Tunnel: 10.100.0.0/24                                      │
│  UDP Port: 51820                                                │
│                                                                  │
│  역할별 IP 할당:                                                 │
│  ├─ 10.100.0.1        → VPN Server                              │
│  ├─ 10.100.0.16/28    → DEVOPS (17-30): Full Access            │
│  ├─ 10.100.0.32/28    → BACKEND (33-46): SSH, MySQL, Spring    │
│  ├─ 10.100.0.48/28    → FRONTEND (49-62): Web Ports            │
│  └─ 10.100.0.64/28    → AIML (65-78): FastAPI, SSH             │
│                                                                  │
│  등록된 사용자:                                                  │
│  ├─ patrick (DEVOPS)   - 10.100.0.17 ✅                         │
│  ├─ logan   (DEVOPS)   - 10.100.0.18 ✅                         │
│  ├─ hooni   (BACKEND)  - 10.100.0.33 ✅                         │
│  ├─ bluer   (FRONTEND) - 10.100.0.49 ✅                         │
│  └─ bina    (AIML)     - 10.100.0.65 ✅                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### VPN + VPC Peering 라우팅 문제 및 해결

**문제점:**
VPC Peering은 상대 VPC CIDR 내 목적지만 전달함.
VPN 터널 IP(10.100.0.0/24)는 Management VPC CIDR(10.2.0.0/16)에 포함되지 않음.

**해결책:**
VPN 서버에서 Masquerade(SNAT) 적용:
```bash
# wg0.conf PostUp 규칙
iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j MASQUERADE
```

---

## Phase 1: WireGuard VPN 구축 ✅ 완료

### Step 1.1: VPN 서버 배포
- [x] Management VPC 생성
- [x] VPN Server EC2 배포 (t4g.micro)
- [x] WireGuard 설치 및 설정
- [x] 역할별 IP 할당 정책 수립

### Step 1.2: VPN 사용자 등록
- [x] DEVOPS 팀 등록 (patrick, logan)
- [x] BACKEND 팀 등록 (hooni)
- [x] FRONTEND 팀 등록 (bluer)
- [x] AIML 팀 등록 (bina)

### Step 1.3: VPC Peering 설정
- [x] Management ↔ Dev VPC Peering
- [x] Management ↔ Prod VPC Peering
- [x] Route Table 업데이트

### Step 1.4: VPN 접속 테스트
```bash
# VPN 서버에서 확인
sudo wg show

# 클라이언트에서 접속 테스트
ping 10.2.1.x    # VPN 서버
ping 10.0.1.x    # Dev 서버 (VPC Peering 경유)
ping 10.2.2.x    # Monitoring 서버 (Private)
```

- [x] 모든 사용자 VPN 연결 확인
- [x] VPC Peering 경유 접속 확인

---

## Phase 2: 중앙 모니터링 구축 ✅ 완료

### Step 2.1: Monitoring 서버 배포
- [x] Private Subnet에 Monitoring 서버 배포
- [x] Docker 및 Docker Compose 설치
- [x] Prometheus, Grafana, Loki 설치

### Step 2.2: Dev/Prod 에이전트 설정
- [x] Node Exporter 설치 (메트릭)
- [x] cAdvisor 설치 (컨테이너 메트릭)
- [x] Promtail 설치 (로그)

### Step 2.3: 모니터링 연동 확인
- [x] Prometheus → Dev/Prod 메트릭 수집
- [x] Loki → Dev/Prod 로그 수집
- [x] Grafana 대시보드 설정

---

## Phase 3: Security Group 강화 (진행 중)

### Step 3.1: SSH 접근 제한 ✅
```hcl
# SSH - VPN에서만 접근
ingress {
  description = "SSH from VPN"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["10.100.0.0/24"]  # VPN 터널 CIDR
}
```

- [x] Dev SSH → VPN만
- [x] Prod SSH → VPN만
- [x] Management SSH → VPN만

### Step 3.2: Database 접근 제한 ✅
```hcl
# MySQL - VPN + VPC 내부만
ingress {
  description = "MySQL from VPN and VPC"
  from_port   = 3306
  to_port     = 3306
  protocol    = "tcp"
  cidr_blocks = ["10.100.0.0/24", var.vpc_cidr]
}
```

- [x] Dev MySQL → VPN + VPC
- [x] Prod MySQL → VPN + VPC

### Step 3.3: 애플리케이션 포트 내부화 (예정)
```hcl
# Spring Boot - localhost만 (Nginx 경유)
# TODO: 현재는 디버깅을 위해 열어둠
ingress {
  description = "Spring Boot"
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = ["127.0.0.1/32"]
}
```

- [ ] Spring Boot (8080) → localhost만
- [ ] Next.js (3000) → localhost만
- [ ] FastAPI (5000) → localhost만

---

## Phase 4: VPN 서버 접근 제어 강화 (예정)

### Step 4.1: iptables 역할별 필터링

VPN 서버에서 역할별 접근 제어:

```bash
# BACKEND (10.100.0.32/28) - SSH, MySQL, Spring Boot만
iptables -A FORWARD -s 10.100.0.32/28 -p tcp --dport 22 -j ACCEPT
iptables -A FORWARD -s 10.100.0.32/28 -p tcp --dport 3306 -j ACCEPT
iptables -A FORWARD -s 10.100.0.32/28 -p tcp --dport 8080 -j ACCEPT
iptables -A FORWARD -s 10.100.0.32/28 -j DROP

# FRONTEND (10.100.0.48/28) - Web만
iptables -A FORWARD -s 10.100.0.48/28 -p tcp --dport 80 -j ACCEPT
iptables -A FORWARD -s 10.100.0.48/28 -p tcp --dport 443 -j ACCEPT
iptables -A FORWARD -s 10.100.0.48/28 -p tcp --dport 3000 -j ACCEPT
iptables -A FORWARD -s 10.100.0.48/28 -j DROP

# DEVOPS - Full Access (필터링 없음)
```

- [ ] iptables 규칙 작성
- [ ] 규칙 테스트
- [ ] 영구 적용 (iptables-persistent)

---

## Phase 5: SSM 백업 경로 (예정)

> VPN 장애 시 백업 접근 경로

### Step 5.1: IAM Role에 SSM 정책 추가

```hcl
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

- [ ] IAM 정책 추가
- [ ] terraform apply

### Step 5.2: SSM 연결 테스트

```bash
aws ssm start-session --target <INSTANCE_ID> --region ap-northeast-2
```

- [ ] SSM 연결 테스트 성공

---

## Phase 6: CI/CD 보안 (예정)

### Step 6.1: GitHub Actions OIDC 전환

- [ ] AWS OIDC Provider 생성
- [ ] GitHub Actions IAM Role 생성
- [ ] Workflow 수정 (Access Key → OIDC)

### Step 6.2: 배포 방식 결정

| 방식 | 현재 상태 | 목표 |
|------|----------|------|
| SSH 직접 | ❌ IP 문제 | - |
| SSM Run Command | 예정 | 메인 |
| Self-hosted Runner | 고려 중 | 백업 |

---

## 완료 체크리스트

### Phase 1 완료 조건 (WireGuard VPN) ✅
- [x] VPN 서버 배포 및 설정
- [x] 역할별 IP 할당
- [x] VPC Peering 설정
- [x] 사용자 등록 및 접속 테스트

### Phase 2 완료 조건 (중앙 모니터링) ✅
- [x] Monitoring 서버 배포
- [x] Prometheus/Grafana/Loki 설치
- [x] Dev/Prod 메트릭/로그 수집

### Phase 3 완료 조건 (Security Group) 진행 중
- [x] SSH → VPN만
- [x] MySQL → VPN + VPC
- [ ] 애플리케이션 포트 → localhost만

### Phase 4 완료 조건 (역할별 접근 제어)
- [ ] iptables 규칙 적용
- [ ] 역할별 접근 테스트

### Phase 5 완료 조건 (SSM 백업)
- [ ] SSM 정책 적용
- [ ] 연결 테스트

### Phase 6 완료 조건 (CI/CD)
- [ ] OIDC 전환
- [ ] 배포 테스트

---

## 접근 방법 정리

| 상황 | 접근 방법 | 명령어 |
|------|----------|--------|
| 일상 작업 | WireGuard VPN | `wg-quick up billage` → `ssh ubuntu@10.x.x.x` |
| VPN 장애 | SSM (예정) | `aws ssm start-session --target i-xxx` |
| Grafana | VPN 연결 후 | `http://10.2.2.x:3000` |
| Prometheus | VPN 연결 후 | `http://10.2.2.x:9090` |

---

## 롤백 절차

### Security Group 롤백
```bash
# Terraform으로 이전 상태 복원
cd envs/dev
terraform apply -var="ssh_allowed_cidr=[\"0.0.0.0/0\"]"
```

### 긴급 상황 시
1. AWS Console → EC2 → Security Groups
2. SSH 규칙에 `0.0.0.0/0` 임시 추가
3. 문제 해결 후 Terraform으로 상태 복구

---

## 다음 단계

- [ ] 애플리케이션 포트 내부화 (8080, 3000, 5000 → localhost만)
- [ ] SSM Parameter Store로 시크릿 이관
- [ ] OIDC 전환 (AWS Access Key 제거)
- [ ] iptables 역할별 필터링 적용
- [ ] WAF 도입 검토

---

*문서 버전: 2.0*
*작성일: 2026-02-09*
*작성자: Billage 인프라팀*