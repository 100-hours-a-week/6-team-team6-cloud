# RDS Fault Injection Engineering Report

## 근본 목적

이 문서는 `Spring -> RDS` 의존성 지연 실험에서 장애가 어떻게 전파됐는지와 그 원인을 어떤 증거로 확인했는지를 남겨, 이후 유사 장애의 원인 추적 시간을 줄이는 데 목적이 있다.

## 비목적

이 문서는 곧바로 해결책을 제시하거나 일회성 장애를 과장하는 데 목적이 없다. 이번 문서의 범위는 `무슨 일이 일어났는지`, `왜 그렇게 해석하는지`, `무엇을 추가로 확인해야 하는지`까지다.

## 1. 실험 요약

- 실험 일시: `2026-03-25`
- 실험 대상: `billage-app/spring-boot`
- 의존성 경로: `Spring -> Toxiproxy -> RDS`
- 대상 API: `GET /groups/21/posts`
- 부하 방식: `k6 constant-arrival-rate`, `RPS 50` 고정
- 지연 주입 단계:
  - `300ms`, `jitter 50ms`
  - `1s`, `jitter 100ms`
  - `3s`, `jitter 200ms`
- 관련 실행 보고서: [rds-fault-injection-execution-report-2026-03-25.md](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-execution-report-2026-03-25.md)
- raw evidence: [2026-03-25-rds-latency](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-25-rds-latency)

## 2. Fault Injection 방식

이번 실험은 DB 자체를 직접 흔들지 않고, 애플리케이션과 DB 사이에 `toxiproxy-rds`를 삽입해 지연을 주입하는 방식으로 수행했다.

- Spring datasource:
  - `jdbc:mysql://toxiproxy-rds.billage-app.svc.cluster.local:3306/billage?useSSL=false`
- Toxiproxy upstream:
  - 실제 `RDS endpoint:3306`
- 부하 대상:
  - `GET /groups/21/posts`
  - 인증 토큰을 포함한 실사용 경로
- k6 프로파일:
  - `rate: 50`
  - `timeUnit: 1s`
  - `duration: 60m`
  - `preAllocatedVUs: 50`
  - `maxVUs: 200`

이 구성의 장점은 인프라 전체 장애가 아니라 `Spring -> RDS` 경계 하나만 고립시켜 볼 수 있다는 점이다. 따라서 이후 장애 원인을 `DB latency`, `probe`, `HPA`, `scheduler`로 좁혀 해석할 수 있다.

## 3. 관찰된 현상

실험 중 실제로 관찰된 현상은 네 갈래였다.

1. `spring-boot` HPA가 `3 -> 9` replica까지 scale-out을 시도했다.
2. 새로 생성된 일부 pod는 `Running`이 되지 못하고 `Pending`에 머물렀다.
3. 기존 Running pod도 `readiness`, `liveness`, `startup` probe 실패를 반복했고 일부는 `CrashLoopBackOff`로 진입했다.
4. `toxics: []`로 cleanup한 뒤에도 즉시 정상 상태로 돌아오지 않았고, 한동안 재시작과 scale-down 지연이 이어졌다.

대표 증상은 아래와 같았다.

- `spring-boot-55b4d4d878-gsmg2`, `mrvz2`, `rvpc8`, `sf8ws`, `w5w9c`가 `Pending`
- Running pod들도 `0/1` 상태로 readiness 미통과
- `spring-boot-55b4d4d878-624vz`는 `CrashLoopBackOff`, `Exit Code 137`
- `port-forward` 후 API 직접 호출도 `code=000`으로 실패한 시점이 있었다

## 4. 핵심 증거

### 4.1 HPA는 실제로 scale-out을 시도했다

이벤트에서 아래 사실이 확인됐다.

- `Scaled up replica set spring-boot-55b4d4d878 to 9 from 7`
- `New size: 9; reason: cpu resource utilization (percentage of request) above target`

즉 HPA는 fault 상황에서 CPU metric을 근거로 replica를 늘리려 했다. 이 부분은 추정이 아니라 이벤트로 확인된 사실이다.

다만 이 문장을 곧바로 `RDS latency가 CPU를 올렸고 그래서 HPA가 동작했다`로 읽으면 과하다. HPA 이벤트 자체는 사실이지만, Grafana에서 본 CPU 사용량과 HPA가 scale-out을 결정한 시점의 CPU snapshot이 정확히 일치하는지는 별도 검증이 필요하다.

### 4.2 신규 pod Pending에는 `Insufficient cpu`가 직접 찍혔다

`spring-boot-55b4d4d878-gsmg2`의 `describe pod` 결과에서 아래 이벤트가 반복됐다.

