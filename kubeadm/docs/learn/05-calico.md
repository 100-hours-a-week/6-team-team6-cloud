# 05. Calico CNI 설치 및 BGP 설정

**대상: cp-01에서 kubectl 실행**

CNI(Container Network Interface)를 설치해야 파드 간 통신이 가능하고 노드가 Ready 상태가 된다.
Calico를 선택한 이유: BGP를 사용해 오버레이(VXLAN/IPIP) 없이 라우팅하므로 성능이 좋고, NetworkPolicy를 풍부하게 지원한다.

---

## CNI가 없으면 무슨 일이 일어나는가?

```
kubelet → CRI(containerd) → 컨테이너 생성 → CNI 플러그인 호출 → IP 할당/네트워크 설정
```

CNI가 없으면 kubelet이 파드에 IP를 할당할 수 없어 파드가 `Pending` 또는 `ContainerCreating`에서 멈춘다.
coredns도 CNI가 있어야 Ready가 된다.

---

## Calico 설치 방법: tigera-operator

Calico는 두 가지 설치 방식이 있다:
1. **manifest 직접 적용** — 단순하지만 커스터마이징이 어렵다
2. **tigera-operator** — Operator 패턴. `Installation` CRD로 선언적 관리 (권장)

여기서는 operator 방식을 사용한다.

```bash
# cp-01에서 실행
export KUBECONFIG=/etc/kubernetes/admin.conf
CALICO_VERSION="v3.31.0"
CLUSTER_NAME="my-cluster"
CONTROL_PLANE_ENDPOINT="k8s-api.village.internal"
POD_CIDR="192.168.0.0/16"
BGP_AS_NUMBER="64512"
```

---

## 1. kubernetes-services-endpoint ConfigMap

**왜 필요한가?**
Calico의 calico-node, calico-kube-controllers는 쿠버네티스 API 서버에 접속해야 한다.
하지만 CNI 설치 전에는 파드 IP가 없어서 `KUBERNETES_SERVICE_HOST` 환경변수(기본: ClusterIP `10.96.0.1`)로 접속하면 실패한다.
tigera-operator가 이 configmap을 읽어 Calico 파드에 실제 API 엔드포인트를 주입한다.

```bash
kubectl create namespace tigera-operator

kubectl create configmap kubernetes-services-endpoint \
  -n tigera-operator \
  --from-literal=KUBERNETES_SERVICE_HOST="${CONTROL_PLANE_ENDPOINT}" \
  --from-literal=KUBERNETES_SERVICE_PORT="6443"

kubectl get configmap -n tigera-operator kubernetes-services-endpoint -o yaml
```

---

## 2. tigera-operator 설치

```bash
kubectl apply -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

# operator Pod가 Running이 될 때까지 대기
kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=5m
```

---

## 3. CRD 생성 대기

tigera-operator가 Calico 관련 CRD를 등록하는 데 시간이 걸린다.

```bash
# Installation CRD 대기
until kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; do
  echo "waiting for installations CRD..."
  sleep 5
done

# BGPConfiguration CRD 대기
until kubectl get crd bgpconfigurations.crd.projectcalico.org >/dev/null 2>&1; do
  echo "waiting for BGPConfiguration CRD..."
  sleep 5
done

echo "CRD 준비 완료"
```

---

## 4. Installation CR 적용

`Installation` CR이 Calico의 실제 네트워크 설정을 정의한다.

```bash
cat > /opt/kubeadm/rendered/calico-installation.yaml <<EOF
# Installation: Calico 네트워크 구성
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    bgp: Enabled  # BGP 라우팅 사용 (오버레이 없음)
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26         # 각 노드에 할당되는 /26 블록 (64개 IP)
        cidr: ${POD_CIDR}     # 192.168.0.0/16
        encapsulation: None   # BGP 사용 시 캡슐화 불필요
        natOutgoing: Enabled  # 파드 → 외부 통신 시 노드 IP로 SNAT
        nodeSelector: all()
---
# BGPConfiguration: AS 번호와 mesh 설정
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: ${BGP_AS_NUMBER}     # BGP Autonomous System 번호
  nodeToNodeMeshEnabled: true    # 모든 노드가 서로 BGP 피어링 (full mesh)
EOF

kubectl apply -f /opt/kubeadm/rendered/calico-installation.yaml
```

**BGP란?**
각 노드가 자신에게 할당된 Pod CIDR 블록(/26)을 다른 노드들에게 BGP로 광고한다.
예: node-A(192.168.1.0/26)는 "이 범위의 파드는 나에게로" 라고 다른 노드에 알린다.
오버레이(터널) 없이 순수 L3 라우팅으로 파드 간 통신이 가능하다.

---

## 5. Calico 파드에 API 엔드포인트 주입

