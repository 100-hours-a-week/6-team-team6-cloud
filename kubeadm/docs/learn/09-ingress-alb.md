# 09. Ingress Controller + AWS Load Balancer Controller

**대상: cp-01에서 kubectl/helm 실행**

외부 트래픽이 클러스터 안으로 들어오는 경로를 구성한다.

**트래픽 경로**:
```
인터넷 → ALB (AWS, internet-facing, HTTPS:443) → ingress-nginx (NodePort, HTTP:443) → 파드
```

**왜 이 구조인가?**
- ALB: AWS에서 관리하는 L7 로드 밸런서. ACM TLS 인증서로 외부 HTTPS를 처리한다.
- ingress-nginx: 클러스터 안의 실제 HTTP 라우팅(경로 기반, 호스트 기반)을 담당한다.
- ALB가 직접 파드로 연결하지 않고 nginx를 거치는 이유: nginx가 클러스터 내부 서비스 디스커버리, 재시도, 헤더 조작 등 더 세밀한 제어를 제공하기 때문이다.

---

## Helm 설치

Helm은 쿠버네티스 패키지 매니저다. ingress-nginx와 aws-lbc는 Helm chart로 설치한다.

```bash
# cp-01에서 실행
export KUBECONFIG=/etc/kubernetes/admin.conf

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version
# 기대: version.BuildInfo{Version:"v3.x.x", ...}
```

---

## 1. ingress-nginx 설치

```bash
# Helm repo 추가
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx

# 설치
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "4.12.1" \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.externalTrafficPolicy=Cluster \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClass=nginx \
  --set controller.watchIngressWithoutClass=false
```

**주요 설정 설명**:
- `service.type=NodePort`: ALB가 노드의 NodePort로 트래픽을 보낸다. LoadBalancer 타입은 AWS ELB를 노드 당 하나씩 만들어버리기 때문에 ALB 앞에 두는 구조에서는 NodePort가 적합하다.
- `watchIngressWithoutClass=false`: `ingressClassName: nginx`가 명시된 Ingress 리소스만 처리. 다른 컨트롤러(ALB 등)의 Ingress와 충돌하지 않는다.

```bash
# 배포 완료 대기
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=5m

# NodePort 번호 확인
kubectl get svc -n ingress-nginx
# ingress-nginx-controller   NodePort   ...  80:3xxxx/TCP,443:3xxxx/TCP
```

---

## 2. AWS Load Balancer Controller 설치

aws-load-balancer-controller는 쿠버네티스 Ingress/Service 리소스를 감시하다가
`ingressClassName: alb` Ingress를 보면 자동으로 AWS ALB를 생성한다.

```bash
CLUSTER_NAME="my-cluster"
AWS_REGION="ap-northeast-2"

# VPC ID 가져오기 (EC2 메타데이터 또는 환경변수)
VPC_ID=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/ \
  | head -1 \
  | xargs -I{} curl -s "http://169.254.169.254/latest/meta-data/network/interfaces/macs/{}vpc-id")

echo "VPC_ID=$VPC_ID"

# Helm repo 추가
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

# 설치
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "1.12.0" \
  --namespace kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=true \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}"
```

**IRSA vs Instance Profile**:
공식적으로는 IRSA(IAM Roles for Service Accounts)를 권장하지만, 설정이 복잡하다.
여기서는 01단계에서 노드 IAM role에 ALB 정책을 직접 붙였으므로 Instance Profile로 동작한다.

```bash
kubectl rollout status deployment/aws-load-balancer-controller \
  -n kube-system --timeout=5m

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
# 기대: 2/2 Running
```

---

## 3. Smoke Test 서비스 생성 (billage-edge)

ALB → nginx → 파드 전체 경로가 동작하는지 검증하기 위한 최소 서비스를 만든다.

