# 의존성 지연 주입 실험 계획

## 근본 목적

- `Spring -> RabbitMQ / RDS` 의존성 경로에 지연과 손실을 주입했을 때, 장애가 단일 요청 실패로 끝나는지 아니면 thread pool, connection pool, retry, probe를 통해 전체 서비스 지연으로 전파되는지를 관측한다.
- 이후 timeout, retry, backoff, circuit breaker, degraded mode, probe 설계를 조정해 장애 전파 반경을 줄였다는 점을 수치로 증명한다.

## 비목적

- 클러스터 전체 장애를 유도하는 chaos 실험을 하는 것이 목적은 아니다.
- 컨트롤 플레인(etcd, kube-apiserver) 장애 실험이나 AZ 단위 복구 실험을 이번 범위에 포함하지 않는다.

---

## 1. 현재 클러스터 구성

본 실험 대상은 `kubeadm` 기반 self-managed Kubernetes 클러스터다. 클러스터는 `ap-northeast-2` 리전에 배치되어 있고, control-plane 3대와 worker 7대로 구성된다. control-plane은 `cp-01/02/03` 3대로 `ap-northeast-2a`, `ap-northeast-2b`, `ap-northeast-2c`에 분산되어 있으며, 각 노드는 kubeadm control-plane join을 통해 etcd 멤버를 함께 가진다.

worker는 역할별로 분리되어 있다.

- app plane: `app-01~04`
- data plane: `data-01~03`

data plane은 `workload-plane=data:NoSchedule` taint를 사용하며, RabbitMQ와 Qdrant 같은 stateful 워크로드가 이 영역에 배치된다.

네임스페이스도 역할별로 분리되어 있다.

- `billage-app`: Next.js, Spring Boot, FastAPI
- `billage-data`: RabbitMQ, Qdrant
- `billage-edge`: edge / TLS
- `billage-ops`: 운영 도구

이 분리는 fault injection 실험에 유리하다. app 계층 장애와 data 계층 장애를 분리해서 관측할 수 있고, 전파 경로도 비교적 명확하다.

트래픽 경로는 다음과 같다.

`인터넷 -> ALB -> ingress-nginx -> Service -> Pod`

즉 최종 사용자 체감 지표는 ingress와 app pod에서 함께 봐야 한다.

서비스 간 허용 경로도 이미 설계돼 있다.

- `billage-edge -> billage-app`
- `billage-app -> billage-data`
- `billage-app -> RDS / Redis`
- `billage-ops -> billage-data`

따라서 이번 실험은 `Spring -> RabbitMQ`, `Spring -> RDS` 같은 의존성 경로에 집중하는 것이 자연스럽다.

### 1.1 현재 구조상 fault injection 후보 지점

이번 클러스터에서 fault injection을 넣을 수 있는 후보 지점은 크게 네 군데다.

1. `Spring pod -> RDS`
2. `Spring pod -> RabbitMQ`
3. `readinessProbe / livenessProbe`
4. `ingress-nginx -> app Service` 구간

이 중 이번 목적에 가장 직접적으로 맞는 지점은 `Spring -> RDS`, `Spring -> RabbitMQ`다. ingress나 control-plane은 사용자 체감은 크지만, "의존성 지연이 내부에서 어떻게 전파되는가"를 보여주기에는 원인과 결과가 덜 선명하다.

---

## 2. 왜 이 실험이 효과적인가

이번 실험은 단순한 네트워크 장애 재현이 아니라, "의존성 지연이 어떻게 사용자 요청 전체를 늦추는가"를 보여주는 데 목적이 있다.

특히 Spring Boot는 JVM 힙, WebSocket 세션, 커넥션 풀을 함께 가지는 핵심 워크로드다. 외부 의존성이 느려지면 다음과 같은 전파가 발생할 가능성이 높다.

- 요청 스레드가 느린 의존성 응답을 기다리며 점유된다.
- DB / RabbitMQ 커넥션 풀이 회수되지 않고 묶인다.
- retry가 겹치면 원래 1번이면 끝날 요청이 2~3배 부하로 증폭된다.
- 정상 요청도 free thread, free connection을 얻지 못해 같이 느려진다.
- readiness / liveness가 외부 의존성에 묶여 있으면 pod가 살아 있어도 unready 또는 restart가 난다.
- HPA는 CPU나 memory 상승만 보고 scale-out하지만, root cause는 의존성 지연이라 확장이 문제를 완전히 해결하지 못한다.

