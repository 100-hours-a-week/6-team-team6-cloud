# RDS API Recovery Second Fix Report

## 근본 목적

이 문서는 `probe/scheduler 안정화 이후에도 남아 있던 API recovery gap`을 줄이기 위해 애플리케이션 경로를 실제로 수정하고, 같은 `RDS 1.5s latency` fault 조건에서 무엇이 얼마나 달라졌는지를 기록하는 데 목적이 있다.

## 비목적

이 문서는 제어 조건이 다른 실험을 무리하게 동일 비교로 포장하는 데 목적이 없다. 특히 이번 2차 검증은 `groupId=21`의 기존 데이터셋이 아니라, 실험자가 새로 만든 제어된 그룹을 사용했다는 한계를 그대로 남긴다.

## 한눈에 보는 결론

출발점이 된 원래 문제는 두 단계였다.

- `RDS 1.5s latency` 주입 시 `/actuator/health`를 함께 보던 `startup/readiness/liveness`가 모두 흔들리면서 pod 재시작, unready, Pending이 발생했다.
- 1차 개선으로 이 `probe/scheduler 붕괴`는 줄였지만, `GET /groups/{groupId}/posts`는 여전히 hot state에서 `200 32.025387`, cleanup 뒤 첫 recovery poll에서 `8s timeout`을 보여 `API recovery gap`이 남았다.

2차 개선은 `남아 있던 API recovery gap`을 실제로 줄였다.

- 1차 개선 후에는 `RDS 1.5s latency` 중 hot state API가 `200 32.025387`, cleanup 뒤 첫 recovery poll도 `8s timeout`이었다. [`rds-fault-injection-recovery-comparison-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-recovery-comparison-2026-03-26.md)
- 2차 개선 후 제어된 그룹(`groupId=11`)에서 같은 `RPS 50`, 같은 `RDS 1.5s latency`를 넣었을 때 baseline under load는 `200 0.156516`, hot state도 `200 0.209392`였다. [`10-rebaseline-under-load.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/10-rebaseline-under-load.txt) [`12-hot-state-under-load.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/12-hot-state-under-load.txt)
- cleanup 이후 첫 poll은 `200 0.082838`, 두 번째 poll은 `200 0.047266`이었다. 즉 cleanup 직후 관측 구간에서 회복 tail이 사실상 사라졌다. [`14-recovery-polls.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/14-recovery-polls.txt)

다만 이 수치는 `원래 실험하던 groupId=21`과 동일 데이터셋이 아니다. 따라서 이번 결론은 `수정한 코드 경로가 제어된 조건에서는 recovery gap을 줄였다`까지로 해석해야 한다.

## 무엇을 바꿨는가

2차 개선은 `요청 경로 자체`를 줄이는 데 집중했다. 이유는 1차 개선이 이미 `probe/scheduler 붕괴`는 줄였지만, 실제 비즈니스 API는 여전히 느린 DB 경로를 오래 붙잡고 있었기 때문이다.

1. 첫 페이지 추천 경로를 끌 수 있는 설정을 추가했다.
2. fault injection 실험 배포에서는 `POST_FEED_FIRST_PAGE_RECOMMENDATION_ENABLED=false`로 첫 페이지 추천 경로를 끄도록 했다.
3. datasource/Hikari timeout을 명시했다.
   - `DB_CONNECTION_TIMEOUT_MS=3000`
   - `DB_VALIDATION_TIMEOUT_MS=1000`
   - `DB_INITIALIZATION_FAIL_TIMEOUT_MS=1`

관련 코드 변경은 아래다.

- [`PostFacade.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-application/src/main/java/ktb/billage/application/post/PostFacade.java)
- [`application.yml`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-api/src/main/resources/application.yml)
- [`application-dbsource.yml`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-infra/src/main/resources/application-dbsource.yml)
- [`PostFacadeUnitTest.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-application/src/test/java/ktb/billage/application/post/PostFacadeUnitTest.java)

클러스터에는 아래 env가 실제로 반영됐다.

- `DEV_DB_URL=jdbc:mysql://toxiproxy-rds.billage-app.svc.cluster.local:3306/billage?useSSL=false`
- `DB_CONNECTION_TIMEOUT_MS=3000`
- `DB_VALIDATION_TIMEOUT_MS=1000`
- `DB_INITIALIZATION_FAIL_TIMEOUT_MS=1`
- `POST_FEED_FIRST_PAGE_RECOMMENDATION_ENABLED=false`

## 실험 방법

이번 2차 검증은 기존 `groupId=21` 접근용 테스트 계정이 더 이상 유효하지 않아, 제어된 새 사용자와 새 그룹을 만들어 다시 구성했다.

