# 클러스터 핵심 정보

kubeadm self-managed 클러스터. 10노드, ap-northeast-2.

---

## 접속

```bash
cd kubeadm/envs/prod
CP01=$(terraform output -json control_plane_instance_ids | jq -r '."cp-01"')
aws ssm start-session --target "$CP01" --region ap-northeast-2

# 접속 후
sudo -i
kubectl get nodes
```

---

## 노드

| 노드 | 수 | 라벨 | taint |
|------|----|------|-------|
| cp-01/02/03 | 3 | `workload-plane=control-plane` | NoSchedule |
| app-01/02/03/04 | 4 | `workload-plane=app` | 없음 |
| data-01/02/03 | 3 | `workload-plane=data` | `workload-plane=data:NoSchedule` |

data 노드에 배포하려면 반드시 toleration 필요:
```yaml
tolerations:
  - key: workload-plane
    value: data
    effect: NoSchedule
nodeSelector:
  workload-plane: data
```

---

## 네임스페이스 / ServiceAccount

| 네임스페이스 | 용도 | ServiceAccount |
|-------------|------|----------------|
| `billage-app` | 애플리케이션 | `billage-app-deployer` |
| `billage-data` | RabbitMQ, Qdrant 등 데이터 | `billage-data-operator` |
| `billage-edge` | edge / TLS | `billage-edge-operator` |
| `billage-ops` | 운영 도구 (ArgoCD, 모니터링 등) | `billage-ops-operator` |

---

## NetworkPolicy (기적용)

| 허용 경로 |
|----------|
| ingress-nginx → billage-edge |
| billage-edge → billage-app |
| billage-app → billage-data |
| billage-ops → billage-data |
| billage-data 내부 |
| billage-ops 외부 HTTPS egress |
| 전체 → kube-system DNS (UDP 53) |

그 외 모든 인바운드는 default-deny. 추가 경로 필요하면 NetworkPolicy 직접 추가.

---

## 설치된 컴포넌트

| 컴포넌트 | 네임스페이스 | 비고 |
|---------|------------|------|
| Calico CNI | calico-system | BGP full-mesh, Pod CIDR 192.168.0.0/16 |
| ingress-nginx | ingress-nginx | NodePort, `ingressClassName: nginx` |
| aws-load-balancer-controller | kube-system | internet-facing ALB 자동 생성 |
| cert-manager | cert-manager | Let's Encrypt, `edge-public-tls` 시크릿 발급됨 |
| metrics-server | kube-system | HPA 사용 가능 |
| EBS CSI Driver | kube-system | — |
| StorageClass `gp3` | — | **default**, `WaitForFirstConsumer`, `Retain` |

---

## Ingress 트래픽 경로

```
인터넷 → ALB (ACM TLS 종료) → ingress-nginx (NodePort) → Ingress → Service → Pod
```

Ingress 등록 시 `ingressClassName: nginx`, TLS secret은 `edge-public-tls` 사용 가능.

---

## Service CIDR / Pod CIDR

| 구분 | CIDR |
|------|------|
| VPC | 10.30.0.0/16 |
| Service | 10.96.0.0/12 |
| Pod (Calico) | 192.168.0.0/16 |
| Cluster DNS | 10.96.0.10 |