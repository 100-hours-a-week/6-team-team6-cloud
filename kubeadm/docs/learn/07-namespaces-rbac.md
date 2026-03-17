# 07. 네임스페이스 및 RBAC 설정

**대상: cp-01에서 kubectl 실행**

애플리케이션 경계를 네임스페이스로 분리하고, 각 팀/컴포넌트가 자기 영역만 조작할 수 있도록 RBAC을 구성한다.

---

## 네임스페이스 설계

| 네임스페이스 | 목적 | 주요 워크로드 |
|------------|------|-------------|
| `billage-app` | 애플리케이션 서비스 | API 서버, 백엔드 서비스 |
| `billage-data` | 데이터 계층 | DB, Redis, RabbitMQ 등 |
| `billage-edge` | 외부 진입점 | ingress smoke test, edge 서비스 |
| `billage-ops` | 운영 도구 | 모니터링, 로깅, CI/CD |

네임스페이스에 `platform.billage.io/boundary` 라벨을 붙인다.
이 라벨은 NetworkPolicy에서 `namespaceSelector`로 참조된다.

---

## 1. 네임스페이스 생성

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: billage-app
  labels:
    platform.billage.io/boundary: app
---
apiVersion: v1
kind: Namespace
metadata:
  name: billage-data
  labels:
    platform.billage.io/boundary: data
---
apiVersion: v1
kind: Namespace
metadata:
  name: billage-edge
  labels:
    platform.billage.io/boundary: edge
---
apiVersion: v1
kind: Namespace
metadata:
  name: billage-ops
  labels:
    platform.billage.io/boundary: ops
EOF

kubectl get ns billage-app billage-data billage-edge billage-ops
```

---

## 2. RBAC 설계 원칙

쿠버네티스 RBAC는 세 가지 오브젝트로 구성된다:

```
ServiceAccount  →  RoleBinding  →  Role
    (주체)          (연결)        (권한 목록)
```

- **ServiceAccount**: 파드 또는 CI/CD 파이프라인이 API 서버를 호출하는 주체
- **Role**: 특정 네임스페이스 안에서 허용할 리소스/동사(verb) 목록
- **RoleBinding**: ServiceAccount에 Role을 연결

여기서는 **최소 권한 원칙**으로 각 네임스페이스에 딱 필요한 권한만 부여한다.

---

## 3. billage-app: 앱 배포자

앱 배포자는 Deployment, Service, Ingress 등 일반 앱 리소스를 관리한다.
PersistentVolume이나 Node는 건드릴 수 없다.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: billage-app-deployer
  namespace: billage-app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: billage-app-deployer
  namespace: billage-app
rules:
  - apiGroups: [""]
    resources: ["configmaps", "pods", "pods/log", "secrets", "services"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["batch"]
    resources: ["cronjobs", "jobs"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: billage-app-deployer
  namespace: billage-app
subjects:
  - kind: ServiceAccount
    name: billage-app-deployer
    namespace: billage-app
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: billage-app-deployer
EOF
```

---

## 4. billage-data: 데이터 운영자

데이터 운영자는 StatefulSet, PVC 등 상태를 가진 리소스를 관리한다.
Deployment는 없고 StatefulSet만 있는 점에 주목한다.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: billage-data-operator
  namespace: billage-data
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: billage-data-operator
  namespace: billage-data
rules:
  - apiGroups: [""]
    resources: ["configmaps", "persistentvolumeclaims", "pods", "pods/log", "secrets", "services"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: billage-data-operator
  namespace: billage-data
subjects:
  - kind: ServiceAccount
    name: billage-data-operator
    namespace: billage-data
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: billage-data-operator
EOF
```

---

## 5. billage-edge: 엣지 운영자

edge 네임스페이스는 외부 노출 서비스만 다루므로 Deployment와 Ingress 권한만 갖는다.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: billage-edge-operator
  namespace: billage-edge
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: billage-edge-operator
  namespace: billage-edge
rules:
  - apiGroups: [""]
    resources: ["configmaps", "pods", "pods/log", "secrets", "services"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: billage-edge-operator
  namespace: billage-edge
subjects:
  - kind: ServiceAccount
    name: billage-edge-operator
    namespace: billage-edge
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: billage-edge-operator
EOF
```

---

## 6. billage-ops: 운영 도구 운영자

ops는 DaemonSet, ServiceAccount 등 더 넓은 권한이 필요하다.
모니터링 에이전트(DaemonSet), CI/CD 서비스 어카운트 생성 등을 담당한다.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: billage-ops-operator
  namespace: billage-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: billage-ops-operator
  namespace: billage-ops
rules:
  - apiGroups: [""]
    resources: ["configmaps", "pods", "pods/log", "secrets", "services", "serviceaccounts"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["apps"]
    resources: ["daemonsets", "deployments", "statefulsets"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["batch"]
    resources: ["cronjobs", "jobs"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: billage-ops-operator
  namespace: billage-ops
subjects:
  - kind: ServiceAccount
    name: billage-ops-operator
    namespace: billage-ops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: billage-ops-operator
EOF
```

---

## 확인

```bash
# 네임스페이스와 라벨 확인
kubectl get ns billage-app billage-data billage-edge billage-ops \
  -L platform.billage.io/boundary

# 기대 출력
# NAME           STATUS   AGE   BOUNDARY
# billage-app    Active   1m    app
# billage-data   Active   1m    data
# billage-edge   Active   1m    edge
# billage-ops    Active   1m    ops

# ServiceAccount 확인
kubectl get serviceaccount -n billage-app
kubectl get serviceaccount -n billage-data
kubectl get serviceaccount -n billage-edge
kubectl get serviceaccount -n billage-ops

# Role 권한 확인 예시
kubectl describe role billage-app-deployer -n billage-app
```

---

## RBAC 권한 테스트 (선택)

특정 ServiceAccount가 특정 동작을 할 수 있는지 확인한다.

```bash
# billage-app-deployer가 Deployment를 생성할 수 있는가?
kubectl auth can-i create deployments -n billage-app \
  --as=system:serviceaccount:billage-app:billage-app-deployer
# → yes

# billage-app-deployer가 Node를 조회할 수 있는가?
kubectl auth can-i get nodes \
  --as=system:serviceaccount:billage-app:billage-app-deployer
# → no
```

---

다음: [08-network-policy.md](./08-network-policy.md)