- 새 사용자 생성
- 새 그룹 생성
- 해당 사용자로 `GET /groups/{groupId}/posts` 호출
- 로컬 `k6`에서 `RPS 50` constant-arrival-rate
- `Toxiproxy rds-upstream`에 `latency_downstream=1500ms, jitter=150ms` 주입

실험 fixture는 여기에 저장했다. [`00-test-fixture.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/00-test-fixture.txt)

중요한 사실:

- 새 그룹 생성은 성공했다.
- 게시글 생성은 `SERVER01`로 실패했다.
- 그럼에도 `GET /groups/11/posts`는 `200`으로 응답했다.

즉 이번 2차 검증은 `post list code path`는 타지만, 데이터량은 매우 작은 제어 조건이다.

## 결과

### 0. 왜 2차 개선이 필요했는가

2차 개선의 직접 배경은 1차 개선 이후에도 아래 현상이 남아 있었기 때문이다.

- pod/scheduler/HPA는 빠르게 안정화됨
- 그러나 `GET /groups/21/posts`는 hot state에서 `200 32.025387`
- cleanup 뒤 첫 recovery poll도 `8s timeout`

즉 `인프라 레벨 복구`와 `사용자 요청 복구` 사이에 큰 간극이 있었다.

### 1. baseline under load

- 시각: `2026-03-26T01:23:16Z`
- `k6`: `50.00 iters/s`
- 직접 호출: `GET /groups/11/posts code=200 total=0.156516`

증거: [`10-rebaseline-under-load.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/10-rebaseline-under-load.txt)

### 2. toxic apply

- `latency_downstream=1500ms, jitter=150ms`
- `rds-upstream.toxics`에 실제로 독성이 생성됨

증거: [`11-toxic-apply.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/11-toxic-apply.json)

### 3. hot state under load

- 시각: `2026-03-26T01:24:12Z`
- `k6`: `50.00 iters/s`
- 직접 호출: `GET /groups/11/posts code=200 total=0.209392`

증거: [`12-hot-state-under-load.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/12-hot-state-under-load.txt)

### 4. recovery poll

- 첫 poll: `2026-03-26T01:25:18Z`, `200 0.082838`
- 두 번째 poll: `2026-03-26T01:25:33Z`, `200 0.047266`
- 세 번째 poll: `2026-03-26T01:26:03Z`, `200 0.405808`

증거: [`14-recovery-polls.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/14-recovery-polls.txt)

### 5. k6 요약

3분 부하 결과의 핵심 수치는 다음과 같다.

- `http_req_failed`: `0.00%`
- `http_req_duration avg`: `30.53ms`
- `http_req_duration p95`: `90.25ms`
- `http_req_duration max`: `4.6s`
- `http_reqs`: `8818`
- `dropped_iterations`: `183`

## 해석

이번 2차 개선은 적어도 제어된 그룹 조건에서는 효과가 있었다.

- 독성 주입 전 `0.156s`
- 독성 주입 중 `0.209s`
- cleanup 직후 첫 poll `0.083s`

즉 1차 개선 때 남아 있던 `cleanup 뒤에도 API가 수십 초~수분 느린 현상`은 이번 제어 실험에선 보이지 않았다.

다만 이 결과를 그대로 `groupId=21에서도 완전히 해결됐다`로 쓰면 과장이다. 이유는 세 가지다.

1. 이번 실험은 새 그룹(`groupId=11`) 기준이다.
2. 게시글 생성이 실패해서 데이터량이 매우 작다.
3. 따라서 기존 `groupId=21`의 무거운 데이터셋과 절대 지연값을 직접 비교할 수 없다.

정확한 결론은 아래다.

- `코드 경로 관점`: 첫 페이지 추천 경로 제거 + 짧은 DB/Hikari timeout은 recovery gap을 줄이는 방향으로 작동했다.
- `운영 데이터셋 관점`: 기존 `groupId=21`과 같은 조건에서 재검증이 한 번 더 필요하다.

## 다음 단계

가장 가치 있는 후속 작업은 아래다.

1. 기존 실험용 데이터셋과 동일한 멤버십/게시글 조건을 다시 확보한다.
2. 같은 `groupId=21` 또는 동등한 데이터량 그룹에서 같은 실험을 재실행한다.
3. Hikari/Tomcat 메트릭을 붙여 `왜 p95/p99가 남는지`를 수치로 닫는다.

## 관련 문서

- 1차 비교: [`rds-fault-injection-recovery-comparison-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-recovery-comparison-2026-03-26.md)
- 원인 분석: [`rds-api-recovery-gap-analysis-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-api-recovery-gap-analysis-2026-03-26.md)
