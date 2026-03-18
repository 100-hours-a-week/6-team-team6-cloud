# 04. 플랫폼 부트스트랩

이 단계에서는 Terraform이 생성한 SSM Document를 cp-01에서 실행해 클러스터 애드온과 기본 정책을 설치한다.

## 근본 목적

- join만 완료된 클러스터를 운영 가능한 플랫폼 상태로 수렴시켜 네트워크, ingress, 인증서, 기본 정책을 한 번에 갖춘다.
- 애드온 설치와 기본 정책 적용을 하나의 표준 SSM 실행으로 묶어 수동 편차를 줄인다.

## 비목적

- 개별 Helm 차트나 YAML 리소스를 여기서 수동 튜닝하는 절차를 기본 흐름으로 삼지 않는다.
- 외부 DNS 등록과 공개 도메인 검증까지 이 단계에서 끝냈다고 가정하지 않는다.

**SSM Document가 수행하는 작업 (순서대로)**:
1. kube-apiserver 응답 대기
2. 10대 노드 join 대기
3. etcd 안정화 대기
4. Helm 설치
5. 노드 라벨 / taint 조정 (`node-group`, `workload-plane`)
6. Calico CNI 설치 (BGP mesh)
7. 노드 Ready 대기
8. 네임스페이스 / RBAC 적용 (`billage-app`, `billage-data`, `billage-edge`, `billage-ops`)
9. cert-manager 설치
10. ingress-nginx 설치
11. aws-load-balancer-controller 설치
12. edge 리소스 생성 (ClusterIssuer, Certificate, ALB Ingress, smoke service)
13. NetworkPolicy 적용

> **전제**: [03-node-join.md](./03-node-join.md) 완료 후 10대 모두 join된 상태여야 한다.
> `$CP01`과 `$SSM_DOC` 변수가 설정되어 있어야 한다.

---

## Step 1. Platform Bootstrap SSM Document 실행

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "$SSM_DOC" \
  --instance-ids "$CP01" \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "Platform Bootstrap Command ID: $CMD_ID"
```

> SSM Document 이름은 `terraform output -raw platform_bootstrap_ssm_document_name`으로 확인한다.
> 직접 지정할 경우 `billage-kubeadm-prod-platform-bootstrap` 형식이다.

---

## Step 2. 진행 상황 모니터링

전체 소요 시간은 **15-25분**이다. 아래 명령으로 10초 간격으로 상태를 확인한다:

```bash
# watch가 설치된 경우 (macOS: brew install watch)
watch -n 10 "aws ssm get-command-invocation \
  --command-id $CMD_ID \
  --instance-id $CP01 \
  --region ap-northeast-2 \
  --query '{Status:Status,Output:StandardOutputContent}' \
  --output text 2>&1 | tail -30"

# watch가 없는 경우 (macOS 기본) — while 루프로 대체
while true; do
  clear
  aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$CP01" \
    --region ap-northeast-2 \
    --query "{Status:Status,Output:StandardOutputContent}" \
    --output text 2>&1 | tail -30
  sleep 10
done
```

또는 한 번씩 수동 확인:
```bash
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "{Status:Status,Output:StandardOutputContent}" \
  --output text
```

**진행 단계별 로그 키워드**:
- `waiting for kube-apiserver` — API 서버 응답 대기 중
- `waiting for 10 joined nodes` — 모든 노드 join 대기 중
- `waiting for local control-plane stability` — etcd 안정화 대기 중
- `+ install_helm` — Helm 설치 시작
- `+ reconcile_node_placement` — 노드 라벨/taint 조정
- `+ apply_calico` — Calico 설치
- `+ apply_foundation_resources` — 네임스페이스/RBAC 적용
- `+ install_cert_manager` — cert-manager 설치
- `+ install_ingress_nginx` — ingress-nginx 설치
- `+ install_aws_load_balancer_controller` — aws-lbc 설치
- `+ apply_edge_resources` — edge 리소스 생성
- `+ apply_network_policies` — NetworkPolicy 적용
- `public ALB hostname:` — 마지막 출력, ALB DNS 확인 가능

---

## Step 3. 설치 완료 확인

SSM 명령 Status가 `Success`가 되면 각 컴포넌트를 확인한다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl get nodes -L node-group,workload-plane",
    "echo ---",
    "kubectl get pods -n calico-system",
    "echo ---",
    "kubectl get pods -n cert-manager",
    "echo ---",
    "kubectl get pods -n ingress-nginx",
    "echo ---",
    "kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "StandardOutputContent" --output text
```

**기대 출력 예시**:

```
NAME                          STATUS   ROLES           NODE-GROUP      WORKLOAD-PLANE
billage-kubeadm-prod-cp-01    Ready    control-plane   control-plane   control-plane
billage-kubeadm-prod-cp-02    Ready    control-plane   control-plane   control-plane
billage-kubeadm-prod-cp-03    Ready    control-plane   control-plane   control-plane
billage-kubeadm-prod-app-01   Ready    <none>          app             app
billage-kubeadm-prod-app-02   Ready    <none>          app             app
billage-kubeadm-prod-app-03   Ready    <none>          app             app
billage-kubeadm-prod-app-04   Ready    <none>          app             app
billage-kubeadm-prod-data-01  Ready    <none>          data            data
billage-kubeadm-prod-data-02  Ready    <none>          data            data
billage-kubeadm-prod-data-03  Ready    <none>          data            data
---
NAME                                       READY   STATUS    RESTARTS
calico-kube-controllers-xxx                1/1     Running   0
calico-node-xxxxx (×10)                    1/1     Running   0
calico-typha-xxx                           1/1     Running   0
---
NAME                                       READY   STATUS    RESTARTS
cert-manager-xxx                           1/1     Running   0
cert-manager-cainjector-xxx               1/1     Running   0
cert-manager-webhook-xxx                  1/1     Running   0
---
NAME                                       READY   STATUS    RESTARTS
ingress-nginx-controller-xxx              1/1     Running   0
---
NAME                                       READY   STATUS    RESTARTS
aws-load-balancer-controller-xxx          1/1     Running   0
```

