# RDS API Recovery Gap Analysis

## 근본 목적

이 문서는 `probe/scheduler 복구는 빨라졌지만 비즈니스 API 복구는 여전히 늦은 이유`를 코드와 실험 증거 기준으로 좁혀, 다음 개선 작업이 어디를 겨냥해야 하는지 명확히 하는 데 목적이 있다.

## 비목적

이 문서는 아직 적용하지 않은 개선안을 성과처럼 포장하거나, 원인이 확인되지 않은 가설을 확정 사실처럼 쓰는 데 목적이 없다. 확인된 사실과 그로부터 가능한 해석만 분리해 기록한다.

## 한눈에 보는 결론

현재 남아 있는 회복 지연의 핵심은 `Spring pod 상태`가 아니라 `GET /groups/{groupId}/posts` API 경로 자체`다.

- resilience patch 이후 `pod/scheduler/HPA`는 빨리 안정화됐다.
- 하지만 `GET /groups/21/posts`는 hot state에서 `200 32.025387`, recovery 초반에는 `8s timeout`을 보였다.
- 코드상 이 API는 단순 목록 조회가 아니라, 첫 페이지 기준으로 `group 검증`, `membership 조회`, `active post count`, `게시글 목록 조회`, `추천용 추가 조회`, `이미지 presign`까지 한 요청 안에서 수행한다.
- 동시에 datasource/Hikari timeout을 애플리케이션에서 명시적으로 짧게 제한한 설정이 보이지 않았다.

즉, 이번 1차 패치는 `서비스가 무너지는 문제`는 줄였지만, `요청 자체가 느린 DB/부가 조회를 오래 기다리는 문제`는 그대로 남아 있었다.

## 실험에서 확인된 사실

기준 비교 문서에 남긴 값은 다음과 같다. [`rds-fault-injection-recovery-comparison-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-recovery-comparison-2026-03-26.md)

- 개선 후 steady state:
  - `spring-boot READY 3/3`
  - `HPA REPLICAS 3`
  - API `200 0.465252`
  - 증거: [`14-postfix-steady-state.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/14-postfix-steady-state.json)
- `RDS latency 1500ms` hot state:
  - pod 상태는 `3/3`, `Pending 0`
  - API는 `200 32.025387`
  - 증거: [`15-postfix-toxic-apply-and-hot-state.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/15-postfix-toxic-apply-and-hot-state.json)
- cleanup 후 `pod 관점 복구`:
  - `38초 이내`
- cleanup 후 `API 관점 복구`:
  - `2026-03-25T17:53:15Z` 시점에도 `8s timeout`
  - `2026-03-25T17:53:53Z` 시점에는 `200 0.072684`
  - 증거: [`17-postfix-recovery-poll-01.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/17-postfix-recovery-poll-01.json), [`18-postfix-api-and-toxic-check.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/18-postfix-api-and-toxic-check.json)

이 차이는 `pod readiness`와 `실제 사용자 요청 경로`가 이미 다른 문제라는 뜻이다.

## 코드 기준 원인 분석

### 1. 대상 API가 생각보다 무겁다

실험 대상 API는 [`PostController.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-api/src/main/java/ktb/billage/api/post/PostController.java) 의 `GET /groups/{groupId}/posts`다.

이 엔드포인트는 [`PostFacade.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-application/src/main/java/ktb/billage/application/post/PostFacade.java) 의 `getPostsByCursor()`로 들어간다. 첫 페이지 요청에서 이 메서드는 아래 단계를 거친다.

1. `groupService.validateGroup(groupId)`
2. `membershipService.findMembershipId(groupId, userId)`
3. `postQueryService.countActivePostsByGroupId(groupId)`
4. 조건 충족 시 `aiPostRecommendationClient.recommendNeeds(membershipId)`
5. 추천 결과를 다시 `postQueryService.getRecommendations(...)`로 조회
6. 일반 목록은 `postQueryService.getPostsByCursor(...)`
7. 응답 직전 각 게시글의 이미지 URL을 `imageService.resolveUrl(...)`로 변환

즉 이 API는 `단순 post list query 1번`이 아니라, 첫 페이지 기준으로 여러 단계의 DB/부가 조회를 합친 `fat endpoint`다.

### 2. dev profile의 추천 mock도 같은 DB를 친다