이 그림은 포트폴리오에서 전달력이 높다. "의존성 한 개가 느려졌을 뿐인데 전체 서비스 tail latency와 오류율이 어떻게 무너지는지"를 한 장의 타임라인과 그래프로 설명할 수 있기 때문이다.

---

## 3. 가장 효과적인 주입 지점 우선순위

### 3.1 1순위: `Main Server(Spring) -> RDS`

가장 드라마틱하다.

이 경로는 사용자 동기 요청과 직접 연결되어 있을 가능성이 높다. 상품 조회, 인증, 채팅방 목록, 알림 조회 같은 기능은 결국 DB read / write 지연의 영향을 바로 받는다. 따라서 latency injection을 넣으면 곧바로 다음 현상이 나타날 가능성이 있다.

- API p95 / p99 급등
- ingress 기준 upstream response time 증가
- Hikari pool active 증가, pending 증가
- servlet / tomcat worker thread 점유 증가
- 정상 경로까지 latency contagion
- timeout 이후 5xx 급증
- readiness flapping 가능성

포트폴리오 관점에서 가장 보기 좋은 시나리오다. "RDS 1초 지연"만으로도 전체 서비스가 거의 불능에 가까워지는 모습을 보여주기 쉽다.

### 3.2 2순위: `Chat / Notification -> RabbitMQ`

전달력은 약간 덜하지만 설계 개선 효과를 보여주기 좋다.

이 경로는 보통 비동기성이 섞여 있어서 즉시 5xx보다 backlog 증가, 처리 지연, 재시도 증폭이 먼저 나타난다. 따라서 장애가 잠복적으로 전파된다.

- publish latency 증가
- consumer lag 증가
- queue depth 증가
- unacked 증가
- retry storm
- executor queue 증가
- websocket message delivery 지연
- broker connection / channel churn 증가

이 시나리오는 "API는 살아 있는데 채팅과 알림이 몇 초씩 늦어지는" 현실적인 운영 문제를 보여주기 좋다.

### 3.3 3순위: `Spring readinessProbe -> 외부 의존성`

이건 개선 전후 비교용 보조 시나리오로 좋다.

외부 의존성 하나가 느려졌을 때 pod가 단지 느려지는 수준을 넘어 unready로 빠지고, rollout과 traffic routing이 함께 흔들리는 구조적 문제를 드러낼 수 있다.

---

## 4. 실험 원칙

- 한 번에 하나의 의존성만 주입한다.
- baseline 없이 주입하지 않는다.
- 동일 부하, 동일 시간대, 동일 메트릭으로 개선 전후를 비교한다.
- control-plane이나 `kube-system`에는 주입하지 않는다.
- 최초 실험은 blast radius가 작은 방식으로 한다.

실험 도구는 두 가지 방식이 가능하다.

### 4.1 방법 A: Toxiproxy

앱과 의존성 사이에 프록시를 두고 latency / loss를 넣는다.

장점:

- 특정 서비스 경로만 정밀하게 주입 가능
- 재현성이 좋음
- 롤백이 쉬움

단점:

- 애플리케이션 connection target을 proxy로 바꿔야 함

### 4.2 방법 B: Chaos Mesh NetworkChaos

Pod egress에 네트워크 지연 / 손실을 건다.

장점:

- 실제 네트워크 장애에 가까움
- 코드 / 설정 변경이 적음

단점:

- 초기 설치와 권한 범위가 큼
- blast radius 통제가 더 중요함

첫 실험은 Toxiproxy가 더 적합하다. 포트폴리오에서는 "정확히 어느 의존성 경로에 얼마나 지연을 넣었는지"가 명확해야 하기 때문이다.

---

## 5. 공통 측정 항목

모든 시나리오에서 아래 4개 계층 메트릭을 동시에 본다.

### 5.1 사용자 체감

- ingress-nginx request rate
- ingress-nginx p50 / p95 / p99
- HTTP status code 분포
- timeout 비율
- 사용자 시나리오 성공률

### 5.2 애플리케이션 내부

- Spring request duration
- active request / thread 수
- executor queue length
- JVM thread 수
- GC pause
- readiness / liveness 실패 횟수

### 5.3 의존성

RDS:

- DatabaseConnections
- ReadLatency / WriteLatency
- CPUUtilization
- connection saturation

RabbitMQ:

- publish rate
- deliver / ack rate
- queue depth
- unacked count
- consumer utilization
- connection / channel count
- memory alarm

