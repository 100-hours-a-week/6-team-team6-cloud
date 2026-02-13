# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Billage Infrastructure - AWS infrastructure as code using Terraform. Multi-VPC architecture with VPC Peering for environment isolation and centralized management.

### Repository Structure

```
terraform/
├── modules/                    # 공용 모듈 (v1, v2 모두 사용)
│   ├── vpc/
│   ├── ec2/
│   ├── security-group/
│   ├── cloudwatch/
│   ├── s3-images/
│   ├── vpc-peering/
│   ├── alb/                    # v2 신규 (TODO)
│   ├── asg/                    # v2 신규 (TODO)
│   ├── rds/                    # v2 신규 (TODO)
│   └── ecr/                    # v2 신규 (TODO)
│
├── v1-bigbang/                 # v1: 단일 인스턴스 (Big Bang 배포)
│   └── envs/
│       ├── dev/
│       └── prod/
│
├── v2/                         # v2: Auto Scaling + ALB 아키텍처
│   └── envs/
│       ├── dev/
│       └── prod/
│
├── shared/                     # 공용 인프라 (v1, v2 공통)
│   ├── management/             # VPN + 모니터링
│   ├── s3-images-dev/
│   └── s3-images-prod/
│
├── monitoring/                 # Docker Compose 기반 모니터링 설정
├── scripts/                    # 서버 설정 스크립트
├── context/                    # 프로젝트 문서
└── docs/                       # 상세 문서
```

### Architecture Versions

#### v1-bigbang (현재 운영 중)
- 단일 EC2 인스턴스에 모든 서비스 배포 (FE + BE + DB + AI)
- Nginx 리버스 프록시
- 중단 배포 방식

#### v2 (마이그레이션 예정)
- ALB + Auto Scaling Groups
- RDS MySQL + ElastiCache Redis
- ECR 기반 Docker 이미지 배포
- 무중단 배포 (Instance Refresh)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    v1 (Big Bang) vs v2 (Scalable)                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  v1-bigbang                          v2                                 │
│  ┌─────────────────┐                ┌─────────────────────────────────┐│
│  │  Single EC2     │                │  ALB                            ││
│  │  ┌───────────┐  │                │    │                            ││
│  │  │ Nginx     │  │                │    ├── Backend ASG (2-6)        ││
│  │  │ Next.js   │  │      →→→       │    ├── Frontend ASG (2-3)       ││
│  │  │ Spring    │  │   Migration    │    └── AI ASG (1-2)             ││
│  │  │ FastAPI   │  │                │                                  ││
│  │  │ MySQL     │  │                │  RDS MySQL + ElastiCache Redis  ││
│  │  └───────────┘  │                └─────────────────────────────────┘│
│  └─────────────────┘                                                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Common Commands

### Terraform Workflow

Commands must be run from the specific environment directory:

```bash
# v1 환경 (현재 운영)
cd v1-bigbang/envs/dev
cd v1-bigbang/envs/prod

# v2 환경 (마이그레이션 준비)
cd v2/envs/dev
cd v2/envs/prod

# 공용 인프라
cd shared/management
cd shared/s3-images-dev
cd shared/s3-images-prod

# Standard workflow
terraform init          # Initialize (first time or after module changes)
terraform validate      # Validate configuration
terraform fmt -recursive # Format code
terraform plan          # Plan changes (dry-run)
terraform apply         # Apply changes
terraform output        # View outputs
terraform state list    # List all resources
```

### Backend Setup (S3 + DynamoDB)

| Environment | Version | S3 Key |
|-------------|---------|--------|
| Dev | v1 | `dev/terraform.tfstate` |
| Dev | v2 | `v2/dev/terraform.tfstate` |
| Prod | v1 | `prod/terraform.tfstate` |
| Prod | v2 | `v2/prod/terraform.tfstate` |
| Management | shared | `management/terraform.tfstate` |
| S3 Images | shared | `s3-images-{env}/terraform.tfstate` |

## Architecture

