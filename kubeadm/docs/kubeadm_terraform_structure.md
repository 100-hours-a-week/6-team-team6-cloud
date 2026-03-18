# kubeadm/envs/prod Terraform 구조 가이드

## 근본 목적

kubeadm self-managed Kubernetes 클러스터를 구성하는 Terraform 파일과 템플릿의 역할, 상호 관계, 현재 상태를 정리한다.

## 비목적

- Terraform 사용법이나 HCL 문법을 처음부터 설명하지 않는다.
- 개별 리소스의 AWS API 명세를 중복 기술하지 않는다.

---

## 전체 디렉토리 구조

```
kubeadm/envs/prod/
├── backend.tf                        # S3 원격 상태 백엔드 설정
├── providers.tf                      # AWS 프로바이더 버전 고정
├── versions.tf                       # Terraform 버전 제약
├── variables.tf                      # 모든 입력 변수 선언
├── main.tf                           # 모듈 조합 + SSM Document 생성
├── outputs.tf                        # 외부에서 참조할 출력값
├── terraform.tfvars.example          # tfvars 작성 가이드 (실제 값 아님)
│
├── modules/
│   ├── network/main.tf               # VPC, 서브넷, 라우팅
│   ├── iam/main.tf                   # IAM Role, Instance Profile, Policy
│   ├── security/main.tf              # Security Group 4종
│   ├── compute/main.tf               # EC2 인스턴스 10대 생성
│   └── api-endpoint/main.tf          # Internal NLB + Route53 private zone
│
└── templates/                        # EC2 user_data / SSM 스크립트 템플릿
    ├── bootstrap-common.sh.tftpl
    ├── cloud-init-control-plane-init.yaml.tftpl
    ├── cloud-init-control-plane-join.yaml.tftpl
    ├── cloud-init-worker-join.yaml.tftpl
    ├── kubeadm-init-config.yaml.tftpl
    ├── kubeadm-join-control-plane-config.yaml.tftpl
    ├── kubeadm-join-worker-config.yaml.tftpl
    ├── ssm-control-plane-init.sh.tftpl
    ├── ssm-control-plane-join.sh.tftpl
    ├── ssm-worker-join.sh.tftpl
    ├── ssm-write-join-env.sh.tftpl
    └── ssm-platform-bootstrap.sh.tftpl
```

---

## 루트 Terraform 파일

### `backend.tf`
```
S3 버킷: billage-terraform-state-prod
키:      kubeadm/envs/prod/terraform.tfstate
락:      DynamoDB billage-terraform-lock-prod
```
- `terraform apply` 전 S3 버킷과 DynamoDB 테이블이 수동으로 먼저 생성되어 있어야 한다.
- `terraform init` 시 이 백엔드에 연결된다.

---

### `variables.tf`
모든 입력 변수를 선언한다. 주요 변수:

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `vpc_cidr` | 없음 | 전용 VPC CIDR (/16 권장) |
| `private_dns_zone_name` | `"village.internal"` | 클러스터 내부 DNS 존 — apply 후 변경 불가 |
| `kube_apiserver_record_name` | `"k8s-api"` | DNS 레코드 이름 (결과: `k8s-api.village.internal`) |
| `availability_zones` | 없음 | 3개 AZ 목록 |
| `kubernetes_version` | `"v1.28.0"` | kubeadm/kubelet 버전 |
| `pod_network_cidr` | 없음 | Calico Pod CIDR (VPC/Service와 겹치면 안 됨) |
| `service_cidr` | 없음 | K8s Service CIDR |
| `calico_bgp_as_number` | 없음 | Calico BGP AS 번호 (보통 64512) |
| `alb_certificate_arn` | 없음 | ap-northeast-2 ACM 인증서 ARN |

> `private_dns_zone_name`은 `terraform apply` 후 변경 불가 (kube-apiserver TLS SAN에 포함됨). 현재 `village.internal`로 확정.

---

### `main.tf`
5개 모듈을 조합하고, **SSM Document 1개**를 직접 생성한다.

