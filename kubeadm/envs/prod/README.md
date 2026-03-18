# kubeadm prod stack

## 근본 목적
`kubeadm/envs/prod`는 AWS 위에 kubeadm 기반 프로덕션 클러스터를 올리고, Pod가 실제로 스케줄링될 수 있는 최소 플랫폼 자산까지 한 번에 준비하기 위한 루트 스택이다.

## 비목적
이 문서는 애플리케이션 배포 런북이나 장기 운영 절차 전체를 설명하지 않는다. 여기서는 인프라, kubeadm bootstrap, CNI, 기본 네임스페이스/RBAC/NetworkPolicy, edge 진입점까지의 실행 순서만 다룬다.

## Apply 전제조건
- AWS 자격 증명이 준비되어 있어야 한다.
  - VPC, Subnet, Route Table, Internet Gateway, EC2, IAM Role/Instance Profile, NLB, Route53 Private Hosted Zone 생성 권한이 필요하다.
- Remote backend가 먼저 준비되어 있어야 한다.
  - S3 bucket: `billage-terraform-state-prod`
  - DynamoDB table: `billage-terraform-lock-prod`
- `terraform.tfvars` 또는 동등한 변수 주입으로 아래 값이 준비되어 있어야 한다.
  - `vpc_cidr`
  - `management_cidrs`
  - `public_edge_host`
  - `cert_manager_email`
  - `alb_certificate_arn`
  - `enable_ssh = true`인 경우 `key_name`, `ssh_allowed_cidrs`
- 선택한 `vpc_cidr`는 기존 VPC와 겹치지 않아야 한다.
- 지정한 3개 AZ에서 아래 자원 할당이 가능해야 한다.
  - control-plane 3대
  - app node 4대
  - data node 3대
  - internal NLB 1개
- 이 스택은 NAT Gateway 대신 node public IP + SG 제한으로 outbound bootstrap egress를 확보한다.
  - kube-apiserver endpoint는 여전히 internal NLB + private DNS만 사용한다.
- app nodes는 edge/ops workload가 landing 할 기본 풀이다.
  - data nodes만 `workload-plane=data:NoSchedule` taint를 가진다.
- `public_edge_host`는 이후 ALB hostname으로 수동 또는 별도 DNS 자동화로 연결되어야 한다.
  - DNS가 연결되기 전에는 cert-manager `Certificate`가 `Ready`가 되지 않는다.

## 포함 범위
- 전용 VPC, public/control-plane/worker subnet, IGW 기반 egress, IAM instance profile, kube-apiserver용 internal NLB + private DNS
- kubeadm `init/join`용 `cloud-init`, `kubeadm` config template, SSM 실행 스크립트
- Calico 설치 및 node-to-node BGP mesh 기본값
- 노드 라벨링과 data pool taint 재조정
- `billage-app`, `billage-data`, `billage-edge`, `billage-ops` 네임스페이스
- 네임스페이스별 서비스 어카운트/RBAC
- default-deny + whitelist 기반 기본 NetworkPolicy
- `ingress-nginx`, `aws-load-balancer-controller`, `cert-manager`
- `ALB(ACM TLS) -> ingress-nginx(NodePort) -> billage-edge smoke service` 경로

## Bootstrap 흐름
1. `terraform apply`로 EC2 10대와 기반 인프라를 만든다.
2. `cp-01`에서 `/opt/kubeadm/bin/control-plane-init.sh`를 실행한다.
   - `kubeadm init --config /opt/kubeadm/templates/kubeadm-init.yaml`
   - `/opt/kubeadm/rendered/cluster-join.env` 생성
   - 이후 `cp-01`은 `/etc/hosts`에 `k8s-api.village.internal -> 자신의 private IP`를 유지한다.
3. `cp-02`, `cp-03`에 `cluster-join.env`를 전달하고 `/opt/kubeadm/bin/control-plane-join.sh`를 실행한다.
   - join 스크립트는 각 control-plane 노드에서 `k8s-api.village.internal -> 자신의 private IP`를 `/etc/hosts`에 유지한다.
4. app/data worker에 `cluster-join.env`를 전달하고 `/opt/kubeadm/bin/worker-join.sh`를 실행한다.
5. 모든 노드가 join된 뒤 Terraform이 만든 SSM Document `billage-kubeadm-prod-platform-bootstrap`을 `cp-01`에 실행한다.
   - Calico 설치
   - 노드 라벨/taint 보정
   - 네임스페이스/RBAC/NetworkPolicy 적용
   - `cert-manager`, `ingress-nginx`, `aws-load-balancer-controller` 설치
   - `billage-edge` smoke service와 public ALB ingress 생성
