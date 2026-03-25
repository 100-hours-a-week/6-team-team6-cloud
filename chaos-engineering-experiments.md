# Billage 카오스 엔지니어링 실험 설계서

> **대상 인프라**: Billage v2 (EC2 ASG) → kubeadm K8s 마이그레이션
> **서비스**: Backend(Spring Boot:8080), Frontend(Next.js:3000), AI(FastAPI:5000)
> **데이터 계층**: RDS MySQL 8.0, ElastiCache Redis 7.0, RabbitMQ, Qdrant Vector DB
> **네트워크**: Multi-AZ VPC(10.0.0.0/16), ALB, NAT Instance, VPC Peering
> **모니터링**: Prometheus + Grafana + Loki + Promtail

---

## 실험 #1 — Worker Node 강제 종료 시 Pod 재스케줄링 내성 검증

### 가설
> "워커노드 1대가 갑자기 죽어도, Backend/Frontend/AI Pod가 60초 이내에 다른 노드로 재스케줄링되어 ALB 헬스체크를 통과하고, 사용자 요청 실패율이 1% 미만을 유지할 것이다."

### 실험 배경
현재 v2에서 ASG min=1, max=2로 운영 중인데, K8s 전환 시 워커노드 장애는 가장 빈번하게 발생하는 시나리오. 특히 t3 인스턴스는 AWS에서 회수(spot이 아니더라도 하드웨어 장애)될 수 있음.

### 실험 방법
```bash
# Litmus ChaosEngine 정의
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: billage-node-drain
spec:
  engineState: active
  chaosServiceAccount: litmus-admin
  experiments:
    - name: node-drain
      spec:
        components:
          env:
            - name: TARGET_NODE
              value: 'worker-02'
            - name: TOTAL_CHAOS_DURATION
              value: '120'
            - name: APP_NS
              value: 'billage'
            - name: APP_LABEL
              value: 'app=backend'
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| Pod 재스케줄링 완료 시간 | < 60s | < 90s |
| ALB Target 재등록 시간 | < 30s | < 45s |
| 요청 실패율 (5xx) | < 1% | < 3% |
| p99 응답 시간 | < 500ms | < 1000ms |

### 예상 취약점 & 개선 방향
- **PDB 미설정**: Backend replica 전부 같은 노드에 몰릴 수 있음 → `PodDisruptionBudget(minAvailable: 1)` 설정
- **podAntiAffinity 미설정**: 동일 서비스 Pod가 같은 노드에 스케줄링 → `preferredDuringSchedulingIgnoredDuringExecution` 설정
- **Spring Boot Graceful Shutdown**: `preStop` hook에 `sleep 15` + `server.shutdown=graceful` 설정 필요

---

## 실험 #2 — RDS MySQL 페일오버 시 Backend 커넥션 풀 복구 검증

### 가설
> "RDS Multi-AZ 페일오버가 발생해도, Backend의 HikariCP 커넥션 풀이 30초 이내에 새 Primary에 재연결되고, 트랜잭션 실패가 사용자에게 전파되지 않을 것이다."

### 실험 배경
현재 prod만 Multi-AZ 활성화 상태. 페일오버 시 DNS 전파 + 커넥션 풀 재구성까지 보통 30~120초 소요. Spring Boot의 HikariCP는 기본적으로 dead connection을 감지하지만, 설정에 따라 장시간 hang 가능.

### 실험 방법
```bash
# AWS CLI로 RDS 페일오버 트리거 (실제 프로덕션에서도 사용 가능한 방법)
aws rds reboot-db-instance \
  --db-instance-identifier billage-dev-db \
  --force-failover

# 동시에 Backend Pod에 지속적인 요청 부하 생성
kubectl run load-generator --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://backend-svc:8080/actuator/health; sleep 0.5; done"
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| 커넥션 풀 복구 시간 | < 30s | < 60s |
| 트랜잭션 실패 건수 | 0 | < 5건 |
| /actuator/health DOWN 지속 시간 | < 30s | < 45s |
| Slow Query 급증 여부 | 없음 | < 10건 |

