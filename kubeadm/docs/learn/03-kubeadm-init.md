# 03. kubeadm init — Control Plane 초기화 (cp-01)

**대상: cp-01 단독**

cp-01에서 `kubeadm init`을 실행해 첫 번째 control-plane을 구성한다.
이 단계가 완료되면 kube-apiserver, etcd, kube-scheduler, kube-controller-manager가 static Pod로 올라온다.

---

## cp-01에 SSH 접속

```bash
source ~/k8s-env.sh

CP01_PUBLIC=$(aws ec2 describe-instances --instance-ids $CP01 \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${CP01_PUBLIC}
sudo -i
```

---

## 1. /etc/hosts 수정 — API 엔드포인트 로컬 우선 해석

**왜 필요한가?**
`controlPlaneEndpoint`로 `k8s-api.village.internal`을 사용하는데, 이 DNS는 NLB를 가리킨다.
cp-01이 NLB를 통해 자기 자신에게 연결하면 NLB 헬스체크가 통과하기 전에는 접속 불가 상태가 된다.
이를 해결하기 위해 cp-01의 `/etc/hosts`에 `k8s-api.village.internal → 자신의 private IP`를 직접 등록한다.
같은 이유로 cp-02, cp-03도 각자 자신의 IP를 등록한다.

```bash
# cp-01의 자신의 private IP 확인
NODE_IP="$(hostname -I | awk '{print $1}')"
echo "NODE_IP=$NODE_IP"
# 기대값: 10.30.1.10

# /etc/hosts에 추가 (중복 방지)
sed -i '/k8s-api.village.internal$/d' /etc/hosts
echo "${NODE_IP} k8s-api.village.internal" >> /etc/hosts

# 확인
grep "k8s-api" /etc/hosts
# 기대값: 10.30.1.10 k8s-api.village.internal
```

---

## 2. kubeadm init 설정 파일 작성

kubeadm은 설정 파일로 동작을 제어한다. 각 필드의 의미를 이해하는 것이 중요하다.

```bash
NODE_IP="$(hostname -I | awk '{print $1}')"
CLUSTER_NAME="my-cluster"

cat > /opt/kubeadm/templates/kubeadm-init.yaml <<EOF
# InitConfiguration: kubeadm init 동작 설정
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}  # 다른 노드에 알릴 이 노드의 API 서버 IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock  # containerd 소켓 경로
  name: ${CLUSTER_NAME}-cp-01  # 이 노드가 클러스터에 등록될 이름 (hostname과 일치시킬 것)
  taints:
    - key: node-role.kubernetes.io/control-plane
      value: ""
      effect: NoSchedule  # control-plane 노드에 일반 파드가 스케줄되지 않도록
  kubeletExtraArgs:
    node-ip: "${NODE_IP}"  # kubelet이 사용할 노드 IP
    resolv-conf: /run/systemd/resolve/resolv.conf  # systemd-resolved DNS 사용
    node-labels: "node-group=control-plane,workload-plane=control-plane"
---
# ClusterConfiguration: 클러스터 전체 설정
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: ${CLUSTER_NAME}
kubernetesVersion: v1.28.0
# HA를 위해 NLB DNS를 엔드포인트로 사용
# 이 주소로 kubeconfig와 kubelet이 API 서버에 접근한다
controlPlaneEndpoint: "k8s-api.village.internal:6443"
networking:
  podSubnet: "192.168.0.0/16"   # Calico IP Pool과 반드시 일치해야 함
  serviceSubnet: "10.96.0.0/12" # ClusterIP 범위
apiServer:
  # TLS 인증서에 포함될 이름들 (이 외의 이름으로 접근하면 TLS 오류 발생)
  certSANs:
    - k8s-api.village.internal
    - ${NODE_IP}
controllerManager:
  extraArgs:
    bind-address: 0.0.0.0  # Prometheus metrics 수집용 (기본값 127.0.0.1)
scheduler:
  extraArgs:
    bind-address: 0.0.0.0
etcd:
  local:
    dataDir: /var/lib/etcd
---
# KubeletConfiguration: 모든 노드의 kubelet 기본 설정
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd          # containerd의 SystemdCgroup = true와 반드시 일치
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
failSwapOn: false              # swap이 켜진 노드에서도 실패하지 않음 (swapoff 권장)
clusterDNS:
  - 10.96.0.10                 # CoreDNS ClusterIP
EOF
```

---

## 3. hostname 설정

