# RDS Fault Injection Recovery Comparison

## 근본 목적

이 문서는 `짧은 RDS 지연 주입` 후 서비스가 얼마나 빨리 정상 상태로 복귀하는지를 개선 전후 동일 조건으로 비교해, 복구 시간 단축 여부를 사실 기반으로 기록하는 데 목적이 있다.

## 비목적

이 문서는 튜닝 항목을 나열하거나 설정 변경 자체를 성과처럼 포장하는 데 목적이 없다. 오직 `같은 부하`, `같은 지연`, `같은 복구 기준`에서 얼마나 달라졌는지를 비교한다.

## 한눈에 보는 결론

이번 개선은 `실제로 효과가 있었다.` 다만 효과가 나타난 지점은 `pod/scheduler 복구`와 `API 응답 복구`가 서로 달랐다.

- 개선 전에는 `1.5s` 지연을 제거한 뒤 `249초`가 지나도 `READY 4/7`, `Pending 3`, `desiredReplicas 7` 상태에서 빠져나오지 못했다.
- 개선 후에는 같은 조건에서 `pod 관점 복구`가 `38초 이내`로 줄었다.
- 개선 후에도 `비즈니스 API`는 cleanup 직후 한동안 느렸고, `완전한 API 복구`는 `118초 초과, 156초 이내`였다.

즉, 이번 패치는 `probe/scheduler 붕괴를 막는 1차 방어선`으로는 성공했고, 다음 과제는 `API 처리 경로 자체의 회복 시간 단축`이다.

## 핵심 수치 비교

| 비교 항목 | 개선 전 | 개선 후 | 해석 |
| --- | --- | --- | --- |
| hot state replica | `7` | `3` | 개선 전엔 HPA와 scheduler가 함께 흔들렸고, 개선 후엔 replica 수가 안정적으로 유지됐다. |
| hot state ready pod | `4/7` | `3/3` | 개선 전엔 일부 pod가 Pending/재시작으로 빠졌고, 개선 후엔 all ready를 유지했다. |
| hot state Pending | `3` | `0` | `requests.cpu 750m -> 300m` 조정과 probe 분리의 효과가 scheduler 적체 감소로 이어졌다. |
| hot state API | `200`, 이후 장기 적체 | `200 32.0s` | 개선 후에도 비즈니스 API는 느렸지만, 장애가 pod 붕괴 대신 응답 지연으로 국소화됐다. |
| cleanup 후 pod 복구 | `249초 초과`에도 미복구 | `38초 이내` | 이번 개선의 가장 큰 정량 효과다. |
| cleanup 후 API 완전 복구 | `249초 초과`에도 완전 복구 미달 | `118초 초과, 156초 이내` | API 회복도 빨라졌지만, pod 복구만큼 짧아지지는 않았다. |

## 체크리스트

- [x] 기준선 환경 상태 확인
- [x] 개선 전 `1.5s` 지연 주입 및 복구 시간 측정
- [x] 개선 방안 적용
- [x] 개선 후 동일 조건 재실험
- [x] 전후 결과 비교 정리
- [x] 증거 파일 경로 정리

## 실험 조건

- 대상 API: `GET /groups/21/posts`
- 부하: `k6 constant-arrival-rate`, `RPS 50`
- 주입 경로: `Spring -> Toxiproxy -> RDS`
- 주입 강도: `latency 1500ms`
- 복구 완료 기준:
  - `spring-boot` deployment `readyReplicas=3`
  - `spring-boot` 관련 `Pending` pod `0`
  - `CrashLoopBackOff` pod `0`
  - `HPA desiredReplicas=3`
  - 대상 API `HTTP 200`

## 개선 전 기준선

기준선은 기존 설정 그대로 측정했다.

- `requests.cpu=750m`
- `startup/readiness/liveness` 모두 `/actuator/health`
- 세 probe 모두 `timeoutSeconds=1`
- HPA scaleDown stabilization window `300s`