### 5.4 Kubernetes

- pod restart
- pod ready / unready 전환
- HPA desired / current replicas
- node CPU / memory
- network retransmit / drop
- event log

---

## 6. 상세 실험 시나리오

## 시나리오 A. `Spring -> RDS` 지연 주입

### 목적

DB 응답 지연이 synchronous request path를 통해 전체 API latency와 app pool을 어떻게 무너뜨리는지 관측한다.

### 주입 지점

- `billage-app` 네임스페이스의 Spring Boot pod
- DB connection target 앞단 proxy 또는 egress network

### 단계

1. baseline 15분
2. 고정 부하 10분 유지
3. DB latency 100ms 주입 10분
4. DB latency 300ms 주입 10분
5. DB latency 1s 주입 10분
6. DB latency 3s 주입 5분
7. 회복 10분

### 예측 현상

100ms:

- 평균 latency는 조금 증가하지만 대부분 정상
- p95가 먼저 흔들리기 시작
- pool saturation은 아직 제한적

300ms:

- 동시성 높은 API에서 대기열 증가
- Hikari active connection 증가
- request thread 점유 시간 증가
- 정상 요청도 p95 악화

1s:

- timeout 설정이 길면 thread와 connection이 장시간 점유
- pending acquire 증가
- retry가 있으면 DB 부하와 app 대기가 증폭
- ingress p99 급등, 5xx 시작
- readiness가 DB health를 본다면 unready 전환 가능

3s:

- connection timeout과 request timeout이 짧지 않으면 대규모 hung request 발생
- HPA가 scale-out하더라도 DB가 bottleneck이라 효과 제한
- 일부 pod는 살아 있지만 사실상 서비스 불능
- circuit breaker가 없으면 장애가 전체로 전파

### 드라마틱 포인트

이 시나리오는 "DB는 죽지 않았고 느려졌을 뿐인데 서비스는 거의 죽는다"를 보여준다. 가장 설득력이 강하다.

### 개선 후 기대 효과

- connection timeout 단축
- query timeout 단축
- retry 상한 1~2회
- exponential backoff + jitter
- circuit breaker open
- fallback response 또는 읽기 축소 응답
- readiness에서 DB hard dependency 제거

개선 후 동일 주입 시 기대하는 결과:

- p95 증가폭 축소
- Hikari pending 억제
- 5xx 비율 감소
- pod unready / restart 없음
- 장애가 일부 기능 실패로 국소화

---

## 시나리오 B. `Spring -> RDS` 패킷 손실 주입

### 목적

지연보다 더 현실적인 네트워크 품질 저하가 connection reset, TCP retransmission, query timeout으로 어떻게 나타나는지 본다.

### 주입 지점

- Spring pod egress to RDS

### 단계

1. loss 1%
2. loss 5%
3. loss 10%
4. 필요 시 20%

### 예측 현상

1%:

- 눈에 띄는 실패는 적지만 tail latency 증가

5%:

- handshake 및 query retransmit 증가
- 간헐 timeout 발생
- retry 존재 시 부하 증폭

10%:

- pooled connection의 유효성 문제 증가
- connection reset, stale connection 증가
- 장애가 "간헐적이라 더 디버깅 어려운" 형태로 나타남

### 드라마틱 포인트

완전 단절보다 현실적이다. "가끔씩 느리고 가끔 실패"하는 형태는 실제 운영에서 더 어렵고, 탐지와 진단 능력을 보여주기 좋다.

---

## 시나리오 C. `Chat / Notification -> RabbitMQ` 지연 주입

### 목적

비동기 의존성의 지연이 즉시 5xx보다 backlog, retry, delivery delay로 전파되는 양상을 관측한다.

### 주입 지점

- chat / notification producer pod -> RabbitMQ
- 필요 시 consumer -> RabbitMQ도 별도 실험

### 단계

1. baseline 15분
2. steady chat / notification load
3. publish path latency 50ms
4. 200ms
5. 1s
6. 회복 구간 관측

### 예측 현상

50ms:

- 큰 영향 없음
- publish latency 소폭 상승

200ms:

- producer throughput 저하
- 메시지 생성 속도 > broker 반영 속도면 내부 queue 축적
- 사용자 체감상 알림 / 채팅 딜레이 시작

1s:

- sync publish를 기다리는 경로라면 API latency에도 영향
- retry가 겹치면 duplicate pressure
- consumer lag 증가
- queue depth, unacked 증가
- broker connection churn 가능

