# 02. Control Plane 초기화 및 Join Env 추출

이 단계에서는 cloud-init 완료를 확인하고, cp-01에서 `kubeadm init`을 실행한 뒤, 나머지 노드에 전달할 join 정보를 추출한다.

## 근본 목적

- 첫 control-plane을 안정적으로 초기화하고, 이후 모든 노드가 같은 join 재료를 사용하도록 표준 env를 확보한다.
- cp-01 초기화 실패와 join 재료 추출 실패를 분리해 원인 파악을 빠르게 만든다.

## 비목적

- 나머지 control-plane 및 worker join을 이 단계에서 함께 수행하지 않는다.
- CNI 설치 전 `NotReady` 상태를 장애로 오해해 불필요한 재시도를 유발하지 않는다.

> **전제**: [01-terraform.md](./01-terraform.md)의 변수 export가 현재 셸에 설정되어 있어야 한다.
> `$CP01`, `$CP02`, `$CP03`, `$APP_NODES`, `$DATA_NODES`, `$SSM_DOC` 확인:
> ```bash
> echo "CP01=$CP01  CP02=$CP02  CP03=$CP03"
> ```

---

## Step 1. Cloud-init 완료 대기

EC2가 시작된 후 cloud-init이 containerd, kubelet, kubeadm, kubectl을 설치한다. 완료까지 최대 5분이 걸릴 수 있다.

### cp-01 단독 확인

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["cloud-init status --wait && echo CLOUD_INIT_READY"]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "CMD_ID=$CMD_ID"

# 완료까지 대기 후 결과 확인
sleep 10
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "{Status:Status,Output:StandardOutputContent}" \
  --output text
```

기대값: `Status: Success`, 출력에 `CLOUD_INIT_READY` 포함

### 전체 10대 스크립트 배치 확인

```bash
ALL_NODES="$CP01 $CP02 $CP03 $APP_NODES $DATA_NODES"

CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids $ALL_NODES \
  --parameters 'commands=["test -f /opt/kubeadm/bin/bootstrap-common.sh && echo READY || echo NOT_READY"]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "CMD_ID=$CMD_ID"
sleep 10

# 각 노드 결과 확인
for NODE in $ALL_NODES; do
  RESULT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$NODE" \
    --region ap-northeast-2 \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "PENDING")
  echo "$NODE: $RESULT"
done
```

기대값: 전체 10대에서 `READY` 출력. `NOT_READY`가 있으면 해당 노드의 cloud-init이 미완료된 것이므로 1-2분 후 재시도한다.

---

## Step 2. Control Plane 초기화 (cp-01)

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["/opt/kubeadm/bin/control-plane-init.sh"]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

echo "CP Init Command ID: $CMD_ID"
```

완료까지 3-5분 소요된다. 실행 상태를 주기적으로 확인한다:

```bash
# 상태 확인 (InProgress → Success)
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "{Status:Status,Tail:StandardOutputContent}" \
  --output text
```

**성공 확인**: 출력 마지막 줄에 아래 메시지가 있어야 한다.
```
join materials written to /opt/kubeadm/rendered/cluster-join.env
```

**실패 시 로그 확인**:
```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["cat /opt/kubeadm/logs/kubeadm-init.log | tail -50"]' \
  --region ap-northeast-2
```

> 실패 원인이 `kubeadm-init.log`에 없으면 `journalctl -u kubelet --no-pager | tail -50`도 확인한다.

---

## Step 3. Join Env 추출 및 Base64 인코딩

### cluster-join.env 내용 확인

```bash
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["cat /opt/kubeadm/rendered/cluster-join.env"]' \
  --region ap-northeast-2 \
  --query "Command.CommandId" --output text)

sleep 5

JOIN_ENV_CONTENT=$(aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CP01" \
  --region ap-northeast-2 \
  --query "StandardOutputContent" --output text)

echo "$JOIN_ENV_CONTENT"
```

기대 출력 형식:
```
BOOTSTRAP_TOKEN=abcdef.0123456789abcdef
CA_CERT_HASH=sha256:aaaa...bbbb
CERTIFICATE_KEY=cccc...dddd
CONTROL_PLANE_ENDPOINT=k8s-api.billage.internal
```

> `BOOTSTRAP_TOKEN`은 24시간 유효하다. 그 이상 경과하면 cp-01에서 `kubeadm token create`로 새 토큰을 발급해야 한다.

### Base64 인코딩

```bash
# macOS
JOIN_ENV_B64=$(echo "$JOIN_ENV_CONTENT" | base64 -b 0)

# Linux
# JOIN_ENV_B64=$(echo "$JOIN_ENV_CONTENT" | base64 -w 0)

echo "JOIN_ENV_B64 길이: ${#JOIN_ENV_B64}"
echo "$JOIN_ENV_B64"
```

> **macOS vs Linux**: macOS는 `-b 0`, Linux는 `-w 0`으로 줄바꿈 없는 base64를 출력한다.
> 인코딩된 문자열에 줄바꿈이 포함되면 디코딩 오류가 발생하므로 반드시 한 줄인지 확인한다.

`JOIN_ENV_B64` 변수를 현재 셸에 보관한다. 이 값은 다음 단계(03)에서 사용된다.

---

## 성공 확인

```bash
# cp-01이 NotReady 상태여도 정상 (CNI 미설치)
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["kubectl get nodes"]' \
  --region ap-northeast-2
```

기대값: `cp-01` 노드 1대가 `NotReady` 상태로 표시됨

---

다음: [03-node-join.md](./03-node-join.md)