이번 클러스터 배포는 `dev` profile을 사용한다. 이 profile에서는 실제 AI 서버 클라이언트 대신 [`LoadTestAiMockConfig.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-infra/src/main/java/ktb/billage/infra/ai/LoadTestAiMockConfig.java) 가 활성화된다.

중요한 점은 이 mock이 `빠른 메모리 stub`가 아니라 `JdbcTemplate`로 같은 DB를 다시 조회한다는 점이다.

- `recommendNeeds(membershipId)`는 `membership -> group_id`를 조회한다.
- 이어서 최근 active post id 목록을 다시 조회한다.

즉 `GET /groups/{groupId}/posts` 첫 페이지는 이미 느린 RDS를 한 번만 보는 게 아니라, 추천 mock 때문에 추가 DB round trip을 더 만든다.

이 구조는 `RDS latency`가 남아 있을 때 API 회복이 pod 상태보다 더 늦는 현상을 설명한다.

### 3. datasource/Hikari timeout이 코드상 보이지 않는다

[`application-dbsource.yml`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-infra/src/main/resources/application-dbsource.yml) 에는 아래 수준의 설정만 있다.

- driver class
- URL
- username/password
- JPA dialect / ddl-auto

하지만 아래 설정은 보이지 않았다.

- `spring.datasource.hikari.connectionTimeout`
- `spring.datasource.hikari.validationTimeout`
- `spring.datasource.hikari.maximumPoolSize`
- JDBC `socketTimeout`
- JDBC `queryTimeout`
- DB retry 상한

즉, 애플리케이션 레벨에서 `느린 DB 호출을 몇 초 안에 포기할지`가 명시적으로 드러나지 않는다.

이건 중요한 사실이다. 현재 보고서의 `hot state API 32s`와 `recovery 초반 API 8s timeout`은, 요청이 느린 DB 경로를 오래 붙잡고 있을 가능성과 잘 맞는다.

여기서 `32초`가 정확히 어느 timeout 값에서 왔는지까지는 아직 코드만으로 확정할 수 없다. 다만 `짧은 DB timeout 상한이 없다`는 점 자체는 확인된 사실이다.

### 4. 이미지 URL 변환도 요청당 동기 작업이다

응답 직전 `PostFacade.resolveFeedSummary()`는 각 게시글의 `imageService.resolveUrl()`을 호출한다. [`PostFacade.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-application/src/main/java/ktb/billage/application/post/PostFacade.java)

`dev`/`prod` profile에서 이 구현은 [`S3ImageStorage.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-infra/src/main/java/ktb/billage/infra/image/S3ImageStorage.java) 의 presign 경로를 타고, 캐시는 보이지 않는다.

이 단계는 `RDS 지연`의 직접 원인은 아니지만, 게시글 20개 응답을 만드는 과정에서 추가 synchronous work를 만든다. 즉 recovery gap을 키우는 보조 요인으로는 볼 수 있다.

## 지금 시점의 가장 설득력 있는 원인

현재 확인된 사실만 놓고 보면, 남은 API recovery gap의 가장 설득력 있는 원인은 아래 조합이다.

1. `GET /groups/{groupId}/posts`가 첫 페이지 기준으로 여러 DB 단계와 부가 작업을 가진 무거운 경로다.
2. `dev` profile의 추천 mock조차 같은 DB를 다시 조회한다.
3. datasource/Hikari/JDBC timeout을 짧게 제한한 코드 설정이 보이지 않는다.
4. 그래서 pod는 ready가 되어도, 실제 요청은 느린 DB 경로를 계속 오래 기다릴 수 있다.

이건 `probe가 더 문제`라는 뜻이 아니다. probe 문제는 1차 패치로 상당 부분 줄였다. 지금 남은 건 `요청 처리 경로`의 문제다.

## 아직 확정하지 않은 것

아래는 아직 `가능성`으로만 남겨둔다.

- 실제 DB 호출이 Hikari connection wait인지, JDBC read wait인지, query execution wait인지
- recovery 초반 `8s timeout`이 app server timeout, client timeout, 혹은 backlog 영향인지
- 이미지 presign 비용이 전체 latency에서 차지하는 비율

이 세 가지는 현재 코드와 실험 evidence만으로는 확정할 수 없다. 다음 단계에서 Hikari/Tomcat/JDBC 메트릭을 붙이면 닫을 수 있다.

## 다음 개선 우선순위

원인 분석 기준으로 보면 다음 순서가 맞다.

1. `DEV_DB_URL`에 JDBC-level timeout을 명시한다.
2. Hikari `connectionTimeout`, `validationTimeout`, pool size를 명시한다.
3. `GET /groups/{groupId}/posts` 첫 페이지의 추천 경로를 분리하거나, 최소한 실험용 endpoint를 추천 없이 고정한다.
4. `dev` profile의 AI mock이 DB를 다시 치지 않도록 바꾼다.
5. Hikari/Tomcat/HTTP timeout 메트릭을 붙여 다음 실험에서 `어디서 기다렸는지`를 수치로 확인한다.

## 결론

현재 단계의 결론은 명확하다.

- `실제로 개선은 됐다.`
- 하지만 개선된 것은 `pod/scheduler 복구`다.
- `API recovery gap`은 별도 문제이며, 그 직접 원인은 `무거운 첫 페이지 조회 경로 + 같은 DB를 다시 치는 추천 mock + 짧게 제한되지 않은 DB timeout` 조합으로 보는 것이 가장 타당하다.

따라서 다음 작업은 probe/HPA를 더 만지는 게 아니라, `Spring 요청 경로의 DB timeout과 조회 경로 자체`를 줄이는 쪽이어야 한다.
