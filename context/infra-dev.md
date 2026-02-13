# Dev 인프라

## 개요

Billage 프로젝트의 개발 환경 인프라 구성입니다. 단일 EC2 인스턴스에 모든 서비스를 호스팅하는 모놀리식 아키텍처입니다.

- **목표**: 500 MAU (동시 접속 50명)
- **리전**: ap-northeast-2 (서울)
- **환경**: dev
- **배포 방식**: 중단 배포 (단순 재시작)

---

## 아키텍처 다이어그램

```
                           ┌─────────────────────────────────────────────────────────────┐
                           │                        AWS Cloud                            │
                           │                    (ap-northeast-2)                         │
                           │                                                             │
                           │  ┌───────────────────────────────────────────────────────┐  │
                           │  │              VPC: billage-dev-vpc                     │  │
                           │  │              CIDR: 10.0.0.0/16                        │  │
  ┌─────────┐              │  │                                                       │  │
  │         │              │  │  ┌─────────────────────────────────────────────────┐  │  │
  │ Internet│              │  │  │        Public Subnet: 10.0.1.0/24               │  │  │
  │         │              │  │  │        AZ: ap-northeast-2a                       │  │  │
  │         │              │  │  │                                                  │  │  │
  └────┬────┘              │  │  │  ┌────────────────────────────────────────────┐ │  │  │
       │                   │  │  │  │     EC2: billage-dev-main-server           │ │  │  │
       ▼                   │  │  │  │     Type: t4g.medium (2 vCPU, 4GB RAM)     │ │  │  │
  ┌─────────┐              │  │  │  │     OS: Ubuntu 24.04 LTS (ARM64)           │ │  │  │
  │   IGW   │◄─────────────┼──┼──┼──┤                                            │ │  │  │
  │         │              │  │  │  │     Services:                              │ │  │  │
  │         │              │  │  │  │     ├─ Nginx      (:80/:443)               │ │  │  │
  └─────────┘              │  │  │  │     ├─ Next.js    (:3000)                  │ │  │  │
       │                   │  │  │  │     ├─ Spring Boot(:8080)                  │ │  │  │
       │                   │  │  │  │     ├─ FastAPI    (:5000)                  │ │  │  │
       │                   │  │  │  │     └─ MySQL      (:3306)                  │ │  │  │
  ┌────▼─────────────────┐ │  │  │  │                                            │ │  │  │
  │  Management VPC      │ │  │  │  │     Monitoring Agents:                     │ │  │  │
  │  VPN + Monitoring    │ │  │  │  │     ├─ Node Exporter (:9100)              │ │  │  │
  │  (VPC Peering)       │ │  │  │  │     ├─ cAdvisor     (:8088)               │ │  │  │
  └──────────────────────┘ │  │  │  │     └─ Promtail     (→ Loki)              │ │  │  │
                           │  │  │  │                                            │ │  │  │
                           │  │  │  │     Root Volume: 30GB gp3 (encrypted)      │ │  │  │
                           │  │  │  └────────────────────────────────────────────┘ │  │  │
                           │  │  │                                                  │  │  │
                           │  │  └─────────────────────────────────────────────────┘  │  │
                           │  │                                                       │  │
                           │  └───────────────────────────────────────────────────────┘  │
                           │                                                             │
                           └─────────────────────────────────────────────────────────────┘
```

---

## 리소스 상세

### 1. VPC (module.vpc)

| 리소스 | 이름 | 설정 |
|--------|------|------|
| VPC | billage-dev-vpc | CIDR: 10.0.0.0/16, DNS Hostnames: Enabled |
| Subnet | billage-dev-public-subnet | CIDR: 10.0.1.0/24, AZ: ap-northeast-2a |
| Internet Gateway | billage-dev-igw | VPC에 연결됨 |
| Route Table | billage-dev-public-rt | 0.0.0.0/0 → IGW, 10.2.0.0/16 → Peering |

### 2. VPC Peering

| Peering | 방향 | 용도 |
|---------|------|------|
| dev-to-management | Dev ↔ Management | VPN 접근, 모니터링 |

### 3. Security Group (module.security_group)

#### Inbound Rules

| Port | Protocol | Source | Description |
|------|----------|--------|-------------|
| 22 | TCP | 10.100.0.0/24 | SSH (VPN Only) |
| 80 | TCP | 0.0.0.0/0 | HTTP |
| 443 | TCP | 0.0.0.0/0 | HTTPS |
| 3000 | TCP | 0.0.0.0/0 | Next.js (Frontend) |
| 3306 | TCP | 10.100.0.0/24, 10.0.0.0/16 | MySQL (VPN + VPC) |
| 5000 | TCP | 0.0.0.0/0 | FastAPI (AI Service) |
| 8080 | TCP | 0.0.0.0/0 | Spring Boot (Backend) |
| 9100 | TCP | 10.2.0.0/16 | Node Exporter (Prometheus) |
| 8088 | TCP | 10.2.0.0/16 | cAdvisor (Prometheus) |