```bash
# ACM 인증서 ARN (01단계에서 발급한 것)
ALB_CERT_ARN="arn:aws:acm:ap-northeast-2:123456789012:certificate/XXXX"
PUBLIC_EDGE_HOST="api.example.com"

kubectl apply -f - <<EOF
# smoke test 앱: HTTP 요청에 "billage-edge ok" 응답
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-smoketest
  namespace: billage-edge
spec:
  replicas: 2
  selector:
    matchLabels:
      app: edge-smoketest
  template:
    metadata:
      labels:
        app: edge-smoketest
    spec:
      nodeSelector:
        workload-plane: app   # app 노드에만 스케줄
      containers:
        - name: http-echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=billage-edge ok"]
          ports:
            - containerPort: 5678
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: http
---
apiVersion: v1
kind: Service
metadata:
  name: edge-smoketest
  namespace: billage-edge
spec:
  selector:
    app: edge-smoketest
  ports:
    - name: http
      port: 80
      targetPort: http
---
# nginx가 처리하는 Ingress: HTTPS → edge-smoketest
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: edge-smoketest
  namespace: billage-edge
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${PUBLIC_EDGE_HOST}
      secretName: edge-public-tls   # cert-manager가 채워줄 Secret (10단계)
  rules:
    - host: ${PUBLIC_EDGE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: edge-smoketest
                port:
                  number: 80
---
# ALB Ingress: aws-lbc가 이 리소스를 보고 AWS ALB를 생성
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-nginx-public-alb
  namespace: ingress-nginx
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing        # 인터넷에서 접근 가능
    alb.ingress.kubernetes.io/target-type: instance          # NodePort 대상
    alb.ingress.kubernetes.io/backend-protocol: HTTPS        # ALB → nginx HTTPS 연결
    alb.ingress.kubernetes.io/certificate-arn: "${ALB_CERT_ARN}"  # ACM TLS 인증서
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: "200-404"       # nginx 404도 헬스체크 통과
spec:
  ingressClassName: alb
  rules:
    - host: ${PUBLIC_EDGE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ingress-nginx-controller
                port:
                  number: 443   # nginx NodePort HTTPS
EOF
```

---

## 4. ALB 생성 확인

aws-lbc가 ALB를 만드는 데 2-5분이 걸린다.

```bash
# ALB hostname 대기
kubectl get ingress -n ingress-nginx ingress-nginx-public-alb -w

# ADDRESS 필드에 ALB hostname이 나타나면 성공
# NAME                      CLASS   HOSTS              ADDRESS
# ingress-nginx-public-alb  alb     api.example.com    k8s-ingressni-xxx.ap-northeast-2.elb.amazonaws.com
```

ALB hostname을 기록한다. DNS 등록에 사용한다.

```bash
ALB_HOST=$(kubectl get ingress -n ingress-nginx ingress-nginx-public-alb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB_HOST=$ALB_HOST"
```

---

## 5. DNS CNAME 등록

`public_edge_host` 도메인을 ALB hostname으로 CNAME 등록한다.

```bash
# Route53에 등록 (공개 호스팅 존 ID로 교체)
PUBLIC_ZONE_ID="ZXXXXXXXXXXXX"

aws route53 change-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${PUBLIC_EDGE_HOST}\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"${ALB_HOST}\"}]
      }
    }]
  }"

# DNS 전파 확인
dig CNAME ${PUBLIC_EDGE_HOST} +short
# 기대: ALB hostname
```

---

## 확인

```bash
# smoke test 파드 상태
kubectl get pods -n billage-edge
# edge-smoketest-xxx   1/1   Running   0

# ALB → nginx 연결 테스트 (cert-manager 설치 전이므로 TLS 오류 예상)
curl -v https://${PUBLIC_EDGE_HOST}/ --insecure 2>&1 | grep "billage-edge ok"
```

---

## 트러블슈팅

**ALB가 생성되지 않는 경우**
```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# 자주 나오는 오류
# "subnet not found" → 퍼블릭 서브넷에 kubernetes.io/role/elb=1 태그 확인
# "AccessDenied" → 노드 IAM role에 ALB 정책 부착 확인
```

**NodePort 범위 SG 누락**
```bash
# ALB가 NodePort에 접근하려면 app 노드 SG에 30000-32767 허용이 있어야 함
# 01단계의 APP_SG 설정 확인
aws ec2 describe-security-groups --group-ids $APP_SG \
  --query "SecurityGroups[0].IpPermissions"
```

---

다음: [10-cert-manager.md](./10-cert-manager.md)
