# 02. 노드 공통 설정

**대상: 전체 10대 노드 (cp-01~03, app-01~04, data-01~03)**

이 단계는 모든 노드에서 동일하게 실행한다.
containerd, kubelet, kubeadm, kubectl을 설치하고 커널 파라미터를 조정한다.

---

## SSH 접속

```bash
source ~/k8s-env.sh  # 01단계에서 저장한 변수

# cp-01 Public IP 가져오기
CP01_PUBLIC=$(aws ec2 describe-instances \
  --instance-ids $CP01 \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${CP01_PUBLIC}
```

이하 모든 명령은 **root 권한**으로 실행한다.

```bash
sudo -i
```

---

## 1. Swap 비활성화

**왜 필요한가?**
kubelet은 swap이 활성화된 상태에서 기본적으로 실행을 거부한다.
쿠버네티스는 파드의 메모리 limit을 정확히 보장하기 위해 swap을 사용하지 않아야 한다.
swap을 켜두면 OOM이 발생해야 할 파드가 죽지 않고 디스크를 사용하게 되어 예측 불가능한 성능 저하가 발생한다.

```bash
# 즉시 swap 끄기
swapoff -a

# 재부팅 후에도 비활성화 (fstab에서 swap 항목 주석 처리)
cp /etc/fstab /etc/fstab.bak
sed -ri '/\sswap\s/s/^/# /' /etc/fstab

# 확인: 아무것도 출력되지 않아야 정상
swapon --show
```

---

## 2. 커널 모듈 로드

**왜 필요한가?**
- `overlay`: containerd가 컨테이너 파일시스템(레이어)을 구성하는 데 사용하는 커널 모듈
- `br_netfilter`: 브리지 네트워크를 통과하는 패킷이 iptables를 거치게 만든다. 없으면 파드 간 통신에서 NetworkPolicy가 동작하지 않는다.

```bash
# 재부팅 시에도 자동 로드
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

# 지금 즉시 로드
modprobe overlay
modprobe br_netfilter

# 확인
lsmod | grep -E "^(overlay|br_netfilter)"
```

---

## 3. sysctl (커널 네트워크 파라미터)

**왜 필요한가?**
- `net.bridge.bridge-nf-call-iptables=1`: 브리지(도커/CNI가 만드는 가상 스위치)를 통과하는 패킷을 iptables가 검사하도록 한다. NetworkPolicy와 kube-proxy가 이 설정에 의존한다.
- `net.bridge.bridge-nf-call-ip6tables=1`: IPv6 동일 목적
- `net.ipv4.ip_forward=1`: 노드가 라우터처럼 패킷을 포워딩하도록 한다. 파드 트래픽이 노드를 경유할 때 필요하다.
- `vm.swappiness=0`: 커널이 swap을 최대한 사용하지 않도록 설정

```bash
cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
vm.swappiness=0
EOF

# 즉시 적용
sysctl --system

# 확인
sysctl net.ipv4.ip_forward
# 기대값: net.ipv4.ip_forward = 1
```

---

## 4. 필수 패키지 설치

```bash
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gpg \
  jq \
  openssl \
  software-properties-common
```

---

## 5. containerd 설치

**왜 containerd인가?**
쿠버네티스 1.24부터 dockershim이 제거되었다. kubelet은 CRI(Container Runtime Interface)를 통해 컨테이너 런타임과 통신하며, containerd가 표준 CRI 구현체다.

```bash
K8S_MINOR="v1.28"

# Kubernetes 저장소 GPG 키
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Kubernetes 저장소 등록
cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF

# containerd + kubernetes 설치
apt-get update
apt-get install -y containerd kubelet kubeadm kubectl

# 버전 고정 (apt upgrade 시 의도치 않은 업그레이드 방지)
apt-mark hold kubelet kubeadm kubectl
```

---

## 6. containerd 설정 — SystemdCgroup 활성화

**왜 중요한가?**
cgroup은 프로세스의 CPU/메모리 사용량을 제한하는 리눅스 기능이다.
kubelet과 컨테이너 런타임이 **같은 cgroup 드라이버**를 사용해야 한다.
Ubuntu 22.04+는 systemd cgroup v2를 기본으로 사용하므로 containerd도 `SystemdCgroup = true`로 설정해야 한다.
이 값이 불일치하면 kubelet이 파드를 시작하지 못하고 계속 재시작된다.

```bash
mkdir -p /etc/containerd

# 기본 설정 파일 생성
containerd config default > /etc/containerd/config.toml

# cgroupDriver를 systemd로 변경
# 기본값은 false(cgroupfs)이므로 반드시 바꿔야 한다
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 변경 확인
grep "SystemdCgroup" /etc/containerd/config.toml
# 기대값: SystemdCgroup = true
```

---

## 7. 서비스 활성화

```bash
systemctl daemon-reload

# containerd: 컨테이너 실행 담당
systemctl enable --now containerd

# kubelet: 이 노드에서 파드를 실행/관리. kubeadm join 전에는 대기 상태
systemctl enable kubelet

# containerd 상태 확인
systemctl status containerd --no-pager
# 기대값: active (running)
```

---

## 8. 작업 디렉토리 생성

```bash
mkdir -p \
  /opt/kubeadm/bin \
  /opt/kubeadm/templates \
  /opt/kubeadm/rendered \
  /opt/kubeadm/logs
```

---

## 전체 10대에 반복 실행하는 방법

위 1~8단계를 모든 노드에 실행해야 한다.
PC에서 아래 스크립트로 한 번에 배포할 수 있다.

```bash
source ~/k8s-env.sh

# 전체 노드 Public IP 수집
ALL_IPS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-*" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].PublicIpAddress" \
  --output text)

# node-setup.sh 스크립트 파일 생성
cat > /tmp/node-setup.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
K8S_MINOR="v1.28"

# 1. Swap 비활성화
swapoff -a
cp /etc/fstab /etc/fstab.bak
sed -ri '/\sswap\s/s/^/# /' /etc/fstab

# 2. 커널 모듈
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 3. sysctl
cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
vm.swappiness=0
EOF
sysctl --system

# 4. 패키지 설치
apt-get update -qq
apt-get install -y apt-transport-https ca-certificates curl gpg jq openssl software-properties-common

# 5. containerd + k8s 설치
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF
apt-get update -qq
apt-get install -y containerd kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 6. containerd cgroup 설정
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 7. 서비스 활성화
systemctl daemon-reload
systemctl enable --now containerd
systemctl enable kubelet

# 8. 디렉토리 생성
mkdir -p /opt/kubeadm/bin /opt/kubeadm/templates /opt/kubeadm/rendered /opt/kubeadm/logs

echo "=== node setup complete ==="
SCRIPT

# 각 노드에 스크립트 복사 후 실행
for IP in $ALL_IPS; do
  echo "=== $IP 설정 시작 ==="
  scp -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no \
    /tmp/node-setup.sh ubuntu@${IP}:/tmp/node-setup.sh
  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no \
    ubuntu@${IP} "sudo bash /tmp/node-setup.sh"
  echo "=== $IP 완료 ==="
done
```

---

## 확인

각 노드에서 아래 결과가 나와야 다음 단계로 진행할 수 있다.

```bash
# containerd 실행 중
systemctl is-active containerd
# → active

# kubelet은 아직 설정이 없어 실패 상태여도 정상
systemctl status kubelet --no-pager | head -5
# → 실패(activating)여도 무방 — kubeadm init/join 후 정상화

# 도구 버전 확인
kubeadm version
kubectl version --client
containerd --version
```

---

다음: [03-kubeadm-init.md](./03-kubeadm-init.md) — **cp-01에서만** 실행
