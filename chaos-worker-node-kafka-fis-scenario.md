# 워커노드 + Kafka StatefulSet 카오스 엔지니어링 — FIS 실험 설계서

> **실험 대상**: kubeadm 워커노드 (EC2) + Kafka StatefulSet (3 브로커)
> **실험 도구**: AWS FIS (`aws:ec2:stop-instances`) + Chaos Mesh
> **관련 워크로드**: Backend(Spring Boot), Frontend(Next.js), AI(FastAPI), Kafka(StatefulSet), Qdrant(StatefulSet), RabbitMQ(Deployment)
> **클러스터 구성**: Control Plane 노드 + 워커노드 3대 (worker-01, worker-02, worker-03)

---

## 왜 워커노드 + Kafka인가?

kubeadm 클러스터에서 워커노드가 죽는 것은 가장 현실적인 장애 시나리오다.
AWS EC2는 하드웨어 장애, 유지보수 이벤트, AZ 장애 등으로 예고 없이 종료될 수 있다.

핵심 문제는 **"그 노드 위에 뭐가 있었느냐"**에 따라 장애 범위가 완전히 달라진다는 것이다.

### 워커노드 3대 위의 Pod 배치 (실험 전 확인 필요)

```
worker-01 (AZ-a)              worker-02 (AZ-c)              worker-03 (AZ-a)
├── kafka-0 (StatefulSet)     ├── kafka-1 (StatefulSet)     ├── kafka-2 (StatefulSet)
├── backend-xxx (Deployment)  ├── backend-yyy (Deployment)  ├── qdrant-0 (StatefulSet)
├── frontend-xxx (Deployment) ├── frontend-yyy (Deployment) ├── ai-xxx (Deployment)
├── rabbitmq-xxx (Deployment) ├── ai-yyy (Deployment)       ├── frontend-zzz (Deployment)
└── promtail (DaemonSet)      └── promtail (DaemonSet)      └── promtail (DaemonSet)
```

> **주의**: 위는 예시이며, 실제 배치는 K8s 스케줄러가 결정한다.
> Anti-affinity 미설정 시 Backend 2개가 같은 노드에 몰릴 수 있고,
> Kafka 브로커와 Qdrant가 같은 노드에 있을 수도 있다.
> **이 "어디에 뭐가 있었는지 모른다"는 것 자체가 실험의 핵심 동기다.**

### 워커노드 장애 시 영향받는 범위

| 워크로드 유형 | 재스케줄링 방식 | 복구 특성 | 위험도 |
|-------------|---------------|----------|--------|
| Deployment (Backend, Frontend, AI, RabbitMQ) | 즉시 다른 노드에 새 Pod 생성 | 빠름 (이미지 캐시 있으면 수십 초) | 중간 |
| StatefulSet (Kafka) | **같은 이름으로 재생성, 같은 PVC 재마운트 필요** | 느림 (PVC AZ 바인딩 문제 가능) | **높음** |
| StatefulSet (Qdrant) | 같은 이름으로 재생성, PVC 재마운트 | 느림 (단일 replica라 다운타임 발생) | **높음** |
| DaemonSet (Promtail) | 노드 복구 시 자동 생성 | 노드 의존 | 낮음 |

---

## 실험 전체 구조 (5개 시나리오)

```
시나리오 A: 워커노드 1대 강제 종료 — Kafka 브로커 포함 노드 (Before)
    ↓
시나리오 B: 워커노드 1대 강제 종료 — Qdrant 포함 노드 (Before)
    ↓
시나리오 C: Kafka 파티션 리더 집중 노드 종료 — 메시지 유실 검증 (Before)
    ↓
[개선 적용]
    ↓
시나리오 D: 개선 후 동일 실험 재수행 (After)
    ↓
시나리오 E: 복합 장애 — 워커노드 1대 종료 + 네트워크 지연 동시 주입 (After)
```

---

## 시나리오 A — Kafka 브로커가 있는 워커노드 강제 종료

### 가설
> "워커노드 1대가 갑자기 죽어도, Kafka 클러스터는 나머지 2개 브로커로
> 메시지 생산/소비를 계속 처리하고, 해당 노드의 Deployment Pod들은
> 60초 이내에 다른 노드로 재스케줄링되어 서비스 가용률 99% 이상을 유지할 것이다."

### 가설에서 검증하고 싶은 진짜 질문들
> 1. Kafka 브로커 1대가 빠지면 파티션 리더 재선출에 얼마나 걸리나?
> 2. 그 사이 프로듀서(Backend)가 메시지 쓰기에 실패하나?
> 3. 컨슈머 그룹 리밸런싱 중 메시지 중복 처리가 발생하나?
> 4. kafka-0 Pod가 재생성될 때 PVC(EBS)가 다른 AZ 노드에서 마운트 가능한가?
> 5. Backend Pod가 anti-affinity 없이 같은 노드에 2개 있었다면 동시에 죽는가?

### 실험 전 준비