### 예상 취약점 & 개선 방향
- **HikariCP validation query 미설정**: `spring.datasource.hikari.connection-test-query=SELECT 1` 추가
- **maxLifetime 과도하게 길 경우**: 죽은 커넥션을 계속 보유 → `maxLifetime=580000`(약 10분)으로 단축
- **retry 로직 부재**: `@Retryable` 또는 Resilience4j retry로 일시적 DB 연결 실패 시 재시도 구현
- **K8s Readiness Probe 연동**: DB 연결 실패 시 `/actuator/health`가 DOWN → ALB가 트래픽 차단하도록 readinessProbe 설정

---

## 실험 #3 — RabbitMQ 장애 시 WebSocket 메시지 유실 검증

### 가설
> "RabbitMQ 프로세스가 5분간 중단되어도, STOMP 기반 WebSocket 메시지가 유실되지 않고, RabbitMQ 복구 후 미전달 메시지가 정상적으로 소비자에게 전달될 것이다."

### 실험 배경
현재 RabbitMQ는 **단일 EC2 인스턴스**(t3.small, 클러스터링 안 됨). STOMP(61613)으로 WebSocket 브릿징 중이라 장애 시 실시간 알림, 채팅 등 기능에 직접 영향. K8s 전환 시 StatefulSet으로 클러스터링해야 하는 근거를 만드는 핵심 실험.

### 실험 방법
```bash
# K8s 환경에서 RabbitMQ Pod 강제 kill
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: rabbitmq-pod-kill
spec:
  appinfo:
    appns: billage-infra
    applabel: app=rabbitmq
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: '300'        # 5분간 지속
            - name: CHAOS_INTERVAL
              value: '300'        # 복구 직후 다시 kill하지 않음
            - name: FORCE
              value: 'true'
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| WebSocket 연결 끊김 감지 시간 | < 5s | < 10s |
| 클라이언트 자동 재연결 시간 | < 10s | < 30s |
| 메시지 유실 건수 | 0건 | 0건 (Durable Queue) |
| RabbitMQ 복구 후 적체 메시지 처리 시간 | < 30s | < 60s |

### 예상 취약점 & 개선 방향
- **단일 인스턴스 SPOF**: 클러스터 미러링 미구성 → K8s에서 RabbitMQ Operator + 3노드 클러스터로 전환
- **Durable Queue 미설정**: 메시지 영속성 미보장 → `durable=true`, `delivery_mode=2` 설정
- **클라이언트 재연결 로직 부재**: Frontend WebSocket이 끊기면 재연결 안 함 → SockJS/STOMP 클라이언트에 `reconnectDelay: 5000` 설정
- **Dead Letter Queue**: 처리 실패 메시지를 DLQ로 라우팅하여 유실 방지

---

## 실험 #4 — ElastiCache Redis 장애 시 세션/캐시 폴백 검증

### 가설
> "Redis가 완전히 다운되어도, Backend 서비스가 DB 직접 조회로 폴백하여 기능적으로 정상 동작하며, 응답 시간 증가는 3배 이내에 머물 것이다."

### 실험 배경
현재 Redis(cache.t3.micro, 단일 노드)를 세션 캐싱 + 실시간 데이터 + Pub/Sub 용도로 사용 중. Redis 장애 시 세션 유실 → 전체 사용자 로그아웃, 캐시 미스 → DB 부하 폭증 가능.

### 실험 방법
```bash
# K8s 환경: Redis Pod에 네트워크 차단 주입
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: redis-network-loss
spec:
  appinfo:
    appns: billage-infra
    applabel: app=redis
  experiments:
    - name: pod-network-loss
      spec:
        components:
          env:
            - name: NETWORK_INTERFACE
              value: 'eth0'
            - name: TOTAL_CHAOS_DURATION
              value: '180'        # 3분간 네트워크 완전 차단
            - name: NETWORK_PACKET_LOSS_PERCENTAGE
              value: '100'
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| Backend 5xx 에러율 | 0% | < 1% |
| 평균 응답 시간 증가율 | < 2x | < 3x |
| 세션 유지 여부 | 유지 | - |
| MySQL 쿼리 수 증가율 | < 5x | < 10x |
| Redis 복구 후 캐시 워밍업 시간 | < 60s | < 120s |

### 예상 취약점 & 개선 방향
- **Cache-Aside 패턴 미구현**: Redis 실패 시 예외가 사용자에게 전파 → try-catch로 DB 폴백 구현
- **세션 저장소 단일 의존**: Redis 죽으면 전원 로그아웃 → JWT 토큰 기반으로 전환하거나, 세션을 DB에도 이중 저장
- **Circuit Breaker 미적용**: Redis 타임아웃이 누적되어 스레드 고갈 → Resilience4j CircuitBreaker로 빠른 실패 처리
- **Connection Timeout**: Lettuce 기본 timeout이 너무 길면 hang → `spring.redis.timeout=2000ms`로 단축