```
module "network"       → VPC/서브넷/라우팅
module "iam"           → IAM Role/Profile/Policy
module "security"      → Security Group 4종
module "compute"       → EC2 10대 (user_data에 templates/ 주입)
module "api_endpoint"  → Internal NLB + Route53 private zone

resource "aws_ssm_document" "platform_bootstrap"
  → ssm-platform-bootstrap.sh.tftpl을 렌더링해서 SSM Document로 등록
```

**핵심 local 변수:**
```hcl
# Calico CSI hotfix: cp-01의 실제 private IP를 직접 참조
# CNI가 ClusterIP(10.96.0.1)를 쓰면 circular dependency 발생 → 이를 방지
calico_kubernetes_service_host = lookup(
  module.compute.control_plane_private_ips,
  "${var.cluster_name}-cp-01",
  fallback_to_dns  # cp-01 IP 조회 실패 시 DNS fallback
)
```

---

### `outputs.tf`
`terraform output` 명령으로 확인 가능한 값들. runbook에서 변수 export 시 사용:

| output | 용도 |
|--------|------|
| `control_plane_instance_ids` | CP01/02/03 instance ID → SSM 명령 대상 |
| `app_instance_ids` / `data_instance_ids` | worker instance ID |
| `control_plane_private_ips` | cp-01 private IP (Calico hotfix용) |
| `kube_apiserver_fqdn` | `k8s-api.village.internal` |
| `platform_bootstrap_ssm_document_name` | SSM Document 이름 |

---

### `terraform.tfvars.example`
실제 값을 채워야 하는 변수 가이드. `cp terraform.tfvars.example terraform.tfvars` 후 수정한다.

`private_dns_zone_name = "village.internal"`이 설정되어 있다. 이 값이 클러스터 전체에서 사용하는 내부 DNS 존이다.

---

## 모듈별 역할

### `modules/network/main.tf`
**생성 리소스**: VPC 1개, 서브넷 9개, IGW 1개, 라우팅 테이블

```
VPC: var.vpc_cidr (예: 10.30.0.0/16)

서브넷 구조 (AZ당 3종):
  public         /24  — IGW 직접 연결, ALB 배치
  control-plane  /24  — cp-01/02/03 배치, 외부 직접 노출 안 함
  worker         /24  — app/data 노드 배치

라우팅:
  - private 서브넷도 기본 게이트웨이가 IGW (NAT Gateway 없음)
  - 노드가 public IP를 가지고 직접 인터넷 통신
  - source_dest_check=false (Calico BGP 라우팅을 위해 필수)
```

서브넷 태그:
- `kubernetes.io/role/elb = 1` → public (internet-facing ALB)
- `kubernetes.io/role/internal-elb = 1` → worker (internal ALB 후보)

---

### `modules/iam/main.tf`
**생성 리소스**: IAM Role 1개, Instance Profile 1개, Managed Policy 연결 3개, Custom Policy 1개

| 연결 Policy | 용도 |
|-------------|------|
| `AmazonSSMManagedInstanceCore` | SSH 없이 SSM Session Manager / Run Command 사용 |
| `AmazonEC2ContainerRegistryReadOnly` | ECR 이미지 pull |
| `CloudWatchAgentServerPolicy` | 메트릭/로그 수집 |
| Custom `aws-load-balancer-controller` | ALB/NLB 생성·관리 (EC2 instance profile 방식, IRSA 아님) |

> **EBS CSI Driver**: 별도 policy가 없다. EBS CSI는 `04-platform.md Step 4-3`에서 수동 설치 시 instance profile의 기존 권한으로 동작하거나, 추가 policy 연결이 필요하다.

---

### `modules/security/main.tf`
**생성 리소스**: Security Group 4개

| SG 이름 | 대상 | 주요 규칙 |
|---------|------|-----------|
| `cluster-mesh-sg` | 전체 10대 공통 | self-referencing: 클러스터 노드 간 모든 포트 허용 (Calico BGP, VXLAN 등) |
| `control-plane-sg` | cp-01/02/03 추가 | 6443(kube-apiserver) from VPC+management CIDR, 2379-2380(etcd) self |
| `app-sg` | app-01~04 추가 | 30000-32767(NodePort) from VPC (ALB → ingress-nginx) |
| `data-sg` | data-01~03 추가 | NodePort 없음, egress만 허용 (외부 접근 차단) |