```bash
# 1. 현재 Pod 배치 확인 (어떤 노드에 뭐가 있는지)
kubectl get pods -o wide -n billage
kubectl get pods -o wide -n kafka

# 2. Kafka 토픽/파티션 리더 배치 확인
kubectl exec -n kafka kafka-0 -- \
  kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic billage-events

# 출력 예시:
# Topic: billage-events  Partition: 0  Leader: 0  Replicas: 0,1,2  Isr: 0,1,2
# Topic: billage-events  Partition: 1  Leader: 1  Replicas: 1,2,0  Isr: 1,2,0
# Topic: billage-events  Partition: 2  Leader: 2  Replicas: 2,0,1  Isr: 2,0,1

# 3. 어떤 워커노드에 kafka-0이 있는지 확인
KAFKA_0_NODE=$(kubectl get pod kafka-0 -n kafka -o jsonpath='{.spec.nodeName}')
echo "kafka-0 is on: $KAFKA_0_NODE"

# 4. 해당 노드의 EC2 Instance ID 확인
INSTANCE_ID=$(kubectl get node $KAFKA_0_NODE \
  -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)
echo "Instance ID: $INSTANCE_ID"

# 5. 해당 노드에 있는 모든 Pod 목록 (장애 영향 범위 사전 파악)
kubectl get pods --all-namespaces --field-selector spec.nodeName=$KAFKA_0_NODE
```

### FIS 실험 템플릿

```json
{
  "description": "Billage 워커노드 강제 종료 - Kafka 브로커 포함",
  "targets": {
    "kafkaWorkerNode": {
      "resourceType": "aws:ec2:instance",
      "resourceArns": ["arn:aws:ec2:ap-northeast-2:ACCOUNT:instance/INSTANCE_ID"],
      "selectionMode": "ALL"
    }
  },
  "actions": {
    "stopWorkerNode": {
      "actionId": "aws:ec2:stop-instances",
      "description": "Kafka 브로커가 위치한 워커노드 강제 종료",
      "parameters": {
        "startInstancesAfterDuration": "PT15M"
      },
      "targets": {
        "Instances": "kafkaWorkerNode"
      }
    }
  },
  "stopConditions": [
    {
      "source": "aws:cloudwatch:alarm",
      "value": "arn:aws:cloudwatch:ap-northeast-2:ACCOUNT:alarm:billage-all-services-down"
    }
  ],
  "roleArn": "arn:aws:iam::ACCOUNT:role/billage-fis-role",
  "tags": {
    "Experiment": "worker-node-kafka-scenario-a",
    "Environment": "dev"
  }
}
```

### 실험 전 부하 생성 (Steady State 확보)

```bash
# Kafka 프로듀서 부하 — Backend에서 Kafka로 이벤트 지속 발행
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-producer-load
  namespace: kafka
spec:
  template:
    spec:
      containers:
        - name: producer
          image: bitnami/kafka:latest
          command:
            - bash
            - -c
            - |
              seq 1 100000 | while read i; do
                echo "{\"eventId\":$i,\"type\":\"rental_created\",\"timestamp\":\"$(date -Iseconds)\"}"
                sleep 0.1
              done | kafka-console-producer.sh \
                --bootstrap-server kafka-0.kafka-headless.kafka:9092,kafka-1.kafka-headless.kafka:9092,kafka-2.kafka-headless.kafka:9092 \
                --topic billage-events \
                --property "parse.key=false"
      restartPolicy: Never
EOF

# Kafka 컨슈머 — 메시지 수신 카운터 (유실 감지용)
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-consumer-counter
  namespace: kafka
spec:
  template:
    spec:
      containers:
        - name: consumer
          image: bitnami/kafka:latest
          command:
            - bash
            - -c
            - |
              kafka-console-consumer.sh \
                --bootstrap-server kafka-0.kafka-headless.kafka:9092,kafka-1.kafka-headless.kafka:9092,kafka-2.kafka-headless.kafka:9092 \
                --topic billage-events \
                --group chaos-test-group \
                --from-beginning 2>/dev/null | \
              awk '{count++} END {print "Total messages consumed:", count}'
      restartPolicy: Never
EOF

# API 부하 테스트 (사용자 트래픽 시뮬레이션)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-worker-node-test
  namespace: billage
data:
  test.js: |
    import http from 'k6/http';
    import { check, sleep } from 'k6';
    import { Rate, Trend, Counter } from 'k6/metrics';

    const errorRate = new Rate('errors');
    const rentalDuration = new Trend('rental_duration');
    const kafkaProduceErrors = new Counter('kafka_produce_errors');

    export const options = {
      vus: 30,
      duration: '20m',
    };

    const BASE = 'http://backend-svc.billage:8080';

    export default function () {
      // 물품 등록 (Kafka 이벤트 발행 트리거)
      const createRes = http.post(`${BASE}/api/rentals`, JSON.stringify({
        title: `chaos-test-${Date.now()}`,
        description: 'chaos engineering test item',
      }), { headers: { 'Content-Type': 'application/json' } });

      if (createRes.status !== 201) {
        kafkaProduceErrors.add(1);
      }

      // 물품 리스트 조회
      const listRes = http.get(`${BASE}/api/rentals`);
      rentalDuration.add(listRes.timings.duration);
      check(listRes, { 'list_200': (r) => r.status === 200 }) || errorRate.add(1);

      // WebSocket 채팅 헬스 (RabbitMQ 의존)
      const wsHealth = http.get(`${BASE}/api/chat/health`);
      check(wsHealth, { 'chat_healthy': (r) => r.status === 200 });

      sleep(1);
    }
EOF
```

