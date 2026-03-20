# 2026-03-20 Stateless 서비스 배포 트러블슈팅 보고서

## 작업 개요

kubeadm 클러스터에 Stateless 서비스(Spring Boot, FastAPI, Next.js)를 Helm Chart로 배포하는 과정에서 발생한 문제들과 해결 과정.

---

## 트러블슈팅 목록

### 1. Zone Label 미설정으로 Pod 스케줄링 실패

**증상:**
```
0/10 nodes are available: 4 node(s) didn't match pod topology spread constraints (missing required label)
```
모든 Pod가 Pending 상태.

**원인:**
- Helm Chart의 `topologySpreadConstraints`에서 `topology.kubernetes.io/zone` 라벨 기준으로 Pod를 AZ 균등 분배하도록 설정
- `whenUnsatisfiable: DoNotSchedule` → zone 라벨이 없으면 스케줄링 자체를 거부
- **EKS는 AWS가 자동으로 zone 라벨을 부여**하지만, **kubeadm은 수동으로 부여해야 함**

**해결:**
```bash
# 실제 AZ 배치를 AWS API로 확인 후 라벨 부여
kubectl label node billage-kubeadm-prod-app-01 topology.kubernetes.io/zone=ap-northeast-2a
kubectl label node billage-kubeadm-prod-app-02 topology.kubernetes.io/zone=ap-northeast-2b
# ... 10개 노드 전부
```

**교훈:**
- kubeadm 클러스터에서는 EKS가 자동으로 해주는 것들을 수동으로 설정해야 함
- cloud-init 또는 Terraform에서 zone 라벨을 자동 부여하도록 개선 필요

---

### 2. ECR 이미지 Pull 실패 (ImagePullBackOff)

**증상:**
```
Failed to pull image: authorization failed: no basic auth credentials
```

**원인:**
- ECR은 인증이 필요한 private registry
- EKS에서는 IAM Role로 자동 인증되지만, kubeadm에서는 수동으로 `imagePullSecret` 필요

**해결:**
```bash
# 로컬에서 ECR 토큰 생성
ECR_TOKEN=$(aws ecr get-login-password --region ap-northeast-2)

# K8s docker-registry Secret 생성
kubectl create secret docker-registry ecr-secret -n billage-app \
  --docker-server=988319239270.dkr.ecr.ap-northeast-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$ECR_TOKEN"

# default ServiceAccount에 연결
kubectl patch serviceaccount default -n billage-app \
  -p '{"imagePullSecrets": [{"name": "ecr-secret"}]}'
```

**주의:**
- ECR 토큰은 **12시간 후 만료** → CronJob으로 자동 갱신 필요
- 또는 kubelet의 `ecr-credential-provider` 설정으로 영구 해결 가능

---

### 3. Spring Boot 환경변수 불일치 (CrashLoopBackOff)

**증상:**
```
Failed to bind properties under 'logging.level.root' to LogLevel:
Value: "${LOGGING_LEVEL}"
Reason: No enum constant org.springframework.boot.logging.LogLevel.${LOGGING_LEVEL}
```

**원인:**
- application.yml에서 `${LOGGING_LEVEL}`, `${PROD_DB_URL}` 등의 환경변수를 참조
- K8s Secret의 키 이름이 application.yml의 `${}` 참조명과 불일치
  - Secret: `DB_URL` → application.yml 기대: `PROD_DB_URL`
  - Secret: `JWT_SECRET` → application.yml 기대: `JWT_SECRET_KEY`
  - `LOGGING_LEVEL`, `KAFKA_BOOTSTRAP_SERVERS` 완전 누락

**해결:**
1. 백엔드 소스의 `application-*.yml` 파일에서 실제 `${}` 참조명 전수 조사
2. Secret 키 이름과 values-prod.yaml의 `envFromSecret` 매핑을 application.yml과 정확히 일치시킴
3. 누락된 환경변수(`LOGGING_LEVEL`, `KAFKA_BOOTSTRAP_SERVERS`) 추가

**교훈:**
- 환경변수 이름은 반드시 **application.yml의 `${}` 참조명과 1:1 일치**해야 함
- SSM Parameter Store의 키 이름과 Spring Boot 환경변수 이름은 다를 수 있음 (매핑 테이블 관리 필요)

