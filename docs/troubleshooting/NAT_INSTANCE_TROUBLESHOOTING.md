# NAT Instance 트러블슈팅 가이드

## 문서 정보

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-02-26 |
| 대상 | Private Subnet 인터넷 접근 구성 중 발생한 이슈 |
| 환경 | Dev (Private Subnet EC2 → 인터넷) |

---

## 목차

1. [VPN 서버 NAT via VPC Peering 실패 (Edge-to-Edge 제한)](#1-vpn-서버-nat-via-vpc-peering-실패-edge-to-edge-제한)
2. [VPN 서버까지 패킷 미도달 확인](#2-vpn-서버까지-패킷-미도달-확인)
3. [Dev ↔ Management VPC 간 ping 실패](#3-dev--management-vpc-간-ping-실패)
4. [AWS_PROFILE 미설정으로 Terraform DynamoDB Lock 오류](#4-aws_profile-미설정으로-terraform-dynamodb-lock-오류)
5. [ASG 헬스체크 인스턴스 교체 사이클](#5-asg-헬스체크-인스턴스-교체-사이클)

---

## 1. VPN 서버 NAT via VPC Peering 실패 (Edge-to-Edge 제한)

### 증상

Private Subnet EC2에서 인터넷 접근 불가. VPC Peering 경유로 Management VPC의 VPN 서버를 NAT Instance로 사용하려 했으나 실패.

```bash
# Dev EC2에서 실행
$ curl -s --max-time 10 https://google.com
# → Connection timed out

$ curl -s --max-time 10 https://988319239270.dkr.ecr.ap-northeast-2.amazonaws.com/
# → Connection timed out
```

### 구성

```
Dev EC2 (10.0.20.174, Private Subnet)
  → Route: 0.0.0.0/0 → VPC Peering (pcx-0f57e5fe71ee6c565)
  → Management VPC의 VPN 서버에서 MASQUERADE → IGW → 인터넷
```

VPN 서버 iptables에는 규칙이 존재했으나 0 packets:
```
# iptables -L FORWARD -n -v
16  0  0  ACCEPT  0  --  *  ens5  10.0.0.0/16  0.0.0.0/0

# iptables -t nat -L POSTROUTING -n -v
3   0  0  MASQUERADE  0  --  *  ens5  10.0.0.0/16  0.0.0.0/0
```

### 원인

**AWS Edge-to-Edge 라우팅 제한.** VPC Peering을 통해 들어온 트래픽은 다른 게이트웨이(IGW, NAT Gateway, VPN Gateway 등)로 전달할 수 없다.

```
Dev EC2 → VPC Peering → Management VPC 도착
  → Management VPC Route: 0.0.0.0/0 → IGW
  → AWS 차단! (VPC Peering → IGW = Edge-to-Edge)
  → 패킷 드롭 (VPN 서버까지 도달하지 못함)
```

AWS 공식 문서: "Edge to edge routing through a gateway or private virtual interface is not supported."

이것은 AWS 네트워크 레벨의 제한으로, iptables 설정과 무관하게 패킷 자체가 차단된다.

### 혼동 포인트: VPN SSH는 왜 되는가?

VPN SSH 접속은 다른 경로를 사용하기 때문:

```
VPN SSH (작동):
  VPN 클라이언트 → WireGuard 터널 → VPN 서버 (10.2.1.76)
  → MASQUERADE (src = 10.2.1.76, Management VPC IP)
  → VPC Peering → Dev EC2
  → 응답: Dev EC2 → 10.2.1.76 (Management VPC CIDR) → VPC Peering → VPN 서버

인터넷 접근 (실패):
  Dev EC2 → 8.8.8.8 → VPC Peering → Management VPC
  → 8.8.8.8은 VPC 외부 IP → IGW 필요 → Edge-to-Edge 차단
```

핵심 차이: VPN SSH는 목적지가 Management VPC CIDR 내 IP(10.2.1.76)이므로 VPC Peering이 정상 처리. 인터넷 접근은 목적지가 VPC 외부 IP이므로 IGW가 필요하지만 Edge-to-Edge로 차단.

### 해결

VPC Peering 경유 NAT 방식을 포기하고, **Dev VPC 내에 NAT Instance(t3.nano)를 배치**.

```hcl
# 라우트 테이블 변경
route {
  cidr_block           = "0.0.0.0/0"
  network_interface_id = aws_instance.nat.primary_network_interface_id  # VPC Peering 대신 NAT Instance
}
```

---

## 2. VPN 서버까지 패킷 미도달 확인

### 증상

VPN 서버의 iptables FORWARD 규칙에 Dev VPC용 규칙이 있지만, 패킷 카운터가 항상 0.

```bash
# VPN 서버에서 확인
$ sudo iptables -L FORWARD -n -v --line-numbers
16  0  0  ACCEPT  0  --  *  ens5  10.0.0.0/16  0.0.0.0/0   # ← 0 packets!
```

### 원인

Edge-to-Edge 제한으로 패킷이 Management VPC에 도착하더라도 VPN 서버의 ENI까지 전달되지 않는다. AWS 네트워크 레벨에서 드롭되므로 iptables에 도달하지 않아 카운터가 0.

### 확인 방법

```bash
# Dev EC2에서 VPN 서버로 TCP 테스트 (VPC Peering 내부 통신)
$ nc -zv -w 5 10.2.1.76 22
Connection to 10.2.1.76 22 port [tcp/ssh] succeeded!  # ← VPC Peering 내부 = 성공

# Dev EC2에서 인터넷 테스트 (VPC Peering → IGW 필요)
$ curl -s --max-time 10 https://google.com
# → 타임아웃  # ← Edge-to-Edge = 실패
```

VPC Peering 내부 통신(10.2.0.0/16)은 정상, 외부 인터넷만 불가 → Edge-to-Edge 확정.

---

## 3. Dev ↔ Management VPC 간 ping 실패

### 증상

Dev EC2에서 VPN 서버(10.2.1.76)로 ping이 실패했고, VPN 서버에서 Dev EC2(10.0.20.174)로 ping도 실패.

```bash
# Dev → VPN 서버
$ ping -c 2 10.2.1.76
2 packets transmitted, 0 received, 100% packet loss

# VPN → Dev
$ ping -c 2 10.0.20.174
2 packets transmitted, 0 received, 100% packet loss
```

### 원인

**Security Group에 ICMP 규칙이 없었다.** 양쪽 SG 모두 TCP 포트만 허용하고 ICMP(ping)는 허용하지 않았다.

- Dev SG: port 22(SSH), port 8080(ALB) 만 인바운드 허용
- VPN SG: 10.0.0.0/16에 대해 all protocol 허용 → 이쪽은 OK

Dev SG에서 ICMP 인바운드가 없어서 VPN → Dev ping이 실패. Dev → VPN은 VPN SG가 all protocol이므로 요청은 도달하지만, Dev SG의 stateful 특성상 응답은 허용됐어야 하는데... 실제로는 연결 추적이 안 됐을 수 있음.

### 해결

ping 테스트 대신 **TCP 테스트(nc)로 전환**하여 VPC Peering 연결을 검증.

```bash
# TCP로 확인 (ping 대신)
$ nc -zv -w 5 10.2.1.76 22
Connection succeeded!  # VPC Peering 정상 확인
```

> 참고: ping이 필요하면 SG에 ICMP 규칙을 추가하면 되지만, 보안 정책상 불필요하므로 추가하지 않았다.

---

## 4. AWS_PROFILE 미설정으로 Terraform DynamoDB Lock 오류

### 증상

```
Error: Error acquiring the state lock
ResourceNotFoundException: Requested resource not found
Unable to retrieve item from DynamoDB table "billage-terraform-lock-dev"
```

### 원인

`AWS_PROFILE` 환경변수가 설정되지 않아 Terraform이 **default 프로필**(개인 계정)로 실행됨. 개인 계정에는 `billage-terraform-lock-dev` DynamoDB 테이블이 없다.

```bash
# 확인
$ echo $AWS_PROFILE
(비어있음)

# billage 프로필로 테이블 존재 확인
$ aws dynamodb list-tables --profile billage
{
    "TableNames": [
        "billage-terraform-lock-dev",    # ← 있음!
        "billage-terraform-lock-management",
        "billage-terraform-lock-prod"
    ]
}
```

### 해결

```bash
export AWS_PROFILE=billage
terraform apply -var 'golden_ami_id=ami-01488502d83cfffa4'
```

### 예방

Terraform 실행 전 항상 프로필 확인:
```bash
# 현재 프로필 확인
echo $AWS_PROFILE
aws sts get-caller-identity

# 프로필 설정
export AWS_PROFILE=billage
```

---

## 5. ASG 헬스체크 인스턴스 교체 사이클

### 증상

ASG의 desired=1, min=1, max=1인데 실제 EC2가 2~3대씩 떠 있었다.

```
$ aws autoscaling describe-auto-scaling-groups ...
BE ASG: Count=3, Desired=1  (2대 Terminating)
FE ASG: Count=2, Desired=1  (1대 Terminating)
AI ASG: Count=2, Desired=1  (1대 Terminating)
```

### 원인

ECR에 Docker 이미지가 아직 Push되지 않은 상태에서:
1. EC2 부팅 → user_data 실행 → `docker pull` 실패 (이미지 없음)
2. 컨테이너 미실행 → ALB Health Check 실패
3. ASG가 인스턴스를 Unhealthy로 마킹
4. ReplaceUnhealthy 프로세스가 새 인스턴스 생성
5. 새 인스턴스도 동일하게 실패 → 반복

### 해결

콘솔에서 ASG의 `ReplaceUnhealthy`, `HealthCheck` 프로세스를 일시 중지:

**EC2 > Auto Scaling Groups > ASG 선택 > Details > Advanced configurations > Edit > Suspended processes**

또는 CLI:
```bash
aws autoscaling suspend-processes \
  --auto-scaling-group-name billage-dev-v2-be-asg \
  --scaling-processes ReplaceUnhealthy HealthCheck
```

> 주의: Terraform 코드에 suspend 설정이 없으므로, `terraform apply` 시 suspended_processes가 해제된다.
> ECR에 이미지를 Push한 후에 다시 활성화하면 정상 동작한다.

### 근본 해결

ECR에 Docker 이미지를 Push하면 Health Check가 통과하면서 자연 해소:
```bash
# GitHub Actions CI/CD로 이미지 Push 후
# 또는 수동:
docker build -t 988319239270.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest .
docker push 988319239270.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest

# Instance Refresh 트리거
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-dev-v2-be-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage": 0}'
```