### 실험 실행 타임라인

```
T+0:00   부하 테스트 시작 (Steady State 확인, 3분간)
         - Kafka 프로듀서: 초당 10건 이벤트 발행 중
         - API 부하: 초당 30 요청 처리 중
         - 모든 Kafka 파티션 ISR = [0,1,2] 확인

T+3:00   ★ FIS 실험 트리거 — worker-01 (kafka-0 + backend-xxx + frontend-xxx 위치) 강제 종료

=== Phase 1: 즉각 영향 (T+3:00 ~ T+3:30) ===

T+3:00   worker-01 EC2 Stop 시작
T+3:05   [예상] kubelet 응답 중단, 노드 상태는 아직 Ready (node-monitor-grace-period)
T+3:10   [관찰] Kafka 브로커 0 연결 끊김
         → kafka-0을 리더로 가진 파티션들의 프로듀서 요청 실패 시작
         → 프로듀서 설정에 따라:
           - acks=all, retries=3 → 다른 브로커로 재시도
           - acks=1, retries=0 → 메시지 유실 가능
T+3:15   [예상] Kafka Controller(kafka-1 또는 kafka-2)가 브로커 0 감지
         → 파티션 리더 재선출 시작
T+3:20   [예상] 파티션 리더 재선출 완료 (ISR에서 새 리더 선택)
         → 프로듀서 메타데이터 리프레시 → 새 리더로 요청 전환

=== Phase 2: K8s 반응 (T+3:40 ~ T+5:00) ===

T+3:40   [예상] node-monitor-grace-period(40초) 만료
         → 노드 상태: Ready → NotReady
T+3:40   [예상] 컨슈머 그룹 리밸런싱 트리거
         → 해당 노드의 컨슈머 파티션 할당 해제
         → 나머지 컨슈머에게 파티션 재할당
         → 리밸런싱 중 일시적 소비 중단 (session.timeout.ms 만큼)
T+4:00   [관찰] Backend/Frontend Deployment Pod 재스케줄링 시작
         → worker-02 또는 worker-03에 새 Pod 생성
         → 이미지 캐시 있으면 ~10초, 없으면 ECR pull 필요 (VPC Endpoint 있으면 빠름)
T+4:20   [예상] pod-eviction-timeout(5분, 기본값) 대기 시작
         → Taint 기반 eviction: node.kubernetes.io/unreachable:NoExecute

=== Phase 3: StatefulSet 복구 시도 (T+5:00 ~ T+10:00) ===

T+5:00   [관찰] kafka-0 Pod가 Terminating 상태
         → StatefulSet 컨트롤러가 새 kafka-0 Pod 생성 시도
T+5:10   ★★★ 핵심 관찰 포인트 ★★★
         kafka-0의 PVC(EBS 볼륨)가 worker-01이 있던 AZ-a에 묶여 있음
         → 새 kafka-0이 worker-03(AZ-a)에 스케줄링되면: PVC 마운트 성공 → 복구
         → 새 kafka-0이 worker-02(AZ-c)에 스케줄링되면: PVC 마운트 실패 → Pending ← 장애 지속!

T+5:30   [관찰] RabbitMQ Deployment Pod 재스케줄링
         → Deployment라 빠르게 다른 노드에 생성
         → 단, 기존 WebSocket 연결은 끊김 → 클라이언트 재연결 필요

T+8:00   장애 지속 상태 안정성 확인
         - Kafka: 2/3 브로커로 운영 중, 메시지 정상 처리 여부
         - Backend: 새 Pod에서 Kafka 프로듀서 재연결 여부
         - 물품 리스트 API: 정상 응답 여부

=== Phase 4: 노드 복구 (T+15:00 ~) ===

T+15:00  FIS 자동 복구 — worker-01 EC2 재시작
T+16:00  [예상] kubelet 재시작, 노드 상태: NotReady → Ready
T+16:30  [관찰] kafka-0 Pod가 원래 노드에서 재생성 또는 유지
         → EBS 볼륨 재마운트, Kafka 브로커 재조인
T+17:00  [관찰] Kafka ISR이 다시 [0,1,2]로 복구되는 시간 측정
T+18:00  전체 정상화 확인
```

### 수집할 데이터 매트릭스

| 카테고리 | 지표 | 수집 도구 | Steady | Chaos | Recovery |
|---------|------|----------|--------|-------|----------|
| **Kafka** | ISR 파티션 수 (under-replicated) | Prometheus (JMX) | 0 | __개 | 0 |
| **Kafka** | 파티션 리더 재선출 시간 | Kafka 로그 | - | __초 | - |
| **Kafka** | 프로듀서 실패율 (record-error-rate) | Prometheus | 0% | __% | 0% |
| **Kafka** | 컨슈머 리밸런싱 소요 시간 | Kafka 로그 | - | __초 | - |
| **Kafka** | 메시지 유실 건수 | 프로듀서 sent - 컨슈머 received | 0 | __건 | 0 |
| **K8s** | 노드 NotReady 전환 시간 | kubectl events | - | __초 | - |
| **K8s** | Deployment Pod 재스케줄링 시간 | kubectl events | - | __초 | - |
| **K8s** | StatefulSet Pod 재생성 시간 | kubectl events | - | __초 | - |
| **K8s** | PVC 마운트 성공/실패 | kubectl describe pod | - | 성공/실패 | - |
| **서비스** | 물품 리스트 API 가용률 | Prometheus | __% | __% | __% |
| **서비스** | 물품 리스트 p99 응답시간 | Prometheus | __ms | __ms | __ms |
| **서비스** | 물품 등록 API 성공률 (Kafka 연동) | Prometheus | __% | __% | __% |
| **서비스** | WebSocket 재연결 시간 | 클라이언트 로그 | - | __초 | - |
| **리소스** | 나머지 노드 CPU 사용률 | Prometheus | __% | __% | __% |
| **리소스** | 나머지 노드 Memory 사용률 | Prometheus | __% | __% | __% |