---

## 실험 #5 — ALB → Backend 경로의 네트워크 지연 주입 (Cascade Failure 검증)

### 가설
> "Backend Pod에 200ms 네트워크 지연이 발생해도, Frontend → Backend API 호출 체인에서 timeout cascade가 발생하지 않고, 사용자 체감 응답시간이 SLO(2초) 이내를 유지할 것이다."

### 실험 배경
현재 ALB idle timeout이 300초(WebSocket 지원용)로 매우 넉넉. 하지만 Backend ↔ AI 서비스 간 내부 호출, Backend ↔ RDS/Redis 간 호출이 모두 체인으로 엮여 있어서, 한 구간의 지연이 전체로 전파될 가능성이 큼. 특히 AI 서비스(FastAPI)의 임베딩 처리가 느려지면 Backend가 블로킹될 수 있음.

### 실험 방법
```yaml
# Chaos Mesh: 특정 Pod에 네트워크 지연 주입
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: backend-latency-injection
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - billage
    labelSelectors:
      app: backend
  delay:
    latency: '200ms'
    jitter: '50ms'
    correlation: '75'
  duration: '300s'
  direction: to      # Backend로 들어오는 트래픽에 지연
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| Frontend → Backend p99 응답시간 | < 1.5s | < 2s (SLO) |
| Backend → AI 내부 호출 타임아웃 발생률 | < 5% | < 10% |
| Backend 스레드풀 활성 스레드 수 | < 150 | < 200 (max) |
| HikariCP active connections | < 8 | < 10 (pool size) |
| Tomcat rejected requests | 0 | < 10 |

### 예상 취약점 & 개선 방향
- **Backend → AI 호출 timeout 미설정**: RestTemplate/WebClient 기본 무한대기 → `connectTimeout=3s`, `readTimeout=5s` 명시
- **Tomcat 스레드 고갈**: 지연 누적 시 200 스레드 전부 점유 → Bulkhead 패턴으로 AI 호출용 스레드풀 분리
- **Circuit Breaker**: AI 서비스 지연 감지 시 빠른 실패 → Resilience4j `slowCallDurationThreshold=3s`, `slowCallRateThreshold=80%`
- **비동기 전환**: AI 호출을 `@Async` + `CompletableFuture`로 전환하여 블로킹 방지

---

## 실험 #6 — CoreDNS 장애 시 서비스 디스커버리 내성 검증

### 가설
> "CoreDNS Pod가 전부 다운되어도, 이미 resolve된 서비스 간 통신은 DNS 캐시로 30초간 유지되고, CoreDNS 복구 후 10초 이내에 전체 서비스 디스커버리가 정상화될 것이다."

### 실험 배경
kubeadm 클러스터에서 CoreDNS는 모든 서비스 디스커버리의 핵심. `backend-svc.billage.svc.cluster.local` 같은 내부 DNS가 풀리지 않으면 서비스 간 통신 전체가 마비됨. 대부분의 Java/Python/Node 앱은 DNS 결과를 캐싱하지 않아서 생각보다 취약.

### 실험 방법
```bash
# CoreDNS deployment를 0으로 스케일다운
kubectl scale deployment coredns -n kube-system --replicas=0

# 60초 후 복구
sleep 60
kubectl scale deployment coredns -n kube-system --replicas=2

# 실험 중 서비스 간 통신 모니터링
kubectl exec -n billage deploy/backend -- \
  nslookup redis-svc.billage-infra.svc.cluster.local
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| DNS 캐시 유효 지속 시간 | > 30s | > 15s |
| 서비스 간 통신 실패 시작 시점 | > 30s | > 15s |
| CoreDNS 복구 후 정상화 시간 | < 10s | < 20s |
| Backend → RDS 연결 영향 | 없음 (IP 직접) | 없음 |
| Backend → Redis 연결 영향 | 없음 (IP 직접) | 없음 |

