# Rehearsal Standard (Monitoring/Test First)

## Goal

리허설 단계의 1순위는 아래 두 가지다.

1. cutover 전/중/후를 끊김 없이 관측할 수 있는 모니터링 신뢰성 확보
2. 같은 테스트를 반복 재현할 수 있는 실행 표준 고정

롤백은 안전장치로 유지하되, 설계/개선 시간의 중심은 모니터링과 테스트 환경에 둔다.

## Fixed Environment

### 1) Monitoring Server (single source of truth)

- Prometheus
- Alertmanager
- Grafana
- InfluxDB (K6 metrics sink)
- Blackbox exporter
- mysqld exporter for RDS (external scrape)

### 2) Source Server

- node exporter
- nginx exporter
- mysqld exporter (source MySQL local metrics)

### 3) Load Generator

- K6 only
- K6 output must be sent to monitoring-server InfluxDB

## Required Metrics

### Cutover SLI/SLO

- downtime (ms)
- error rate (%)
- p95/p99 latency
- HTTP 5xx rate

### DB/Replication

- replication lag (`mysql_slave_status_seconds_behind_master`)
- replication io/sql running state
- source/target connections
- source/target QPS

### Infra/API Health

- nginx active connections
- node cpu/memory/load
- blackbox probe success/failure for critical endpoints

## Rehearsal Loop (One Change Per Run)

1. pre-check: exporters up, prometheus targets up, dashboards alive
2. baseline run: 10m
3. replication-under-load run: 10m
4. warmup (GET only to `:8081`)
5. cutover-monitor start
6. cutover execute
7. verify-data execute
8. summary write (same template every run)
9. apply only one improvement for next run

## Run Exit Criteria

- same scenario success 3 times in a row
- downtime <= 3000ms
- error rate <= 0.1%
- no data mismatch in verification report