---

## 시나리오 B — Qdrant가 있는 워커노드 강제 종료

### 가설
> "Qdrant(StatefulSet, replicas=1)가 있는 워커노드가 죽으면,
> AI 벡터 검색 기능은 완전히 중단되지만,
> NAT 시나리오에서 적용한 격벽 패턴이 동작하여
> 물품대여 리스트 등 핵심 기능은 영향받지 않을 것이다."

### 시나리오 A와 다른 점
> Qdrant는 **replicas=1**이므로 복제본이 없다.
> 죽으면 벡터 검색 기능이 **완전히 중단**되고, 복구는 PVC 재마운트에 의존한다.
> Kafka처럼 다른 브로커가 대신하는 구조가 아니므로, **애플리케이션 레벨 격벽**이 유일한 방어선이다.

### FIS 실험 (시나리오 A와 동일한 방식, 대상 노드만 다름)

```bash
# Qdrant가 있는 노드 확인
QDRANT_NODE=$(kubectl get pod qdrant-0 -n billage -o jsonpath='{.spec.nodeName}')
INSTANCE_ID=$(kubectl get node $QDRANT_NODE \
  -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)

echo "qdrant-0 is on: $QDRANT_NODE ($INSTANCE_ID)"

# 해당 노드의 모든 Pod 확인 (Kafka 브로커도 있을 수 있음!)
kubectl get pods --all-namespaces --field-selector spec.nodeName=$QDRANT_NODE -o wide
```

### 핵심 관찰 포인트

```
T+3:00   ★ 워커노드 종료

T+3:00   Qdrant Pod 즉시 다운
         → AI 서비스 → Qdrant gRPC 연결 실패
         → 벡터 검색 API 전면 중단

T+3:00   [핵심 검증] NAT 시나리오에서 적용한 격벽 패턴이 여기서도 동작하는가?
         → AI 추천 실패 → 물품 리스트 조회에 영향 없어야 함
         → CircuitBreaker OPEN → fallback(빈 추천) 반환

T+5:00   qdrant-0 Pod 재생성 시도
         → PVC AZ 바인딩 문제 동일하게 발생 가능
         → 마운트 성공 시: Qdrant 시작 → 벡터 데이터 로드 (파일 크기에 따라 1~5분)
         → 마운트 실패 시: Pending 상태 → 수동 개입 필요
```

### 측정 지표 (시나리오 A 보완)

| 지표 | 기대값 | NAT 시나리오 격벽 교차 검증 |
|------|--------|--------------------------|
| AI 벡터 검색 가용률 | 0% (예상됨) | - |
| 물품 리스트 가용률 | 100% | ← NAT 시나리오 격벽 패턴이 여기서도 동작하는지 |
| CircuitBreaker 상태 전환 | CLOSED → OPEN (3초 내) | ← Resilience4j 설정값 검증 |
| Qdrant PVC 재마운트 시간 | < 60초 (같은 AZ) | - |
| Qdrant 데이터 로드 시간 | < 300초 | 벡터 인덱스 크기에 따라 |
| Qdrant 복구 후 AI 서비스 정상화 | < 30초 | CircuitBreaker HALF_OPEN → CLOSED |

---

## 시나리오 C — Kafka 파티션 리더 집중 노드 종료 (Worst Case)

### 가설
> "Kafka 토픽의 모든 파티션 리더가 특정 브로커에 집중되어 있을 때,
> 해당 브로커 노드가 죽으면 모든 파티션에서 동시에 리더 재선출이 발생하여
> 프로듀서 쓰기 실패 시간이 시나리오 A보다 길어질 것이다."

### 왜 이 시나리오가 필요한가
> Kafka는 파티션 리더를 자동으로 분산하지만,
> 브로커 재시작 등 운영 이벤트 후 리더가 한쪽에 몰릴 수 있다.
> `auto.leader.rebalance.enable=true`여도 리밸런스 주기(기본 300초) 사이에
> 장애가 오면 worst case가 된다.

### 실험 방법