### 예상 취약점 & 개선 방향
- **JVM DNS 캐싱**: Java는 `networkaddress.cache.ttl=30`이 기본이지만, 보안 매니저 하에서는 영구 캐싱 → K8s 환경에서 `networkaddress.cache.ttl=10` 명시
- **Node.js DNS 캐싱 없음**: Next.js는 매번 DNS 조회 → `dns.setDefaultResultOrder('ipv4first')` + 커스텀 DNS 캐시 미들웨어
- **Python DNS 캐싱 없음**: FastAPI도 매번 조회 → `cachetools` 기반 DNS 결과 캐싱 또는 사이드카로 dnsmasq 운영
- **CoreDNS PDB 설정**: `minAvailable: 1`로 최소 1개 Pod 보장
- **NodeLocal DNSCache**: 각 노드에 DNS 캐시 DaemonSet 배포하여 CoreDNS 의존도 감소

---

## 실험 #7 — etcd 클러스터 멤버 장애 시 Control Plane 가용성 검증

### 가설
> "3노드 etcd 클러스터에서 1개 멤버가 죽어도 quorum(2/3)이 유지되어, kubectl 명령과 새로운 Pod 스케줄링이 정상 동작할 것이다. 2개 멤버가 죽으면 read-only 모드로 전환되어 기존 워크로드는 영향받지 않을 것이다."

### 실험 배경
**이 실험이 kubeadm 포트폴리오의 최대 차별화 포인트.** EKS/GKE 사용자는 절대 할 수 없는 실험. kubeadm으로 직접 구축했기 때문에 etcd 접근과 조작이 가능. etcd는 K8s의 모든 상태를 저장하므로, 여기가 죽으면 클러스터 전체가 무력화됨.

### 실험 방법
```bash
# 1단계: etcd 클러스터 상태 확인
ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.0.20.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list

# 2단계: etcd 멤버 1개 프로세스 강제 종료
ssh worker-01 "sudo systemctl stop etcd"

# 3단계: 장애 상태에서 K8s 동작 검증
kubectl get nodes                    # 응답 확인
kubectl create deployment test-nginx --image=nginx  # 새 배포 가능 여부
kubectl delete pod <random-pod>      # 삭제 후 재생성 여부

# 4단계: 2번째 멤버도 종료 (quorum 손실)
ssh worker-02 "sudo systemctl stop etcd"

# 5단계: 복구
ssh worker-01 "sudo systemctl start etcd"
ssh worker-02 "sudo systemctl start etcd"
```

### 측정 지표
| 지표 | 1멤버 장애 | 2멤버 장애 (quorum 손실) |
|------|-----------|------------------------|
| kubectl 응답 | 정상 | 타임아웃 또는 read-only |
| 새 Pod 스케줄링 | 정상 | 불가 |
| 기존 Pod 동작 | 영향 없음 | 영향 없음 (kubelet 독립) |
| etcd write 지연 | < 20ms | 불가 |
| 복구 후 정상화 시간 | 즉시 | < 30s |

### 예상 취약점 & 개선 방향
- **etcd 단일 노드 운영**: kubeadm 기본 설치 시 etcd 1개 → `kubeadm join --control-plane`으로 3노드 확장
- **etcd 자동 백업 미구성**: cronjob으로 `etcdctl snapshot save` 매시간 실행 + S3 업로드
- **etcd 디스크 성능**: etcd는 디스크 latency에 민감 → gp3 IOPS 3000 이상 보장, `--quota-backend-bytes` 조정
- **복구 런북**: snapshot restore 절차를 문서화하고 실제로 복구 훈련 수행

---

## 실험 #8 — AI 서비스(FastAPI) + Qdrant 벡터DB 동시 장애 시 Graceful Degradation 검증

### 가설
> "AI 서비스와 Qdrant가 동시에 다운되어도, Backend의 핵심 CRUD 기능(회원관리, 게시글 등)은 정상 동작하며, AI 의존 기능(추천, 검색 등)만 '일시적으로 사용할 수 없습니다' 응답을 반환할 것이다."

### 실험 배경
AI 서비스(FastAPI:5000)와 Qdrant(6333/6334)는 부가 기능. 이것들이 죽었다고 전체 서비스가 다운되면 안 됨. 현재 ALB 리스너 룰에서 `/ai/*` 경로가 AI 타겟그룹으로 라우팅되는데, AI가 죽으면 502가 사용자에게 직접 노출될 가능성이 있음.

