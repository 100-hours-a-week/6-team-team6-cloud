# 08. NetworkPolicy — Default Deny + Whitelist

**대상: cp-01에서 kubectl 실행**

NetworkPolicy는 파드 간 트래픽을 제어한다. Calico가 설치되어 있어야 적용된다.

---

## 설계 원칙: Default Deny + Whitelist

보안의 기본은 **"허용되지 않은 것은 모두 차단"** 이다.

```
각 네임스페이스에 default-deny-all 적용
  → 모든 Ingress/Egress 차단
  → 필요한 통신만 whitelist 규칙으로 허용
```

단, **kube-system DNS (port 53)** 은 모든 네임스페이스에서 열어두어야 한다.
서비스 이름(예: `my-service.billage-app.svc.cluster.local`) 해석이 안 되면 아무것도 동작하지 않기 때문이다.

---

## 우리 클러스터의 트래픽 흐름

```
인터넷
  → ALB (포트 443/80)
    → ingress-nginx (NodePort)
      → billage-edge (edge smoke service, 포트 5678)
        → billage-app (앱 서비스)
          → billage-data (DB/MQ, 포트 5432/5672 등)

billage-ops → billage-data (운영 쿼리)
```

---

## 1. Default Deny — 4개 네임스페이스 전체 차단

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl apply -f - <<'EOF'
# billage-app: 기본 전체 차단
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: billage-app
spec:
  podSelector: {}       # 네임스페이스 내 모든 파드에 적용
  policyTypes:
    - Ingress
    - Egress
---
# billage-data: 기본 전체 차단
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: billage-data
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# billage-edge: 기본 전체 차단
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: billage-edge
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# billage-ops: 기본 전체 차단
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: billage-ops
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF
```

---

## 2. DNS Egress 허용 — 4개 네임스페이스 공통

```bash
kubectl apply -f - <<'EOF'
# billage-app DNS 허용
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: billage-app
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system  # CoreDNS가 있는 네임스페이스
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: billage-data
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: billage-edge
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: billage-ops
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF
```

---

## 3. billage-app Whitelist

### Ingress: ingress-nginx / billage-edge → billage-app

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-from-edge
  namespace: billage-app
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: billage-edge
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 3000    # Grafana 등
        - protocol: TCP
          port: 8080    # 앱 HTTP
        - protocol: TCP
          port: 8000    # 앱 HTTP alternate
EOF
```

### Egress: billage-app → billage-data

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-data
  namespace: billage-app
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: billage-data
      ports:
        - protocol: TCP
          port: 5672    # RabbitMQ AMQP
        - protocol: TCP
          port: 15672   # RabbitMQ Management
        - protocol: TCP
          port: 6333    # Qdrant HTTP
        - protocol: TCP
          port: 6334    # Qdrant gRPC
EOF
```

---

## 4. billage-data Whitelist

```bash
kubectl apply -f - <<'EOF'
# data 네임스페이스 내부 통신 허용 (DB 클러스터 replication 등)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-data-intra-namespace
  namespace: billage-data
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - podSelector: {}  # 같은 네임스페이스의 모든 파드
  egress:
    - to:
        - podSelector: {}
---
# billage-app, billage-ops 에서 data로 접근 허용
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-data-from-app-and-ops
  namespace: billage-data
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: billage-app
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: billage-ops
      ports:
        - protocol: TCP
          port: 5672    # RabbitMQ AMQP
        - protocol: TCP
          port: 15672   # RabbitMQ Management
        - protocol: TCP
          port: 6333    # Qdrant HTTP
        - protocol: TCP
          port: 6334    # Qdrant gRPC
EOF
```

---

## 5. billage-edge Whitelist

```bash
kubectl apply -f - <<'EOF'
# ingress-nginx → billage-edge (edge smoke service 등)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-edge-from-ingress-nginx
  namespace: billage-edge
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 5678    # http-echo (smoke test)
        - protocol: TCP
          port: 8089    # 기타 edge 서비스
EOF
```

---

## 6. billage-ops Whitelist

```bash
kubectl apply -f - <<'EOF'
# ops 파드가 외부 HTTPS(Helm, container registry 등) 요청 가능
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ops-egress-https
  namespace: billage-ops
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0   # 모든 외부 IP
      ports:
        - protocol: TCP
          port: 443
EOF
```

---

## 확인

```bash
kubectl get networkpolicy -A
```

기대 출력 (12개 이상):
```
NAMESPACE      NAME                        POD-SELECTOR   AGE
billage-app    default-deny-all            <none>         1m
billage-app    allow-dns-egress            <none>         1m
billage-app    allow-app-from-edge         <none>         1m
billage-app    allow-app-to-data           <none>         1m
billage-data   default-deny-all            <none>         1m
billage-data   allow-dns-egress            <none>         1m
billage-data   allow-data-intra-namespace  <none>         1m
billage-data   allow-data-from-app-and-ops <none>         1m
billage-edge   default-deny-all            <none>         1m
billage-edge   allow-dns-egress            <none>         1m
billage-edge   allow-edge-from-ingress-nginx <none>       1m
billage-ops    default-deny-all            <none>         1m
billage-ops    allow-dns-egress            <none>         1m
billage-ops    allow-ops-egress-https      <none>         1m
```

---

## NetworkPolicy 동작 확인 (선택)

```bash
# billage-app에 테스트 파드 실행
kubectl run test-app -n billage-app \
  --image=busybox --restart=Never \
  --command -- sleep 3600

# DNS는 되어야 함
kubectl exec -n billage-app test-app -- nslookup kubernetes.default
# → 성공

# 외부 인터넷 접근은 차단되어야 함 (allow-app-to-data 외 Egress 없음)
kubectl exec -n billage-app test-app -- wget -T3 -q google.com -O- 2>&1
# → wget: download timed out (차단 확인)

# 테스트 파드 정리
kubectl delete pod test-app -n billage-app
```

---

다음: [09-ingress-alb.md](./09-ingress-alb.md)