6. `ingress-nginx-public-alb`의 hostname을 확인하고 `public_edge_host`를 그 ALB로 연결한다.
7. DNS 전파 후 `kubectl get certificate -n billage-edge`와 `kubectl get ingress -n ingress-nginx`로 edge 경로를 확인한다.

## 템플릿 파일 요약
- `bootstrap-common.sh.tftpl`: containerd, kubelet, kubeadm, kubectl, sysctl, swap, 커널 모듈 준비
- `cloud-init-control-plane-init.yaml.tftpl`: `cp-01`에 init/bootstrap 스크립트 배치
- `cloud-init-control-plane-join.yaml.tftpl`: 추가 control-plane join 스크립트 배치
- `cloud-init-worker-join.yaml.tftpl`: worker join 스크립트 배치
- `kubeadm-init-config.yaml.tftpl`: `InitConfiguration`, `ClusterConfiguration`, `KubeletConfiguration`, taint 지원
- `kubeadm-join-control-plane-config.yaml.tftpl`: 추가 control-plane용 `JoinConfiguration`, taint 지원
- `kubeadm-join-worker-config.yaml.tftpl`: worker용 `JoinConfiguration`, taint 지원
- `ssm-control-plane-init.sh.tftpl`: init 실행과 join artifact 생성
- `ssm-control-plane-join.sh.tftpl`: control-plane join config 렌더링 및 join 실행
- `ssm-worker-join.sh.tftpl`: worker join config 렌더링 및 join 실행
- `ssm-write-join-env.sh.tftpl`: base64 또는 plain text join env 기록
- `ssm-platform-bootstrap.sh.tftpl`: SSM Document 본문으로 들어가는 플랫폼 부트스트랩 스크립트

## 실행 예시

```bash
# 1) cp-01 초기화
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "i-controlplane01" \
  --parameters 'commands=["/opt/kubeadm/bin/control-plane-init.sh"]'

# 2) join env 추출
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "i-controlplane01" \
  --parameters 'commands=["cat /opt/kubeadm/rendered/cluster-join.env"]'

# 3) 추가 control-plane / worker join
JOIN_ENV_B64="$(base64 -w0 cluster-join.env)"

aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "i-controlplane02" "i-controlplane03" \
  --parameters "commands=[
    \"export JOIN_ENV_B64=${JOIN_ENV_B64}\",
    \"/opt/kubeadm/bin/write-join-env.sh\",
    \"/opt/kubeadm/bin/control-plane-join.sh /opt/kubeadm/rendered/cluster-join.env\"
  ]"

aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "i-app01" "i-app02" "i-app03" "i-app04" "i-data01" "i-data02" "i-data03" \
  --parameters "commands=[
    \"export JOIN_ENV_B64=${JOIN_ENV_B64}\",
    \"/opt/kubeadm/bin/write-join-env.sh\",
    \"/opt/kubeadm/bin/worker-join.sh /opt/kubeadm/rendered/cluster-join.env\"
  ]"

# 4) 플랫폼 자산 적용
aws ssm send-command \
  --document-name "billage-kubeadm-prod-platform-bootstrap" \
  --instance-ids "i-controlplane01"
```

## 검증 포인트
- `kubectl get nodes -L node-group,workload-plane`
  - control-plane 3, app 4, data 3이 모두 보여야 한다.
- `kubectl get pods -n calico-system`
  - `calico-node`, `calico-kube-controllers`가 정상이어야 한다.
- `kubectl get ns billage-app billage-data billage-edge billage-ops`
- `kubectl get networkpolicy -A`
- `kubectl get ingress -n ingress-nginx ingress-nginx-public-alb`
- `kubectl get certificate -n billage-edge`
- `kubectl get svc -n billage-edge edge-smoketest`

## 주의사항
- control-plane 노드는 `k8s-api.village.internal`을 로컬 private IP로 우선 해석하도록 설계한다.
  - 목적은 kubelet/admin kubeconfig가 자기 자신까지 NLB를 경유하는 self-dependency를 피하는 것이다.
- `platform-bootstrap.sh`는 cluster add-on 설치와 기본 정책 적용을 함께 수행한다. cert-manager `Certificate`는 DNS가 연결되기 전까지 pending일 수 있다.
- 외부 TLS는 ALB의 ACM certificate로 종료되고, cert-manager는 nginx ingress용 cluster certificate 자산을 관리한다.
- `aws-load-balancer-controller`는 IRSA가 아니라 노드 instance profile을 사용한다. 그래서 현재 스택은 노드 IAM role에 공식 controller 정책을 추가한다.
