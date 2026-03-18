# 03. 나머지 노드 Join

이 단계에서는 cp-02/cp-03을 control-plane으로 join하고, app/data worker 7대를 클러스터에 합류시킨다.

## 근본 목적

- cp-01에서 확보한 join 재료를 이용해 나머지 9대를 일관되게 합류시키고, 플랫폼 부트스트랩 전 전체 노드 구성을 확정한다.
- control-plane join과 worker join을 한 문서에서 관리하되 확인 지점을 분리해 실패 범위를 빠르게 좁힌다.

## 비목적

- CNI 설치 전 `NotReady` 상태를 즉시 해결하려고 하지 않는다.
- 플랫폼 애드온 설치와 DNS 검증을 이 단계와 혼합하지 않는다.

> **전제**: 아래 변수들이 현재 셸에 설정되어 있어야 한다.
> ```bash
> echo "CP01=$CP01  CP02=$CP02  CP03=$CP03"
> echo "APP_NODES=$APP_NODES"
> echo "DATA_NODES=$DATA_NODES"
> echo "JOIN_ENV_B64 길이: ${#JOIN_ENV_B64}"
> ```
> `JOIN_ENV_B64`가 비어 있으면 [02-cp-init.md](./02-cp-init.md) Step 3을 다시 실행한다.

> **⏱ CERTIFICATE_KEY 만료 주의**: `cluster-join.env`에 포함된 `CERTIFICATE_KEY`는 **2시간** 후 만료된다.
> 02-cp-init.md 완료 후 이 단계를 2시간 이내에 시작해야 한다.
> 만료된 경우 cp-01에서 아래 명령으로 갱신한 뒤 `JOIN_ENV_B64`를 다시 생성한다:
> ```bash
> # cp-01에서 certificate key 재생성
> aws ssm send-command \
>   --document-name "AWS-RunShellScript" \
>   --instance-ids "$CP01" \
>   --parameters 'commands=["kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1"]' \
>   --region ap-northeast-2
> # 출력된 새 CERTIFICATE_KEY를 cluster-join.env에 반영 후 JOIN_ENV_B64 재생성
> ```

---

## Step 1. 추가 Control Plane Join (cp-02, cp-03)

> **반드시 순차적으로 join한다.** cp-02/cp-03을 동시에 join하면 etcd quorum 전환 중 충돌이 발생해
> 둘 다 실패하거나 control plane 전체가 불안정해진다. ([99-troubleshooting.md](./99-troubleshooting.md) 참조)

### Step 1-1. cp-02 Join

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP02" \
  --parameters "{\"commands\":[
    \"export JOIN_ENV_B64=${JOIN_ENV_B64}\",
    \"/opt/kubeadm/bin/write-join-env.sh\",
    \"/opt/kubeadm/bin/control-plane-join.sh /opt/kubeadm/rendered/cluster-join.env\"
  ]}" \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "CP02 Join Command ID: $CMD_ID"

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP02" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP02" --region ap-northeast-2 \
  --query "{Status:Status,Output:StandardOutputContent}" --output text
```

**성공 확인**: `Status: Success`이고 출력에 `This node has joined the cluster` 포함.

### Step 1-2. cp-02 Readiness 확인 후 cp-03 Join

cp-02 join이 성공한 후, etcd 3-member quorum이 안정화될 때까지 확인한다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=[
    "export KUBECONFIG=/etc/kubernetes/admin.conf",
    "for i in $(seq 1 12); do STATUS=$(curl -ks -o /dev/null -w \"%{http_code}\" https://localhost:6443/readyz); if [ \"$STATUS\" = \"200\" ]; then echo \"readyz: OK (attempt $i)\"; break; fi; echo \"readyz: $STATUS (attempt $i), waiting...\"; sleep 10; done",
    "kubectl get nodes --no-headers | wc -l"
  ]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP01" --region ap-northeast-2 \
  --query "StandardOutputContent" --output text
```

**통과 조건**: `readyz: OK`이고 노드 수가 2 이상이어야 한다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP03" \
  --parameters "{\"commands\":[
    \"export JOIN_ENV_B64=${JOIN_ENV_B64}\",
    \"/opt/kubeadm/bin/write-join-env.sh\",
    \"/opt/kubeadm/bin/control-plane-join.sh /opt/kubeadm/rendered/cluster-join.env\"
  ]}" \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "CP03 Join Command ID: $CMD_ID"

aws ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CP03" --region ap-northeast-2 || true

aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CP03" --region ap-northeast-2 \
  --query "{Status:Status,Output:StandardOutputContent}" --output text
```

**성공 확인**: `Status: Success`이고 출력에 `This node has joined the cluster` 포함.

> join 후 각 control-plane 노드는 `/etc/hosts`에 `k8s-api.village.internal → 자신의 private IP`를 등록한다.
> 이는 kubelet/kubeconfig가 NLB를 self-loop하는 것을 방지하기 위한 설계다.

---

## Step 2. Worker Node Join (app 4대 + data 3대)

```bash
ALL_WORKERS="$APP_NODES $DATA_NODES"

CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids $ALL_WORKERS \
  --parameters "{\"commands\":[
    \"export JOIN_ENV_B64=${JOIN_ENV_B64}\",
    \"/opt/kubeadm/bin/write-join-env.sh\",
    \"/opt/kubeadm/bin/worker-join.sh /opt/kubeadm/rendered/cluster-join.env\"
  ]}" \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "Worker Join Command ID: $CMD_ID"
```

완료까지 2-3분 소요된다.

```bash
# 결과 확인
for NODE in $ALL_WORKERS; do
  echo "=== $NODE ==="
  aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$NODE" \
    --region ap-northeast-2 \
    --query "{Status:Status,Output:StandardOutputContent}" \
    --output text
done
```

---

## Step 3. 전체 노드 Join 완료 확인

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["kubectl get nodes -L node-group,workload-plane"]' \
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

기대 출력 예시 (10대, 모두 `NotReady` — CNI 미설치 상태는 **정상**):
```
NAME                          STATUS     ROLES           AGE   NODE-GROUP      WORKLOAD-PLANE
billage-kubeadm-prod-cp-01    NotReady   control-plane   8m    <none>          <none>
billage-kubeadm-prod-cp-02    NotReady   control-plane   3m    <none>          <none>
billage-kubeadm-prod-cp-03    NotReady   control-plane   3m    <none>          <none>
billage-kubeadm-prod-app-01   NotReady   <none>          2m    <none>          <none>
billage-kubeadm-prod-app-02   NotReady   <none>          2m    <none>          <none>
billage-kubeadm-prod-app-03   NotReady   <none>          2m    <none>          <none>
billage-kubeadm-prod-app-04   NotReady   <none>          2m    <none>          <none>
billage-kubeadm-prod-data-01  NotReady   <none>          2m    <none>          <none>
billage-kubeadm-prod-data-02  NotReady   <none>          2m    <none>          <none>
billage-kubeadm-prod-data-03  NotReady   <none>          2m    <none>          <none>
```

노드 수가 10대 미만이면 해당 노드의 join 명령 상태를 다시 확인한다:
```bash
# 노드 수 카운트
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["kubectl get nodes --no-headers | wc -l"]' \
  --region ap-northeast-2
```

---

## 다음 단계 전 체크

- [ ] `kubectl get nodes` 결과에 10대 모두 보임
- [ ] Status가 `NotReady`여도 무방 (Calico 설치 전)
- [ ] `join materials written to ...` 메시지로 join 성공 확인

다음: [04-platform.md](./04-platform.md)
