# NAT Instance 구축 보고서

> 작성일: 2026-02-26
> 작성자: Billage 인프라팀
> 버전: 1.0

---

## 1. 개요

### 1.1 배경
v2 Dev 환경의 EC2 인스턴스들을 Public Subnet에서 **Private Subnet으로 전환**하면서, Private Subnet EC2가 외부 인터넷에 접근할 수 있는 방법이 필요했다.

주요 인터넷 접근 요구사항:
- **ECR Pull**: Docker 이미지 다운로드
- **SSM Parameter Store**: 환경변수 조회 (AWS API)
- **외부 API**: 앱에서 호출하는 외부 서비스

### 1.2 Private Subnet 전환 이유
- Public Subnet은 SG 실수 시 인스턴스가 외부에 직접 노출
- Private Subnet은 네트워크 레벨에서 격리 → 방어 계층 추가
- Dev/Prod 동일한 네트워크 구조로 일관성 유지

---

## 2. 방안 비교 및 의사결정

### 2.1 검토한 방안

| 방안 | 월 비용 | 장점 | 단점 |
|------|---------|------|------|
| **NAT Gateway** | ~$35 + 데이터 | AWS 관리형, 고가용성 | Dev에 과한 비용 |
| **VPC Endpoints** | ~$22 (3개) | 인터넷 미경유, 보안 우수 | ECR/SSM만 가능, 외부 API 불가 |
| **VPN 서버 NAT (VPC Peering 경유)** | $0 | 기존 인프라 활용, 무비용 | AWS Edge-to-Edge 제한으로 **불가** |
| **NAT Instance (Dev VPC 내)** | ~$3.80 | 최저 비용, 인터넷 전체 접근 | 단일 장애점, 수동 관리 |

### 2.2 최초 시도: VPN 서버를 NAT Instance로 활용 (실패)

Management VPC의 기존 VPN 서버에 MASQUERADE가 설정되어 있어, VPC Peering을 통해 Dev Private Subnet 트래픽을 VPN 서버로 보내 NAT 처리하려 했다.

```
의도한 흐름:
Dev EC2 (10.0.20.x)
  → 0.0.0.0/0 → VPC Peering → Management VPC
  → VPN 서버 MASQUERADE → IGW → 인터넷
```

**결과: 실패** (상세 트러블슈팅은 NAT_INSTANCE_TROUBLESHOOTING.md 참조)

AWS Edge-to-Edge 라우팅 제한으로 VPC Peering을 통해 들어온 트래픽은 IGW로 나갈 수 없다.
패킷이 VPN 서버까지 도달하지 못하고 AWS 네트워크 레벨에서 드롭됨.

### 2.3 최종 결정: Dev VPC 내 NAT Instance

VPN 서버 NAT 방식이 불가능함을 확인 후, Dev VPC Public Subnet에 t3.nano NAT Instance를 배치하기로 결정.

**선택 근거:**
- 비용: $3.80/월 (NAT Gateway 대비 89% 절감)
- Dev 환경이라 단일 장애점 감수 가능
- 인터넷 전체 접근 가능 (VPC Endpoints의 제한 없음)
- Terraform으로 관리하므로 재생성 용이

---

## 3. 최종 아키텍처

```
Dev VPC (10.0.0.0/16)
│
├── Public Subnet A (10.0.1.0/24)
│   ├── ALB (외부 트래픽 진입점)
│   └── NAT Instance (t3.nano, 10.0.1.226)  ← 신규
│       ├── source_dest_check = false
│       ├── ip_forward = 1
│       └── iptables MASQUERADE
│
├── Public Subnet C (10.0.2.0/24)
│   └── ALB (Multi-AZ)
│
├── Private Subnet A (10.0.20.0/24)
│   └── BE/FE/AI EC2 (인터넷 → NAT Instance 경유)
│
├── Private Subnet C (10.0.21.0/24)
│   └── BE/FE/AI EC2
│
└── Private Subnet RDS (10.0.12.0/24, 10.0.13.0/24)
    └── RDS MySQL

Private Route Table:
  0.0.0.0/0   → NAT Instance ENI (인터넷)
  10.2.0.0/16 → VPC Peering (VPN SSH 접속용)
```

### 3.1 패킷 흐름

**인터넷 접근 (ECR Pull 등):**
```
Dev EC2 (10.0.20.174)
  → Private RT: 0.0.0.0/0 → NAT Instance ENI
  → NAT Instance: MASQUERADE (src → 10.0.1.226)
  → Public Subnet → IGW → 인터넷
  → 응답: 역방향 NAT → Dev EC2
```