### 실험 방법
```yaml
# 동시에 두 서비스의 Pod 삭제
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: ai-qdrant-simultaneous-kill
spec:
  engineState: active
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TARGET_PODS
              value: 'ai-deployment-xxx,qdrant-statefulset-0'
            - name: TOTAL_CHAOS_DURATION
              value: '600'        # 10분간 지속
            - name: FORCE
              value: 'true'
            - name: CHAOS_INTERVAL
              value: '30'         # 30초마다 반복 kill (자동 복구 방지)
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| Backend 핵심 API 가용률 | 100% | 99.9% |
| AI 관련 API 응답 | 503 + 메시지 | 5xx (graceful) |
| Frontend 에러 화면 표시 | Fallback UI | - |
| Backend 에러 로그 폭주 여부 | 분당 < 10건 | 분당 < 50건 |
| Backend CPU/Memory 영향 | 없음 | < 10% 변동 |

### 예상 취약점 & 개선 방향
- **Backend → AI 호출 시 예외 전파**: `RestClientException`이 500으로 전파 → `@ControllerAdvice`에서 AI 관련 예외를 503으로 래핑
- **Frontend 에러 핸들링 미흡**: AI API 502 시 빈 화면 → React Error Boundary + Fallback 컴포넌트
- **Circuit Breaker**: AI 서비스 3회 연속 실패 시 회로 차단 → 폴백 응답 반환 → 30초 후 half-open 시도
- **Qdrant 데이터 영속성**: Pod 재시작 시 벡터 데이터 유실 → PVC(Persistent Volume Claim) + 정기 스냅샷

---

## 실험 #9 — NAT Instance 장애 시 Private Subnet 외부 통신 검증

### 가설
> "NAT Instance가 다운되어도 이미 실행 중인 서비스는 영향받지 않으며, ECR 이미지 풀이 필요한 신규 Pod 생성만 실패할 것이다. NAT 복구 후 3분 이내에 pending Pod가 정상 배포될 것이다."

### 실험 배경
**v2 인프라의 가장 독특한 설계 포인트.** NAT Gateway 대신 t3.nano NAT Instance를 사용해서 비용 절감($3.80/월). 하지만 이건 SPOF(단일 장애점). NAT가 죽으면 Private Subnet의 모든 외부 통신이 끊김 → ECR pull 실패, SSM Parameter Store 접근 불가, 외부 API 호출 불가.

### 실험 방법
```bash
# NAT Instance의 네트워크 인터페이스에서 소스/대상 확인 비활성화를 되돌림 (트래픽 포워딩 중단)
# 또는 K8s 환경에서 NAT 역할 Pod에 네트워크 장애 주입

# EC2 환경에서의 실험 (v2 현행)
aws ec2 stop-instances --instance-ids <nat-instance-id>

# 실험 중 검증
# 1. 기존 서비스 동작 확인 (이미 pull된 이미지로 동작 중)
curl -f https://v2.dev.billages.com/actuator/health

# 2. 새로운 배포 시도 (ECR pull 필요)
kubectl rollout restart deployment/backend -n billage

# 3. SSM Parameter Store 접근 시도
aws ssm get-parameter --name "/billage/dev/db-password"

# 복구
aws ec2 start-instances --instance-ids <nat-instance-id>
```

### 측정 지표
| 지표 | 기대값 | 허용 임계치 |
|------|--------|------------|
| 기존 서비스 가용률 | 100% | 100% |
| 새 Pod 생성 (ImagePull) | 실패 | 실패 (예상됨) |
| 외부 API 호출 (카카오 등) | 실패 | 실패 (예상됨) |
| NAT 복구 후 정상화 시간 | < 120s | < 180s |
| Pending Pod 자동 해소 시간 | < 180s | < 300s |

### 예상 취약점 & 개선 방향
- **NAT 이중화 미구성**: AZ별 NAT Instance → ASG(min=1, max=1) + Health Check로 자동 복구
- **ECR 이미지 캐싱**: 노드 로컬에 이미지 캐시 유지 → `imagePullPolicy: IfNotPresent` + 주기적 pre-pull DaemonSet
- **VPC Endpoint 도입**: ECR, SSM, S3용 VPC Endpoint(PrivateLink) 구성 → NAT 의존 제거
- **Fallback 외부 통신**: 중요 외부 API 응답을 Redis에 캐싱하여 일시적 오프라인 모드 지원

---

## 실험 #10 — 전체 서비스 통합 GameDay: 복합 장애 시나리오

### 가설
> "동시에 워커노드 1대 장애 + Redis 다운 + 네트워크 지연 200ms가 발생하는 복합 장애 상황에서도, 서비스 전체 가용률 95% 이상을 유지하고, 15분 이내에 모든 자동 복구가 완료될 것이다."

### 실험 배경
실제 장애는 단일 원인으로 오지 않음. AWS AZ 장애 시 여러 컴포넌트가 동시에 영향받음. 이 실험은 앞선 9개 실험의 개선 사항이 모두 적용된 후, 최종 통합 검증으로 수행. **면접에서 "GameDay를 운영해봤다"고 말할 수 있는 근거**.

### 실험 방법 (3단계 Escalation)
```yaml
# Phase 1 (0분): Redis 장애
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: gameday-phase1-redis
spec:
  action: pod-kill
  selector:
    labelSelectors:
      app: redis