- `3 Insufficient cpu`
- `1 node(s) didn't match pod topology spread constraints`
- `3 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }`
- `3 node(s) had untolerated taint {workload-plane: data}`

즉 app workload가 실제로 배치 가능한 노드는 `app-01~04` 네 대뿐이었고, 그 중 일부는 topology spread 조건에 걸렸으며, 나머지 세 노드는 scheduler 관점에서 CPU 예약 여유가 부족했다.

### 4.3 CPU request는 높고, 실제 사용량은 낮았다

`spring-boot` deployment의 리소스 설정은 아래와 같았다.

- `requests.cpu=750m`
- `limits.cpu=2`
- `requests.memory=1Gi`
- `limits.memory=2Gi`

반면 실험 종료 후 확인한 실제 사용량은 훨씬 낮았다.

- `spring-boot-55b4d4d878-7tb26`: `78m`
- `spring-boot-55b4d4d878-q57b9`: `64m`
- `spring-boot-55b4d4d878-rxw4k`: `62m`

또한 app node의 allocatable CPU는 모두 `2 core`였다.

- `billage-kubeadm-prod-app-01`: `2`
- `billage-kubeadm-prod-app-02`: `2`
- `billage-kubeadm-prod-app-03`: `2`
- `billage-kubeadm-prod-app-04`: `2`

즉 Grafana의 CPU Quota 패널에서 `0.08~0.10 core` 수준이 보였더라도, scheduler는 실제 사용량이 아니라 `request=750m` 기준으로 새 pod 배치 가능 여부를 판단한다.

### 4.4 node allocated resources도 request 기준 병목을 뒷받침했다

실험 후 수집한 node allocated resources는 아래와 같았다.

- `app-02`: `cpu requests 1800m (90%)`
- `app-01`: `cpu requests 1400m (70%)`
- `app-04`: `cpu requests 1020m (51%)`
- `app-03`: `cpu requests 550m (27%)`

실사용량과 별개로 request 기준 예약률은 이미 높은 편이었고, 여기에 `750m`짜리 spring pod가 몇 개 더 필요해지자 일부 pod는 `Pending`으로 밀렸다.

### 4.5 Running pod도 안정적이지 않았다

`spring-boot-55b4d4d878-624vz`의 이전 로그와 `describe pod`는 단순 Pending 외에 실행 중 pod의 불안정성도 보여줬다.

관찰된 사실:

- `Liveness probe failed: context deadline exceeded`
- `Readiness probe failed: context deadline exceeded`
- `Startup probe failed: dial tcp ... connect: connection refused`
- `Back-off restarting failed container`
- `Last State: Terminated`
- `Exit Code: 137`

또한 애플리케이션 로그에서는 기동 중 DB 관련 초기화가 매우 길어졌다.

- `HikariPool-1 - Starting...` 이후 첫 connection 추가까지 약 `30초`
- `Flyway repair` 완료까지 추가로 약 `42초`

즉 DB latency가 걸린 상태에서 애플리케이션 기동 및 health 응답이 probe timeout보다 훨씬 느려졌고, 그 결과 기존 pod도 안정적으로 살아남지 못했다.

## 5. 원인 분석

## 5.1 1차 원인: DB latency가 Spring 기동과 health 응답을 늦췄다

이번 실험은 `RDS downstream latency`를 `300ms -> 1s -> 3s`로 높여가며 수행했다. DB latency가 올라가자 Spring은 datasource 초기화와 Flyway 처리에서 길게 대기했고, `/actuator/health` 응답도 같이 느려졌다.

기존 smoke 실험에서도 baseline `~10ms`였던 `/actuator/health`가 `300ms` toxic만으로 `~600ms`까지 증가한 적이 있었다. 이번 정식 부하 실험에서는 여기에 `RPS 50`이 겹치면서 health probe 실패와 재시작까지 이어졌다.

이 단계에서 중요한 해석은 `애플리케이션 내부 CPU가 높은지`가 아니라, `느린 RDS 호출이 health와 startup 경로까지 끌어내렸는지`다. 이번 증거는 후자 쪽을 강하게 지지한다.

## 5.2 2차 원인: HPA scale-out 이후 scheduler가 request 기반 CPU 예약에 막혔다

사용자 가설의 핵심은 아래였다.

- 실제 CPU 사용량은 낮았다.
- 그런데 `cpu request=750m`가 높게 잡혀 있었다.
- 그래서 HPA가 늘리려 한 pod가 예약 가능한 CPU 부족으로 Pending 됐을 것이다.

이 가설은 `Pending 원인`에 대해서는 맞다.

확인 근거:

- Pending pod 이벤트에 `3 Insufficient cpu`
- deployment에 `requests.cpu=750m`
- app node allocatable이 모두 `2 core`
- node allocated resources가 `70%`, `90%`, `51%` 수준

