# 04. 나머지 노드 Join

**cp-02, cp-03**: control-plane join (etcd 클러스터 확장, apiserver 추가)
**app-01~04, data-01~03**: worker join

---

## 준비: cluster-join.env 각 노드에 배포

PC에서 실행한다.

```bash
source ~/k8s-env.sh

# 모든 노드 Public IP 수집
declare -A NODE_IPS

for TAG in cp-02 cp-03 app-01 app-02 app-03 app-04 data-01 data-02 data-03; do
  IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-${TAG}" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
  NODE_IPS[$TAG]=$IP
  echo "${TAG}: ${IP}"
done

# join env 파일 각 노드에 복사
for TAG in cp-02 cp-03 app-01 app-02 app-03 app-04 data-01 data-02 data-03; do
  IP=${NODE_IPS[$TAG]}
  echo "=== $TAG ($IP) ==="
  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${IP} \
    "sudo mkdir -p /opt/kubeadm/rendered"
  scp -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no \
    ~/cluster-join.env ubuntu@${IP}:/tmp/cluster-join.env
  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${IP} \
    "sudo mv /tmp/cluster-join.env /opt/kubeadm/rendered/cluster-join.env && sudo chmod 600 /opt/kubeadm/rendered/cluster-join.env"
done
```

---

## Control Plane Join (cp-02, cp-03)

**왜 cp join이 worker join과 다른가?**
control-plane join 시에는:
1. etcd 클러스터에 새 멤버로 참가 (분산 합의 확장)
2. kube-apiserver/scheduler/controller-manager static Pod 추가
3. 인증서(apiserver, etcd 등)를 `CERTIFICATE_KEY`로 복호화해 받아야 함

이 단계는 cp-02, cp-03 각각에서 순서대로 실행한다.

### cp-02에 SSH 접속

```bash
ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${NODE_IPS[cp-02]}
sudo -i
```

### cp-02 hostname 설정

```bash
hostnamectl set-hostname my-cluster-cp-02
```

### /etc/hosts 수정 (self-loop 방지)

```bash
NODE_IP="$(hostname -I | awk '{print $1}')"
sed -i '/k8s-api.village.internal$/d' /etc/hosts
echo "${NODE_IP} k8s-api.village.internal" >> /etc/hosts

grep "k8s-api" /etc/hosts
# 기대값: 10.30.5.10 k8s-api.village.internal
```

### join 설정 파일 작성

```bash
NODE_IP="$(hostname -I | awk '{print $1}')"
NODE_NAME="my-cluster-cp-02"

# join env 로드
source /opt/kubeadm/rendered/cluster-join.env

cat > /opt/kubeadm/rendered/kubeadm-join-cp.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${CONTROL_PLANE_ENDPOINT}:6443"
    token: "${BOOTSTRAP_TOKEN}"
    caCertHashes:
      - "sha256:${CA_CERT_HASH}"
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: ${NODE_NAME}
  taints:
    - key: node-role.kubernetes.io/control-plane
      value: ""
      effect: NoSchedule
  kubeletExtraArgs:
    node-ip: "${NODE_IP}"
    resolv-conf: /run/systemd/resolve/resolv.conf
    node-labels: "node-group=control-plane,workload-plane=control-plane"
# controlPlane 블록이 있으면 control-plane으로 join (없으면 worker)
controlPlane:
  certificateKey: "${CERTIFICATE_KEY}"  # cp-01에서 업로드한 인증서 복호화 키
  localAPIEndpoint:
    advertiseAddress: "${NODE_IP}"
    bindPort: 6443
EOF
```

### kubeadm join 실행

```bash
kubeadm join \
  --config /opt/kubeadm/rendered/kubeadm-join-cp.yaml \
  | tee /opt/kubeadm/logs/kubeadm-join-cp.log
```

완료 메시지 확인:
```
[kubelet-start] Starting the kubelet
This node has joined the cluster and a new control plane instance was created:
...
```

