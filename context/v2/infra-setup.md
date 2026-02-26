# v2 Dev 인프라 구성 기록

## 구성 일자
2026-02-25

## 생성된 리소스

### 네트워크
| 리소스 | 이름/ID | CIDR |
|--------|---------|------|
| Public Subnet A | billage-dev-public-subnet (기존 v1) | 10.0.1.0/24 |
| Public Subnet C | billage-dev-v2-public-subnet-c | 10.0.2.0/24 |
| Private Subnet A (EC2) | billage-dev-v2-private-subnet-a | 10.0.20.0/24 |
| Private Subnet C (EC2) | billage-dev-v2-private-subnet-c | 10.0.21.0/24 |
| Private Subnet A (RDS) | billage-dev-v2-rds-private-a | 10.0.12.0/24 |
| Private Subnet C (RDS) | billage-dev-v2-rds-private-c | 10.0.13.0/24 |

### Private Subnet 인터넷 접근 방식
VPC Peering을 통해 Management VPC의 VPN 서버(NAT Instance)를 경유.
- Route: `0.0.0.0/0 → VPC Peering (pcx-0f57e5fe71ee6c565)`
- VPN 서버 iptables: `FORWARD 10.0.0.0/16 ACCEPT` + `MASQUERADE 10.0.0.0/16`
- 비용: $0 (기존 VPN 서버 활용)
- 주의: AWS 공식 지원 패턴이 아님. 문제 발생 시 Dev VPC 내 NAT Instance(t3.nano ~$3/월)로 전환.

### RDS
| 항목 | 값 |
|------|---|
| Identifier | billage-dev-v2-mysql |
| Endpoint | billage-dev-v2-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com |
| Engine | MySQL 8.0 |
| Instance Class | db.t4g.micro |
| Username | billage_admin |
| 관리 위치 | shared/rds/dev/ |

### 리허설 RDS (기존)
| 항목 | 값 |
|------|---|
| Identifier | billage-dev-mysql |
| 관리 위치 | shared/rds/rehearsal/ (폴더명 변경됨) |
| 용도 | Host→RDS 마이그레이션 리허설용 |

### ALB
| 항목 | 값 |
|------|---|
| 이름 | billage-dev-v2-alb |
| URL | https://v2.dev.billages.com |
| HTTP | 80 → 443 리다이렉트 |
| HTTPS 기본 | → Frontend TG |
| /api/* | → Backend TG |
| /ai/* | → AI TG |

### ASG / Launch Template
| 서비스 | ASG | Instance Type | AMI |
|--------|-----|--------------|-----|
| Backend | billage-dev-v2-be-asg | t3.small (x86_64) | ami-01488502d83cfffa4 |
| Frontend | billage-dev-v2-fe-asg | t3.small (x86_64) | ami-01488502d83cfffa4 |
| AI | billage-dev-v2-ai-asg | t3.small (x86_64) | ami-01488502d83cfffa4 |

- Golden AMI: `billage-golden-ami-20260210-071324` (x86_64, Docker 설치됨)
- 배포: Private Subnet, Public IP 없음
- SSH: VPN 접속 후 Private IP로 접근

### ECR
| 리포지토리 | 용도 |
|------------|------|
| billage-be | Backend Docker 이미지 |
| billage-fe | Frontend Docker 이미지 |
| billage-ai | AI Docker 이미지 |

## Terraform 관리 구조

```
shared/rds/dev/        → v2 전용 RDS (billage-dev-v2-mysql)
shared/rds/rehearsal/  → 리허설 RDS (billage-dev-mysql, 기존)
v2/envs/dev/           → ALB, ASG, Subnet, SG, IAM, Route53 등
shared/management/     → VPN 서버, 모니터링, VPC Peering
```

### Apply 순서
```
1. shared/management (VPC Peering, VPN 서버)
2. shared/rds/dev (RDS)
3. v2/envs/dev (ALB, ASG 등) - golden_ami_id 변수 필요
```

```bash
cd v2/envs/dev
terraform apply -var 'golden_ami_id=ami-01488502d83cfffa4'
```

## user_data (sh.tpl) 동작 방식

Launch Template의 user_data로 sh.tpl을 사용. EC2 부팅 시 자동 실행.

Terraform에서 주입하는 값 (부트스트랩 정보만):
- `env`, `project_name`, `aws_region`, `ecr_registry`

애플리케이션 환경변수는 **전부 SSM Parameter Store**에서 런타임에 조회:
- 경로: `/billage/dev/{service}/`
- 키 이름이 자동으로 대문자+언더스코어 환경변수로 변환됨

## 의사결정 기록

### Private Subnet 선택 이유
- Public Subnet에 EC2를 두면 SG 실수 시 외부 노출 위험
- Private Subnet은 네트워크 레벨에서 격리 → 방어 계층 추가
- Dev/Prod 동일한 네트워크 구조로 일관성 유지

### VPN NAT 경유 선택 이유
- NAT Gateway ($35/월), VPC Endpoint ($22+/월) 대비 $0
- 기존 VPN 서버에 MASQUERADE + ip_forward 이미 설정됨
- Dev 환경이라 단일 장애점 감수 가능
- 트래픽 로깅이 VPN 서버에서 이미 동작 (보안 가시성)

### SSM 환경변수 통일 이유
- 기존: Terraform 주입 + SSM 혼용 → 환경변수 추가 시 코드 수정 필요
- 변경: SSM 통일 → 환경변수 추가/변경 시 SSM만 수정, Terraform 코드 변경 불필요