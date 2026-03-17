# 10. cert-manager 및 TLS 설정

**대상: cp-01에서 kubectl/helm 실행**

cert-manager는 쿠버네티스에서 TLS 인증서를 자동으로 발급하고 갱신한다.
여기서는 Let's Encrypt ACME http01 challenge로 인증서를 발급한다.

---

## TLS 구조

```
외부 사용자
  → ALB (ACM 인증서: AWS에서 관리, 외부 HTTPS 종료)
    → ingress-nginx (cert-manager 인증서: 클러스터 내 HTTPS)
      → billage-edge 파드
```

- **ALB의 TLS**: AWS ACM이 관리. 자동 갱신. 01단계에서 발급.
- **nginx의 TLS**: cert-manager가 관리. Let's Encrypt 인증서. 클러스터 내부 HTTPS에 사용.

**왜 cert-manager가 필요한가?**
ingress-nginx가 HTTPS를 제공하려면 TLS Secret(인증서+키)이 필요하다.
cert-manager 없이는 직접 openssl로 인증서를 만들어서 Secret을 수동 관리해야 한다.
cert-manager는 `Certificate` 리소스를 감시해 자동으로 발급/갱신한다.

---

## 1. cert-manager 설치

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
CERT_MANAGER_VERSION="v1.17.2"

helm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager \
  --version "${CERT_MANAGER_VERSION}" \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true   # CRD를 Helm이 함께 설치
```

`crds.enabled=true`로 `Certificate`, `Issuer`, `ClusterIssuer` 등 CRD를 자동 설치한다.

```bash
# 3개 배포 모두 Ready 대기
kubectl rollout status deployment/cert-manager \
  -n cert-manager --timeout=5m
kubectl rollout status deployment/cert-manager-webhook \
  -n cert-manager --timeout=5m
kubectl rollout status deployment/cert-manager-cainjector \
  -n cert-manager --timeout=5m

kubectl get pods -n cert-manager
# NAME                                       READY   STATUS    RESTARTS
# cert-manager-xxx                           1/1     Running   0
# cert-manager-cainjector-xxx               1/1     Running   0
# cert-manager-webhook-xxx                  1/1     Running   0
```

---

## 2. ClusterIssuer 생성 (Let's Encrypt)

ClusterIssuer는 클러스터 전체에서 사용할 수 있는 인증서 발급 주체다.
(Issuer는 특정 네임스페이스에서만 사용 가능)

```bash
CERT_MANAGER_EMAIL="platform@example.com"  # 실제 이메일로 변경

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${CERT_MANAGER_EMAIL}    # 인증서 만료 알림 수신 이메일
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key  # ACME 계정 키 저장 Secret
    solvers:
      - http01:
          ingress:
            # ingress-nginx가 ACME challenge 경로를 서빙
            ingressClassName: nginx
EOF
```

**ACME http01 Challenge 동작 방식**:
1. cert-manager가 Let's Encrypt에 인증서 발급 요청
2. Let's Encrypt가 도전(challenge): `http://<도메인>/.well-known/acme-challenge/<token>`으로 GET 요청을 보냄
3. cert-manager가 위 경로를 서빙하는 임시 Ingress를 ingress-nginx에 생성
4. ALB → nginx → cert-manager 임시 서비스로 요청이 전달됨
5. Let's Encrypt가 응답을 확인하면 인증서 발급

**따라서 DNS(CNAME)가 ALB를 가리키고 있어야 challenge가 성공한다.**

---

## 3. ClusterIssuer 상태 확인

```bash
kubectl get clusterissuer letsencrypt-prod
# NAME                 READY   AGE
# letsencrypt-prod     True    30s
```

`READY: True`가 되어야 한다. False이면:
```bash
kubectl describe clusterissuer letsencrypt-prod
```

---

## 4. Certificate 리소스 생성

```bash
PUBLIC_EDGE_HOST="api.example.com"  # 실제 도메인으로 변경

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: edge-public-tls
  namespace: billage-edge
spec:
  secretName: edge-public-tls    # 인증서가 저장될 Secret 이름
  dnsNames:
    - ${PUBLIC_EDGE_HOST}        # 인증서에 포함할 도메인
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: letsencrypt-prod
EOF
```

---

## 5. 인증서 발급 모니터링

