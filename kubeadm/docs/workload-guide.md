# B 담당자 워크로드 운영 가이드

**전제**: A 담당자의 runbook(00~05)이 완료된 상태. 클러스터 10대 Ready, 네임스페이스/RBAC/NetworkPolicy/ingress-nginx/cert-manager 적용 완료.

---

## 1. 클러스터 접근 (kubeconfig)

### cp-01에 SSM 접속 후 kubectl 사용

```bash
cd kubeadm/envs/prod
CP01=$(terraform output -json control_plane_instance_ids | jq -r '."cp-01"')

aws ssm start-session --target "$CP01" --region ap-northeast-2
```

접속 후:
```bash
sudo -i
kubectl get nodes
```

> 인스턴스 ID를 모를 때는 [ssm-connect.md](./ssm-connect.md) 참고.

---

## 2. 클러스터 구조

### 노드 구성

```
kubectl get nodes -L node-group,workload-plane
```

| 노드 | 수 | node-group | workload-plane | taint |
|------|-----|------------|----------------|-------|
| cp-01/02/03 | 3 | control-plane | control-plane | NoSchedule |
| app-01/02/03/04 | 4 | app | app | 없음 |
| data-01/02/03 | 3 | data | data | `workload-plane=data:NoSchedule` |

**app 노드**: 일반 애플리케이션 (Spring Boot, Next.js, FastAPI, ingress-nginx 등)
**data 노드**: 데이터 workload 전용 (RabbitMQ, Qdrant). toleration 없으면 스케줄링 안 됨.

### 네임스페이스

| 네임스페이스 | 용도 | ServiceAccount |
|-------------|------|----------------|
| `billage-app` | Spring Boot, Next.js, FastAPI | `billage-app-deployer` |
| `billage-data` | RabbitMQ, Qdrant | `billage-data-operator` |
| `billage-edge` | edge 서비스, TLS 인증서 | `billage-edge-operator` |
| `billage-ops` | ArgoCD, Prometheus, Grafana, Loki | `billage-ops-operator` |

---

## 3. 워크로드 배포 규칙

### app 노드에 배포 (기본)

```yaml
spec:
  nodeSelector:
    workload-plane: app
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app: <your-app>
```

### data 노드에 배포 (RabbitMQ, Qdrant)

```yaml
spec:
  nodeSelector:
    workload-plane: data
  tolerations:
    - key: workload-plane
      value: data
      effect: NoSchedule
```

### NetworkPolicy 허용 범위 (이미 적용됨)

| 통신 방향 | 허용 여부 |
|-----------|----------|
| ingress-nginx → billage-edge | ✅ |
| billage-edge → billage-app | ✅ |
| billage-app → billage-data | ✅ |
| billage-ops → billage-data | ✅ |
| billage-data 내부 통신 | ✅ |
| billage-ops 외부 HTTPS | ✅ |
| 그 외 모든 인바운드 | ❌ default-deny |

> 새로운 통신 경로가 필요하면 NetworkPolicy를 직접 추가해야 한다.

### Ingress 등록

외부 트래픽 경로: `ALB → ingress-nginx(NodePort) → Ingress → Service → Pod`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: billage-app
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  ingressClassName: nginx
  rules:
    - host: api.billages.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: my-app-svc
                port:
                  number: 8080
  tls:
    - hosts:
        - api.billages.com
      secretName: edge-public-tls  # cert-manager가 이미 발급한 인증서
```

### 스토리지 (PVC)

gp3 StorageClass가 기본(default)으로 설정되어 있다.

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: gp3
      resources:
        requests:
          storage: 10Gi
```

---

## 4. 주요 workload 배포 패턴

### Service

모든 Deployment/StatefulSet에 대응하는 Service가 필요하다.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: spring-app-svc
  namespace: billage-app
spec:
  selector:
    app: spring-app
  ports:
    - port: 8080
      targetPort: 8080
```

StatefulSet headless Service (RabbitMQ/Qdrant DNS 기반 클러스터링에 필수):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq-headless
  namespace: billage-data
spec:
  clusterIP: None
  selector:
    app: rabbitmq
  ports:
    - port: 5672
```

---

### Deployment (Spring Boot / Next.js / FastAPI)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spring-app
  namespace: billage-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: spring-app
  template:
    metadata:
      labels:
        app: spring-app
    spec:
      serviceAccountName: billage-app-deployer
      nodeSelector:
        workload-plane: app
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: spring-app
      containers:
        - name: app
          image: <ECR_URI>/spring-app:latest
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 40
            periodSeconds: 15
```

### StatefulSet (RabbitMQ 3노드 quorum)

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rabbitmq
  namespace: billage-data
spec:
  serviceName: rabbitmq-headless
  replicas: 3
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      serviceAccountName: billage-data-operator
      nodeSelector:
        workload-plane: data
      tolerations:
        - key: workload-plane
          value: data
          effect: NoSchedule
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: rabbitmq
              topologyKey: kubernetes.io/hostname
      containers:
        - name: rabbitmq
          image: rabbitmq:3.13-management
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 2Gi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources:
          requests:
            storage: 20Gi
```