SSH(22)는 `enable_ssh=true`일 때만 열림. 프로덕션은 `false` 권장.

---

### `modules/compute/main.tf`
**생성 리소스**: EC2 인스턴스 10대

노드 구성:
```
control-plane (cp-01/02/03):
  - subnet: control-plane 서브넷 (AZ별 고정)
  - private_ip: 서브넷 CIDR의 .10 고정 (cidrhost 함수)
    예) ap-northeast-2a의 cp 서브넷 10.30.3.0/24 → cp-01 IP = 10.30.3.10
  - SG: cluster-mesh-sg + control-plane-sg
  - IMDSv2 필수, hop_limit=2 (Pod에서 IMDS 접근 허용)

app (app-01~04):
  - subnet: worker 서브넷 (AZ 라운드로빈)
  - SG: cluster-mesh-sg + app-sg
  - taint 없음 (일반 workload 스케줄링 가능)

data (data-01~03):
  - subnet: worker 서브넷 (AZ 라운드로빈)
  - SG: cluster-mesh-sg + data-sg
  - taint: workload-plane=data:NoSchedule (데이터 workload 전용)
```

**user_data 주입 구조** (EC2 시작 시 cloud-init이 자동 실행):
```
cp-01  → cloud-init-control-plane-init.yaml.tftpl
           ├── bootstrap-common.sh.tftpl     (containerd/kubelet/kubeadm 설치)
           ├── ssm-control-plane-init.sh.tftpl  (kubeadm init 스크립트)
           ├── ssm-write-join-env.sh.tftpl   (join env 디코딩 유틸)
           └── kubeadm-init-config.yaml.tftpl   (kubeadm 초기화 설정)

cp-02/03 → cloud-init-control-plane-join.yaml.tftpl
           ├── bootstrap-common.sh.tftpl
           ├── ssm-control-plane-join.sh.tftpl  (kubeadm join --control-plane)
           ├── ssm-write-join-env.sh.tftpl
           └── kubeadm-join-control-plane-config.yaml.tftpl

app/data → cloud-init-worker-join.yaml.tftpl
           ├── bootstrap-common.sh.tftpl
           ├── ssm-worker-join.sh.tftpl      (kubeadm join worker)
           ├── ssm-write-join-env.sh.tftpl
           └── kubeadm-join-worker-config.yaml.tftpl
```

> cloud-init은 EC2 **최초 시작 시에만** 실행된다. 스크립트를 수정해도 이미 떠있는 인스턴스에는 반영 안 됨 — terraform destroy → apply 필요.

---

### `modules/api-endpoint/main.tf`
**생성 리소스**: Internal NLB, Target Group, Listener, Route53 Private Hosted Zone, A 레코드

```
Internal NLB
  └── Target Group (port 6443, TCP)
       ├── cp-01 (6443)
       ├── cp-02 (6443)
       └── cp-03 (6443)

Route53 Private Hosted Zone: village.internal (VPC 내부 전용)
  └── A 레코드 (ALIAS): k8s-api → NLB DNS
      결과: k8s-api.village.internal:6443 → NLB → cp-01~03:6443
```

**self-loop 방지 설계**: control-plane 노드 자신이 NLB를 통해 자신의 kube-apiserver에 접근하면 NLB 헬스체크 타임아웃 등으로 불안정해진다. 이를 방지하기 위해 각 cp 노드의 `/etc/hosts`에 `k8s-api.village.internal → 자신의 private IP`를 등록한다 (cloud-init에서 자동 처리).

---

## templates/ 파일 상세

### cloud-init 계열 (EC2 user_data — EC2 시작 시 1회 실행)