### 네임스페이스 및 정책 확인

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl get ns billage-app billage-data billage-edge billage-ops",
    "echo ---",
    "kubectl get networkpolicy -A --no-headers | wc -l"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "StandardOutputContent" --output text
```

기대값: 4개 네임스페이스 `Active`, NetworkPolicy 12개 이상

---

---

## Step 4. 수동 추가 설치 (SSM Document 미포함)

SSM Document가 완료된 후 아래 컴포넌트를 추가로 설치해야 한다. 이 단계들은 SSM Document에 포함되어 있지 않으므로 반드시 수동으로 수행한다.

> 아래 명령은 `$CP01` SSM으로 전달하거나, kubeconfig를 로컬로 복사한 뒤 직접 실행해도 된다.

### 4-1. ingress-nginx 고가용성 (replica 2개)

SSM Document는 기본 단일 replica로 설치한다. app 노드 2대에 분산되도록 2개로 스케일한다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl scale deployment ingress-nginx-controller -n ingress-nginx --replicas=2",
    "kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=120s"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP01" \
  --region ap-northeast-2 --query "StandardOutputContent" --output text
```

### 4-2. metrics-server (HPA 필수)

metrics-server가 없으면 `kubectl top`, HPA가 동작하지 않는다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update",
    "helm upgrade --install metrics-server metrics-server/metrics-server \
      --namespace kube-system \
      --set args={--kubelet-insecure-tls} \
      --wait --timeout 120s"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP01" \
  --region ap-northeast-2 --query "StandardOutputContent" --output text
```

> `--kubelet-insecure-tls`는 kubeadm 클러스터에서 kubelet 인증서가 self-signed이기 때문에 필요하다.

확인:
```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["kubectl top nodes"]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP01" \
  --region ap-northeast-2 --query "StandardOutputContent" --output text
```

### 4-3. AWS EBS CSI Driver + gp3 StorageClass (StatefulSet PVC 필수)

RabbitMQ, Qdrant 등 StatefulSet이 PVC를 사용하려면 EBS CSI Driver와 gp3 StorageClass가 있어야 한다.

> **전제**: EBS CSI Driver용 IAM Role이 사전에 생성되어 있어야 한다 ([00-prereqs.md](./00-prereqs.md) 참조).
>
> **참고**: 현재 Terraform outputs에 `ebs_csi_controller_role_arn`은 정의되어 있지 않다.
> IAM Role ARN을 직접 지정해야 한다. IRSA를 사용하지 않는 경우(노드 instance profile로 권한 부여 시),
> Role ARN 설정 없이 설치할 수 있다.

```bash
# IAM Role ARN 설정 — 아래 중 하나를 선택
# (A) IRSA 사용 시: 사전에 생성한 Role ARN을 직접 입력
# EBS_CSI_ROLE_ARN="arn:aws:iam::ACCOUNT_ID:role/billage-kubeadm-prod-ebs-csi-controller"
# (B) 노드 instance profile 사용 시 (현재 구성): 빈 문자열
EBS_CSI_ROLE_ARN=""

# Step 1: Helm으로 EBS CSI Driver 설치
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver --force-update",
    "helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver --namespace kube-system --wait --timeout 180s"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP01" \
  --region ap-northeast-2 --query "StandardOutputContent" --output text

# Step 2: gp3 StorageClass 생성
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "cat <<SCEOF | kubectl apply -f -\napiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata:\n  name: gp3\n  annotations:\n    storageclass.kubernetes.io/is-default-class: \"true\"\nprovisioner: ebs.csi.aws.com\nparameters:\n  type: gp3\n  encrypted: \"true\"\nvolumeBindingMode: WaitForFirstConsumer\nreclaimPolicy: Retain\nSCEOF"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP01" \
  --region ap-northeast-2 --query "StandardOutputContent" --output text
```

확인:
```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver",
    "echo ---",
    "kubectl get storageclass"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP01" \
  --region ap-northeast-2 --query "StandardOutputContent" --output text
```

기대값: `ebs-csi-controller` 2개 Running, `gp3` StorageClass가 `(default)`로 표시

---

## 다음 단계 전 체크

- [ ] 전체 10대 노드 `Ready`
- [ ] `calico-node` DaemonSet 전체 Running
- [ ] `cert-manager`, `ingress-nginx`, `aws-load-balancer-controller` Pod Running
- [ ] `billage-app/data/edge/ops` 네임스페이스 Active
- [ ] SSM 명령 Status `Success`
- [ ] `ingress-nginx-controller` replica 2개 Running
- [ ] `kubectl top nodes` 출력 정상 (metrics-server)
- [ ] `gp3` StorageClass `(default)` 설정
- [ ] `ebs-csi-controller` Running

다음: [05-dns-verify.md](./05-dns-verify.md)