### StatefulSet (Qdrant)

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: qdrant
  namespace: billage-data
spec:
  serviceName: qdrant-headless
  replicas: 1
  selector:
    matchLabels:
      app: qdrant
  template:
    metadata:
      labels:
        app: qdrant
    spec:
      serviceAccountName: billage-data-operator
      nodeSelector:
        workload-plane: data
      tolerations:
        - key: workload-plane
          value: data
          effect: NoSchedule
      containers:
        - name: qdrant
          image: qdrant/qdrant:latest
          ports:
            - containerPort: 6333
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 4Gi
          volumeMounts:
            - name: data
              mountPath: /qdrant/storage
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources:
          requests:
            storage: 50Gi
```

---

## 5. HPA

metrics-server가 이미 설치되어 있다 (`kubectl top nodes`로 확인).

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: spring-app-hpa
  namespace: billage-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: spring-app
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
```

> app 노드가 4대이므로 maxReplicas는 노드당 스케줄 가능한 수 × 4 이하로 설정.

---

## 6. PDB

롤링 업데이트/노드 드레인 시 최소 가용 Pod 수를 보장한다.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: spring-app-pdb
  namespace: billage-app
spec:
  minAvailable: 1      # 또는 maxUnavailable: 1
  selector:
    matchLabels:
      app: spring-app
```

---

## 7. ArgoCD 설치

`billage-ops` 네임스페이스에 설치한다.

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update

helm upgrade --install argocd argo/argo-cd \
  --namespace billage-ops \
  --create-namespace \
  --set server.service.type=ClusterIP \
  --wait --timeout 300s
```

초기 admin 비밀번호 확인:
```bash
kubectl get secret argocd-initial-admin-secret -n billage-ops \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

UI 접근 (cp-01에서 port-forward):
```bash
kubectl port-forward svc/argocd-server -n billage-ops 8080:443
# 브라우저: https://localhost:8080  (인증서 경고 무시)
```

### ArgoCD Application 구성

```yaml
# billage-app 배포
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: billage-app
  namespace: billage-ops
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo
    targetRevision: main
    path: k8s/billage-app
  destination:
    server: https://kubernetes.default.svc
    namespace: billage-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
# billage-data 배포
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: billage-data
  namespace: billage-ops
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo
    targetRevision: main
    path: k8s/billage-data
  destination:
    server: https://kubernetes.default.svc
    namespace: billage-data
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 8. 모니터링 스택 (Prometheus + Grafana + Loki)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update

# kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace billage-ops \
  --set grafana.adminPassword=changeme \
  --set prometheus.prometheusSpec.nodeSelector.workload-plane=app \
  --set grafana.nodeSelector.workload-plane=app \
  --wait --timeout 300s

# Loki
helm upgrade --install loki grafana/loki-stack \
  --namespace billage-ops \
  --set loki.nodeSelector.workload-plane=app \
  --set promtail.enabled=true \
  --wait --timeout 300s
```

> `billage-ops` 네임스페이스는 `allow-ops-egress-https` NetworkPolicy로 외부 HTTPS 통신이 허용되어 있다.

Prometheus가 `billage-app`, `billage-data` 등 다른 네임스페이스의 메트릭을 수집하려면 NetworkPolicy를 추가해야 한다:

```yaml
# billage-app에서 Prometheus 스크래핑 허용
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: billage-app
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: billage-ops
      ports:
        - port: 8080   # 앱 메트릭 포트로 변경
```

`billage-data`에도 동일하게 적용한다.

---

## 9. Qdrant 백업 CronJob (S3)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: qdrant-backup
  namespace: billage-data
spec:
  schedule: "0 3 * * *"   # 매일 새벽 3시
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: billage-data-operator
          nodeSelector:
            workload-plane: data
          tolerations:
            - key: workload-plane
              value: data
              effect: NoSchedule
          containers:
            - name: backup
              image: amazon/aws-cli:latest
              command:
                - /bin/sh
                - -c
                - |
                  # Qdrant snapshot 생성
                  curl -X POST http://qdrant:6333/snapshots
                  # S3 업로드
                  aws s3 sync /qdrant/snapshots s3://your-backup-bucket/qdrant/$(date +%Y%m%d)/
              env:
                - name: AWS_DEFAULT_REGION
                  value: ap-northeast-2
          restartPolicy: OnFailure
```

> 노드 instance profile에 S3 write 권한이 있어야 한다. 없으면 IAM 정책 추가 필요.

---

## 10. 현재 상태 빠른 확인

```bash
# 노드 상태
kubectl get nodes -L node-group,workload-plane

# 전체 Pod 이상 여부
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 네임스페이스별 리소스
kubectl get all -n billage-app
kubectl get all -n billage-data
kubectl get all -n billage-ops

# StorageClass (PVC 사용 전 확인)
kubectl get storageclass

# HPA 상태
kubectl get hpa -A

# 인증서 상태
kubectl get certificate -n billage-edge
```