tigera-operator가 calico-node, calico-kube-controllers, calico-typha를 생성한 후,
이들 파드에 `KUBERNETES_SERVICE_HOST` 환경변수를 명시적으로 설정한다.

```bash
# 파드 생성 대기
until kubectl get namespace calico-system >/dev/null 2>&1; do
  echo "waiting for calico-system namespace..."
  sleep 5
done

until kubectl get daemonset calico-node -n calico-system >/dev/null 2>&1; do
  echo "waiting for calico-node daemonset..."
  sleep 5
done

until kubectl get deployment calico-kube-controllers -n calico-system >/dev/null 2>&1; do
  echo "waiting for calico-kube-controllers deployment..."
  sleep 5
done

until kubectl get deployment calico-typha -n calico-system >/dev/null 2>&1; do
  echo "waiting for calico-typha deployment..."
  sleep 5
done

echo "Calico 리소스 준비 완료, API 엔드포인트 환경변수 주입 시작"

# 각 Calico 컴포넌트에 실제 API 엔드포인트 주입
kubectl set env daemonset/calico-node -n calico-system \
  KUBERNETES_SERVICE_HOST="${CONTROL_PLANE_ENDPOINT}" \
  KUBERNETES_SERVICE_PORT="6443"

kubectl set env deployment/calico-kube-controllers -n calico-system \
  KUBERNETES_SERVICE_HOST="${CONTROL_PLANE_ENDPOINT}" \
  KUBERNETES_SERVICE_PORT="6443"

kubectl set env deployment/calico-typha -n calico-system \
  KUBERNETES_SERVICE_HOST="${CONTROL_PLANE_ENDPOINT}" \
  KUBERNETES_SERVICE_PORT="6443"

# 재시작 (환경변수 적용)
kubectl rollout restart daemonset/calico-node -n calico-system
kubectl rollout restart deployment/calico-kube-controllers -n calico-system
kubectl rollout restart deployment/calico-typha -n calico-system
```

---

## 6. Calico 정상화 대기

```bash
echo "calico-typha 대기 중..."
kubectl rollout status deployment/calico-typha -n calico-system --timeout=10m

echo "calico-node 대기 중 (전체 노드 수만큼)..."
kubectl rollout status daemonset/calico-node -n calico-system --timeout=15m

echo "calico-kube-controllers 대기 중..."
kubectl rollout status deployment/calico-kube-controllers -n calico-system --timeout=10m

echo "Calico 설치 완료"
```

---

## 7. 노드 Ready 확인

```bash
kubectl get nodes
```

기대 출력:
```
NAME                  STATUS   ROLES           AGE
my-cluster-cp-01      Ready    control-plane   25m
my-cluster-cp-02      Ready    control-plane   18m
my-cluster-cp-03      Ready    control-plane   15m
my-cluster-app-01     Ready    <none>          12m
my-cluster-app-02     Ready    <none>          12m
my-cluster-app-03     Ready    <none>          12m
my-cluster-app-04     Ready    <none>          12m
my-cluster-data-01    Ready    <none>          10m
my-cluster-data-02    Ready    <none>          10m
my-cluster-data-03    Ready    <none>          10m
```

모두 **Ready** 상태여야 한다.

---

## 8. Calico 파드 상태 확인

```bash
kubectl get pods -n calico-system

# 기대 출력
# NAME                                      READY   STATUS    RESTARTS
# calico-node-xxxxx (노드 10대 각각)         1/1     Running   0
# calico-kube-controllers-xxxxxxxxx-xxxxx   1/1     Running   0
# calico-typha-xxxxxxxxx-xxxxx              1/1     Running   0
```

---

## BGP 라우팅 확인 (선택)

노드에 직접 접속해서 BGP 피어링이 구성됐는지 확인할 수 있다.

```bash
# calicoctl 설치 (cp-01)
curl -L https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/calicoctl-linux-amd64 \
  -o /usr/local/bin/calicoctl
chmod +x /usr/local/bin/calicoctl

# BGP 피어 목록 확인
DATASTORE_TYPE=kubernetes KUBECONFIG=/root/.kube/config calicoctl node status
```

---

## 트러블슈팅

**calico-node가 CrashLoopBackOff**
```bash
kubectl logs -n calico-system -l app.kubernetes.io/name=calico-node --tail=30

# 주로 KUBERNETES_SERVICE_HOST 환경변수가 빠진 경우
kubectl describe daemonset calico-node -n calico-system | grep -A5 "KUBERNETES_SERVICE_HOST"
```

**Installation이 Degraded 상태**
```bash
kubectl describe installation default
# spec.calicoNetwork.ipPools[0].cidr가 실제 kubeadm podSubnet과 일치하는지 확인
```

---

다음: [06-labels-taints.md](./06-labels-taints.md)