kubeadm은 `nodeRegistration.name`이 실제 hostname과 일치해야 한다.

```bash
hostnamectl set-hostname my-cluster-cp-01

# 확인
hostname
# 기대값: my-cluster-cp-01
```

---

## 4. kubeadm init 실행

```bash
kubeadm init \
  --config /opt/kubeadm/templates/kubeadm-init.yaml \
  | tee /opt/kubeadm/logs/kubeadm-init.log
```

**소요 시간**: 약 2-4분. 아래와 같은 출력이 나와야 한다:

```
[init] Using Kubernetes version: v1.28.0
[preflight] Running pre-flight checks
[preflight] Pulling images required for setting up a Kubernetes control plane
...
[bootstrap-token] Creating the "cluster-info" ConfigMap in the "kube-public" namespace
...
Your Kubernetes control-plane has initialized successfully!
```

실패 시 로그 확인:
```bash
cat /opt/kubeadm/logs/kubeadm-init.log | tail -30
journalctl -u kubelet --no-pager | tail -30
```

---

## 5. kubectl 설정

```bash
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

# 정상 동작 확인
kubectl get nodes
# 기대: my-cluster-cp-01   NotReady (CNI 미설치 상태는 정상)

kubectl get pods -n kube-system
# 기대: etcd, kube-apiserver, kube-controller-manager, kube-scheduler 모두 Running
```

---

## 6. Join 정보 추출

cp-02, cp-03, worker 노드가 클러스터에 참가하려면 아래 세 가지 정보가 필요하다.

| 항목 | 설명 | 유효기간 |
|------|------|---------|
| BOOTSTRAP_TOKEN | worker/cp join용 일회성 토큰 | 24시간 |
| CA_CERT_HASH | API 서버 CA 인증서 지문 (조작 방지) | 무기한 |
| CERTIFICATE_KEY | control-plane join 시 인증서 공유용 암호화 키 | 2시간 |

```bash
# 새 bootstrap token 생성 (kubeadm init이 만든 토큰은 사용하지 않고 새로 생성)
BOOTSTRAP_TOKEN=$(kubeadm token create)

# CA 인증서 해시 (SHA256 fingerprint)
CA_CERT_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl pkey -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex \
  | awk '{print $2}')

# control-plane join용 인증서 키 (etcd/apiserver 인증서를 암호화해 etcd에 저장)
CERTIFICATE_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null \
  | tail -n 1 | tr -d '\r')

echo "BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}"
echo "CA_CERT_HASH=${CA_CERT_HASH}"
echo "CERTIFICATE_KEY=${CERTIFICATE_KEY}"
```

---

## 7. cluster-join.env 저장

이 파일을 cp-02, cp-03, worker 노드에 전달해야 한다.

```bash
cat > /opt/kubeadm/rendered/cluster-join.env <<EOF
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
CA_CERT_HASH=${CA_CERT_HASH}
CERTIFICATE_KEY=${CERTIFICATE_KEY}
CONTROL_PLANE_ENDPOINT=k8s-api.village.internal
EOF

chmod 600 /opt/kubeadm/rendered/cluster-join.env
cat /opt/kubeadm/rendered/cluster-join.env
```

---

## 8. Join env를 로컬 PC로 복사

```bash
# PC에서 실행
source ~/k8s-env.sh

CP01_PUBLIC=$(aws ec2 describe-instances --instance-ids $CP01 \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

scp -i ~/.ssh/${KEY_NAME}.pem \
  ubuntu@${CP01_PUBLIC}:/opt/kubeadm/rendered/cluster-join.env \
  ~/cluster-join.env

cat ~/cluster-join.env
```

---

## 현재 상태 확인

```bash
# cp-01에서 실행
kubectl get nodes
# NAME               STATUS     ROLES           AGE
# my-cluster-cp-01   NotReady   control-plane   3m
# → NotReady는 CNI(Calico) 미설치 상태이므로 정상

kubectl get pods -n kube-system
# NAME                                     READY   STATUS    RESTARTS
# etcd-my-cluster-cp-01                    1/1     Running   0
# kube-apiserver-my-cluster-cp-01          1/1     Running   0
# kube-controller-manager-my-cluster-cp-01 1/1     Running   0
# kube-scheduler-my-cluster-cp-01          1/1     Running   0
# coredns-xxx                              0/1     Pending   0  ← CNI 없어서 Pending, 정상
```

---

다음: [04-node-join.md](./04-node-join.md) — cp-02/03, app/data 노드에서 실행