---

### 4. VPC Peering 후 Pod에서 외부 인프라 연결 실패

**증상:**
- 노드(EC2)에서는 dev v2 RDS(10.0.13.193:3306) 연결 성공
- Pod에서는 같은 대상으로 Connection timed out
- **심지어 같은 VPC의 다른 노드(10.30.3.10:6443)에도 연결 실패**

**진단 과정:**
```bash
# 노드에서 테스트 → 성공
nc -zv -w5 10.0.13.193 3306  # ✅

# Pod에서 테스트 → 실패
kubectl exec test-pod -- nc -zv -w10 10.0.13.193 3306  # ❌ timeout
kubectl exec test-pod -- nc -zv -w5 10.30.3.10 6443    # ❌ timeout (같은 VPC도!)
```

같은 VPC 통신도 안 되는 것으로 보아 **VPC Peering이나 SNAT 문제가 아님**을 확인.

**원인:**
```bash
kubectl get networkpolicy -n billage-app
# default-deny-all    — 모든 Ingress/Egress 차단
# allow-dns-egress    — DNS(UDP 53)만 허용
```

`default-deny-all` NetworkPolicy가 **모든 Egress를 차단**하고, `allow-dns-egress`만 DNS를 허용. Pod에서 나가는 TCP 트래픽(MySQL 3306, API 6443 등)은 전부 거부됨.

**해결:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-external
  namespace: billage-app
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.0/16    # dev v2 VPC
        - ipBlock:
            cidr: 10.30.0.0/16   # kubeadm VPC
      ports:
        - {protocol: TCP, port: 3306}   # MySQL
        - {protocol: TCP, port: 5672}   # RabbitMQ AMQP
        - {protocol: TCP, port: 61613}  # RabbitMQ STOMP
        - {protocol: TCP, port: 9092}   # Kafka
        - {protocol: TCP, port: 6333}   # Qdrant HTTP
        - {protocol: TCP, port: 6334}   # Qdrant gRPC
        - {protocol: TCP, port: 6443}   # K8s API
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - {protocol: TCP, port: 443}    # HTTPS (외부 API)
```

**교훈:**
- NetworkPolicy의 `default-deny-all`이 있으면 **허용 규칙을 명시적으로 추가**해야 함
- 디버깅 시 "노드에서는 되고 Pod에서는 안 된다" → **NetworkPolicy를 먼저 확인**
- VPC Peering, 보안그룹, 라우팅을 다 점검해도 안 되면 K8s 레벨 정책을 의심

---

### 5. FastAPI OOMKilled

**증상:**
```json
{"exitCode": 137, "reason": "OOMKilled"}
```
Pod가 시작 후 약 20초 만에 강제 종료.

**원인:**
- FastAPI 앱이 시작 시 Qdrant 클라이언트 초기화 + ML 관련 라이브러리 로딩
- 메모리 사용량이 limits(1Gi)를 초과하여 커널 OOM Killer가 SIGKILL(exit code 137) 전송

**해결:**
```yaml
# values-prod.yaml
resources:
  requests:
    memory: "1Gi"    # 512Mi → 1Gi
  limits:
    memory: "2Gi"    # 1Gi → 2Gi
```

**교훈:**
- ML/AI 서비스는 모델 로딩 시 메모리를 많이 사용 → 넉넉한 limits 설정 필요
- OOMKilled는 Pod 로그에 안 남음 → `kubectl describe pod` 또는 `crictl inspect`로 exitCode 137 확인

---

### 6. Next.js NEXTAUTH_SECRET 누락

**증상:**
```
[next-auth][error][NO_SECRET] Please define a `secret` in production.
```
liveness probe에서 `/login` 경로가 500 반환 → CrashLoopBackOff.

**원인:**
- NextAuth.js는 production 환경에서 `NEXTAUTH_SECRET` 환경변수 필수
- Secret 생성 시 `NEXTAUTH_SECRET`을 포함하지 않음
- SSM Parameter Store `/billage/dev/fe/nextauth-secret`에 값이 있었지만 누락

**해결:**
```bash
kubectl create secret generic nextjs-secret -n billage-app \
  --from-literal=nextauth-secret='Bov22nOTk4VPQHDPtiEeOQYULV2B6LS7OZs6zd1DJ0g='
  # + 기존 키들
