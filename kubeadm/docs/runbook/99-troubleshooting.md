# 99. 트러블슈팅

각 단계에서 발생하는 주요 실패 케이스와 해결 방법을 정리한다.

---

## 근본 목적

- 단계별 대표 실패 패턴을 증상, 원인, 확인 명령으로 고정해 복구 시간을 줄인다.
- 같은 장애가 재발했을 때 전체 문서를 다시 훑지 않고도 필요한 진단 지점으로 바로 이동하게 한다.

## 비목적

- 모든 운영 이슈를 이 문서 하나에 누적하지 않는다.
- 실제 발생하지 않은 가설성 시나리오를 과도하게 추가하지 않는다.

---

## SSM 명령 공통

### SSM Agent가 응답하지 않음

**증상**: `send-command` 후 `InvocationDoesNotExist` 오류 또는 Status가 `Pending` 지속

**원인**: 인스턴스 시작 직후 SSM Agent 초기화 미완료, 또는 SSM 엔드포인트 연결 문제

**해결**:
```bash
# 인스턴스 상태 확인
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$CP01" \
  --region ap-northeast-2 \
  --query "InstanceInformationList[].{ID:InstanceId,PingStatus:PingStatus}" \
  --output text

# PingStatus가 Online이어야 한다. Offline이면 EC2 인스턴스 상태부터 확인
aws ec2 describe-instance-status \
  --instance-ids "$CP01" \
  --region ap-northeast-2
```

---

## 02단계: cloud-init 미완료

**증상**: `test -f /opt/kubeadm/bin/control-plane-init.sh` 결과 `NOT_READY`

**원인**: EC2 시작 후 cloud-init이 아직 실행 중 (패키지 설치 소요)

**해결**:
```bash
# cloud-init 진행 상태 확인
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["cloud-init status"]' \
  --region ap-northeast-2

# 상세 로그 확인
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["tail -50 /var/log/cloud-init-output.log"]' \
  --region ap-northeast-2
```

1-2분 간격으로 재확인한다. 5분 이상 `NOT_READY`이면 cloud-init 로그에서 오류를 확인한다.

---

## 02단계: kubeadm init 실패

**증상**: `control-plane-init.sh` 명령 Status `Failed`

**로그 확인**:
```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["cat /opt/kubeadm/logs/kubeadm-init.log | tail -80"]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

sleep 5
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "StandardOutputContent" --output text
```

**주요 원인별 해결**:

| 오류 | 원인 | 해결 |
|------|------|------|
| `[ERROR Swap]` | swap 미비활성화 | cloud-init 로그 확인, bootstrap-common.sh swap 비활성화 확인 |
| `[ERROR CRI]` | containerd 미실행 | `systemctl status containerd` 확인 |
| `connection refused` on `6443` | API 서버 이미 실행 중 (재시도 시) | `/etc/kubernetes/admin.conf` 존재 확인 (이미 초기화된 경우 정상) |
| `node already exists` | 이전 join 시도 잔재 | `kubeadm reset -f` 후 재시도 |

```bash
# kubelet 상태 확인
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["systemctl status kubelet --no-pager", "journalctl -u kubelet --no-pager | tail -30"]' \
  --region ap-northeast-2
```

---

## 02단계: Join Env Base64 디코딩 오류

**증상**: `write-join-env.sh` 실행 시 `invalid input` 또는 join env 파일 내용이 깨짐

**원인**: macOS(`-b 0`)와 Linux(`-w 0`)의 base64 플래그 차이, 또는 줄바꿈 포함

**해결**:
```bash
# 현재 셸 OS 확인
uname -s
# Darwin → macOS, Linux → Linux

# macOS (줄바꿈 없이 인코딩)
JOIN_ENV_B64=$(echo "$JOIN_ENV_CONTENT" | base64 -b 0)

# Linux (줄바꿈 없이 인코딩)
JOIN_ENV_B64=$(echo "$JOIN_ENV_CONTENT" | base64 -w 0)

# 인코딩 결과에 줄바꿈이 없는지 확인
echo "$JOIN_ENV_B64" | wc -l
# 기대값: 1 (한 줄)
```

---

## 03단계: Control Plane Join 실패

**증상**: cp-02 또는 cp-03의 join 명령 Status `Failed`

**로그 확인**:
```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP02" \
  --parameters 'commands=["journalctl -u kubelet --no-pager | tail -50"]' \
  --region ap-northeast-2
```