```bash
# Certificate 상태 확인
kubectl get certificate -n billage-edge
# NAME              READY   SECRET            AGE
# edge-public-tls   False   edge-public-tls   30s  ← 발급 진행 중

# 상세 이벤트 확인
kubectl describe certificate edge-public-tls -n billage-edge

# CertificateRequest 확인
kubectl get certificaterequest -n billage-edge

# ACME Order/Challenge 확인
kubectl get order -n billage-edge
kubectl get challenge -n billage-edge
```

**정상 진행 단계**:
```
Certificate → CertificateRequest → Order → Challenge (pending → valid) → Certificate (Ready: True)
```

발급 완료 후:
```bash
kubectl get certificate -n billage-edge
# NAME              READY   SECRET            AGE
# edge-public-tls   True    edge-public-tls   5m
```

---

## 6. 최종 경로 검증

DNS 전파 + 인증서 발급이 완료된 후 전체 경로를 테스트한다.

```bash
PUBLIC_EDGE_HOST="api.example.com"

# HTTPS 요청
curl -v https://${PUBLIC_EDGE_HOST}/

# 기대 응답
# * SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
# * Server certificate: ... CN=api.example.com
# < HTTP/2 200
# billage-edge ok
```

---

## 7. 전체 컴포넌트 최종 확인

```bash
echo "=== 노드 상태 ==="
kubectl get nodes -L node-group,workload-plane

echo "=== Calico ==="
kubectl get pods -n calico-system

echo "=== cert-manager ==="
kubectl get pods -n cert-manager

echo "=== ingress-nginx ==="
kubectl get pods -n ingress-nginx

echo "=== aws-lbc ==="
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo "=== 네임스페이스 ==="
kubectl get ns billage-app billage-data billage-edge billage-ops

echo "=== NetworkPolicy 수 ==="
kubectl get networkpolicy -A --no-headers | wc -l

echo "=== ALB Ingress ==="
kubectl get ingress -n ingress-nginx ingress-nginx-public-alb -o wide

echo "=== Certificate ==="
kubectl get certificate -n billage-edge

echo "=== Edge Smoke Service ==="
kubectl get svc -n billage-edge edge-smoketest
```

---

## 완료 기준 체크리스트

| 항목 | 확인 방법 | 기대값 |
|------|----------|--------|
| 전체 노드 Ready | `kubectl get nodes` | 10대 모두 `Ready` |
| Calico 파드 정상 | `kubectl get pods -n calico-system` | 모두 `Running` |
| 네임스페이스 4개 | `kubectl get ns billage-*` | 4개 `Active` |
| RBAC 설정 | `kubectl auth can-i ...` | 예상 권한 일치 |
| NetworkPolicy 적용 | `kubectl get netpol -A` | 14개 이상 |
| ingress-nginx 동작 | `kubectl get pods -n ingress-nginx` | `Running` |
| ALB 생성 | `kubectl get ingress -n ingress-nginx ...` | ADDRESS 있음 |
| TLS 인증서 | `kubectl get certificate -n billage-edge` | `READY: True` |
| 외부 접근 | `curl https://<도메인>/` | `billage-edge ok` |

---

## 트러블슈팅

**Certificate가 계속 False**
```bash
kubectl describe challenge -n billage-edge

# 주로 나오는 원인:
# 1. DNS가 ALB를 아직 가리키지 않음 → dig CNAME <도메인> +short
# 2. ALB가 포트 80을 열지 않음 → ALB Ingress의 listen-ports에 HTTP:80 포함 확인
# 3. NetworkPolicy가 cert-manager → ingress-nginx 통신 차단
#    → ingress-nginx, cert-manager 네임스페이스는 기본적으로 차단 없음 (NetworkPolicy 미적용)
```

**ingress-nginx에 TLS Secret이 없음**
```bash
kubectl get secret edge-public-tls -n billage-edge
# Certificate가 READY: True가 되면 자동 생성됨
```

---

## 구축 완료

이 단계까지 완료하면 아래 상태가 된다:
- 쿠버네티스 클러스터 10대, HA 구성
- Calico CNI로 파드 간 통신 및 BGP 라우팅
- 노드 역할별 분리 (control-plane / app / data)
- 네임스페이스별 접근 제어 (RBAC)
- NetworkPolicy default-deny + whitelist
- 인터넷 → ALB → ingress-nginx → 파드 전체 경로
- Let's Encrypt TLS 인증서 자동 발급