```bash
# Step 1: 의도적으로 파티션 리더를 kafka-0에 집중시키기
# preferred replica election 을 통해 리더 쏠림 유도

# 현재 리더 분포 확인
kubectl exec -n kafka kafka-0 -- \
  kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic billage-events | \
  awk '/Leader/ {leaders[$NF]++} END {for (l in leaders) print "Broker", l, ":", leaders[l], "partitions"}'

# 모든 파티션의 preferred leader를 broker 0으로 재할당 (실험용)
cat <<'EOF' > /tmp/reassignment.json
{
  "version": 1,
  "partitions": [
    {"topic": "billage-events", "partition": 0, "replicas": [0, 1, 2]},
    {"topic": "billage-events", "partition": 1, "replicas": [0, 2, 1]},
    {"topic": "billage-events", "partition": 2, "replicas": [0, 1, 2]},
    {"topic": "billage-rental", "partition": 0, "replicas": [0, 1, 2]},
    {"topic": "billage-rental", "partition": 1, "replicas": [0, 2, 1]},
    {"topic": "billage-rental", "partition": 2, "replicas": [0, 1, 2]}
  ]
}
EOF

kubectl cp /tmp/reassignment.json kafka/kafka-0:/tmp/
kubectl exec -n kafka kafka-0 -- \
  kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file /tmp/reassignment.json --execute

# preferred leader election 실행
kubectl exec -n kafka kafka-0 -- \
  kafka-leader-election.sh --bootstrap-server localhost:9092 \
  --election-type preferred --all-topic-partitions

# Step 2: 리더 집중 확인
kubectl exec -n kafka kafka-0 -- \
  kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic billage-events
# 모든 파티션 Leader = 0 확인

# Step 3: FIS로 kafka-0 노드 종료 (시나리오 A와 동일)
# → 모든 파티션에서 동시 리더 재선출 발생
```

### 시나리오 A vs C 비교 측정

| 지표 | 시나리오 A (리더 분산) | 시나리오 C (리더 집중) |
|------|---------------------|---------------------|
| 영향받는 파티션 수 | 전체의 ~33% | 전체의 **100%** |
| 리더 재선출 총 시간 | __초 | __초 (더 길 것으로 예상) |
| 프로듀서 쓰기 실패 구간 | __초 | __초 |
| 컨슈머 리밸런싱 시간 | __초 | __초 |
| 메시지 유실 건수 | __건 | __건 |
| 물품 등록 API 실패율 | __% | __% |

---

## 개선 방안 적용

### 개선 1: Pod Anti-Affinity — 동일 서비스 Pod 분산 배치 (K8s)

> Backend Pod 2개가 같은 노드에 몰리면 노드 장애 시 전멸.
> Anti-affinity로 반드시 다른 노드에 배치한다.

```yaml
# Backend Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: billage
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: backend
    spec:
      affinity:
        podAntiAffinity:
          # 강제: 같은 노드에 backend Pod 2개 불가
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - backend
              topologyKey: "kubernetes.io/hostname"

      containers:
        - name: backend
          image: billage-backend:TAG
          # Graceful Shutdown: SIGTERM 받으면 진행 중 요청 완료 후 종료
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 15"]
          # Pod 종료 시 최대 30초 대기
          terminationGracePeriodSeconds: 30

---
# Frontend도 동일하게 적용
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: billage
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: frontend
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - frontend
              topologyKey: "kubernetes.io/hostname"
```

### 개선 2: PodDisruptionBudget — 최소 가용 Pod 보장

```yaml
# Backend PDB: 항상 최소 1개는 Running
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
  namespace: billage
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: backend

---
# Kafka PDB: 3개 중 최소 2개는 Running (quorum 유지)
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kafka-pdb
  namespace: kafka
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: kafka
```

### 개선 3: Kafka StatefulSet — AZ 인식 스케줄링 + PVC 설정

> Kafka 브로커가 특정 AZ에 치우치지 않고, PVC가 재마운트 가능하도록 설정한다.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: kafka
spec:
  replicas: 3
  serviceName: kafka-headless
  podManagementPolicy: Parallel    # 순서 무관하게 동시 시작 (복구 속도 향상)
  template:
    metadata:
      labels:
        app: kafka
    spec:
      affinity:
        podAntiAffinity:
          # Kafka 브로커끼리 반드시 다른 노드에 배치
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - kafka
              topologyKey: "kubernetes.io/hostname"

      # 노드 장애 시 빠른 재스케줄링을 위한 toleration
      tolerations:
        - key: "node.kubernetes.io/unreachable"
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 30      # 기본 300초 → 30초로 단축

      containers:
        - name: kafka
          image: bitnami/kafka:3.6
          ports:
            - containerPort: 9092
              name: client
            - containerPort: 9093
              name: interbroker
          env:
            - name: KAFKA_CFG_MIN_INSYNC_REPLICAS
              value: "2"
            - name: KAFKA_CFG_DEFAULT_REPLICATION_FACTOR
              value: "3"
            - name: KAFKA_CFG_OFFSETS_TOPIC_REPLICATION_FACTOR
              value: "3"
            # 프로듀서 재시도를 위한 설정
            - name: KAFKA_CFG_UNCLEAN_LEADER_ELECTION_ENABLE
              value: "false"        # 데이터 유실 방지: ISR 밖의 replica를 리더로 선출하지 않음

          volumeMounts:
            - name: kafka-data
              mountPath: /bitnami/kafka

  volumeClaimTemplates:
    - metadata:
        name: kafka-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3-retain    # ← 커스텀 StorageClass 사용
        resources:
          requests:
            storage: 20Gi