### VPC Structure

| VPC | CIDR | Purpose |
|-----|------|---------|
| Dev | 10.0.0.0/16 | Development environment |
| Prod | 10.1.0.0/16 | Production environment |
| Management | 10.2.0.0/16 | VPN Server + Centralized Monitoring |

### VPC Peering

```
Management VPC (Hub)
       │
       ├──── Peering ──── Dev VPC
       │
       └──── Peering ──── Prod VPC
```

- Dev and Prod do NOT peer directly
- All cross-VPC traffic goes through Management VPC
- Monitoring server can scrape metrics from Dev/Prod via peering

### WireGuard VPN

**VPN Server**: Management VPC Public Subnet (10.2.1.x)
**VPN Tunnel Network**: 10.100.0.0/24

**Role-based IP allocation**:
```
DEVOPS Team:   10.100.0.16/28 (10.100.0.17-30)  - Full Access
BACKEND Team:  10.100.0.32/28 (10.100.0.33-46)  - SSH, MySQL, Spring Boot
FRONTEND Team: 10.100.0.48/28 (10.100.0.49-62)  - Web Ports
AIML Team:     10.100.0.64/28 (10.100.0.65-78)  - FastAPI, GPU
```

**Known Issue**: VPC Peering only allows traffic destined to peer VPC's CIDR.
VPN tunnel IPs (10.100.0.0/24) are not part of any VPC CIDR, so return traffic
from Dev/Prod cannot reach VPN clients without NAT/Masquerade.

### Resource Dependencies

```
VPC Module
    ↓
Security Group Module (depends on VPC ID)
    ↓
EC2 Module (depends on Subnet ID + Security Group IDs)
    ↓
VPC Peering Module (depends on both VPCs)
```

## Important Notes

### Security Considerations

- SSH/DB access should be restricted to VPN CIDR (10.100.0.0/24)
- Application ports (3000, 8080, 5000) should only be accessible via Nginx/ALB
- Monitoring ports (Grafana:3000, Prometheus:9090) restricted to VPN only
- WireGuard UDP port 51820 is open to 0.0.0.0/0 (required for VPN)

### VPN Access Control

VPN server uses iptables for role-based access control:
- DEVOPS: Full access to all ports
- BACKEND: SSH(22), MySQL(3306), Spring Boot(8080)
- FRONTEND: HTTP(80), HTTPS(443), Next.js(3000)
- AIML: FastAPI(5000), SSH(22)

### Monitoring Architecture

```
Dev/Prod Servers
    │
    │ Docker Network (prometheus_net)
    │ - Promtail scrapes logs
    │ - Node Exporter exposes metrics
    │
    ▼
Management VPC (Private Subnet)
    │
    │ VPC Peering
    │
    ├── Prometheus (scrapes metrics via VPC Peering)
    ├── Loki (receives logs via VPC Peering)
    └── Grafana (dashboards)
```

### Key Files

| File | Purpose |
|------|---------|
| `shared/management/main.tf` | VPN server, monitoring, VPC peering |
| `shared/management/user_data/vpn_setup.sh` | WireGuard VPN installation script |
| `modules/vpc-peering/main.tf` | VPC peering connection and routes |
| `context/v2-migration-milestone.md` | v2 마이그레이션 마일스톤 |
| `docs/security/SECURITY_ANALYSIS.md` | Security analysis and decisions |

## v2 Migration

v2 마이그레이션은 GitHub Issues로 관리:
- https://github.com/100-hours-a-week/6-team-team6-cloud/issues

주요 마일스톤:
- M1: Docker 이미지 & ECR 파이프라인
- M2: 데이터 계층 구축 (RDS + Redis)
- M3: v2 네트워크 설계 & ALB
- M4: Auto Scaling Group & Launch Template
- M5: CI/CD v2 파이프라인
- M6: 모니터링 전환
- M7: MySQL → RDS 마이그레이션
- M8: 점진적 트래픽 전환
- M9: v1 인프라 정리