따라서 `실사용량이 낮았는데 왜 Pending이냐`는 질문에 대한 답은 명확하다. scheduler는 `실시간 사용량`이 아니라 `request 합계`를 기준으로 본다.

다만 이 해석을 `CPU만이 유일 원인`으로 단정하면 틀린다. 같은 이벤트에는 `topology spread constraints`도 함께 찍혔다. 정확한 문장은 아래와 같다.

- HPA는 CPU metric을 보고 scale-out을 시도했다.
- scale-out 결과 생성된 신규 pod는 `높은 cpu request`와 `topology spread constraints` 때문에 일부 app node에 배치되지 못했다.
- 따라서 Pending은 `CPU reservation + 배치 제약`의 결합 결과다.

반대로 `RDS latency가 CPU를 직접 밀어 올려 HPA가 동작했다`는 인과는 아직 닫히지 않았다. 현재까지 확보한 사실은 아래 수준이다.

- HPA는 CPU metric 기준으로 scale-out 이벤트를 남겼다.
- Grafana와 `kubectl top`에서 확인한 실사용 CPU는 실험 후반 기준으로 높지 않았다.
- 따라서 `scale-out이 일어난 정확한 시점의 pod 평균 CPU/request`와 Grafana 패널의 집계 구간을 추가로 대조해야 이 인과를 확정할 수 있다.

## 5.3 3차 원인: health probe timeout이 fault 상황에서 너무 짧았다

`spring-boot` pod의 probe는 모두 `timeoutSeconds=1`이었다.

- liveness probe:
  - `GET /actuator/health`
  - `initialDelaySeconds=5`
  - `timeoutSeconds=1`
  - `periodSeconds=20`
  - `failureThreshold=3`
- readiness probe:
  - `GET /actuator/health`
  - `initialDelaySeconds=5`
  - `timeoutSeconds=1`
  - `periodSeconds=10`
  - `failureThreshold=3`
- startup probe:
  - `GET /actuator/health`
  - `initialDelaySeconds=10`
  - `timeoutSeconds=1`
  - `periodSeconds=5`
  - `failureThreshold=30`

RDS latency가 `1s`, `3s`까지 올라가고 기동 중 datasource 초기화와 migration까지 느려진 상황에서, 이 값은 사실상 공격적으로 짧다. 실제 이벤트에도 `context deadline exceeded`와 `connect: connection refused`가 반복해서 찍혔다.

중요한 점은 `liveness`만 문제가 아니었다는 것이다. 세 probe가 모두 같은 `/actuator/health`를 보고 있었고, 각각 아래처럼 다른 방식으로 장애를 증폭시켰다.

- `readiness probe` 실패:
  - pod가 살아 있어도 서비스 엔드포인트에서 빠진다.
  - 결과적으로 살아남은 pod에 트래픽이 더 몰릴 수 있다.
- `liveness probe` 실패:
  - pod를 재시작시킨다.
  - 느린 DB 상황에서 재시작은 오히려 startup 경로를 다시 밟게 만들어 복구를 더 늦출 수 있다.
- `startup probe` 실패:
  - 신규 pod가 충분히 기동되기 전에 실패로 간주될 수 있다.
  - 특히 datasource 초기화와 Flyway 수행이 길어지는 상황에서 영향을 크게 받는다.

즉 이번 장애는 단순히 `DB가 느려졌다`에서 끝난 것이 아니라, `느린 DB -> 느린 health 응답 -> readiness 실패 -> liveness/startup 실패 -> restart -> 다시 startup 지연`으로 자기증폭 루프를 만들었다.

## 5.4 복구가 늦어 보인 이유

toxic을 cleanup한 뒤에도 즉시 정상 상태로 보이지 않았던 이유는 두 가지다.

1. 이미 일부 pod는 `CrashLoopBackOff`와 probe failure 이력을 안고 있었다.
2. HPA는 바로 scale-down 하지 않고 stabilization window 동안 점진적으로 내려갔다.

실제로 이벤트에는 `9 -> 8 -> 7 -> 6 -> 5 -> 4 -> 3`으로 천천히 줄어드는 과정이 남아 있다.

따라서 `toxics: []` 확인 직후에도 시스템이 곧바로 평온해 보이지 않았던 것은 이상 현상이 아니라, 실험 중 누적된 재시작과 scale-down 지연이 남아 있었기 때문이다.

## 6. 원인을 어떻게 찾아냈는가

이번 원인 분석은 아래 순서로 진행했다.