### kubectl 설정

```bash
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config
```

---

### cp-03도 동일하게 실행

```bash
# PC에서 cp-03에 SSH 접속 후
ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${NODE_IPS[cp-03]}
sudo -i
```

```bash
# cp-03에서 실행 (hostname만 다름)
hostnamectl set-hostname my-cluster-cp-03

NODE_IP="$(hostname -I | awk '{print $1}')"  # 10.30.9.10
sed -i '/k8s-api.village.internal$/d' /etc/hosts
echo "${NODE_IP} k8s-api.village.internal" >> /etc/hosts

source /opt/kubeadm/rendered/cluster-join.env

cat > /opt/kubeadm/rendered/kubeadm-join-cp.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${CONTROL_PLANE_ENDPOINT}:6443"
    token: "${BOOTSTRAP_TOKEN}"
    caCertHashes:
      - "sha256:${CA_CERT_HASH}"
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: my-cluster-cp-03
  taints:
    - key: node-role.kubernetes.io/control-plane
      value: ""
      effect: NoSchedule
  kubeletExtraArgs:
    node-ip: "${NODE_IP}"
    resolv-conf: /run/systemd/resolve/resolv.conf
    node-labels: "node-group=control-plane,workload-plane=control-plane"
controlPlane:
  certificateKey: "${CERTIFICATE_KEY}"
  localAPIEndpoint:
    advertiseAddress: "${NODE_IP}"
    bindPort: 6443
EOF

kubeadm join \
  --config /opt/kubeadm/rendered/kubeadm-join-cp.yaml \
  | tee /opt/kubeadm/logs/kubeadm-join-cp.log

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config
```

---

## Worker Node Join (app-01~04, data-01~03)

worker join은 control-plane join보다 단순하다. `controlPlane` 블록이 없고, CERTIFICATE_KEY도 필요 없다.
단, app과 data 노드는 서로 다른 **taint**를 가진다.

### app 노드 join 스크립트 (app-01~04)

PC에서 루프로 실행한다:

```bash
source ~/k8s-env.sh
source ~/cluster-join.env

for TAG in app-01 app-02 app-03 app-04; do
  IP=${NODE_IPS[$TAG]}
  NODE_NAME="my-cluster-${TAG}"

  echo "=== ${TAG} join 시작 ==="

  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${IP} \
    "sudo hostnamectl set-hostname ${NODE_NAME}"

  # join 설정 파일 생성 후 전송
  cat > /tmp/kubeadm-join-worker.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${CONTROL_PLANE_ENDPOINT}:6443"
    token: "${BOOTSTRAP_TOKEN}"
    caCertHashes:
      - "sha256:${CA_CERT_HASH}"
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: ${NODE_NAME}
  taints: []  # app 노드는 taint 없음 — 일반 workload 스케줄 가능
  kubeletExtraArgs:
    resolv-conf: /run/systemd/resolve/resolv.conf
    node-labels: "node-role=app,node-group=app,workload-plane=app"
EOF

  scp -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no \
    /tmp/kubeadm-join-worker.yaml ubuntu@${IP}:/tmp/kubeadm-join-worker.yaml

  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${IP} bash <<'REMOTE'
    sudo mv /tmp/kubeadm-join-worker.yaml /opt/kubeadm/rendered/kubeadm-join-worker.yaml
    sudo kubeadm join \
      --config /opt/kubeadm/rendered/kubeadm-join-worker.yaml \
      | sudo tee /opt/kubeadm/logs/kubeadm-join-worker.log
REMOTE

  echo "=== ${TAG} join 완료 ==="
done
```

### data 노드 join 스크립트 (data-01~03)

data 노드는 `workload-plane=data:NoSchedule` taint를 가진다.
이 taint가 있으면 일반 파드는 이 노드에 스케줄되지 않는다.
데이터베이스, 메시지 큐 등 data 전용 워크로드만 `toleration`을 추가해 실행할 수 있다.