---
# StorageClass: AZ 바인딩 문제 해결
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-retain
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Retain                           # Pod 삭제 시 EBS 보존
volumeBindingMode: WaitForFirstConsumer          # ★ Pod가 스케줄링된 AZ에서 EBS 생성
allowVolumeExpansion: true
```

> **`WaitForFirstConsumer`가 핵심이다.**
> 기본값 `Immediate`는 PVC 생성 시점에 랜덤 AZ에 EBS를 만들어버려서,
> Pod가 다른 AZ에 스케줄링되면 마운트 실패한다.
> `WaitForFirstConsumer`는 Pod가 스케줄링된 후 해당 AZ에 EBS를 생성하므로,
> 최초 배포 시 AZ 불일치 문제가 없다.
>
> 단, **노드 장애 후 Pod가 다른 AZ 노드로 재스케줄링되면 여전히 문제**다.
> 이를 해결하려면 Kafka 브로커별로 nodeAffinity를 걸어 AZ를 고정하거나,
> **EBS Multi-Attach**(io2 볼륨)를 쓰거나, 워커노드를 AZ별로 최소 1대씩 유지해야 한다.

### 개선 4: Kafka 프로듀서 설정 — Backend (애플리케이션)

> 브로커 1대 장애 시 메시지 유실을 방지하는 프로듀서 설정.

```yaml
# Backend application.yml
spring:
  kafka:
    producer:
      # 모든 ISR replica에 쓰기 완료 확인 (유실 방지)
      acks: all

      # 브로커 연결 실패 시 재시도
      retries: 3
      properties:
        # 재시도 간격 (지수 백오프)
        retry.backoff.ms: 1000
        # 재시도 최대 시간
        delivery.timeout.ms: 30000
        # 메타데이터 리프레시 (새 리더 발견)
        metadata.max.age.ms: 30000
        # 리더 재선출 대기
        request.timeout.ms: 10000
        # 브로커 연결 풀에서 죽은 연결 감지
        connections.max.idle.ms: 60000

      # 멱등성 프로듀서 (중복 방지)
      properties:
        enable.idempotence: true
        max.in.flight.requests.per.connection: 5

    consumer:
      # 리밸런싱 설정
      properties:
        # 컨슈머 세션 타임아웃 (이 시간 안에 heartbeat 없으면 dead 판정)
        session.timeout.ms: 15000
        # heartbeat 주기 (session.timeout의 1/3 이하)
        heartbeat.interval.ms: 5000
        # 리밸런싱 전략
        partition.assignment.strategy: org.apache.kafka.clients.consumer.CooperativeStickyAssignor
        # 자동 오프셋 리셋
        auto.offset.reset: earliest
```

### 개선 5: Kafka 프로듀서 장애 격리 — Backend (애플리케이션)

> Kafka 프로듀서가 실패해도 API 응답은 정상 반환.
> 이벤트 발행은 비동기로 분리하고, 실패 시 DB에 저장 후 재시도 (Outbox 패턴).

```java
@Service
@RequiredArgsConstructor
public class RentalService {

    private final RentalRepository rentalRepository;
    private final OutboxRepository outboxRepository;
    private final KafkaTemplate<String, String> kafkaTemplate;

    /**
     * 물품 등록: DB 저장은 반드시 성공, Kafka 이벤트는 best-effort
     */
    @Transactional
    public RentalResponse createRental(RentalRequest request) {
        // 1. 핵심: DB에 물품 저장 (반드시 성공해야 함)
        RentalItem item = rentalRepository.save(request.toEntity());

        // 2. Outbox: 같은 트랜잭션에 이벤트 기록
        //    → Kafka가 죽어도 DB에는 남아있음
        OutboxEvent event = OutboxEvent.builder()
            .aggregateType("RentalItem")
            .aggregateId(item.getId().toString())
            .eventType("RENTAL_CREATED")
            .payload(toJson(item))
            .status(OutboxStatus.PENDING)
            .build();
        outboxRepository.save(event);

        // 3. 비동기 Kafka 발행 시도 (실패해도 API 응답에 영향 없음)
        publishEventAsync(event);

        return RentalResponse.from(item);
    }

    /**
     * 비동기 Kafka 발행: 실패 시 Outbox에 PENDING으로 남김
     * → 스케줄러가 주기적으로 재시도
     */
    private void publishEventAsync(OutboxEvent event) {
        try {
            kafkaTemplate.send("billage-events", event.getAggregateId(), event.getPayload())
                .whenComplete((result, ex) -> {
                    if (ex != null) {
                        log.warn("[Kafka] 이벤트 발행 실패, Outbox 재시도 예정: {}",
                                 ex.getMessage());
                        // PENDING 상태 유지 → 스케줄러가 재시도
                    } else {
                        // 성공 시 Outbox 상태 업데이트
                        outboxRepository.markAsPublished(event.getId());
                    }
                });
        } catch (Exception e) {
            log.warn("[Kafka] 프로듀서 연결 실패, Outbox 재시도 예정: {}",
                     e.getMessage());
        }
    }

