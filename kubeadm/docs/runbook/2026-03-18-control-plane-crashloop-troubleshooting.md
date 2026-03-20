# 2026-03-18 Control Plane CrashLoopBackOff 트러블슈팅 보고서

## 증상

- kubeadm init 완료 후 etcd, kube-apiserver, kube-scheduler, kube-controller-manager 전부 **CrashLoopBackOff**
- `kubectl get nodes` 실행 시 `connection refused` (apiserver 간헐적 다운)
- apiserver가 올라와도 **수분 내 다시 종료** (exit code 0, graceful shutdown)
- 4시간 이상 CrashLoop 반복 (restart count 60+)

## 환경

- Kubernetes: v1.28.15
- OS: Ubuntu 24.04.4 LTS
- Kernel: 6.17.0-1007-aws
- Container Runtime: containerd 1.7.28
- CNI: 미설치 상태에서 발생
- 인스턴스: m7i.large (2 vCPU, 8GB RAM)

## 근본 원인 (2가지)

### 원인 1: containerd sandbox image 불일치 (핵심)

```
containerd 설정:  sandbox_image = "registry.k8s.io/pause:3.8"
kubeadm 기대값:   registry.k8s.io/pause:3.9
```

- containerd는 pause:3.8로 pod sandbox를 생성
- kubelet은 pause:3.9를 기대하여 sandbox hash 불일치 감지
- kubelet이 sandbox를 **반복적으로 Stop → Recreate**
- sandbox가 재생성되면 그 안의 모든 컨테이너(etcd, apiserver 등)가 SIGTERM을 받고 종료
- exit code 0 (graceful shutdown) → CrashLoopBackOff 진입

**증거:**
```
# containerd 로그에서 sandbox 반복 재생성 확인
StopPodSandbox for "6fe5c97d13ddd..." → RunPodSandbox Attempt:41
StopPodSandbox for "e522bf5386d76..." → RunPodSandbox Attempt:53

# kubeadm init 시 경고 메시지
W0318 07:46:00 checks.go:835] detected that the sandbox image
"registry.k8s.io/pause:3.8" of the container runtime is inconsistent
with that used by kubeadm. It is recommended that using
"registry.k8s.io/pause:3.9" as the CRI sandbox image.
```

### 원인 2: CNI 미설치로 NetworkPluginNotReady

- kubeadm init 후 Calico 설치 전까지 kubelet이 `NetworkReady=false` 상태
- `Container runtime network not ready` 로그 지속 출력
- 이 상태에서 sandbox 재생성이 더 빈번하게 발생
- 노드가 `NotReady` 상태 → kube-proxy 등 추가 CrashLoop 유발

**증거:**
```
E0318 05:24:17 kubelet.go:2874] "Container runtime network not ready"
networkReady="NetworkReady=false reason:NetworkPluginNotReady
message:Network plugin retu..."
```

## 혼동을 준 요인들

| 확인 항목 | 결과 | 왜 혼동을 줬는가 |
|-----------|------|------------------|
| OOM kill | 없음 | 메모리 6.7GB 가용 |
| 디스크 | 89% 여유 | 디스크 문제 아님 |
| etcd 로그 | 정상 시작, 리더 선출 성공 | etcd 자체는 문제없음 |
| apiserver 로그 | 정상 시작, cache sync 성공 | apiserver 자체도 문제없음 |
| exit code | 0 (Completed) | 크래시가 아닌 graceful shutdown이라 원인 추적 어려움 |
| liveness probe | 실패 로그 없음 | probe가 아닌 sandbox 재생성이 원인 |
| manifest 파일 | 변경 없음 (md5 동일) | manifest 변경도 아님 |

## 해결 방법

### 1. sandbox image 수정

```bash
# /etc/containerd/config.toml 에서 pause 버전 변경
sed -i 's|sandbox_image = "registry.k8s.io/pause:3.8"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml

# 이미지 pull 및 containerd 재시작
crictl pull registry.k8s.io/pause:3.9
systemctl restart containerd
systemctl restart kubelet
```

### 2. kubeadm reset 후 재초기화 (기존 클러스터가 오염된 경우)

```bash
kubeadm reset -f
rm -rf /var/lib/etcd
/opt/kubeadm/bin/control-plane-init.sh
```

### 3. Calico CNI 즉시 설치 (init 직후)

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

### 4. Terraform 영구 수정

`kubeadm/envs/prod/templates/bootstrap-common.sh.tftpl`에 추가:

```bash
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# ↓ 이 줄 추가
sed -ri 's|sandbox_image = "registry.k8s.io/pause:3.8"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml
```

## 디버깅 과정에서 유용했던 명령어

```bash
# 컨테이너 상태 확인 (kubectl 안 될 때)
crictl ps -a | head -15

# 컨테이너 로그 확인
crictl logs <container-id> 2>&1 | tail -50

# 컨테이너 종료 원인 확인
crictl inspect <container-id> | grep -E 'exitCode|reason|oomKill'

# sandbox 재생성 확인 (containerd 로그)
journalctl -u containerd --since "5 minutes ago" | grep -i sandbox

# kubelet이 pod를 죽이는 이유 확인
journalctl -u kubelet --since "5 minutes ago" | grep -i -E 'kill|liveness|Unhealthy|probe'

# OOM 확인
dmesg | grep -i -E 'oom|kill'

# static pod manifest 변경 여부
md5sum /etc/kubernetes/manifests/*.yaml
```

## 교훈

1. **kubeadm init 경고 메시지를 무시하지 말 것** — sandbox image 불일치 경고가 근본 원인이었음
2. **CNI는 kubeadm init 직후 즉시 설치할 것** — 지연되면 kubelet 불안정 유발
3. **exit code 0은 "정상"이 아닐 수 있음** — SIGTERM을 graceful하게 처리한 것일 뿐, 외부에서 강제 종료된 것
4. **sandbox 재생성은 kubelet 로그가 아닌 containerd 로그에서 확인** — `journalctl -u containerd | grep sandbox`
5. **terraform cloud-init에서 containerd 설정을 kubeadm 버전과 맞출 것** — `containerd config default`가 생성하는 기본값이 kubeadm과 다를 수 있음