### 드라마틱 포인트

"서비스는 살아 있는데 사용자 경험은 무너진다"는 메시지가 나온다. 운영 복잡도를 보여주기 좋다.

### 개선 후 기대 효과

- publisher confirm timeout 제한
- bounded retry
- duplicate-safe idempotency
- 비핵심 이벤트 drop / defer
- degraded mode
- 비동기 queue backlog 기반 autoscaling 또는 consumer tuning

---

## 시나리오 D. `Chat / Notification -> RabbitMQ` 손실 / 단절 주입

### 목적

broker unreachable 상황에서 retry 정책과 fallback이 없을 때 어떤 폭주가 생기는지 본다.

### 단계

1. broker 연결에 5% loss
2. 10% loss
3. 30초 단절
4. 60초 단절

### 예측 현상

5~10% loss:

- intermittent publish failure
- retry storm
- connection / channel recreate 증가

30~60초 단절:

- publish blocking 또는 immediate failure
- backlog local accumulation
- 일부 기능은 정상 API 응답 후 내부 알림만 실패할 수도 있음
- fallback이 없으면 사용자 요청 전체가 실패로 전파 가능

### 드라마틱 포인트

"비핵심 비동기 기능 하나의 장애가 핵심 동기 API까지 잡아먹는지"를 보여주기 좋다.

---

## 시나리오 E. readinessProbe 전파 검증

### 목적

외부 의존성 문제를 readiness가 과하게 반영해, 앱 자체는 살아 있는데 traffic이 빠지고 rollout까지 흔들리는지 검증한다.

### 주입 지점

- 시나리오 A 또는 시나리오 C와 병행 관측

### 예측 현상

- DB / RabbitMQ 지연 시 readiness 실패 증가
- pod가 계속 살아 있는데 service endpoint에서 빠짐
- scale-out 중 신규 pod도 ready 되지 못할 가능성
- 결과적으로 장애가 성능 저하를 넘어 가용성 저하로 전환

### 개선 방향

- liveness는 프로세스 생존 확인만 담당
- readiness는 "이 pod가 트래픽 받을 준비가 되었는가"만 판단
- 외부 의존성 hard check 제거 또는 soft dependency화
- downstream 장애 시 degraded readiness 전략 검토

이 시나리오는 개선 효과가 매우 선명하다. "probe 설계만 바꿔도 장애 전파가 줄었다"는 그림이 나온다.

---

## 7. 추천 실험 순서

가장 전달력 좋은 순서는 아래다.

1. `Spring -> RDS latency`
2. `Spring -> RDS latency + readiness 관측`
3. 개선 적용
4. 동일 실험 재실행
5. `Chat / Notification -> RabbitMQ latency`
6. `RabbitMQ short outage`
7. 개선 적용 후 재실행

이 순서가 좋은 이유는 첫 번째 실험에서 즉시 체감형 장애를 확보하고, 두 번째 축에서 "동기 경로와 비동기 경로는 장애 양상이 다르며 대응 전략도 달라야 한다"는 점을 대비시킬 수 있기 때문이다.

---

## 8. 포트폴리오용 핵심 비교 프레임

문서와 발표는 반드시 전후 비교로 가져가야 한다.

### 8.1 개선 전

- 긴 timeout
- 과도한 retry
- jitter 없는 backoff
- circuit breaker 없음
- readiness가 외부 의존성에 강결합

### 8.2 개선 후

- 짧고 명확한 timeout
- bounded retry
- exponential backoff + jitter
- circuit breaker
- fallback / degraded mode
- readiness 재설계

### 8.3 보여줄 결과

- p95 / p99 변화
- error rate 변화
- thread pool saturation 여부
- DB connection pending 변화
- queue depth recovery time
- readiness flap 유무
- pod restart 유무
- 장애 전파 범위 축소

---

## 9. 최종 권장안

한 개만 먼저 한다면 `Spring -> RDS latency injection`이 가장 효과적이다.

이유는 세 가지다.

- 사용자-facing API latency로 바로 드러난다.
- thread pool, connection pool, retry, probe 전파가 한 번에 보인다.
- 개선 전후 차이가 가장 극적으로 나타난다.

그 다음 두 번째 실험으로 `Chat / Notification -> RabbitMQ latency / loss`를 붙이면, "동기 경로와 비동기 경로는 장애 양상이 다르며 대응 전략도 달라야 한다"는 점까지 보여줄 수 있다.
