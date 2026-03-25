# RDS Fault Injection 계획

## 근본 목적

- `Spring -> RDS` 경로에 지연과 손실을 주입해, 느린 DB 의존성이 사용자 요청 지연, thread pool 점유, connection pool 고갈, probe 전파로 어떻게 확산되는지 관측한다.
- timeout, retry, backoff, circuit breaker, degraded mode, readiness 재설계를 통해 장애 전파 반경을 줄였음을 동일 조건 재실험으로 증명한다.

## 비목적

- 이번 문서에서 RabbitMQ, Qdrant, control-plane 장애 실험까지 함께 다루지 않는다.
- 운영 배포나 실제 장애 복구 절차를 본 문서에서 수행하지 않는다.

---

## 1. 대상 클러스터 구성

실험 대상은 `kubeadm` 기반 self-managed Kubernetes 클러스터다.

- control-plane: `cp-01/02/03`
- app plane: `app-01~04`
- data plane: `data-01~03`
- namespace: `billage-app`, `billage-data`, `billage-edge`, `billage-ops`

이번 실험은 `billage-app`의 Spring 서비스가 RDS를 호출하는 경로를 대상으로 한다.

기본 사용자 경로:

`User -> ALB -> ingress-nginx -> Spring API -> RDS`

실험 경로:

`User -> ALB -> ingress-nginx -> Spring API -> Toxiproxy -> RDS`

즉 사용자 요청 경로는 유지하고, Spring의 DB 의존성만 프록시를 통해 조작한다.

---

## 2. 왜 RDS가 가장 뾰족한가

`RDS`는 동기 요청 경로와 직접 연결될 가능성이 가장 높다. 따라서 latency injection을 주입하면 결과가 즉시 사용자 체감으로 드러난다.

예상 전파:

1. DB 응답 지연
2. JDBC 커넥션 반환 지연
3. Hikari pool active 증가, pending 증가
4. servlet / tomcat worker thread 점유 증가
5. 정상 요청까지 tail latency 악화
6. timeout 이후 5xx 증가
7. readiness가 외부 의존성에 묶여 있으면 unready 전파

이 구조는 "DB가 죽지 않았고 느려졌을 뿐인데 서비스 전체가 무너진다"는 메시지를 가장 선명하게 보여준다.

---

## 3. 주입 지점과 방식

주입 지점은 `Spring Pod -> RDS` 구간으로 제한한다.

주입 방식은 `Toxiproxy`를 사용한다.

이유:

- 특정 서비스의 특정 downstream만 정밀하게 제어 가능
- latency, loss, blackout을 단계적으로 주입 가능
- rollback이 빠름
- 포트폴리오에서 설명이 쉬움

Spring datasource 예시:

```properties
spring.datasource.url=jdbc:mysql://toxiproxy-rds.billage-app.svc.cluster.local:3306/app
```

proxy upstream 예시:

```text
toxiproxy-rds -> mydb.cluster-xxxxx.ap-northeast-2.rds.amazonaws.com:3306
```

---

## 4. 실험 시나리오

## 시나리오 A. Latency Injection

### 목적

느린 RDS 응답이 요청 지연과 pool saturation으로 어떻게 전파되는지 확인한다.

### 단계

1. baseline 15분
2. steady load 10분
3. latency 100ms 10분
4. latency 300ms 10분
5. latency 1000ms 10분
6. latency 3000ms 5분
7. toxic 제거 후 recovery 10분

### 예측 현상

100ms:

- 평균 응답은 유지되지만 p95가 먼저 상승
- active connection 증가 시작

300ms:

- Hikari active 증가
- pending acquire 증가 시작
- 정상 요청도 p95 악화

1000ms:

- retry가 있으면 부하 증폭
- request thread 점유 증가
- ingress p99 급등
- 5xx 시작

3000ms:

- timeout이 길면 hung request 증가
- pool saturation 본격화
- 일부 pod는 살아 있으나 실질 처리량 급감
- readiness 설계가 나쁘면 unready 전파

## 시나리오 B. Packet Loss Injection

### 목적

완전한 지연보다 더 현실적인 품질 저하가 timeout, retransmit, stale connection 문제를 어떻게 만드는지 본다.

### 단계

1. loss 1%
2. loss 5%
3. loss 10%
4. 필요 시 20%

### 예측 현상

1%:

- 눈에 띄는 실패는 적지만 tail latency 증가

5%:

- 간헐 timeout 증가
- retry 존재 시 request amplification 발생

10% 이상:

- connection reset, stale connection 증가
- 간헐 실패가 누적되며 디버깅 난이도 상승

## 시나리오 C. Short Blackout

### 목적

짧은 DB unreachable 상황에서 timeout과 retry 설계가 얼마나 방어적인지 본다.

### 단계

1. 30초 blackout
2. recovery 10분

### 예측 현상

- timeout이 길면 대량의 hung request 발생
- retry 폭주 시 정상 복구 후에도 회복 지연
- readiness hard dependency면 endpoint 감소 가능

---

## 5. 모니터링 계획

모니터링은 4계층으로 나눈다.

## 5.1 사용자 체감

- ingress request rate
- ingress p50 / p95 / p99
- HTTP 5xx 비율
- timeout 비율
- `k6` 성공률

이 계층은 사용자 영향의 최종 증거다.

## 5.2 Spring 내부

- `http_server_requests_seconds`
- tomcat busy threads
- Hikari `active`, `idle`, `pending`, `timeout`
- JVM live threads
- GC pause
- retry count
- circuit breaker open count
- fallback count

핵심 증거는 아래다.

- `hikaricp_connections_active`
- `hikaricp_connections_pending`
- `hikaricp_connections_timeout_total`

`pending` 증가가 보이면 장애 전파가 시작된 것이다.

## 5.3 RDS 자체

- `DatabaseConnections`
- `ReadLatency`
- `WriteLatency`
- CPUUtilization
- FreeableMemory
- DiskQueueDepth

이 계층은 downstream이 실제로 느려졌는지 보여준다.

## 5.4 Kubernetes

- pod ready / unready 전환
- restart count
- deployment replica 상태
- HPA desired / current replicas
- event log

이 계층은 성능 저하가 플랫폼 전파로 이어졌는지 보여준다.

---

## 6. 증거 수집 방식

실험마다 아래 산출물을 고정으로 남긴다.

1. 실험 타임라인 표
2. Grafana 캡처
3. `k6` 결과 요약
4. `kubectl` 상태 스냅샷
5. 실험 메모

예시 타임라인:

- `14:00` baseline 시작
- `14:15` 300ms latency 주입
- `14:25` 1000ms latency 주입
- `14:35` 3000ms latency 주입
- `14:40` toxic 제거
- `14:50` recovery 종료

필수 캡처 시점:

- baseline 마지막 1분
- `1000ms` 주입 후 2~3분
- `3000ms` 최악 구간
- toxic 제거 후 recovery 완료 시점

---

## 7. 개선 항목

이번 실험에서 검증할 개선안은 아래다.

1. DB connect / read / query timeout 단축
2. retry 상한 제한
3. exponential backoff + jitter
4. circuit breaker
5. fallback 또는 degraded response
6. readiness에서 DB hard dependency 제거

핵심 메시지는 "느린 DB 호출을 빨리 포기하고, 실패를 전체 요청 경로로 전파시키지 않는다"이다.

---

## 8. 개선 후 재검증

개선 후에는 반드시 같은 부하, 같은 API, 같은 주입 강도로 재실험한다.

비교 항목:

- p95
- p99
- 5xx 비율
- Hikari pending
- Hikari timeout count
- tomcat busy thread peak
- ready pod 수
- recovery time

개선 전 기대 증거:

- `RDS 1s latency` 주입 시 p95 / p99 급등
- Hikari pending 증가
- 5xx 시작
- readiness flap 가능

개선 후 기대 증거:

- p95 / p99 상승폭 축소
- pending connection 감소
- 5xx 감소
- readiness flap 제거
- recovery time 단축

---

## 9. 최종 성공 기준

이번 실험의 성공은 "장애가 없었다"가 아니라 "장애 전파 반경이 줄었다"로 정의한다.

성공 기준 예시:

- 동일한 `RDS 1s latency` 주입에서도 API `p95` 상승폭이 의미 있게 감소
- Hikari pending이 억제됨
- 5xx 비율이 낮아짐
- pod restart 또는 readiness flap이 없어짐
- toxic 제거 후 recovery 시간이 짧아짐

이 기준을 만족하면 timeout, retry, circuit breaker, readiness 설계 개선이 실제로 효과가 있었음을 증명할 수 있다.