| 파일 | 대상 노드 | 역할 |
|------|----------|------|
| `cloud-init-control-plane-init.yaml.tftpl` | cp-01 | cloud-config 형식. 아래 스크립트들을 `/opt/kubeadm/bin/`에 배치하고 `bootstrap-common.sh`를 즉시 실행 |
| `cloud-init-control-plane-join.yaml.tftpl` | cp-02, cp-03 | 동일 구조. `control-plane-join.sh` 배치 (join은 SSM으로 수동 실행) |
| `cloud-init-worker-join.yaml.tftpl` | app-01~04, data-01~03 | 동일 구조. `worker-join.sh` 배치 (join은 SSM으로 수동 실행) |

**cloud-init이 배치하는 파일 경로**: `/opt/kubeadm/bin/`
- `bootstrap-common.sh` — 모든 노드에 존재 (**cloud-init check 시 이 파일로 확인**)
- `control-plane-init.sh` — cp-01에만 존재
- `control-plane-join.sh` — cp-02/03에만 존재
- `worker-join.sh` — app/data 노드에만 존재
- `write-join-env.sh` — 모든 노드에 존재

---

### bootstrap-common.sh.tftpl
모든 10대 노드에서 cloud-init이 **즉시 실행**하는 공통 설치 스크립트.

실행 내용:
1. swap 비활성화 (`/etc/fstab` 영구 처리)
2. kernel 모듈 로드: `overlay`, `br_netfilter`
3. sysctl 설정: `ip_forward`, `bridge-nf-call-iptables`
4. containerd 설치 및 설정 (`SystemdCgroup = true`)
5. kubeadm / kubelet / kubectl 설치 (`kubernetes_minor_version` 기반)
6. kubelet 활성화 (start는 kubeadm이 담당)

---

### ssm-control-plane-init.sh.tftpl
cp-01에서 `kubeadm init`을 실행하는 스크립트. **SSM RunShellScript로 수동 트리거** (cloud-init이 자동 실행하지 않음).

실행 내용:
1. `/etc/hosts`에 `k8s-api.village.internal → 자신의 private IP` 등록 (NLB self-loop 방지)
2. `kubeadm init --config kubeadm-init-config.yaml` 실행
3. kubeconfig 설정 (`~root/.kube/config`)
4. join 재료(token, CA hash, certificate key) 추출 → `/opt/kubeadm/rendered/cluster-join.env`에 저장

---

### ssm-control-plane-join.sh.tftpl
cp-02/03에서 실행. **SSM RunShellScript로 수동 트리거**.

실행 내용:
1. `/etc/hosts`에 self-IP 등록
2. `cluster-join.env`를 읽어 `kubeadm join --control-plane` 실행

---

### ssm-worker-join.sh.tftpl
app/data 노드에서 실행. **SSM RunShellScript로 수동 트리거**.

실행 내용:
1. `cluster-join.env`를 읽어 `kubeadm join` 실행 (worker 모드)

---

### ssm-write-join-env.sh.tftpl
모든 노드에 배치되는 유틸리티 스크립트.

역할: `JOIN_ENV_B64` 환경변수(base64 인코딩된 join 재료)를 디코딩해서 `/opt/kubeadm/rendered/cluster-join.env`에 저장.

```bash
# 사용 패턴 (runbook 03-node-join.md)
export JOIN_ENV_B64=<base64_string>
/opt/kubeadm/bin/write-join-env.sh
/opt/kubeadm/bin/control-plane-join.sh /opt/kubeadm/rendered/cluster-join.env
```

---

### kubeadm-init-config.yaml.tftpl
`kubeadm init`에 전달되는 설정 파일 템플릿.

주요 설정:
```yaml
controlPlaneEndpoint: "k8s-api.village.internal:6443"  # NLB endpoint
podSubnet: 192.168.0.0/16                               # Calico Pod CIDR
serviceSubnet: 10.96.0.0/12
certSANs:
  - k8s-api.village.internal
  - <cp-01 private IP>
nodeRegistration:
  kubeletExtraArgs:
    node-labels: "node-group=control-plane,workload-plane=control-plane"
```

---

### kubeadm-join-control-plane-config.yaml.tftpl / kubeadm-join-worker-config.yaml.tftpl
cp-02/03 및 worker의 `kubeadm join` 설정 파일 템플릿.

