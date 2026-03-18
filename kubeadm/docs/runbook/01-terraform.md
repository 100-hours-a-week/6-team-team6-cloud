# 01. Terraform Apply 및 Output 수집

이 문서에서는 `terraform.tfvars`를 작성하고, `terraform apply`로 인프라를 생성한 뒤, 이후 단계에서 사용할 변수들을 추출한다.

---

## 근본 목적

- 클러스터 기반 인프라를 한 번에 재현 가능하게 생성하고, 이후 SSM/bootstrap 단계에서 필요한 식별자를 표준 변수로 고정한다.
- 다음 단계 문서가 같은 출력값을 재사용하도록 연결해 수동 조회 실수를 줄인다.

## 비목적

- Terraform 모듈 내부 구현을 여기서 상세 해설하지 않는다.
- 이후 kubeadm 초기화나 플랫폼 애드온 설치 절차를 이 문서 안에 섞지 않는다.

---

## Step 1. terraform.tfvars 작성

```bash
cd kubeadm/envs/prod
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`를 열어 아래 변수를 실제 값으로 채운다.

```hcl
# 전용 VPC CIDR — 기존 VPC와 겹치지 않는 /16 블록
vpc_cidr = "10.30.0.0/16"

# Management VPC CIDR (bastion, CI/CD 서버 등에서 접근 허용할 범위)
management_cidrs = [
  "10.2.0.0/16",
]

# SSH 접근 (프로덕션은 SSM만 사용하므로 disable 권장)
enable_ssh        = false
ssh_allowed_cidrs = []
key_name          = null

# Private DNS 설정 (기본값 유지 권장)
private_dns_zone_name      = "billage.internal"
kube_apiserver_record_name = "k8s-api"

# 공개 도메인 — ALB CNAME을 등록할 대상
public_edge_host = "api.billages.com"

# cert-manager ACME 등록 이메일
cert_manager_email = "platform@billages.com"

# ACM 인증서 ARN (ap-northeast-2 리전, 00-prereqs.md에서 발급)
alb_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"

# Kubernetes 버전 (기본값 유지 권장)
kubernetes_version       = "v1.28.0"
kubernetes_minor_version = "v1.28"
pod_network_cidr         = "192.168.0.0/16"
service_cidr             = "10.96.0.0/12"
cluster_dns_ip           = "10.96.0.10"

# cert-manager ACME 서버 (기본값: Let's Encrypt production)
cert_manager_acme_server = "https://acme-v02.api.letsencrypt.org/directory"

# Calico 버전 및 BGP AS 번호
calico_version       = "v3.31.0"
calico_bgp_as_number = 64512
```

> **주의**: `pod_network_cidr`는 `vpc_cidr`, `service_cidr`와 겹치지 않아야 한다.
> 기본 구성(`192.168.0.0/16`, `10.96.0.0/12`, `10.30.0.0/16`)은 서로 겹치지 않는다.

---

## Step 2. Terraform Init / Plan / Apply

```bash
cd kubeadm/envs/prod

# 백엔드 초기화 및 프로바이더 설치
terraform init

# 구문 및 참조 검증
terraform validate

# 실행 계획 저장
terraform plan -out=tfplan

# 인프라 생성 (~8-12분)
terraform apply tfplan
```

**생성되는 주요 리소스**

| 리소스 | 수량 |
|--------|------|
| EC2 인스턴스 | 10대 (cp×3, app×4, data×3) |
| VPC / 서브넷 / 라우팅 | 1 VPC, 9 서브넷 (3 AZ × public/cp/worker) |
| IGW | 1 |
| Internal NLB | 1 |
| Route53 Private Hosted Zone + Record | 1 Zone, 1 Record |
| IAM Role / Instance Profile | 1 |
| Security Group | 4 (mesh, cp, app, data) |
| SSM Document | 1 (`{cluster_name}-platform-bootstrap`) |

---

## Step 3. Terraform Output 수집 및 변수 Export

> **중요**: 아래 export 블록은 **이후 모든 단계(02~05)에서 재사용**한다.
> 새 터미널 세션을 열 때마다 이 블록을 다시 실행해야 한다.

```bash
cd kubeadm/envs/prod

# 인스턴스 ID 변수 설정
# cluster_name 확인 (terraform.tfvars에서 직접 확인하거나 아래 명령 사용)
CLUSTER_NAME=$(terraform output -raw platform_bootstrap_ssm_document_name | sed 's/-platform-bootstrap//')
echo "CLUSTER_NAME=$CLUSTER_NAME"

CP01=$(terraform output -json control_plane_instance_ids | jq -r --arg n "${CLUSTER_NAME}-cp-01" '.[$n]')
CP02=$(terraform output -json control_plane_instance_ids | jq -r --arg n "${CLUSTER_NAME}-cp-02" '.[$n]')
CP03=$(terraform output -json control_plane_instance_ids | jq -r --arg n "${CLUSTER_NAME}-cp-03" '.[$n]')

APP_NODES=$(terraform output -json app_instance_ids | jq -r 'values[]' | tr '\n' ' ' | xargs)
DATA_NODES=$(terraform output -json data_instance_ids | jq -r 'values[]' | tr '\n' ' ' | xargs)

SSM_DOC=$(terraform output -raw platform_bootstrap_ssm_document_name)

# 확인 출력
echo "CP01=$CP01"
echo "CP02=$CP02"
echo "CP03=$CP03"
echo "APP_NODES=$APP_NODES"
echo "DATA_NODES=$DATA_NODES"
echo "SSM_DOC=$SSM_DOC"
```

기대 출력 예시:
```
CLUSTER_NAME=billage-kubeadm-prod
CP01=i-0a1b2c3d4e5f60001
CP02=i-0a1b2c3d4e5f60002
CP03=i-0a1b2c3d4e5f60003
APP_NODES=i-0a1b2c3d4e5f60004 i-0a1b2c3d4e5f60005 i-0a1b2c3d4e5f60006 i-0a1b2c3d4e5f60007
DATA_NODES=i-0a1b2c3d4e5f60008 i-0a1b2c3d4e5f60009 i-0a1b2c3d4e5f60010
SSM_DOC=billage-kubeadm-prod-platform-bootstrap
```

> 변수가 비어있으면 `terraform output -json control_plane_instance_ids`로 키 이름을 직접 확인한다.

---

## 성공 확인

```bash
# EC2 인스턴스 상태 확인
aws ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,State:State.Name,ID:InstanceId}" \
  --output table \
  --region ap-northeast-2
```

기대값: 10대 모두 `running` 상태

---

다음: [02-cp-init.md](./02-cp-init.md)
