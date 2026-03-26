# RDS Fault Injection Continuation Status

## 근본 목적

이 문서는 지금까지의 `RDS fault injection` 작업이 어떤 상태로 끝났는지와, 다음 담당자가 어떤 순서로 이어서 검증하면 되는지를 한 번에 전달하기 위한 handoff 문서다.

## 비목적

이 문서는 결과를 새로 해석하거나, 아직 검증하지 않은 내용을 사실처럼 추가하는 데 목적이 없다. 이미 적용된 변경, 확보된 evidence, 다음 실행 절차만 정리한다.

## 현재 상태

현재 클러스터는 아래 상태다.

- image: `988319239270.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:kube_latest`
- HPA: `4%/70%`, replicas `3`
- deployment: `3/3`
- spring-boot pod: `3/3 Running`
- toxiproxy: `toxics: []`

증거:

- [`13-toxic-cleanup.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/13-toxic-cleanup.json)
- [`15-final-check.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/15-final-check.json)

## 이미 적용된 변경

### 클러스터/배포

- `DEV_DB_URL -> toxiproxy-rds`
- `DB_CONNECTION_TIMEOUT_MS=3000`
- `DB_VALIDATION_TIMEOUT_MS=1000`
- `DB_INITIALIZATION_FAIL_TIMEOUT_MS=1`
- `POST_FEED_FIRST_PAGE_RECOMMENDATION_ENABLED=false`
- probe 분리
  - `liveness=/actuator/health/liveness`
  - `readiness=/actuator/health/readiness`
  - `startup=/actuator/health/liveness`
- probe timeout `5s`
- `startup failureThreshold=60`
- `requests.cpu=300m`
- HPA scaleDown stabilization `60s`

### 백엔드 코드

- 첫 페이지 추천 경로 비활성화 플래그 추가
- Hikari timeout 명시
- 관련 단위 테스트 추가

참고 파일:

- [`PostFacade.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-application/src/main/java/ktb/billage/application/post/PostFacade.java)
- [`application.yml`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-api/src/main/resources/application.yml)
- [`application-dbsource.yml`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-infra/src/main/resources/application-dbsource.yml)
- [`PostFacadeUnitTest.java`](/Users/cho/IdeaProjects/6-team-team6-be/ktb-billage-application/src/test/java/ktb/billage/application/post/PostFacadeUnitTest.java)

## 지금까지 확보된 핵심 결과

### 1차 개선 결과

- `pod/scheduler` 붕괴는 줄였지만
- `groupId=21` 기준 API recovery gap은 여전히 남아 있었다
- hot state API: `200 32.025387`
- cleanup 뒤 API 완전 복구: `118초 초과, 156초 이내`

참고:

- [`rds-fault-injection-recovery-comparison-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-recovery-comparison-2026-03-26.md)

### 2차 개선 결과

- 제어된 새 그룹(`groupId=11`) 기준
- baseline under load: `200 0.156516`
- hot state under load: `200 0.209392`
- recovery first poll: `200 0.082838`

참고:

- [`rds-api-recovery-second-fix-report-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-api-recovery-second-fix-report-2026-03-26.md)

## 해석 시 주의점

2차 개선 수치는 좋지만, 완전한 apples-to-apples 비교는 아니다.

- 1차 실험은 기존 `groupId=21`
- 2차 실험은 새로 만든 `groupId=11`
- `groupId=11`에서는 게시글 생성이 `SERVER01`로 실패했고, 결국 데이터량이 매우 작은 상태에서 `GET /groups/11/posts`를 호출했다

따라서 지금 문서에서 확정적으로 말할 수 있는 것은 아래다.

- `코드 경로`는 개선되었다
- `운영 데이터셋과 동일 조건`에서 한 번 더 재검증이 필요하다

## 이어서 할 일

다음 담당자는 아래 순서로 이어가면 된다.

1. `groupId=21`에 접근 가능한 실험 계정 또는 동등한 데이터량 그룹을 다시 확보한다.
2. 같은 `RPS 50`, 같은 `1.5s latency`로 재실험한다.
3. Hikari/Tomcat 메트릭을 붙여 `왜 p95/p99가 남는지`를 닫는다.
4. 필요하면 `query timeout`, `JDBC socket timeout`, `retry 상한`까지 추가 조정한다.

## 다음 실험 명령 개요

### toxics apply

기본 원리는 이미 검증됐다.

- `toxiproxy-rds:8474/proxies/rds-upstream/toxics`
- `latency_downstream`
- `latency=1500`
- `jitter=150`

적용 evidence:

- [`11-toxic-apply.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/11-toxic-apply.json)

### toxics cleanup

cleanup evidence:

- [`13-toxic-cleanup.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/13-toxic-cleanup.json)

### 부하

- local docker `grafana/k6:0.49.0`
- `constant-arrival-rate`
- `50/s`

k6 요약:

- [`16-k6-summary.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-api-recovery-second-patch/16-k6-summary.txt)

## 읽는 순서 추천

1. [`rds-fault-injection-recovery-comparison-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-recovery-comparison-2026-03-26.md)
2. [`rds-api-recovery-gap-analysis-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-api-recovery-gap-analysis-2026-03-26.md)
3. [`rds-api-recovery-second-fix-report-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-api-recovery-second-fix-report-2026-03-26.md)
4. 이 문서
