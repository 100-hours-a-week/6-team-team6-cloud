# Kubernetes 클러스터 구축 학습 런북

AWS에서 kubeadm 기반 쿠버네티스 클러스터를 처음부터 직접 구축하는 Step-by-Step 학습 가이드.
모든 명령어를 직접 실행하며 각 단계가 **왜 필요한지** 이해하는 것을 목표로 한다.

---

## 학습 순서

| # | 파일 | 핵심 내용 | 대상 노드 |
|---|------|----------|----------|
| 0 | [00-overview.md](./00-overview.md) | 아키텍처 전체 구조, 네트워크 설계 | - |
| 1 | [01-aws-infra.md](./01-aws-infra.md) | VPC/서브넷/SG/IAM/EC2/NLB/Route53 | 로컬 PC |
| 2 | [02-node-setup.md](./02-node-setup.md) | swap/sysctl/containerd/kubelet 설치 | **전체 10대** |
| 3 | [03-kubeadm-init.md](./03-kubeadm-init.md) | kubeadm init, join env 추출 | **cp-01** |
| 4 | [04-node-join.md](./04-node-join.md) | cp-02/03 join, app/data worker join | cp-02/03, workers |
| 5 | [05-calico.md](./05-calico.md) | Calico CNI, BGP mesh, 노드 Ready | cp-01 (kubectl) |
| 6 | [06-labels-taints.md](./06-labels-taints.md) | 노드 라벨, taint (app/data 분리) | cp-01 (kubectl) |
| 7 | [07-namespaces-rbac.md](./07-namespaces-rbac.md) | 네임스페이스 4개, SA/Role/RoleBinding | cp-01 (kubectl) |
| 8 | [08-network-policy.md](./08-network-policy.md) | default-deny + whitelist 규칙 | cp-01 (kubectl) |
| 9 | [09-ingress-alb.md](./09-ingress-alb.md) | Helm, ingress-nginx, aws-lbc, ALB Ingress | cp-01 (kubectl) |
| 10 | [10-cert-manager.md](./10-cert-manager.md) | cert-manager, ClusterIssuer, TLS 인증서 | cp-01 (kubectl) |

---

## 핵심 개념 정리

| 개념 | 한 줄 요약 |
|------|----------|
| kubeadm init | 첫 번째 control-plane 노드 초기화. etcd + apiserver + scheduler + controller 시작 |
| kubeadm join | 나머지 노드를 클러스터에 합류시킴. CP join은 etcd 확장, worker join은 kubelet만 등록 |
| containerd | 컨테이너 런타임. kubelet이 CRI 소켓으로 통신해 컨테이너를 실행시킴 |
| CNI (Calico) | 파드에 IP를 할당하고 파드 간 통신을 라우팅. 없으면 노드가 NotReady |
| BGP | 오버레이 없이 각 노드가 자신의 Pod CIDR을 서로 광고해 L3 라우팅으로 통신 |
| Taint/Toleration | 노드를 "기피" 상태로 만들어 특정 파드만 스케줄되도록 제어 |
| NetworkPolicy | 파드 간 트래픽을 iptables/Calico로 제어. default-deny가 기본 보안 원칙 |
| ingress-nginx | 클러스터 내 HTTP 라우팅. Ingress 리소스를 보고 nginx 설정을 자동 갱신 |
| aws-lbc | Ingress(ingressClassName: alb) 리소스를 보고 AWS ALB를 자동 생성/관리 |
| cert-manager | Certificate 리소스를 보고 Let's Encrypt에서 TLS 인증서를 자동 발급/갱신 |

---

## 완료 기준

```bash
# cp-01에서 실행
kubectl get nodes -L node-group,workload-plane
# → 10대 모두 Ready, 라벨 확인

kubectl get pods -n calico-system
# → calico-node (10개), calico-kube-controllers, calico-typha 모두 Running

kubectl get ns billage-app billage-data billage-edge billage-ops
# → 4개 Active

kubectl get networkpolicy -A --no-headers | wc -l
# → 14개 이상

kubectl get pods -n ingress-nginx
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
# → 모두 Running

kubectl get certificate -n billage-edge
# → READY: True

curl https://<public_edge_host>/
# → "billage-edge ok"
```