```

---

### 7. Next.js envFromSecret 템플릿 누락

**증상:**
- Secret을 올바르게 생성하고 values-prod.yaml에 매핑도 정의했지만
- Pod 내부에서 `env` 명령어 실행 시 Secret 환경변수가 전혀 주입되지 않음

**원인:**
- `charts/nextjs/templates/deployment.yaml`에 `envFromSecret` 렌더링 블록이 없었음
- spring-boot, fastapi 템플릿에는 있었지만 nextjs에는 처음부터 빠져있었음

```yaml
# 누락되었던 블록
{{- range .Values.envFromSecret }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secretName }}
      key: {{ .key }}
{{- end }}
```

**해결:**
deployment.yaml의 `env:` 섹션 아래에 `envFromSecret` 렌더링 블록 추가.

**교훈:**
- values.yaml에 값을 정의해도 **template에서 렌더링하지 않으면 무의미**
- Helm Chart 수정 시 `helm template` 명령으로 렌더링 결과를 사전 검증할 것

---

### 8. Next.js Liveness Probe 경로 문제

**증상:**
```
Liveness probe failed: HTTP probe failed with statuscode: 500
```
기존 probe 경로 `/`에서 500 반환.

**원인:**
- `/` 경로는 SSR(Server Side Rendering)을 수행하며 백엔드 API를 호출
- `NEXT_PUBLIC_API_URL`이 `https://dev.billages.com`으로 설정되어 있어 외부 도메인으로 프록시 시도
- Ingress가 아직 연결되지 않아 프록시 실패 → 500 에러

**해결:**
1. Probe 경로를 `/login`으로 변경 (백엔드 의존 없는 정적 페이지)
2. `NEXT_PUBLIC_API_URL`을 K8s 내부 Spring Boot 서비스 주소로 변경:
   ```
   http://spring-boot.billage-app.svc.cluster.local:8080
   ```

**주의:**
- `NEXT_PUBLIC_*` 변수는 빌드 타임에 번들됨 → 런타임 변경은 서버사이드(rewrites)에만 적용
- 브라우저 JS에서는 빌드 시점 값이 유지됨

---

## 보안그룹 변경 이력

VPC Peering 후 kubeadm VPC(`10.30.0.0/16`)에서 dev v2 인프라에 접근하기 위해 추가한 보안그룹 규칙:

| 대상 | 보안그룹 | 포트 | 설명 |
|------|---------|------|------|
| dev v2 RDS | sg-01ee3860789af9de7 | 3306 | MySQL |
| dev v2 RabbitMQ | sg-08a2202cc1a91a725 | 5672, 61613 | AMQP, STOMP |
| dev v2 Kafka | sg-009c4a120ae44872f | 9092 | Kafka |
| dev v2 Qdrant | sg-00978425971d688f5 | 6333-6334 | REST, gRPC |
| prod v2 RDS | sg-02dfb460464061698 | 3306 | MySQL (미사용) |

---

## 최종 상태

```
NAME                          READY   STATUS    RESTARTS   AGE
fastapi-68f88587db-fh2zr      1/1     Running   0          30m
fastapi-68f88587db-qjbwh      1/1     Running   0          29m
nextjs-785644f795-95nz6       1/1     Running   0          40s
nextjs-785644f795-k7r6h       1/1     Running   0          51s
spring-boot-55d59f556-4p8nw   1/1     Running   0          40m
spring-boot-55d59f556-9z494   1/1     Running   0          40m
spring-boot-55d59f556-bl7c2   1/1     Running   0          40m
```

7개 Pod 전부 1/1 Running, 재시작 0.

---

## 디버깅에 유용했던 명령어

```bash
# Pod 종료 원인 확인 (OOM, Error 등)
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'

# Pod 내부 환경변수 확인
kubectl exec <pod> -- env | grep -i <keyword>

# NetworkPolicy 확인
kubectl get networkpolicy -n <namespace>

# Pod에서 네트워크 연결 테스트
kubectl run test --rm -it --image=busybox -n <namespace> --restart=Never -- sh
# 쉘 안에서: nc -zv -w5 <host> <port>

# Helm 렌더링 사전 검증
helm template <release> <chart> -f values-prod.yaml | grep -A5 env
```