1. `HPA/ReplicaSet` 이벤트를 보고 scale-out이 실제로 있었는지 확인
2. `describe pod`로 Pending 원인이 scheduler 단계인지, container 단계인지 분리
3. deployment의 `requests/limits`를 확인해 scheduler가 어떤 숫자를 보고 있었는지 확인
4. `node allocatable`과 `allocated resources`를 같이 확인해 request 기반으로 얼마나 차 있었는지 확인
5. `top pod`, Grafana CPU Quota 패널과 대조해 실사용량과 request 기반 판단이 다르다는 점을 확인
6. `describe pod`와 이전 로그를 통해 Running pod의 probe failure, restart, CrashLoopBackOff를 별도 축으로 분리

핵심 확인 명령은 아래였다.

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf get hpa -n billage-app spring-boot -o wide
kubectl --kubeconfig /etc/kubernetes/admin.conf get rs -n billage-app -l app=spring-boot
kubectl --kubeconfig /etc/kubernetes/admin.conf get events -n billage-app --sort-by=.lastTimestamp | tail -60
```

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf get deploy -n billage-app spring-boot \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" requests.cpu="}{.resources.requests.cpu}{" limits.cpu="}{.resources.limits.cpu}{" requests.memory="}{.resources.requests.memory}{" limits.memory="}{.resources.limits.memory}{"\n"}{end}'
```

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf describe pod -n billage-app spring-boot-55b4d4d878-gsmg2
kubectl --kubeconfig /etc/kubernetes/admin.conf describe pod -n billage-app spring-boot-55b4d4d878-624vz
kubectl --kubeconfig /etc/kubernetes/admin.conf logs -n billage-app spring-boot-55b4d4d878-624vz --previous
```

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes \
  -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
kubectl --kubeconfig /etc/kubernetes/admin.conf top nodes
kubectl --kubeconfig /etc/kubernetes/admin.conf top pod -n billage-app
kubectl --kubeconfig /etc/kubernetes/admin.conf describe node billage-kubeadm-prod-app-01 | grep -A6 "Allocated resources"
kubectl --kubeconfig /etc/kubernetes/admin.conf describe node billage-kubeadm-prod-app-02 | grep -A6 "Allocated resources"
kubectl --kubeconfig /etc/kubernetes/admin.conf describe node billage-kubeadm-prod-app-03 | grep -A6 "Allocated resources"
kubectl --kubeconfig /etc/kubernetes/admin.conf describe node billage-kubeadm-prod-app-04 | grep -A6 "Allocated resources"
```

## 7. 이번 실험에서 확정적으로 말할 수 있는 것

- `Spring -> RDS` 지연은 단순 API latency 증가로 끝나지 않고 `health probe`, `startup`, `HPA`, `scheduler`까지 연쇄 전파됐다.
- HPA는 실제로 CPU metric 기준 scale-out을 시도했다.
- 새 pod가 Pending 된 직접 원인에는 `Insufficient cpu`가 포함돼 있었다.
- 이 CPU 부족은 `실사용량`이 아니라 `750m request` 기준 reservation 부족이었다.
- 다만 Pending은 `CPU`만의 문제가 아니라 `topology spread constraints`도 함께 작용했다.
- 기존 Running pod의 불안정성은 scheduler가 아니라 `DB latency로 인한 기동/health 지연`과 `1초 probe timeout`의 조합으로 설명된다.
- 다만 `RDS latency가 CPU를 직접 올려 HPA를 움직였다`는 인과는 아직 추가 검증이 필요하다.

## 8. 남은 확인 포인트

이번 문서에서 의도적으로 해결책은 다루지 않았지만, 분석을 더 단단하게 하려면 다음 데이터가 추가로 있으면 좋다.

- 장애 시점의 `Hikari active/pending/timeout`
- `Tomcat busy thread`
- 장애 시점의 `HPA current CPU metric` 시계열
- `spring-boot`별 CPU/memory 시계열
- probe 실패 직전과 직후의 `/actuator/health` 상세 응답

이 데이터가 추가되면 이번 사고는 `RDS latency -> pool 대기 -> health timeout -> restart -> scale-out -> pending`이라는 체인으로 더 정교하게 닫을 수 있다.

## 9. 하단 요약

이번 실험에서 가장 직접적인 장애 전파 경로는 다음과 같았다. `DB 지연 때문에 /actuator/health가 느려졌고, 그 경로를 동시에 보던 startup/readiness/liveness probe가 모두 1초 timeout에 걸리면서, 새 pod는 기동 완료가 늦어지고 기존 pod는 트래픽 제외 또는 재시작되었다.`

이와 별개로 scale-out 이후의 Pending은 scheduler 단계 문제였다. HPA는 CPU 기준으로 scale-out 이벤트를 남겼고, 생성된 신규 pod는 `750m` CPU request, app node의 제한된 allocatable CPU, 그리고 topology spread constraints가 겹치면서 일부가 배치되지 못했다.