**VPN SSH 접속 (개발자):**
```
VPN 클라이언트 (10.100.0.x)
  → VPN 서버 MASQUERADE (src → 10.2.1.76)
  → VPC Peering → Dev VPC
  → Dev EC2 (10.0.20.174) SSH 접속
```

두 경로는 완전히 분리되어 서로 영향 없음.

---

## 4. Terraform 구성

### 4.1 리소스 목록

| 리소스 | 이름 | 설명 |
|--------|------|------|
| `aws_instance.nat` | `billage-dev-v2-nat-instance` | NAT Instance (t3.nano) |
| `aws_security_group.nat` | `billage-dev-v2-nat-sg` | Private Subnet에서만 인바운드 허용 |
| `data.aws_ami.amazon_linux` | - | Amazon Linux 2023 최신 AMI |

### 4.2 핵심 설정

```hcl
resource "aws_instance" "nat" {
  ami               = data.aws_ami.amazon_linux.id
  instance_type     = "t3.nano"
  subnet_id         = data.aws_subnet.public.id  # Public Subnet A
  source_dest_check = false                       # NAT Instance 필수!
  ...
}
```

**source_dest_check = false**: EC2는 기본적으로 자신의 IP가 아닌 패킷을 드롭한다.
NAT Instance는 다른 EC2의 패킷을 포워딩해야 하므로 이 체크를 비활성화해야 한다.

### 4.3 user_data (부트스트랩)

```bash
#!/bin/bash
# IP forwarding 활성화
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# iptables NAT 설정
PUB_IF=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $PUB_IF -s 10.0.20.0/24 -j MASQUERADE
iptables -t nat -A POSTROUTING -o $PUB_IF -s 10.0.21.0/24 -j MASQUERADE
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -s 10.0.20.0/24 -o $PUB_IF -j ACCEPT
iptables -A FORWARD -s 10.0.21.0/24 -o $PUB_IF -j ACCEPT
```

### 4.4 라우트 테이블

```hcl
resource "aws_route_table" "private" {
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }
  route {
    cidr_block                = "10.2.0.0/16"  # Management VPC
    vpc_peering_connection_id = data.aws_vpc_peering_connection.management.id
  }
}
```

### 4.5 Security Group

```
Inbound:  All protocols from 10.0.20.0/24, 10.0.21.0/24 (Private Subnets만)
Outbound: All (0.0.0.0/0)
```

---

## 5. 검증 결과

### 5.1 연결 테스트 (Dev BE 서버 10.0.20.174에서)

| 테스트 | 결과 |
|--------|------|
| `ping 8.8.8.8` | 3/3 성공 (22.7ms) |
| `ping google.com` | 3/3 성공 (29.3ms, DNS 해석 OK) |
| `curl https://google.com` | HTTP 301 (정상) |
| `curl https://ECR-endpoint` | HTTP 401 (인증 필요 = 연결 성공) |
| `aws ecr get-login-password` | 토큰 발급 성공 |

### 5.2 비용

| 항목 | 월 비용 |
|------|---------|
| t3.nano On-Demand | ~$3.80 |
| 데이터 전송 (Dev) | 무시 가능 |
| **합계** | **~$3.80/월** |

---

## 6. 운영 가이드

### 6.1 NAT Instance 모니터링
```bash
# NAT Instance 상태 확인
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=billage-dev-v2-nat-instance" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PrivateIpAddress]' \
  --output table --region ap-northeast-2

# Private Subnet에서 인터넷 연결 테스트
ssh ubuntu@<private-ec2-ip> "ping -c 3 8.8.8.8"
```

### 6.2 NAT Instance 장애 시
NAT Instance가 죽으면 Private Subnet EC2의 인터넷 접근이 불가해진다.

```bash
# 복구: Terraform으로 재생성
cd v2/envs/dev
terraform apply -var 'golden_ami_id=ami-01488502d83cfffa4'
```

### 6.3 주의사항
- NAT Instance 종료/재시작 시 ENI ID가 바뀔 수 있음 → `terraform apply`로 라우트 테이블 갱신 필요
- Prod 환경에서는 NAT Gateway 또는 Multi-AZ NAT Instance 구성 권장
- t3.nano는 네트워크 대역폭이 제한적 → 대량 트래픽 시 병목 가능 (Dev에서는 문제없음)