    /**
     * Outbox 재시도 스케줄러: 1분마다 PENDING 이벤트 재발행
     */
    @Scheduled(fixedRate = 60000)
    @Transactional
    public void retryPendingEvents() {
        List<OutboxEvent> pending = outboxRepository
            .findByStatusAndCreatedAtAfter(OutboxStatus.PENDING,
                                           LocalDateTime.now().minusHours(1));
        for (OutboxEvent event : pending) {
            publishEventAsync(event);
        }
    }
}
```

### 개선 6: 노드 장애 감지 가속화 (K8s)

> 기본 설정은 노드 장애 감지 → Pod eviction까지 5분 이상 걸린다.
> kubeadm 환경에서 이를 단축한다.

```yaml
# kube-controller-manager 설정 (kubeadm)
# /etc/kubernetes/manifests/kube-controller-manager.yaml
spec:
  containers:
    - command:
        - kube-controller-manager
        # 노드 상태 체크 주기 (기본 5초 → 유지)
        - --node-monitor-period=5s
        # NotReady 전환까지 대기 시간 (기본 40초 → 20초)
        - --node-monitor-grace-period=20s
        # Pod eviction 속도
        - --pod-eviction-timeout=30s

---
# kubelet 설정 (각 워커노드)
# /var/lib/kubelet/config.yaml
nodeStatusUpdateFrequency: 5s     # 기본 10초 → 5초
```

> **before**: 노드 다운 → 40초(grace) → NotReady → 300초(eviction) → Pod 삭제 = **~340초**
> **after**: 노드 다운 → 20초(grace) → NotReady → 30초(eviction) → Pod 삭제 = **~50초**

---

## 시나리오 D — 개선 후 동일 실험 재수행 (After)

### 시나리오 A 재실험 — Before / After 비교

| SLI | SLO | Before (시나리오 A) | After (시나리오 D) | 판정 |
|-----|-----|--------------------|--------------------|------|
| Kafka 메시지 유실 | 0건 | __건 | 0건 (acks=all + Outbox) | ○/× |
| 파티션 리더 재선출 시간 | < 10초 | __초 | __초 | ○/× |
| 프로듀서 쓰기 중단 시간 | < 15초 | __초 | __초 (retries + metadata refresh) | ○/× |
| Backend Pod 재스케줄링 | < 60초 | __초 | __초 (anti-affinity + 빠른 eviction) | ○/× |
| Backend Pod 동시 전멸 | 발생 안 함 | 발생/미발생 | 미발생 (anti-affinity 보장) | ○/× |
| 물품 리스트 API 가용률 | 99.9% | __% | __% | ○/× |
| 물품 등록 API 가용률 | 99% | __% | __% (Outbox 폴백) | ○/× |
| kafka-0 PVC 마운트 | 성공 | 성공/실패 | 성공 (WaitForFirstConsumer) | ○/× |
| 노드 장애 → Pod 재생성 | < 60초 | __초 (~340초) | __초 (~50초) | ○/× |

### 시나리오 B 재실험 — Qdrant 격벽 교차 검증

| SLI | Before | After |
|-----|--------|-------|
| 물품 리스트 가용률 (Qdrant 다운 중) | __% | 100% (격벽 동작 확인) |
| AI 추천 가용률 | 0% | 0% (예상됨, graceful) |
| CircuitBreaker OPEN 전환 시간 | __초 | < 3초 |
| Qdrant 복구 후 AI 정상화 | __초 | < 30초 (HALF_OPEN → CLOSED) |

### 시나리오 C 재실험 — 리더 집중 worst case

| 지표 | Before (리더 집중) | After (리더 집중 + 개선) |
|------|-------------------|------------------------|
| 프로듀서 쓰기 중단 시간 | __초 | __초 (retries=3 + timeout=30s) |
| 메시지 유실 | __건 | 0건 (acks=all + Outbox) |
| 물품 등록 API 가용률 | __% | __% (Outbox 폴백) |

---

## 시나리오 E — 복합 장애: 워커노드 종료 + 네트워크 지연 (After)

### 가설
> "워커노드 1대 장애와 동시에 나머지 노드 간 네트워크 지연(200ms)이 발생해도,
> 모든 개선 사항(anti-affinity, PDB, 격벽, Outbox)이 복합적으로 동작하여
> 서비스 가용률 95% 이상, 메시지 유실 0건을 유지할 것이다."

### 실험 방법 (FIS + Chaos Mesh 조합)

```yaml
# Phase 1 (T+0): 네트워크 지연 주입 (Chaos Mesh)
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: gameday-latency
  namespace: chaos-testing
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
  duration: '600s'