측정 결과는 `1.5s` 지연 주입이 끝난 뒤에도 복구가 길게 늘어지는 쪽으로 나타났다.

- toxic cleanup 이후 `111초` 시점에도 `spring-boot`는 `READY 4/7`, `REPLICAS 7`, `Pending 3` 상태였다. [`10-baseline-state-after-cleanup.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/10-baseline-state-after-cleanup.txt)
- toxic cleanup 이후 `249초` 시점에도 여전히 `READY 4/7`, `REPLICAS 7`, `Pending 3` 상태였다. [`12-baseline-state-poll3.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/12-baseline-state-poll3.txt)
- 같은 시점의 API는 `200`이었지만, 우리가 정의한 `완전 복구 기준`인 `readyReplicas=3`, `Pending=0`, `desiredReplicas=3`에는 도달하지 못했다.

따라서 개선 전 기준선의 복구 시간은 `249초 초과`로 기록했다.

## 무엇을 바꿨는가

개선은 `DB 지연이 probe 실패와 scheduler 적체로 전파되는 경로`를 줄이는 데 집중했다.

- `liveness` 경로를 `/actuator/health/liveness`로 분리
- `readiness` 경로를 `/actuator/health/readiness`로 분리
- `startup`도 느린 DB 초기화에 덜 민감한 경로로 분리
- 세 probe의 `timeoutSeconds`를 `1`에서 `5`로 상향
- `startupProbe.failureThreshold`를 `60`으로 상향
- `spring-boot requests.cpu`를 `750m`에서 `300m`로 조정
- HPA scaleDown stabilization window를 `300s`에서 `60s`로 축소

적용은 Terraform이 생성한 SSM 문서 `billage-kubeadm-prod-rds-fault-injection-resilience-patch`로 수행했다. 적용 로그에는 rollout 완료와 최종 spec이 남아 있다. [`13-resilience-patch-apply.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/13-resilience-patch-apply.json)

## 개선 후 재실험

개선 후 steady state는 아래 조건에서 시작했다.

- `spring-boot` `READY 3/3`
- HPA `REPLICAS 3`
- toxics `[]`
- `GET /groups/21/posts` `200 0.465252`
- `k6` 부하 `50.00 iters/s`

steady state 증거는 여기에 남겼다. [`14-postfix-steady-state.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/14-postfix-steady-state.json)

같은 조건에서 `latency 1500ms, jitter 150ms`를 다시 주입했다.

- toxic apply 시각: `2026-03-25T17:48:36Z`
- hot state 수집 시각: `2026-03-25T17:50:06Z`
- hot state에서도 deployment와 HPA는 `3/3`, `REPLICAS 3`을 유지했다.
- 다만 같은 시점의 비즈니스 API는 `200 32.025387`로 크게 느려졌다.