#### Outbound Rules

| Port | Protocol | Destination | Description |
|------|----------|-------------|-------------|
| All | All | 0.0.0.0/0 | Allow all outbound |

### 4. EC2 Instance (module.ec2_main)

| 속성 | 값 |
|------|-----|
| Instance Type | t4g.medium (ARM64, 2 vCPU, 4GB RAM) |
| AMI | Ubuntu 24.04 LTS ARM64 (동적 조회) |
| Key Pair | terraform.tfvars에서 설정 |

#### Root Volume

| 속성 | 값 |
|------|-----|
| Type | gp3 |
| Size | 30 GB |
| IOPS | 3000 |
| Throughput | 125 MB/s |
| Encrypted | Yes (KMS) |

---

## 접속 정보

### VPN 연결 후 접속

```bash
# WireGuard 연결
wg-quick up billage

# SSH 접속 (VPN 터널 경유)
ssh -i <your-key.pem> ubuntu@10.0.1.x

# 서비스 접속 (VPN 연결 상태)
Frontend (Next.js):   http://10.0.1.x:3000
Backend (Spring):     http://10.0.1.x:8080
AI Service (FastAPI): http://10.0.1.x:5000
MySQL:                mysql -h 10.0.1.x -u <user> -p
```

### Public 접속 (HTTP/HTTPS)

```bash
# 도메인 또는 Elastic IP로 접속
http://dev.billages.com
https://dev.billages.com
```

---

## Terraform Outputs

```bash
cd envs/dev
terraform output
```

| Output | 설명 |
|--------|------|
| `vpc_id` | VPC ID |
| `vpc_cidr` | VPC CIDR 블록 (10.0.0.0/16) |
| `public_subnet_id` | Public Subnet ID |
| `main_security_group_id` | Security Group ID |
| `instance_id` | EC2 Instance ID |
| `instance_private_ip` | EC2 Private IP |
| `elastic_ip` | Elastic IP (고정) |

---

## 모니터링

### 메트릭 수집 (Prometheus → Dev)

```
Management VPC의 Prometheus가 VPC Peering을 통해 수집:
├─ Node Exporter (10.0.1.x:9100) - 시스템 메트릭
├─ cAdvisor (10.0.1.x:8088) - 컨테이너 메트릭
└─ Spring Boot Actuator - 애플리케이션 메트릭
```

### 로그 수집 (Promtail → Loki)

```
Dev 서버의 Promtail이 Management VPC의 Loki로 전송:
├─ /var/log/billage/backend/*.log
├─ /var/log/billage/frontend/*.log
├─ /var/log/billage/ai/*.log
└─ /var/log/nginx/*.log
```

### Grafana 대시보드 접근

```bash
# VPN 연결 후
http://10.2.2.x:3000
```

---

## 서비스 구성

### Nginx 라우팅

```
Internet → Nginx (:80/:443)
              ├── /api/*  → Spring Boot (:8080)
              ├── /ai/*   → FastAPI (:5000)
              └── /*      → Next.js (:3000)
```

### Systemd 서비스

| 서비스 | 포트 | 재시작 명령 |
|--------|------|-------------|
| billage-backend | 8080 | `systemctl restart billage-backend` |
| billage-frontend | 3000 | `systemctl restart billage-frontend` |
| billage-ai | 5000 | `systemctl restart billage-ai` |

### 디렉토리 구조 (서버)

```
/opt/billage/
├── backend/
│   ├── app.jar              # Spring Boot JAR
│   └── config/              # application.yml
├── frontend/                # Next.js 빌드
└── ai/                      # FastAPI 소스 + venv

/var/log/billage/
├── backend/
├── frontend/
├── ai/
└── nginx/
```

---

## 보안 고려사항

### 현재 적용됨 ✅

- SSH: VPN(10.100.0.0/24)에서만 접근 가능
- MySQL: VPN + VPC 내부에서만 접근 가능
- 모니터링 에이전트: Management VPC에서만 접근 가능

### 개선 예정 🟠

- Spring Boot (8080): localhost만 허용 예정
- Next.js (3000): localhost만 허용 예정
- FastAPI (5000): localhost만 허용 예정

---

## 비용 예상 (월간)

| 리소스 | 예상 비용 |
|--------|-----------|
| EC2 t4g.medium (On-Demand) | ~$30 |
| EBS gp3 30GB | ~$3 |
| Elastic IP | $0 (연결된 경우) |
| 데이터 전송 (예상) | ~$5-10 |
| **총 예상** | **~$40-50/월** |

---

## 향후 개선 방향

1. **애플리케이션 포트 내부화**: 8080, 3000, 5000 → localhost만
2. **Private Subnet 도입**: 애플리케이션을 Private Subnet으로 이동
3. **RDS 마이그레이션**: MySQL → RDS (자동 백업)
4. **무중단 배포**: Blue-Green 또는 Rolling 배포 도입

---

*문서 작성일: 2026-02-09*
*작성자: Billage 인프라팀*