- `controlPlane.localAPIEndpoint`에 각 노드의 private IP 설정
- worker 설정에 `node-labels`, `node-taints` 주입

---

### ssm-platform-bootstrap.sh.tftpl ⭐ 핵심 파일
10대 노드 join 완료 후 **SSM Document로 등록**되어 실행되는 플랫폼 부트스트랩 스크립트.

`terraform apply` 시 이 파일이 렌더링되어 `aws_ssm_document.platform_bootstrap` 리소스로 AWS에 업로드된다.

**실행 순서:**
```
1. kube-apiserver 응답 대기
2. 10대 노드 join 대기
3. etcd 안정화 대기 (wait_for_local_control_plane_stability)
4. Helm 설치
5. 노드 라벨/taint 조정 (reconcile_node_placement)
6. Calico CNI 설치
   ├── KUBERNETES_SERVICE_HOST=<cp-01 private IP> 주입 (CSI hotfix)
   ├── calico-typha env 패치
   ├── csi-node-driver env 패치
   └── rollout 완료 대기
7. 노드 Ready 대기
8. 네임스페이스/RBAC 적용 (billage-app, billage-data, billage-edge, billage-ops)
9. cert-manager 설치
10. ingress-nginx 설치
11. aws-load-balancer-controller 설치
12. edge 리소스 생성 (ClusterIssuer, Certificate, ALB Ingress, smoke service)
13. NetworkPolicy 적용 (default-deny + whitelist 14개)
```

> **변경 시 주의**: 이 파일을 수정하면 `terraform apply`로 SSM Document를 업데이트해야 반영된다. EC2는 재생성되지 않는다.

---

## 파일 변경 → 반영 방법 정리

| 수정 파일 | 반영 방법 | EC2 재생성 여부 |
|-----------|-----------|----------------|
| `ssm-platform-bootstrap.sh.tftpl` | `terraform apply` (SSM Document 업데이트) | ❌ 불필요 |
| `cloud-init-*.yaml.tftpl` | `terraform destroy → apply` | ✅ 필요 |
| `bootstrap-common.sh.tftpl` | `terraform destroy → apply` | ✅ 필요 |
| `ssm-control-plane-init.sh.tftpl` | `terraform destroy → apply` | ✅ 필요 |
| `ssm-*-join.sh.tftpl` | `terraform destroy → apply` | ✅ 필요 |
| `kubeadm-*-config.yaml.tftpl` | `terraform destroy → apply` | ✅ 필요 |
| `variables.tf` / `main.tf` (SSM 외) | `terraform destroy → apply` | ✅ 필요 (대부분) |

---

## 현재 상태 (2026-03-17 기준)

| 항목 | 상태 | 비고 |
|------|------|------|
| Terraform 코드 | ✅ 커밋 완료 | PR #127 |
| EC2 인프라 | ✅ Live (destroy 안 됨) | 10대 running |
| kubeadm 클러스터 | ✅ 10/10 Ready | |
| Calico | 🔶 설치됨, 간헐적 불안정 | csi-node-driver hotfix 라이브 적용됨 |
| SSM Document | ⚠️ 구버전 (hotfix 미반영) | `terraform apply` 실행 전 |
| billage-* 네임스페이스 | ❌ 미적용 | 04-platform.md 미실행 |
| ingress-nginx / cert-manager | ❌ 미적용 | |
| EBS CSI + StorageClass | ❌ 미적용 | |

### 다음 작업 선택지

**A. 현 상태 이어서 진행** (클러스터 살려두고):
```bash
cd kubeadm/envs/prod
terraform plan -target=aws_ssm_document.platform_bootstrap  # diff 확인 후
terraform apply -target=aws_ssm_document.platform_bootstrap  # SSM Document 업데이트
# → 04-platform.md Step 1 (SSM Document 실행) 진행
```

**B. 완전 재구축** (학습 목적, 권장):
```bash
cd kubeadm/envs/prod
terraform destroy
# terraform.tfvars 확인 후 (private_dns_zone_name = "village.internal")
terraform apply
# → runbook 00-prereqs → 01-terraform → 02 → 03 → 04 → 05 순서대로
```