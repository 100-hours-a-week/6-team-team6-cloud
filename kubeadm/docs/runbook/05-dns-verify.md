# 05. DNS 연결 및 최종 검증

이 단계에서는 ALB DNS를 확인하고 공개 도메인에 CNAME을 등록한 뒤, edge 경로 전체를 검증한다.

## 근본 목적

- 외부 DNS와 TLS까지 포함한 최종 사용자 경로가 실제로 열렸는지 확인해 구축 완료 기준을 명확히 한다.
- `ingress-nginx`, `aws-load-balancer-controller`, `cert-manager`가 함께 수렴했는지 한 단계에서 검증한다.

## 비목적

- 플랫폼 부트스트랩 자체 실패를 DNS 문제로 오인해 우회하지 않는다.
- 애플리케이션 본배포 절차를 최종 검증 단계에 포함하지 않는다.

> **전제**: [04-platform.md](./04-platform.md)의 플랫폼 부트스트랩이 완료된 상태여야 한다.
> `$CP01` 변수가 설정되어 있어야 한다.

---

## Step 1. ALB Hostname 확인

aws-load-balancer-controller가 Ingress를 처리하면 ALB가 생성된다. 생성까지 2-5분이 걸릴 수 있다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl get ingress -n ingress-nginx ingress-nginx-public-alb -o wide",
    "echo ---ALB-HOSTNAME---",
    "kubectl get ingress -n ingress-nginx ingress-nginx-public-alb -o jsonpath={.status.loadBalancer.ingress[0].hostname}"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

sleep 10
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "StandardOutputContent" --output text
```

기대 출력 예시:
```
NAME                      CLASS   HOSTS                ADDRESS
ingress-nginx-public-alb  alb     api.billages.com      k8s-ingressni-xxx.ap-northeast-2.elb.amazonaws.com
---ALB-HOSTNAME---
k8s-ingressni-ingres-xxxx-yyyy.ap-northeast-2.elb.amazonaws.com
```

> ALB hostname이 비어 있으면 aws-load-balancer-controller Pod 로그를 확인한다 — [99-troubleshooting.md](./99-troubleshooting.md) 참고.

---

## Step 2. DNS CNAME 등록

ALB hostname을 `terraform.tfvars`의 `public_edge_host` 도메인으로 CNAME 등록한다.

### Route53에 등록하는 경우

```bash
ALB_HOST="k8s-ingressni-ingres-xxxx.ap-northeast-2.elb.amazonaws.com"  # Step 1 출력값으로 교체
PUBLIC_EDGE_HOST="api.billages.com"  # terraform.tfvars의 값으로 교체
HOSTED_ZONE_ID="ZXXXXXXXXXXXX"      # 도메인이 관리되는 퍼블릭 호스팅 존 ID

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${PUBLIC_EDGE_HOST}\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"${ALB_HOST}\"}]
      }
    }]
  }"
```

### 외부 DNS 레지스트리에 등록하는 경우

등록 화면에서 아래와 같이 설정한다:
- **레코드 타입**: CNAME
- **이름**: `api.billages.com` (또는 서브도메인 부분만)
- **값**: ALB hostname (`k8s-ingressni-...elb.amazonaws.com`)
- **TTL**: 60초 (초기 테스트용, 이후 300으로 변경 가능)

### DNS 전파 확인

```bash
dig CNAME api.billages.com +short
# 또는
nslookup api.billages.com
```

기대값: ALB hostname이 응답으로 나와야 한다. 전파에 최대 수 분이 걸릴 수 있다.

---

## Step 3. cert-manager Certificate 상태 확인

DNS가 전파되면 cert-manager가 Let's Encrypt ACME http01 challenge를 완료한다. 완료까지 수 분이 걸릴 수 있다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl get certificate -n billage-edge",
    "echo ---",
    "kubectl describe certificate edge-public-tls -n billage-edge | tail -20"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

sleep 5
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "StandardOutputContent" --output text
```

기대값:
```
NAME              READY   SECRET            AGE
edge-public-tls   True    edge-public-tls   5m
```

`READY: False`가 지속되면 [99-troubleshooting.md](./99-troubleshooting.md)의 cert-manager 섹션을 참고한다.

---

## Step 4. 최종 검증 체크리스트

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "echo === 노드 상태 ===",
    "kubectl get nodes -L node-group,workload-plane",
    "echo === Calico ===",
    "kubectl get pods -n calico-system",
    "echo === ingress-nginx ===",
    "kubectl get pods -n ingress-nginx",
    "echo === cert-manager ===",
    "kubectl get pods -n cert-manager",
    "echo === aws-lbc ===",
    "kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller",
    "echo === 네임스페이스 ===",
    "kubectl get ns billage-app billage-data billage-edge billage-ops",
    "echo === NetworkPolicy ===",
    "kubectl get networkpolicy -A",
    "echo === ALB Ingress ===",
    "kubectl get ingress -n ingress-nginx ingress-nginx-public-alb -o wide",
    "echo === Certificate ===",
    "kubectl get certificate -n billage-edge",
    "echo === Edge Smoke Service ===",
    "kubectl get svc -n billage-edge edge-smoketest",
    "echo === metrics-server ===",
    "kubectl top nodes 2>&1 | head -5",
    "echo === StorageClass ===",
    "kubectl get storageclass",
    "echo === EBS CSI ===",
    "kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

sleep 10
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "StandardOutputContent" --output text
```

### 완료 기준

| 항목 | 기대값 |
|------|--------|
| 노드 수 | 10대 (`cp×3`, `app×4`, `data×3`) |
| 노드 상태 | 모두 `Ready` |
| `node-group` 라벨 | `control-plane`, `app`, `data` |
| `workload-plane` 라벨 | `control-plane`, `app`, `data` |
| `calico-node` DaemonSet | 전체 Running |
| `calico-kube-controllers` | Running |
| `ingress-nginx-controller` | Running |
| `cert-manager` | 3 Pod 모두 Running |
| `aws-load-balancer-controller` | Running |
| `billage-*` 네임스페이스 | 4개 Active |
| `default-deny-all` NetworkPolicy | 4개 네임스페이스 각각 존재 |
| `ingress-nginx-public-alb` | ADDRESS 필드에 ALB hostname 있음 |
| `edge-public-tls` Certificate | `READY: True` |
| `edge-smoketest` Service | `ClusterIP` 할당됨 |
| `kubectl top nodes` | 각 노드 CPU/Memory 출력 (metrics-server) |
| `gp3` StorageClass | `(default)` 로 설정됨 |
| `ebs-csi-controller` | Running |

---

## Step 5. Smoke Test (선택)

DNS 전파 및 TLS 인증서 발급이 완료된 후 실제 HTTP 요청을 보낸다.

```bash
# TLS 검증 포함 요청
curl -v https://api.billages.com/

# 기대값: HTTP 200, 응답 본문에 "billage-edge ok" 포함
```

---

## 구축 완료

모든 체크리스트 항목이 통과되면 클러스터 구축이 완료된 것이다.

이후 작업:
- 애플리케이션 배포: `billage-app` 네임스페이스에 `billage-app-deployer` Service Account 사용
- 데이터 플레인 배포: `billage-data` 네임스페이스, `workload-plane=data` node selector 필요
- 모니터링 스택 추가: `billage-ops` 네임스페이스
- 문제 발생 시: [99-troubleshooting.md](./99-troubleshooting.md) 참고