---
# Phase 2 (T+2분): FIS로 워커노드 종료
# → 네트워크 지연 상태에서 Kafka 브로커 재선출 + Pod 재스케줄링 동시 발생
# → Kafka 프로듀서 메타데이터 리프레시가 지연으로 느려짐
# → retries가 더 많이 발생
# → Outbox 폴백이 실제로 동작하는지 검증
```

### 복합 장애 타임라인

| 시점 | 이벤트 | 기대 가용률 | 관찰 포인트 |
|------|--------|------------|------------|
| T+0 | 네트워크 지연 200ms 시작 | 99% | API 응답시간 증가 |
| T+2분 | +워커노드 종료 | 95% | Kafka 리더 재선출 + Pod 재스케줄링 동시 |
| T+3분 | Kafka 리더 재선출 완료 | 96% | 지연 상태에서 재선출 시간 측정 |
| T+4분 | Pod 재스케줄링 완료 | 97% | anti-affinity 동작, PDB 보호 |
| T+10분 | 네트워크 지연 종료 | 99% | 정상화 |
| T+15분 | 워커노드 복구 | 100% | Kafka ISR 완전 복구 |

---

## Grafana 대시보드 설계

### 대시보드: Worker Node + Kafka Chaos Experiment

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Row 1: 실험 타임라인 (Annotations)                                        │
│ [노드 종료] ─── [Kafka 리더 재선출] ─── [Pod 재스케줄링] ─── [복구]         │
├──────────────────────────────────────────────────────────────────────────┤
│ Row 2: K8s 노드 상태                                                      │
│ ┌────────────┐ ┌────────────┐ ┌────────────┐                            │
│ │ worker-01  │ │ worker-02  │ │ worker-03  │                            │
│ │  NotReady  │ │   Ready    │ │   Ready    │                            │
│ └────────────┘ └────────────┘ └────────────┘                            │
├──────────────────────────────────────────────────────────────────────────┤
│ Row 3: Kafka 클러스터 상태                                                 │
│ ─── Under-Replicated Partitions (0이어야 정상)                            │
│ ─── ISR Shrink Rate                                                      │
│ ─── Active Controller (리더 컨트롤러 브로커 ID)                            │
│ ─── Partition Leader 분포 (브로커별 리더 수)                               │
├──────────────────────────────────────────────────────────────────────────┤
│ Row 4: Kafka 프로듀서 메트릭                                               │
│ ─── record-send-rate (초당 전송 건수)                                     │
│ ─── record-error-rate (초당 실패 건수)                                    │
│ ─── request-latency-avg (브로커 응답 시간)                                │
│ ─── outgoing-byte-rate                                                   │
├──────────────────────────────────────────────────────────────────────────┤
│ Row 5: Kafka 컨슈머 메트릭                                                │
│ ─── records-consumed-rate (초당 소비 건수)                                │
│ ─── records-lag (파티션별 컨슈머 랙)                                      │
│ ─── rebalance-total (리밸런싱 횟수)                                       │
│ ─── rebalance-latency-avg (리밸런싱 소요 시간)                             │
├──────────────────────────────────────────────────────────────────────────┤
│ Row 6: Outbox 상태                                                       │
│ ─── PENDING 이벤트 수 (Kafka 장애 시 증가 → 복구 후 감소)                  │
│ ─── PUBLISHED 이벤트 수 (정상 발행 누적)                                   │
│ ─── FAILED 이벤트 수 (재시도 실패)                                        │
├──────────────────────────────────────────────────────────────────────────┤
│ Row 7: 서비스 API 가용률                                                  │
│ ─── 물품 리스트 조회 성공률                                                │
│ ─── 물품 등록 성공률 (Kafka 연동)                                         │
│ ─── AI 추천 성공률                                                        │
│ ─── WebSocket 연결 수                                                     │
├──────────────────────────────────────────────────────────────────────────┤
│ Row 8: Pod 상태 변화 (Stat)                                               │
│ Backend: 2/2 → 1/2 → 2/2  | Kafka: 3/3 → 2/3 → 3/3                    │
│ Frontend: 2/2 → 1/2 → 2/2 | Qdrant: 1/1 or 0/1                         │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 비용 분석 — 이 실험으로 인한 추가 비용

| 항목 | 비용 | 비고 |
|------|------|------|
| FIS 실험 실행 | 무료 (월 100 action-minutes 프리티어) | dev 환경이면 충분 |
| Kafka 3노드 EBS (gp3 20GB × 3) | $4.80/월 | 기존 대비 추가 |
| EBS CSI Driver (DaemonSet) | 무료 (오픈소스) | PVC 동적 프로비저닝용 |
| Chaos Mesh (시나리오 E) | 무료 (오픈소스) | K8s 내 설치 |

---

## 포트폴리오 스토리 — 면접에서의 설명 흐름

```
1. "kubeadm으로 K8s 클러스터를 직접 구축한 후,
    워커노드 장애 시 서비스에 어떤 영향이 있는지 검증하고 싶었습니다."

2. "FIS로 워커노드 EC2를 강제 종료했더니 세 가지 문제를 발견했습니다:
    - Backend Pod가 anti-affinity 없이 같은 노드에 몰려있어서 한번에 전멸했고,
    - Kafka 브로커의 PVC가 특정 AZ에 묶여있어서 다른 AZ 노드로 재스케줄링이 안 됐고,
    - 기본 설정으로는 노드 장애 감지에서 Pod 재생성까지 5분 넘게 걸렸습니다."

3. "이를 해결하기 위해:
    - Pod Anti-Affinity로 서비스별 분산 배치를 강제했고,
    - StorageClass의 volumeBindingMode를 WaitForFirstConsumer로 바꿔서 AZ 불일치를 방지했고,
    - node-monitor-grace-period와 tolerationSeconds를 단축해서 복구 시간을 340초에서 50초로 줄였고,
    - Kafka 프로듀서에 Outbox 패턴을 적용해서 브로커 장애 시에도 물품 등록 API 가용률 100%를 유지했습니다."

4. "개선 후 동일 실험을 재수행해서 Before/After 수치로 검증했고,
    복합 장애(노드 종료 + 네트워크 지연) 상황에서도 95% 이상 가용률을 확인했습니다."
```
