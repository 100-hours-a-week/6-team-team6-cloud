# Capture Guide

## 근본 목적

이 가이드는 사용자가 실험 당시의 클러스터 상태와 toxic 설정을 다시 열어 보고 동일한 화면 증거를 직접 캡처할 수 있게 만드는 데 목적이 있다.

## 비목적

이 가이드는 새로운 실험 절차를 설명하는 문서가 아니라, 이미 수행된 실험의 상태를 재확인하고 증거를 수집하는 데 필요한 최소 명령만 제공한다.

## 목적

- PR에 올린 텍스트 증거 외에, 사용자가 직접 클러스터에 들어가 화면 캡처를 남길 수 있도록 현재 확인해야 할 명령을 정리한다.

## 추천 캡처 순서

1. `toxiproxy-rds` pod 및 service 상태
2. Spring deployment / pod 상태
3. `toxics: []` cleanup 상태
4. HPA replica 수와 cooldown 상태
5. baseline 대비 injected latency 결과가 기록된 evidence 파일

## 클러스터 명령

`cp-01`에서 다음 명령을 실행한다.

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get svc,endpoints,pod -n billage-app -l app=toxiproxy-rds -o wide
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get deploy,pod -n billage-app -l app=spring-boot -o wide
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get hpa -n billage-app spring-boot -o wide
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf logs -n billage-app deploy/toxiproxy-rds --tail=50
```

## toxic 상태 확인

one-shot curl pod로 직접 본다.

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf run fi-toxic-check -n billage-app --restart=Never --image=curlimages/curl:8.12.1 --command -- \
  sh -lc "curl -sS http://toxiproxy-rds:8474/proxies/rds-upstream"
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf logs -n billage-app fi-toxic-check
```

기대값:

- cleanup 후: `"toxics":[]`
- 주입 중: `"latency_downstream"` toxic 포함

## health endpoint 캡처

특정 Spring pod를 하나 고른 뒤 포트포워드한다.

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get pod -n billage-app -l app=spring-boot -o wide
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf -n billage-app port-forward pod/<POD_NAME> 18080:8080
curl -sS -o /dev/null -w 'code=%{http_code} total=%{time_total}\n' http://127.0.0.1:18080/actuator/health
```

## 로컬 evidence 파일 경로

- 보고서: [`rds-fault-injection-execution-report-2026-03-25.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/docs/rds-fault-injection-execution-report-2026-03-25.md)
- baseline: [`03-baseline-health.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-25-rds-latency/03-baseline-health.txt)
- injected: [`05-injected-health-300ms.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-25-rds-latency/05-injected-health-300ms.txt)
- toxic cleanup: [`06-toxic-cleanup.txt`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-25-rds-latency/06-toxic-cleanup.txt)

## Grafana 캡처 포인트

다음 대시보드 파일을 기준으로 실제 Grafana에서 같은 패널을 열어 캡처한다.

### 1. App Observability

- 대시보드 파일: [`app-observability-v2.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/monitoring/server/configs/grafana/dashboards/app-observability-v2.json)
- 추천 패널:
  - `Nginx QPS`
  - `Nginx 5xx/s`
  - `Spring 5xx Ratio`
  - `Spring P95 Latency (ms)`
  - `Hikari Pending Connections`
  - `Hikari Acquire Latency (ms)`
  - `Hikari Connection Timeout/s`
  - `Container Restart Events (15m)`

추천 캡처 조합:

1. `Spring P95 Latency (ms)` + `Nginx 5xx/s`
2. `Hikari Pending Connections` + `Hikari Acquire Latency (ms)`
3. `Hikari Connection Timeout/s` + `Container Restart Events (15m)`

### 2. Infra / RDS / ALB

- 대시보드 파일: [`infra-v2-rds-alb.json`](/Users/cho/IdeaProjects/6-team-team6-cloud/monitoring/server/configs/grafana/dashboards/infra-v2-rds-alb.json)
- 추천 패널:
  - `ALB Ingress RPS`
  - `ALB Target 5xx/s`
  - `Hikari Active %`
  - `Hikari Pending Connections`
  - `Hikari Connection Timeout/s`
  - `Hikari Acquire Latency (ms)`

추천 캡처 조합:

1. `ALB Ingress RPS` + `ALB Target 5xx/s`
2. `Hikari Active %` + `Hikari Pending Connections`
3. `Hikari Connection Timeout/s` + `Hikari Acquire Latency (ms)`

## Prometheus 기준 확인할 메트릭

Prometheus Explore에서 직접 확인할 때는 아래 메트릭을 우선 본다.

- `http_server_requests_seconds_bucket`
- `http_server_requests_seconds_count`
- `hikaricp_connections_pending`
- `hikaricp_connections_timeout_total`
- `hikaricp_connections_acquire_seconds_sum`
- `hikaricp_connections_acquire_seconds_count`
- `aws_applicationelb_httpcode_target_5_xx_count_sum`
- `aws_applicationelb_request_count_sum`

## 캡처 타이밍

가능하면 아래 4시점을 각각 캡처한다.

1. toxic 주입 전 baseline
2. `300ms` toxic 주입 직후
3. 응답 시간 상승이 관측된 시점
4. toxic cleanup 후
