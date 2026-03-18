# 06. 노드 라벨링 및 Taint 설정

**대상: cp-01에서 kubectl 실행**

노드 라벨(label)과 taint는 "어떤 파드가 어떤 노드에 스케줄되는가"를 제어하는 핵심 메커니즘이다.

---

## 개념 정리

### 라벨 (Label)
- 노드에 메타데이터를 붙인다. `key=value` 형식.
- `nodeSelector` 또는 `nodeAffinity`로 파드가 특정 라벨을 가진 노드에만 스케줄되도록 제약한다.
- 예: `workload-plane=app` 라벨이 있는 노드에만 앱 파드를 스케줄

### Taint (오염)
- 노드를 "기피" 상태로 만든다. 해당 taint를 `toleration`으로 허용하는 파드만 스케줄된다.
- `NoSchedule`: taint를 견디지 못하는 파드는 새로 스케줄되지 않음
- `NoExecute`: 이미 실행 중인 파드도 퇴거(evict)시킴

### 우리 설계의 의미
```
control-plane 노드:
  taint node-role.kubernetes.io/control-plane:NoSchedule
  → 일반 파드 스케줄 차단 (etcd/apiserver 등 시스템 컴포넌트만)

data 노드:
  taint workload-plane=data:NoSchedule
  → data 전용 파드(DB, MQ 등)만 허용
  → toleration: - key: workload-plane, value: data, effect: NoSchedule

app 노드:
  taint 없음
  → 모든 일반 파드 스케줄 가능 (edge, ops, app 워크로드)
```

---

## Control Plane 노드 라벨/Taint

kubeadm이 init/join 시 이미 `node-role.kubernetes.io/control-plane` taint를 설정했지만,
커스텀 라벨(`node-group`, `workload-plane`)은 별도로 추가해야 한다.

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
CLUSTER_NAME="my-cluster"

for IDX in 01 02 03; do
  NODE="${CLUSTER_NAME}-cp-${IDX}"
  echo "=== $NODE 설정 ==="

  # 라벨 추가
  kubectl label node "$NODE" \
    node-role.kubernetes.io/control-plane= \
    node-group=control-plane \
    workload-plane=control-plane \
    --overwrite

  # control-plane taint 확인/재설정
  kubectl taint node "$NODE" \
    node-role.kubernetes.io/control-plane=:NoSchedule \
    --overwrite
done
```

---

## App 노드 라벨 설정 (Taint 없음)

```bash
for IDX in 01 02 03 04; do
  NODE="${CLUSTER_NAME}-app-${IDX}"
  echo "=== $NODE 설정 ==="

  kubectl label node "$NODE" \
    node-role=app \
    node-group=app \
    workload-plane=app \
    --overwrite

  # 혹시 taint가 잘못 붙었다면 제거 (- 접미사로 taint 제거)
  kubectl taint node "$NODE" workload-plane- 2>/dev/null || true
done
```

---

## Data 노드 라벨/Taint 설정

```bash
for IDX in 01 02 03; do
  NODE="${CLUSTER_NAME}-data-${IDX}"
  echo "=== $NODE 설정 ==="

  kubectl label node "$NODE" \
    node-role=data \
    node-group=data \
    workload-plane=data \
    --overwrite

  # data 전용 taint — 이 taint를 toleration으로 허용하는 파드만 스케줄됨
  kubectl taint node "$NODE" \
    workload-plane=data:NoSchedule \
    --overwrite
done
```

---

## 확인

```bash
kubectl get nodes -L node-group,workload-plane
```

기대 출력:
```
NAME                  STATUS   ROLES           NODE-GROUP      WORKLOAD-PLANE
my-cluster-cp-01      Ready    control-plane   control-plane   control-plane
my-cluster-cp-02      Ready    control-plane   control-plane   control-plane
my-cluster-cp-03      Ready    control-plane   control-plane   control-plane
my-cluster-app-01     Ready    <none>          app             app
my-cluster-app-02     Ready    <none>          app             app
my-cluster-app-03     Ready    <none>          app             app
my-cluster-app-04     Ready    <none>          app             app
my-cluster-data-01    Ready    <none>          data            data
my-cluster-data-02    Ready    <none>          data            data
my-cluster-data-03    Ready    <none>          data            data
```

```bash
# taint 확인
kubectl describe nodes | grep -A3 "Taints:"

# 기대 출력
# my-cluster-cp-* Taints: node-role.kubernetes.io/control-plane:NoSchedule
# my-cluster-app-* Taints: <none>
# my-cluster-data-* Taints: workload-plane=data:NoSchedule
```

---

## data 노드 toleration 예시

data 노드에 파드를 스케줄하려면 다음처럼 toleration을 추가한다:

```yaml
spec:
  tolerations:
    - key: workload-plane
      value: data
      effect: NoSchedule
  nodeSelector:
    workload-plane: data
```

---

다음: [07-namespaces-rbac.md](./07-namespaces-rbac.md)
