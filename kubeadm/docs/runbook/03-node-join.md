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

---

## Step 1. 추가 Control Plane Join (cp-02, cp-03)

cp-02와 cp-03은 동시에 join할 수 있다.

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP02" "$CP03" \
  --parameters "{\"commands\":[
    \"export JOIN_ENV_B64=${JOIN_ENV_B64}\",
    \"/opt/kubeadm/bin/write-join-env.sh\",
    \"/opt/kubeadm/bin/control-plane-join.sh /opt/kubeadm/rendered/cluster-join.env\"
  ]}" \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "CP Join Command ID: $CMD_ID"
```

완료까지 3-5분 소요된다.

```bash
# 각 노드 결과 확인
for NODE in $CP02 $CP03; do
  echo "=== $NODE ==="
  aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$NODE" \
    --region ap-northeast-2 \
    --query "{Status:Status,Output:StandardOutputContent}" \
    --output text
done
```

**성공 확인**: `Status: Success`이고 출력에 `This node has joined the cluster` 포함.

> join 후 각 control-plane 노드는 `/etc/hosts`에 `k8s-api.billage.internal → 자신의 private IP`를 등록한다.
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

sleep 5

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
