# 00. 사전 조건 체크리스트

이 문서는 `kubeadm/envs/prod` 스택으로 쿠버네티스 클러스터를 구축하기 전에 반드시 완료해야 하는 사전 조건을 정리한다.

---

## 근본 목적

- 인프라 생성 전에 권한, backend 리소스, 인증서, 도구 버전을 먼저 고정해 이후 단계의 실패 원인을 환경 누락이 아닌 실제 구축 이슈로 좁힌다.
- apply 중간 실패나 bootstrap 재시도를 줄여 운영 관측 복구와 원인 추적 시간을 단축한다.

## 비목적

- Terraform apply나 kubeadm bootstrap 자체를 이 단계에서 대신 수행하지 않는다.
- 단계 이후에 필요한 변수 export나 join 절차를 미리 설명해 체크리스트의 역할을 흐리지 않는다.

---

## 아키텍처 요약

| 구분 | 대수 | 역할 |
|------|------|------|
| control-plane | 3 | k8s API 서버, etcd, 컨트롤러 |
| app node | 4 | edge/ops workload 기본 풀 |
| data node | 3 | DB/MQ 등 데이터 워크로드 (`workload-plane=data:NoSchedule`) |
| **합계** | **10** | |

**네트워킹 경로**
- kube-apiserver: 전용 VPC + internal NLB + private Route53 (`k8s-api.billage.internal`)
- 외부 진입: internet-facing ALB (ACM TLS) → ingress-nginx (NodePort) → billage-edge
- 클러스터 DNS: `billage.internal` private hosted zone

**부트스트랩 흐름**
```
terraform apply
  → EC2 cloud-init (containerd/kubelet/kubeadm 설치)
  → SSM RunShellScript → control-plane-init.sh (cp-01)
  → SSM RunShellScript → control-plane-join.sh (cp-02, cp-03)
  → SSM RunShellScript → worker-join.sh (app-01~04, data-01~03)
  → SSM Document (platform-bootstrap): Calico, 네임스페이스, RBAC, NetworkPolicy, cert-manager, ingress-nginx, aws-lbc
  → 수동: ingress-nginx replica=2, metrics-server, EBS CSI Driver + gp3 StorageClass (04-platform.md Step 4)
```

---

## 체크리스트

### AWS 자격증명 및 IAM 권한

다음 서비스에 대한 충분한 IAM 권한이 필요하다.

```
EC2           — 인스턴스, 보안 그룹, 키 페어, 볼륨
VPC           — VPC, 서브넷, 라우팅 테이블, IGW
IAM           — Role, InstanceProfile, Policy 생성
NLB           — Network Load Balancer 생성/관리
Route53       — Private Hosted Zone, Record 생성
SSM           — SendCommand, GetCommandInvocation, SSM Document 생성
S3            — 버킷 생성, 객체 읽기/쓰기 (Terraform state)
DynamoDB      — 테이블 생성, 항목 읽기/쓰기 (Terraform lock)
ACM           — 인증서 조회
```

자격증명 확인:
```bash
aws sts get-caller-identity
```

기대 출력 예시:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/platform-admin"
}
```

---

### Terraform Backend 리소스 생성

Terraform remote backend는 apply 전에 수동으로 먼저 만들어야 한다.

```bash
# S3 버킷 생성
aws s3api create-bucket \
  --bucket billage-terraform-state-prod \
  --region ap-northeast-2 \
  --create-bucket-configuration LocationConstraint=ap-northeast-2

# 버전 관리 활성화
aws s3api put-bucket-versioning \
  --bucket billage-terraform-state-prod \
  --versioning-configuration Status=Enabled

# 서버 사이드 암호화 설정
aws s3api put-bucket-encryption \
  --bucket billage-terraform-state-prod \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# DynamoDB 잠금 테이블 생성
aws dynamodb create-table \
  --table-name billage-terraform-lock-prod \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-2
```

생성 확인:
```bash
aws s3api head-bucket --bucket billage-terraform-state-prod
aws dynamodb describe-table --table-name billage-terraform-lock-prod \
  --query "Table.TableStatus" --output text
# 기대값: ACTIVE
```

---

### EBS CSI Driver IAM Role

AWS EBS CSI Driver는 EBS 볼륨을 생성/연결하기 위해 IAM 권한이 필요하다. Terraform이 이 Role을 자동으로 생성하지만, IRSA(IAM Roles for Service Accounts)를 사용하지 않는 kubeadm 환경에서는 EC2 Instance Profile로 연결된다.

Terraform apply 후 아래로 Role ARN을 확인한다:
```bash
terraform -chdir=kubeadm/envs/prod output ebs_csi_controller_role_arn
```

> Role이 output에 없으면 EC2 Instance Profile에 `AmazonEBSCSIDriverPolicy` Managed Policy가 직접 연결되어 있는지 확인한다.

---

### ACM 인증서 발급

`public_edge_host` 도메인에 대한 ACM 인증서가 `ap-northeast-2` 리전에 있어야 한다.
ALB는 같은 리전의 인증서만 사용할 수 있다.

```bash
# 인증서 발급 요청 (도메인 소유 검증 필요)
aws acm request-certificate \
  --domain-name "api.example.com" \
  --validation-method DNS \
  --region ap-northeast-2

# 발급된 인증서 ARN 확인
aws acm list-certificates \
  --region ap-northeast-2 \
  --query "CertificateSummaryList[?DomainName=='api.example.com'].CertificateArn" \
  --output text
```

> **주의**: 인증서 상태가 `ISSUED`여야 한다. DNS 검증을 완료하지 않으면 ALB에 연결할 수 없다.

---

### 도구 버전 확인

```bash
# Terraform v1.5 이상
terraform version
# 기대: Terraform v1.5.x 이상

# AWS CLI v2
aws --version
# 기대: aws-cli/2.x.x

# jq (JSON 처리)
jq --version
# 기대: jq-1.6 이상
```

---

## 사전 조건 확인 완료 후

모든 항목이 충족되면 [01-terraform.md](./01-terraform.md)로 이동한다.