---
# Phase 2 (2분): 네트워크 지연 추가
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: gameday-phase2-latency
spec:
  action: delay
  selector:
    labelSelectors:
      app: backend
  delay:
    latency: '200ms'
---
# Phase 3 (5분): 워커노드 1대 drain
apiVersion: chaos-mesh.org/v1alpha1
kind: PhysicalMachineChaos
metadata:
  name: gameday-phase3-node
spec:
  action: node-stop
  address: 'worker-02:31768'
```

### 측정 지표 (전체 타임라인)
| 시점 | 이벤트 | 기대 가용률 | 주요 관찰 포인트 |
|------|--------|------------|----------------|
| 0분 | Redis 다운 | 99% | DB 폴백 동작, 세션 유지 |
| 2분 | +네트워크 지연 | 97% | Circuit Breaker 동작, 응답시간 |
| 5분 | +노드 장애 | 95% | Pod 재스케줄링, PDB 동작 |
| 10분 | 장애 지속 중 | 95% | 안정 상태 유지 여부 |
| 12분 | 복구 시작 | 97% | 자동 복구 순서 |
| 15분 | 전체 복구 완료 | 100% | 캐시 워밍업, 정상 상태 |

### Grafana 대시보드 구성
```
Row 1: 서비스별 가용률 (Backend/Frontend/AI) - Gauge
Row 2: 요청 처리량 + 에러율 - Time Series
Row 3: Pod 상태 (Running/Pending/Failed) - Stat
Row 4: 노드 리소스 (CPU/Memory) - Time Series
Row 5: DB 커넥션풀 + Redis 연결 상태 - Time Series
Row 6: 장애 주입 이벤트 타임라인 - Annotations
```

### 최종 산출물
- **Chaos Engineering Report**: 실험별 가설 / 결과 / 발견된 취약점 / 개선 사항 정리
- **MTTR (Mean Time To Recovery)**: 장애 유형별 평균 복구 시간 측정
- **SLO 달성 여부**: 가용률 99.5%, p99 < 2s 기준 검증
- **런북 (Runbook)**: 장애 유형별 대응 절차 자동화 문서

---

## 실험 우선순위 로드맵

```
Week 1-2: 실험 #1(Node 장애) + #2(RDS 페일오버) — 기초 인프라 내성
Week 3:   실험 #4(Redis 폴백) + #6(CoreDNS) — 데이터/네트워크 계층
Week 4:   실험 #3(RabbitMQ) + #8(AI+Qdrant) — 서비스 의존성 분리
Week 5:   실험 #5(Cascade Failure) + #9(NAT) — 네트워크 깊이
Week 6:   실험 #7(etcd) — Control Plane (kubeadm 핵심 차별화)
Week 7:   실험 #10(GameDay) — 통합 검증 + 대시보드 + 리포트 작성
```

---

## 포트폴리오 제출 시 강조 포인트

1. **kubeadm 직접 구축 → etcd 실험 가능** (EKS/GKE 사용자 대비 차별화)
2. **비용 최적화 NAT Instance의 SPOF를 카오스 실험으로 발견 → VPC Endpoint로 개선** (비용 vs 가용성 트레이드오프 판단력)
3. **단일 RabbitMQ → 카오스 실험 근거로 클러스터링 전환** (기술적 의사결정의 데이터 기반 근거)
4. **GameDay 운영 경험** (조직 문화 수준의 SRE 역량)
5. **Problem → Discovery → Fix → Re-validation 사이클을 수치로 증명**
