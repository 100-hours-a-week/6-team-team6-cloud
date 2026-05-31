# 의존성 지연 주입 실험 환경 세팅

## 근본 목적

- `Spring -> RDS / RabbitMQ` 의존성 지연 주입 실험을 안전하게 반복 실행할 수 있도록, 주입 경로, 계측, 부하 발생, 롤백 절차를 표준화한다.
- 실험 전후 조건을 고정해 결과 비교가 가능하도록 환경 차이를 줄인다.

## 비목적

- 이번 문서에서 실제 애플리케이션 코드를 수정하거나 운영 배포를 수행하지 않는다.
- Chaos Mesh 같은 대규모 chaos 플랫폼 도입까지 이번 범위에 포함하지 않는다.

---

## 1. 문서 범위

이 문서는 [`dependency-latency-injection-plan.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/dependency-latency-injection-plan.md)를 실제로 실행하기 위한 환경 세팅 문서다.

대상은 아래 두 실험이다.

- `Spring -> RDS` latency / loss injection
- `Spring -> RabbitMQ` latency / loss injection

기본 주입 방식은 `Toxiproxy`를 사용한다. 이유는 다음과 같다.

- 특정 서비스의 특정 의존성 경로만 정밀하게 통제할 수 있다.
- 주입 강도 변경과 롤백이 빠르다.
- 포트폴리오에서 "어느 경로에 얼마의 지연을 넣었는지"를 설명하기 쉽다.

---

## 2. 실험 대상 구조 재확인

현재 클러스터는 역할별로 분리되어 있다.

- `billage-app`: Next.js, Spring Boot, FastAPI
- `billage-data`: RabbitMQ, Qdrant
- `billage-edge`: edge / TLS
- `billage-ops`: 운영 도구

노드도 app plane과 data plane으로 분리돼 있으므로, fault injection pod와 계측 자원은 app 또는 ops 영역에서 관리하고, RabbitMQ 자체에는 직접 독성 설정을 넣지 않는 편이 안전하다.

기본 트래픽 경로는 아래와 같다.

`인터넷 -> ALB -> ingress-nginx -> Service -> Pod`

이번 실험에서 우리가 조작할 경로는 아래 두 개다.

1. `Spring Pod -> Toxiproxy -> RDS`
2. `Spring Pod -> Toxiproxy -> RabbitMQ`

즉 사용자는 기존과 동일하게 ingress를 통해 Spring API를 호출하고, Spring 내부에서만 의존성 호출 경로가 프록시를 통과하게 만든다.

---

## 3. 환경 구성 원칙

- 실제 운영 경로 전체를 바꾸지 않는다.
- 주입 대상은 특정 Spring deployment 또는 canary replica로 제한한다.
- 실험 전과 후의 차이는 `toxicity 설정값`만 달라지게 만든다.
- 부하 발생 도구, 계측 대상, 대시보드는 매 실험에서 동일하게 유지한다.
- rollback은 `Spring 설정 원복`과 `Toxiproxy 독성 제거` 두 단계로 끝나야 한다.

---

## 4. 준비 대상 체크리스트

실험 전에 아래 준비가 되어 있어야 한다.

### 4.1 Kubernetes 접근

- `kubectl`로 대상 클러스터 접근 가능
- `billage-app`, `billage-data`, `billage-ops` 네임스페이스 조회 가능
- 대상 Spring deployment 조회 가능

확인 예시:

```bash
kubectl get ns
kubectl get deploy -n billage-app
kubectl get pods -n billage-app -o wide
kubectl get pods -n billage-data -o wide
```

### 4.2 계측 도구 접근

- Prometheus 쿼리 가능
- Grafana 대시보드 조회 가능
- ingress-nginx 메트릭 확인 가능
- Spring 애플리케이션 메트릭 확인 가능
- RabbitMQ 또는 RDS 지표 조회 가능

최소 필요 지표:

- ingress p50 / p95 / p99
- HTTP 2xx / 4xx / 5xx
- Spring request duration
- JVM thread 수
- DB pool active / pending / timeout
- RabbitMQ queue depth / publish / ack
- pod ready / restart
- HPA desired / current replicas

### 4.3 부하 발생 도구

- `k6` 실행 환경 준비
- 실험용 시나리오 스크립트 준비
- 테스트 대상 엔드포인트와 인증 방식 정리

부하 발생 위치는 둘 중 하나로 고정한다.

- 외부에서 `ALB / public domain`으로 호출
- 클러스터 내부 load-generator pod에서 service / ingress 경유 호출

포트폴리오 기준으로는 사용자 관점 결과를 보여주기 쉬운 외부 호출이 더 낫다.

---

## 5. 권장 아키텍처

## 5.1 RDS 실험 경로

```text
User
  -> ALB
  -> ingress-nginx
  -> Spring API Pod
  -> Toxiproxy Service
  -> RDS
```

Spring이 직접 RDS endpoint를 보지 않고, `Toxiproxy Service`를 DB endpoint처럼 사용한다.

예시:

- 실제 RDS endpoint: `mydb.cluster-xxxxx.ap-northeast-2.rds.amazonaws.com:3306`
- Spring datasource host: `toxiproxy-rds.billage-app.svc.cluster.local:3306`

Toxiproxy가 실제 RDS endpoint로 forward하고, 여기에 latency / loss toxic를 주입한다.

## 5.2 RabbitMQ 실험 경로

```text
User
  -> ALB
  -> ingress-nginx
  -> Spring API Pod
  -> Toxiproxy Service
  -> RabbitMQ Service
```

예시:

- 실제 RabbitMQ service: `rabbitmq.billage-data.svc.cluster.local:5672`
- Spring rabbit host: `toxiproxy-rabbitmq.billage-app.svc.cluster.local:5672`

RabbitMQ 관리 포트나 StatefulSet 자체를 건드리기보다, producer 경로만 프록시화하는 것이 blast radius 제어에 유리하다.

---

## 6. Kubernetes 리소스 세팅

## 6.1 네임스페이스 선택

Toxiproxy는 기본적으로 `billage-app`에 둔다.

이유:

- 실험 대상 Spring pod와 같은 네임스페이스에 두면 service discovery와 접근 제어가 단순하다.
- app 계층에서 outbound dependency만 바꾸면 되므로 RabbitMQ / RDS 본체를 건드리지 않는다.

예외:

- 여러 앱이 공용으로 쓸 실험 프록시를 만들고 싶다면 `billage-ops`에 둘 수 있다.
- 하지만 첫 실험은 `billage-app` 단일 네임스페이스가 더 안전하다.

## 6.2 Toxiproxy 배포 리소스

최소 필요 리소스:

- `Deployment` 1개
- `Service` 1개
- 필요 시 `ConfigMap` 1개

포트 예시:

- admin API: `8474`
- RDS proxy listen: `3306`
- RabbitMQ proxy listen: `5672`

리소스 요청값 예시:

- request: `100m / 128Mi`
- limit: `300m / 256Mi`

Toxiproxy는 stateful하지 않으므로 PDB보다 재배포와 삭제가 쉬운 단순 deployment가 적합하다.

## 6.3 네트워크 정책

현재 클러스터는 default-deny 기반이므로, 아래 경로를 명시적으로 열어야 할 수 있다.

- `Spring Pod -> Toxiproxy`
- `Toxiproxy -> RabbitMQ`
- `Toxiproxy -> RDS`
- `ops 또는 engineer access -> Toxiproxy admin API`

특히 admin API `8474`는 외부에 노출하지 않고 내부에서만 접근 가능하게 제한해야 한다.

권장:

- `8474`는 `billage-app` 내부 특정 pod 또는 bastion/debug pod에서만 접근 허용
- `3306`, `5672`는 Spring pod selector만 접근 허용

---

## 7. 애플리케이션 설정 변경 포인트

이번 실험에서는 애플리케이션 이미지 공급 경로도 분리하는 편이 안전하다.

- 백엔드 리포지토리에서 `kube_latest` 태그를 별도 push
- 클러스터에서는 fault injection 대상 deployment만 `kube_latest`를 pull
- `imagePullPolicy: Always`를 적용해 이전 캐시 이미지 재사용을 막음

## 7.1 Spring -> RDS

Spring datasource 설정에서 host를 실제 RDS가 아니라 Toxiproxy service로 바꾼다.

예시:

```properties
spring.datasource.url=jdbc:mysql://toxiproxy-rds.billage-app.svc.cluster.local:3306/app
```

현재 cloud Terraform의 rollout 문서는 `SPRING_DATASOURCE_URL` env override를 직접 주입하도록 구성했다. 따라서 실험 시에는 아래 값 하나를 Terraform 변수로 넘겨 일관되게 관리하는 편이 좋다.

```hcl
rds_fault_injection_datasource_url = "jdbc:mysql://toxiproxy-rds.billage-app.svc.cluster.local:3306/billage?serverTimezone=Asia/Seoul&useSSL=false&allowPublicKeyRetrieval=true"
```

이때 중요한 점:

- DB 계정, 비밀번호, 스키마명은 기존과 동일
- 바뀌는 것은 host / port뿐
- timeout 값은 실험 전 고정해야 비교가 가능

추가로 확인할 항목:

- Hikari `connectionTimeout`
- Hikari `validationTimeout`
- JDBC socket timeout
- query timeout
- retry 라이브러리 설정

## 7.2 Spring -> RabbitMQ

Spring AMQP 설정에서 host를 Toxiproxy service로 바꾼다.

예시:

```properties
spring.rabbitmq.host=toxiproxy-rabbitmq.billage-app.svc.cluster.local
spring.rabbitmq.port=5672
```

추가로 확인할 항목:

- publisher confirm 사용 여부
- retry template 사용 여부
- listener concurrency
- prefetch
- reconnect backoff

## 7.3 Probe 점검

실험 전 readiness / liveness / startupProbe를 반드시 확인한다.

확인 이유:

- readiness가 DB / RabbitMQ를 hard dependency로 보고 있으면 latency 실험이 성능 저하가 아니라 endpoint 제거로 먼저 나타날 수 있다.
- liveness가 외부 의존성 장애를 반영하면 restart loop가 먼저 생긴다.

실험 전 문서화할 항목:

- readiness endpoint
- liveness endpoint
- startupProbe 유무
- 각 probe timeout / failureThreshold / periodSeconds

---

## 8. 계측 환경 세팅

## 8.1 필수 대시보드

실험 시작 전에 아래 대시보드를 미리 준비한다.

### 대시보드 A. 사용자 체감

- request rate
- ingress p50 / p95 / p99
- 5xx 비율
- timeout 비율

### 대시보드 B. Spring 내부 상태

- http server request duration
- active requests
- tomcat busy threads 또는 servlet executor 사용량
- JVM live threads
- heap / GC pause
- Hikari active / idle / pending / timeout

### 대시보드 C. Kubernetes 상태

- pod CPU / memory
- pod restart
- ready / unready 전환
- HPA desired / current replicas

### 대시보드 D. 의존성 상태

RDS:

- connection count
- read / write latency
- CPU

RabbitMQ:

- publish / deliver / ack
- queue depth
- unacked
- consumer utilization
- connection / channel count

## 8.2 타임라인 기록

모든 실험은 시간축 기준으로 기록한다.

예시:

- `14:00` baseline 시작
- `14:15` 100ms latency 주입
- `14:25` 300ms latency 주입
- `14:35` 1s latency 주입
- `14:45` toxicity 제거
- `14:55` recovery 종료

실험 결과 문서에는 이 타임라인이 반드시 있어야 한다. 그래야 그래프와 주입 시점을 연결할 수 있다.

---

## 9. 부하 발생 환경 세팅

## 9.1 부하 시나리오 분리

`k6` 스크립트는 기능별로 나눠야 한다.

- 읽기 중심 API
- 쓰기 API
- 채팅 발행 API
- 알림 트리거 API

한 스크립트에 모두 넣어도 되지만, 메트릭 해석을 위해 태그를 분리하는 것이 좋다.

## 9.2 부하 강도

최초 실험은 production 최대치가 아니라 "안정적으로 현상이 재현되는 중간 부하"로 시작한다.

권장:

- 평시 수준 고정 부하
- API별 비율 유지
- 실험마다 동일한 가상 사용자 수와 요청 패턴 유지

예시 기준:

- baseline: 정상 부하 15분
- steady load: 실험 중 동일 RPS 유지
- recovery: 독성 제거 후 10분

## 9.3 부하 실행 위치

선택지:

- 외부 runner
- 클러스터 내부 runner pod

권장:

- 사용자 체감까지 보려면 외부 runner
- 네트워크 편차를 줄이고 싶으면 내부 runner

둘 중 하나를 골라 모든 실험에서 고정한다.

---

## 10. Toxiproxy 운영 절차

## 10.1 프록시 생성

실험 전에 아래 두 프록시를 만든다.

- `rds-proxy`
- `rabbitmq-proxy`

각 프록시는 아래 정보를 가진다.

- listen 주소
- upstream 주소
- toxic 적용 여부

## 10.2 초기 상태

초기 상태는 반드시 독성 없는 pass-through여야 한다.

즉:

- Spring은 이미 Toxiproxy를 통하지만
- Toxiproxy는 아무 latency / loss도 주지 않는 상태

이 상태에서 baseline을 먼저 측정해야 "프록시 자체 오버헤드"와 "독성 주입 효과"를 구분할 수 있다.

## 10.3 독성 적용 순서

권장 순서:

1. latency 소량
2. latency 중간
3. latency 대량
4. loss 소량
5. loss 중간
6. short blackout

한 번에 복합 독성을 섞지 않는 것이 좋다. 원인 분석이 어려워지기 때문이다.

## 10.4 독성 제거

각 단계 종료 시:

- toxic 삭제
- 10분 recovery 관측
- 다음 단계 시작

복구 시간이 충분하지 않으면 이전 실험의 backlog가 다음 실험에 영향을 준다.

---

## 11. 실험 전 검증 항목

실험 시작 전 아래를 반드시 확인한다.

### 공통

- 대상 deployment replica 수
- HPA 설정 여부
- PDB 설정 여부
- 현재 pod restart 없는지
- 현재 readiness failures 없는지
- 현재 에러율 정상인지

### RDS 실험 전

- DB connection 수 baseline
- slow query 없는지
- datasource host가 Toxiproxy로 바뀌었는지
- connection pool size 기록

### RabbitMQ 실험 전

- queue backlog 없는지
- unacked 비정상 증가 없는지
- publish / ack 정상인지
- rabbit host가 Toxiproxy로 바뀌었는지

---

## 12. 롤백 절차

롤백은 단순해야 한다.

### 12.1 즉시 롤백

1. Toxiproxy toxic 삭제
2. Spring deployment 원 설정으로 복구
3. rollout status 확인
4. readiness / error rate 정상화 확인

### 12.2 완전 철수

1. Spring 설정에서 원래 endpoint로 복구
2. Toxiproxy deployment / service 삭제
3. 관련 NetworkPolicy 제거
4. Grafana annotation 또는 실험 기록 종료

---

## 13. 권장 실행 순서

### 13.1 1차 세팅

1. Toxiproxy deployment / service 생성
2. Spring 설정을 Toxiproxy 경유로 변경
3. NetworkPolicy 보완
4. baseline 확인

### 13.2 1차 실험

1. `Spring -> RDS` pass-through baseline
2. 100ms / 300ms / 1s latency
3. recovery 관측

### 13.3 개선 후 재실험

1. timeout / retry / breaker / probe 개선
2. 동일 부하, 동일 주입 재실행
3. 전후 비교

### 13.4 2차 실험

1. `Spring -> RabbitMQ` latency
2. short outage
3. recovery time 측정

---

## 14. 포트폴리오용 산출물

실험 환경 세팅이 끝나면 아래 산출물을 남겨야 한다.

- 구조 다이어그램 1장
- 주입 지점 설명 1장
- baseline 대시보드 캡처
- 실험 중 대시보드 캡처
- recovery 대시보드 캡처
- 전후 비교 표

특히 아래 두 그림이 중요하다.

1. `Spring -> RDS 1s latency`에서 p95, Hikari pending, 5xx가 함께 치솟는 그림
2. 개선 후 같은 주입에서 p95와 5xx가 억제되고 readiness flap이 사라진 그림

---

## 15. 최종 권장안

첫 세팅은 `Spring -> RDS`만 대상으로 시작하는 것이 가장 좋다.

이유:

- 설정 변경 포인트가 단순하다.
- 사용자 체감 지표와 연결이 가장 빠르다.
- thread pool, connection pool, timeout, readiness 문제를 한 번에 관측할 수 있다.

RDS 실험이 끝나고 계측과 롤백이 안정화되면, 같은 프레임으로 `Spring -> RabbitMQ` 실험을 추가하는 것이 좋다.