즉 개선 후에는 `pod 스케줄링 붕괴`나 `scale-out 폭주` 대신, 장애가 `응답시간 증가` 쪽으로 더 국소화됐다. [`15-postfix-toxic-apply-and-hot-state.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/15-postfix-toxic-apply-and-hot-state.json)

cleanup 이후 관측은 두 단계로 나뉘었다.

- `2026-03-25T17:51:55Z` 시점에는 deployment/HPA/pod 기준으로 이미 `3/3`, `REPLICAS 3`, `Pending 0`이었다. 이는 cleanup 요청 시각 `2026-03-25T17:51:17Z` 기준 약 `38초` 안에 `pod 관점 복구`가 일어났음을 뜻한다.
- 그러나 `2026-03-25T17:53:15Z` 시점의 비즈니스 API는 여전히 `8초 timeout`이었다. [`17-postfix-recovery-poll-01.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/17-postfix-recovery-poll-01.json)
- `2026-03-25T17:53:53Z`에는 toxics가 `[]`이고, 같은 API가 `200 0.072684`로 돌아왔다. cleanup 요청 시각 기준 약 `156초` 이내다. [`18-postfix-api-and-toxic-check.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/18-postfix-api-and-toxic-check.json)

따라서 개선 후에는 두 개의 복구 시간을 분리해 기록했다.

- `pod 관점 복구`: `38초 이내`
- `API 관점 완전 복구`: `118초 초과, 156초 이내`

## 해석

이번 패치는 `무너지지 않게 하는 1차 방어선`으로는 효과가 있었다.

- probe 분리와 timeout 완화로 `DB 지연`이 곧바로 `liveness/readiness/startup` 전부를 흔들지 않게 됐다.
- `requests.cpu` 축소와 HPA scaleDown window 축소로 `scheduler 적체`와 `scale-down 지연`도 완화됐다.

하지만 `비즈니스 API`는 여전히 일시적으로 크게 느려졌다.

- hot state API `200 32.025387`
- recovery 초반 API `8s timeout`
- 최종 복귀 API `200 0.072684`

즉 이번 실험은 `장애 전파를 pod 붕괴에서 응답 지연으로 낮추는 데는 성공했지만, 요청 처리 경로의 timeout/retry/fallback 문제는 아직 남아 있다`는 결론을 준다.

다음 개선 우선순위는 아래와 같다.

1. 비즈니스 API 자체 timeout 상한 명시
2. DB 호출 retry 정책 상한 설정
3. Hikari/Tomcat 메트릭 계측 추가
4. readiness는 회복됐어도 API가 느린 구간을 드러낼 synthetic check 별도 도입

## 후속 결과

이 문서는 `1차 개선`까지를 직접 비교한 결과다. 이후 `첫 페이지 추천 경로 비활성화 + Hikari timeout 명시`를 적용한 2차 개선 결과는 별도 문서에 정리했다.

- 2차 결과 보고서: [`rds-api-recovery-second-fix-report-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-api-recovery-second-fix-report-2026-03-26.md)
- 이어받기 문서: [`rds-fault-injection-continuation-2026-03-26.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-continuation-2026-03-26.md)

## 읽는 순서 추천

빠르게 파악하려면 아래 순서로 보면 된다.

1. 이 문서의 `한눈에 보는 결론`
2. 이 문서의 `핵심 수치 비교`
3. 기준선 증거: [`10-baseline-state-after-cleanup.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/10-baseline-state-after-cleanup.txt), [`12-baseline-state-poll3.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/12-baseline-state-poll3.txt)
4. 개선 후 증거: [`15-postfix-toxic-apply-and-hot-state.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/15-postfix-toxic-apply-and-hot-state.json), [`17-postfix-recovery-poll-01.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/17-postfix-recovery-poll-01.json), [`18-postfix-api-and-toxic-check.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/18-postfix-api-and-toxic-check.json)

## 증거 파일

- 개선 전 기준선
  - [`05-baseline-clean-start.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/05-baseline-clean-start.txt)
  - [`07-baseline-toxic-apply.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/07-baseline-toxic-apply.json)
  - [`08-baseline-toxic-cleanup.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/08-baseline-toxic-cleanup.json)
  - [`10-baseline-state-after-cleanup.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/10-baseline-state-after-cleanup.txt)
  - [`12-baseline-state-poll3.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/12-baseline-state-poll3.txt)
- 개선 적용
  - [`13-resilience-patch-apply.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/13-resilience-patch-apply.json)
- 개선 후
  - [`14-postfix-steady-state.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/14-postfix-steady-state.json)
  - [`15-postfix-toxic-apply-and-hot-state.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/15-postfix-toxic-apply-and-hot-state.json)
  - [`17-postfix-recovery-poll-01.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/17-postfix-recovery-poll-01.json)
  - [`18-postfix-api-and-toxic-check.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-26-rds-recovery-comparison/18-postfix-api-and-toxic-check.json)