**주요 원인**:
- `token expired` — `BOOTSTRAP_TOKEN`이 만료됨 (유효기간 24시간)
  ```bash
  # cp-01에서 새 토큰 발급 후 cluster-join.env 재생성
  aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$CP01" \
    --parameters 'commands=[
      "NEW_TOKEN=$(kubeadm token create)",
      "sed -i \"s/^BOOTSTRAP_TOKEN=.*/BOOTSTRAP_TOKEN=$NEW_TOKEN/\" /opt/kubeadm/rendered/cluster-join.env",
      "cat /opt/kubeadm/rendered/cluster-join.env"
    ]' \
    --region ap-northeast-2
  # 이후 JOIN_ENV_CONTENT, JOIN_ENV_B64 재추출
  ```
- `certificate key is not valid` — `upload-certs` 2시간 유효기간 초과
  ```bash
  aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$CP01" \
    --parameters 'commands=[
      "NEW_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n1 | tr -d \"\\r\")",
      "sed -i \"s/^CERTIFICATE_KEY=.*/CERTIFICATE_KEY=$NEW_KEY/\" /opt/kubeadm/rendered/cluster-join.env",
      "cat /opt/kubeadm/rendered/cluster-join.env"
    ]' \
    --region ap-northeast-2
  ```

---

## 04단계: Calico NotReady 지속

**증상**: 노드가 오랫동안 `NotReady` 상태 유지, `calico-node` Pod `CrashLoopBackOff`

**확인**:
```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl describe installation default",
    "echo ---",
    "kubectl logs -n calico-system -l app.kubernetes.io/name=calico-node --tail=50"
  ]' \
  --region ap-northeast-2
```

**주요 원인**:
- `kubernetes-services-endpoint` ConfigMap 미적용 — 플랫폼 부트스트랩 스크립트가 tigera-operator 네임스페이스에 configmap을 생성해야 한다.
  ```bash
  aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$CP01" \
    --parameters 'commands=["kubectl get configmap -n tigera-operator kubernetes-services-endpoint -o yaml"]' \
    --region ap-northeast-2
  ```
- KUBERNETES_SERVICE_HOST 환경변수 미설정 — `kubectl set env` 적용 여부 확인
  ```bash
  aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$CP01" \
    --parameters 'commands=["kubectl get daemonset calico-node -n calico-system -o jsonpath={.spec.template.spec.containers[0].env}"]' \
    --region ap-northeast-2
  ```

---

## 04단계: cert-manager Certificate Pending

**증상**: `kubectl get certificate -n billage-edge` 결과 `READY: False`

**확인**:
```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl describe certificaterequest -n billage-edge",
    "echo ---",
    "kubectl describe challenge -n billage-edge"
  ]' \
  --region ap-northeast-2
```

**주요 원인**:
- **DNS 미전파**: ACME http01 challenge는 `public_edge_host`로 HTTP 요청을 보낸다. DNS CNAME이 ALB를 가리키지 않으면 challenge가 실패한다.
  ```bash
  dig CNAME api.billages.com +short
  # ALB hostname이 출력되어야 한다
  ```
- **ALB 미생성**: [아래 섹션](#alb-미생성) 참고

> DNS 전파 후 cert-manager는 자동으로 challenge를 재시도한다. 별도 재시작 없이 수 분 기다린다.

---

## 04단계: ALB 미생성

**증상**: `ingress-nginx-public-alb`의 ADDRESS 필드가 비어있음

**확인**:
```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50"
  ]' \
  --region ap-northeast-2
```

**주요 원인**:

| 오류 키워드 | 원인 | 해결 |
|-------------|------|------|
| `UnauthorizedOperation` | 노드 IAM Role 권한 부족 | IAM role에 AWSLoadBalancerControllerIAMPolicy 정책 추가 확인 |
| `subnet not found` | VPC 서브넷 태그 누락 | public 서브넷에 `kubernetes.io/role/elb=1` 태그 확인 |
| `cluster not found` | `clusterName` 불일치 | `helm values`의 `clusterName`이 `terraform output`의 cluster name과 일치하는지 확인 |

**IAM 권한 확인**:
```bash
ROLE_NAME=$(terraform output -raw instance_role_name)
aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
  --query "AttachedPolicies[].PolicyName" --output text
```

---

## 전체 재시작 절차

Terraform apply는 유지하고 kubeadm bootstrap만 재시도할 경우:

```bash
# 각 노드에서 kubeadm reset (EC2는 유지)
for NODE in $CP01 $CP02 $CP03 $APP_NODES $DATA_NODES; do
  aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$NODE" \
    --parameters 'commands=["kubeadm reset -f && rm -rf /etc/kubernetes /root/.kube /opt/kubeadm/rendered /opt/kubeadm/logs && mkdir -p /opt/kubeadm/rendered /opt/kubeadm/logs"]' \
    --region ap-northeast-2
done

# 이후 02-cp-init.md부터 재시작
```

> 완전 재시작이 필요하면 `terraform destroy` 후 `terraform apply`를 다시 실행한다.
> `terraform destroy`는 **모든 EC2와 네트워크 리소스를 삭제**하므로 신중하게 결정한다.