```bash
source ~/k8s-env.sh
source ~/cluster-join.env

for TAG in data-01 data-02 data-03; do
  IP=${NODE_IPS[$TAG]}
  NODE_NAME="my-cluster-${TAG}"

  echo "=== ${TAG} join 시작 ==="

  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${IP} \
    "sudo hostnamectl set-hostname ${NODE_NAME}"

  cat > /tmp/kubeadm-join-worker.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${CONTROL_PLANE_ENDPOINT}:6443"
    token: "${BOOTSTRAP_TOKEN}"
    caCertHashes:
      - "sha256:${CA_CERT_HASH}"
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: ${NODE_NAME}
  taints:
    - key: workload-plane    # data 전용 워크로드만 허용
      value: "data"
      effect: NoSchedule
  kubeletExtraArgs:
    resolv-conf: /run/systemd/resolve/resolv.conf
    node-labels: "node-role=data,node-group=data,workload-plane=data"
EOF

  scp -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no \
    /tmp/kubeadm-join-worker.yaml ubuntu@${IP}:/tmp/kubeadm-join-worker.yaml

  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${IP} bash <<'REMOTE'
    sudo mv /tmp/kubeadm-join-worker.yaml /opt/kubeadm/rendered/kubeadm-join-worker.yaml
    sudo kubeadm join \
      --config /opt/kubeadm/rendered/kubeadm-join-worker.yaml \
      | sudo tee /opt/kubeadm/logs/kubeadm-join-worker.log
REMOTE

  echo "=== ${TAG} join 완료 ==="
done
```

---

## 전체 노드 join 확인

cp-01에서 실행한다.

```bash
# cp-01에 SSH 접속
ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${CP01_PUBLIC}
sudo kubectl get nodes
```

기대 출력:
```
NAME                  STATUS     ROLES           AGE
my-cluster-cp-01      NotReady   control-plane   15m
my-cluster-cp-02      NotReady   control-plane   8m
my-cluster-cp-03      NotReady   control-plane   5m
my-cluster-app-01     NotReady   <none>          3m
my-cluster-app-02     NotReady   <none>          3m
my-cluster-app-03     NotReady   <none>          3m
my-cluster-app-04     NotReady   <none>          3m
my-cluster-data-01    NotReady   <none>          2m
my-cluster-data-02    NotReady   <none>          2m
my-cluster-data-03    NotReady   <none>          2m
```

> **모두 NotReady여도 정상이다.** CNI(Calico)가 설치되지 않아서 파드 간 통신이 불가능한 상태다.
> etcd도 3개 모두 동작하는지 확인한다.

```bash
kubectl get pods -n kube-system | grep etcd
# etcd-my-cluster-cp-01   1/1   Running   0
# etcd-my-cluster-cp-02   1/1   Running   0
# etcd-my-cluster-cp-03   1/1   Running   0
```

---

## BOOTSTRAP_TOKEN 만료 시 갱신

token은 24시간, certificate-key는 2시간 유효하다. 그 이후에 join이 필요하면:

```bash
# cp-01에서 실행
# 새 bootstrap token
NEW_TOKEN=$(kubeadm token create)

# 새 certificate key
NEW_CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n1 | tr -d '\r')

echo "NEW_TOKEN=${NEW_TOKEN}"
echo "NEW_CERT_KEY=${NEW_CERT_KEY}"

# cluster-join.env 업데이트
sed -i "s/^BOOTSTRAP_TOKEN=.*/BOOTSTRAP_TOKEN=${NEW_TOKEN}/" /opt/kubeadm/rendered/cluster-join.env
sed -i "s/^CERTIFICATE_KEY=.*/CERTIFICATE_KEY=${NEW_CERT_KEY}/" /opt/kubeadm/rendered/cluster-join.env
```

---

다음: [05-calico.md](./05-calico.md) — cp-01에서 실행 (kubectl 사용)
