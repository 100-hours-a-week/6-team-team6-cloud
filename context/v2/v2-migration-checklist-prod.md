# v2 마이그레이션 체크리스트 (Prod 환경)

> 작성일: 2026-02-27
> 대상: v1 (단일 EC2) → v2 (ALB + ASG + RDS)
> 도메인: `www.billages.com` (또는 `billages.com`)
> 참고: [migration overview](../migration/00-migration-overview.md) | [db-migration](../migration/01-db-migration.md) | [cutover-runbook](../migration/08-cutover-runbook.md) | [rollback-runbook](../migration/07-rollback-runbook.md) | [lb-traffic-migration](../migration/05-lb-traffic-migration.md)

---

## 전제 조건

- [x] v2 Terraform 인프라 배포 완료 (ALB, ASG, RDS, RabbitMQ, NAT)
- [x] ECR 리포지토리 생성 및 `:prod-latest` 이미지 푸시 확인
- [x] CI/CD (GitHub Actions) 워크플로우 검증 완료
- [x] v2.billages.com → ALB 정상 응답 확인
- [x] DB 마이그레이션 리허설 완료 (Dev 환경에서 검증)
- [x] **Dev 환경 v2 전환 완료 및 안정화 확인**
- [ ] 롤백 런북 팀 전원 숙지 완료

---

## Phase 0: 사전 준비 (D-7 ~ D-2)

### 0-1. Dev 전환 결과 리뷰

- [ ] Dev 환경 v2 전환 후 발견된 이슈 목록 정리
- [ ] Dev에서 발견된 이슈가 Prod에도 해당되는지 확인
- [ ] Dev 전환 시 누락했던 항목 Prod 체크리스트에 반영

### 0-2. 애플리케이션 호환성 사전 확인

- [ ] 보안 헤더 애플리케이션 레벨 추가 확인 (ALB는 응답 헤더 조작 불가)
  - Spring Boot: HSTS, X-Frame-Options, X-Content-Type-Options
  - Next.js: next.config.js headers() 설정
  - FastAPI: middleware 보안 헤더
- [ ] Backend `X-Forwarded-For` 신뢰 설정 확인 (ALB → Spring Boot)
- [ ] AI 서비스 타임아웃 확인 (ALB idle_timeout=300s vs Nginx proxy_read_timeout=120s)
- [ ] WebSocket heartbeat 간격 설정 확인 (ALB idle_timeout 초과 방지)
- [ ] S3 Presigned URL 생성 정상 동작 확인 (IMDSv2 hop_limit=2)

### 0-3. DNS TTL 사전 낮추기 (D-2)

> 전환 시 빠른 롤백을 위해 TTL을 미리 낮춰둠

- [ ] `www.billages.com` TTL 300초 → **60초**로 변경
  ```bash
  aws route53 change-resource-record-sets --hosted-zone-id <zone-id> \
    --change-batch '{
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "www.billages.com",
          "Type": "A",
          "TTL": 60,
          "ResourceRecords": [{"Value": "<현재-v1-EIP>"}]
        }
      }]
    }'
  ```
- [ ] TTL 변경 후 최소 **기존 TTL(300초) 이상 대기** 후 전환 진행
- [ ] `dig www.billages.com +short` 로 TTL 60초 확인

### 0-4. Prod v2 인프라 최종 점검

- [ ] ALB 헬스체크 정상 (3개 Target Group 모두 healthy)
  ```bash
  aws elbv2 describe-target-health --target-group-arn <be-tg-arn>
  aws elbv2 describe-target-health --target-group-arn <fe-tg-arn>
  aws elbv2 describe-target-health --target-group-arn <ai-tg-arn>
  ```
- [ ] ASG 인스턴스 상태 확인 (BE/FE/AI 각 1대 InService)
  ```bash
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names billage-prod-v2-be-asg billage-prod-v2-fe-asg billage-prod-v2-ai-asg \
    --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState}}'
  ```
- [ ] RDS 상태 `available`, 백업 retention 7일 확인
  ```bash
  aws rds describe-db-instances --db-instance-identifier billage-prod-v2-mysql \
    --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,BackupRetention:BackupRetentionPeriod,Storage:AllocatedStorage}'
  ```
- [ ] RabbitMQ 인스턴스 정상 동작 확인
  ```bash
  # VPN 접속 후 Management UI 확인
  curl -u billage:<password> http://<rabbitmq-private-ip>:15672/api/overview
  ```
- [ ] NAT Instance 정상 동작 (Private 서브넷 인터넷 접근 가능)
- [ ] ACM 인증서 상태 `Issued` 확인 (*.billages.com)
  ```bash
  aws acm list-certificates --query "CertificateSummaryList[?DomainName=='*.billages.com']"
  ```

### 0-5. SSM 파라미터 확인

- [ ] Backend SSM 파라미터 (/billage/prod/be/)
  ```bash
  aws ssm get-parameters-by-path --path /billage/prod/be/ --with-decryption \
    --query 'Parameters[].{Name:Name,Value:Value}'
  ```
  - [ ] `spring-datasource-url` → RDS endpoint 확인
  - [ ] `spring-datasource-password` → RDS 비밀번호 일치 확인
  - [ ] `jwt-secret` → 설정 완료
  - [ ] `cors-allowed` → `www.billages.com` 포함 확인
  - [ ] `rabbitmq-*` → 자동 생성된 값 정상 확인
- [ ] Frontend SSM 파라미터 (/billage/prod/fe/)
  ```bash
  aws ssm get-parameters-by-path --path /billage/prod/fe/ --with-decryption \
    --query 'Parameters[].{Name:Name,Value:Value}'
  ```
  - [ ] `next-public-api-url` → 전환 후 최종 도메인 확인
  - [ ] `nextauth-url` → 전환 후 최종 도메인 확인
  - [ ] `nextauth-secret` → 설정 완료
- [ ] AI SSM 파라미터 (/billage/prod/ai/)

### 0-6. 현재 v1 상태 기록 (기준선)

- [ ] v1 EC2 Elastic IP 기록: `_______________`
- [ ] Route 53 현재 레코드 스냅샷
  ```bash
  aws route53 list-resource-record-sets --hosted-zone-id <zone-id> \
    --query "ResourceRecordSets[?Name=='www.billages.com.']"
  ```
- [ ] v1 MySQL 데이터 건수 기록 (마이그레이션 검증용)
  ```bash
  mysql -u billage_user -p -e "
    SELECT 'users' AS tbl, COUNT(*) AS cnt FROM users
    UNION ALL SELECT 'post', COUNT(*) FROM post
    UNION ALL SELECT 'chatroom', COUNT(*) FROM chatroom
    UNION ALL SELECT 'chat_message', COUNT(*) FROM chat_message
    UNION ALL SELECT 'membership', COUNT(*) FROM membership;
  " billage
  ```
- [ ] v1 서비스 응답 시간 기준선 기록
  ```bash
  curl -w "@curl-format.txt" -o /dev/null -s https://www.billages.com/api/actuator/health
  ```

---

## Phase 1: DB 마이그레이션 (D-Day, Replica 기반)

> Prod는 **Replica 기반 무중단 전환**을 사용한다.
> 상세 명령어: [db-migration-runbook.md](../migration/db-migration-runbook.md) | [cutover-runbook.md](../migration/08-cutover-runbook.md)

### 1-1. Go/No-Go 체크 (컷오버 60분 전)

- [ ] Replica_IO_Running: Yes
- [ ] Replica_SQL_Running: Yes
- [ ] Seconds_Behind_Source: 0~1초
- [ ] Last_Error: 없음
- [ ] RDS CPU < 70%, FreeStorageSpace > 20%
- [ ] 배치/크론 중지됨
- [ ] 진행 중인 DDL 없음
- [ ] 팀원 역할 분담 완료
- [ ] 롤백 절차 숙지 완료

### 1-2. 초기 데이터 동기화 (사전 수행 가능)

> Write Freeze 전에 미리 수행. 서비스 영향 없음.

- [ ] Host MySQL에서 `mysqldump --single-transaction` + GTID 기준점 확보
  ```bash
  mysqldump -u billage_user -p \
    --single-transaction \
    --routines --triggers --events \
    --set-gtid-purged=ON \
    billage | gzip > /tmp/billage-prod-$(date +%Y%m%d).sql.gz
  ```
- [ ] GTID 기준점 기록: `_______________`
- [ ] RDS에 덤프 import
- [ ] RDS를 Host MySQL의 external replica로 설정
  ```sql
  -- RDS에서 실행
  CALL mysql.rds_set_external_source_gtid_purged('<gtid_set>');
  CALL mysql.rds_set_external_master_with_auto_position(
    '<host-mysql-ip>', 3306, 'repl_user', '<password>', 0
  );
  CALL mysql.rds_start_replication;
  ```
- [ ] Replication 정상 동작 확인
  ```sql
  SHOW REPLICA STATUS\G
  -- Replica_IO_Running: Yes
  -- Replica_SQL_Running: Yes
  ```

### 1-3. Lag 모니터링 (Replication catch-up)

- [ ] `Seconds_Behind_Source` 모니터링 (0 도달 대기)
  ```bash
  watch -n 5 "mysql -h <rds-endpoint> -u billage_admin -p<pwd> \
    -e 'SHOW REPLICA STATUS\G' 2>/dev/null | grep -E 'Seconds_Behind|Running|Error'"
  ```
- [ ] Lag=0 안정적 유지 확인 (최소 1분간 0 유지)

### 1-4. Write Freeze & 컷오버 (중단 구간 ~수 초)

- [ ] **팀 공지**: "쓰기 중단 시작" (Slack/Discord)
- [ ] Soft Freeze: v1 WAS 쓰기 차단
  ```bash
  # v1 EC2 SSH
  ./soft-freeze.sh on
  ```
- [ ] Hard Freeze: Host MySQL read_only
  ```bash
  ./hard-freeze.sh on
  ```
- [ ] Lag=0 최종 확인
- [ ] 마커 데이터 검증 (Host에 삽입한 마커가 RDS에 도달했는지)
- [ ] Replication 정리
  ```sql
  CALL mysql.rds_stop_replication;
  CALL mysql.rds_reset_external_master;
  ```
- [ ] 데이터 건수 최종 검증 (v1 스냅샷과 비교)

---

## Phase 2: 서비스 전환

### 2-1. v2 Backend가 RDS를 바라보는지 최종 확인

- [ ] v2 Backend 헬스체크
  ```bash
  curl https://v2.billages.com/api/actuator/health
  ```
- [ ] v2에서 실제 데이터 조회 테스트 (목록 API 등)
- [ ] v2 AI 헬스체크
  ```bash
  curl https://v2.billages.com/ai/health
  ```
- [ ] v2 Frontend 로딩 확인
  ```bash
  curl -I https://v2.billages.com
  ```

### 2-2. v1 Nginx 점검 모드 전환

> v1 Nginx는 정지하지 않고, 점검 페이지를 반환하도록 전환한다.
> DNS 전파 완료 전까지 v1 EIP로 접속하는 유저에게 "점검 중" 메시지를 보여준다.
> 점검 페이지 스크립트는 [부록 A](#부록-a-v1-nginx-점검-페이지-스크립트) 참고.

- [ ] 점검 페이지 배치 및 Nginx 설정 교체
  ```bash
  # v1 EC2 SSH
  ./maintenance-on.sh
  ```
- [ ] 점검 모드 확인
  ```bash
  curl -I https://www.billages.com
  # HTTP/1.1 503 Service Temporarily Unavailable 반환 확인
  ```

### 2-3. v1 애플리케이션 정지

> Nginx는 점검 페이지를 계속 서빙하므로 정지하지 않는다.

- [ ] v1 Backend 정지: `sudo systemctl stop billage-backend`
- [ ] v1 Frontend 정지: `sudo systemctl stop billage-frontend`
- [ ] v1 AI 정지: `sudo systemctl stop billage-ai`
- [ ] **⚠️ v1 Nginx는 정지하지 않음** (DNS 전파 완료 후 Phase 3-2에서 정지)

---

## Phase 3: DNS 전환 (트래픽 스위칭)

> Prod는 가중치 기반 점진적 전환을 권장하지만, v1 서비스를 이미 정지한 경우 즉시 전환 진행.

### Option A: 즉시 전환 (v1 정지 후)

- [ ] `www.billages.com` A 레코드 → ALB Alias로 변경
  ```bash
  # Terraform으로 관리
  terraform plan
  terraform apply

  # 또는 AWS CLI
  aws route53 change-resource-record-sets --hosted-zone-id <zone-id> \
    --change-batch '{
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "www.billages.com",
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": "<alb-hosted-zone-id>",
            "DNSName": "<alb-dns-name>",
            "EvaluateTargetHealth": true
          }
        }
      }]
    }'
  ```
- [ ] billages.com (apex) 도 동일하게 ALB Alias 설정 (필요 시)
- [ ] DNS 전파 확인
  ```bash
  dig www.billages.com +short
  # ALB DNS가 반환되는지 확인 (기존 EIP가 아닌)
  ```

### Option B: 가중치 기반 점진적 전환 (v1 유지 시)

> v1을 살려둔 채 트래픽을 점진적으로 v2로 이동

| 단계 | v1 가중치 | v2 가중치 | 관찰 시간 | 롤백 기준 |
|------|----------|----------|----------|----------|
| 1단계 | 90 | 10 | 30분 | 5xx > 5% |
| 2단계 | 50 | 50 | 1시간 | 5xx > 3% |
| 3단계 | 10 | 90 | 1시간 | 5xx > 1% |
| 4단계 | 0 | 100 | - | 완료 |

```bash
# 예시: 1단계 (v1:90, v2:10)
# Route53 Weighted Routing 설정
# Set ID를 사용한 가중치 레코드 2개 생성
```

### 3-1. 전환 직후 확인

- [ ] `https://www.billages.com` 접속 → 정상 로딩
- [ ] `https://www.billages.com/api/actuator/health` → 200 OK
- [ ] `https://www.billages.com/ai/health` → 200 OK
- [ ] 보안 헤더 확인
  ```bash
  curl -I https://www.billages.com/api/actuator/health 2>/dev/null | \
    grep -iE "strict-transport|x-frame|x-content-type"
  ```

### 3-2. v1 Nginx 최종 정지

> DNS 전파가 완료되어 v1 EIP로의 트래픽이 거의 없어진 후 정지한다.
> TTL 60초 기준, DNS 변경 후 최소 2~3분 대기 후 진행.

- [ ] DNS 전파 확인 (ALB DNS가 반환되는지)
  ```bash
  dig www.billages.com +short
  # ALB DNS가 반환되면 OK
  ```
- [ ] v1 Nginx 정지
  ```bash
  sudo systemctl stop nginx
  ```

---

## Phase 4: 전환 후 검증

### 4-1. 기능 테스트 (E2E)

- [ ] 회원가입 / 로그인 (JWT 발급)
- [ ] 게시글 CRUD (조회/작성/수정/삭제)
- [ ] 이미지 업로드 (S3 Presigned URL)
- [ ] 채팅 (WebSocket `/ws/*` 경로)
- [ ] AI 기능 호출 (`/ai/*` 경로)
- [ ] 그룹/멤버십 기능
- [ ] 로그아웃 후 재로그인

### 4-2. 성능 검증

- [ ] 응답 시간 비교 (v1 기준선 vs v2 실측)
  ```bash
  curl -w "DNS: %{time_namelookup}s, Connect: %{time_connect}s, TTFB: %{time_starttransfer}s, Total: %{time_total}s\n" \
    -o /dev/null -s https://www.billages.com/api/actuator/health
  ```
- [ ] ALB 지표 확인 (CloudWatch)
  - TargetResponseTime (p50, p95, p99)
  - HTTPCode_Target_5XX_Count
  - HealthyHostCount
  - RequestCount

### 4-3. 인프라 모니터링 확인

- [ ] Prometheus → v2 인스턴스 메트릭 수집 정상
- [ ] Grafana 대시보드에 Prod v2 데이터 표시
- [ ] Promtail → Loki 로그 수집 정상
- [ ] RDS CloudWatch 지표 확인
  - CPUUtilization < 70%
  - FreeStorageSpace > 50%
  - DatabaseConnections 정상 범위

### 4-4. 완료 공지

- [ ] Slack/Discord 전환 완료 공지
  ```
  @channel [Prod 환경 v2 전환 완료]
  - www.billages.com이 v2 인프라로 전환되었습니다
  - 서비스 이용에 문제가 있으면 즉시 알려주세요
  - 모니터링 강화 중 (24시간)
  ```

---

## Phase 5: 안정화 & 강화 (D+1 ~ D+14)

### 5-1. 즉시 적용 (D+0)

- [ ] RDS `deletion_protection` 활성화
  ```bash
  aws rds modify-db-instance \
    --db-instance-identifier billage-prod-v2-mysql \
    --deletion-protection \
    --apply-immediately
  ```
- [ ] CloudWatch 알람 설정 확인
  - ALB 5xx 에러 알람
  - RDS CPU/Storage 알람
  - ASG Unhealthy 인스턴스 알람

### 5-2. v1 인프라 유지 (롤백 대비, 최소 2주)

- [ ] v1 EC2 인스턴스 **중지 (Stop)** — 삭제하지 않음
- [ ] v1 Host MySQL 데이터 보존 (EBS 볼륨 유지)
- [ ] v1 EIP 유지 결정
  - 유지 권장: 롤백 시 DNS 즉시 원복 가능 (비용: 미사용 EIP $3.6/월)
  - 해제: 2주 안정화 후 결정

### 5-3. 안정화 관찰

| 기간 | 확인 항목 | 빈도 |
|------|----------|------|
| D+0 ~ D+1 | ALB 5xx, RDS CPU, 응답시간 | 1시간마다 |
| D+1 ~ D+3 | 위 항목 + 사용자 피드백 | 4시간마다 |
| D+3 ~ D+7 | 전체 지표 + 비용 모니터링 | 1일 1회 |
| D+7 ~ D+14 | 주간 리뷰 | 1주 1회 |

### 5-4. CI/CD 전환 확인

- [ ] v1 CI/CD 워크플로우 비활성화 (GitHub Actions에서 disable)
- [ ] v2 CI/CD 정상 동작 확인
  - main 브랜치 push → ECR `:prod-latest` → ASG Instance Refresh
  - Backend / Frontend / AI 각각 독립 배포 확인
- [ ] 롤백 워크플로우 테스트 (이전 이미지 태그로 복원)

### 5-5. Prod 보안 강화

- [ ] SSH `allowed_cidr` 제한 (0.0.0.0/0 → 회사 IP or VPN만)
- [ ] ASG `MinHealthyPercentage` 0 → 50 이상으로 변경
- [ ] RDS Security Group을 VPC 전체(10.1.0.0/16) → Backend SG만 허용으로 축소
- [ ] ALB access log S3 저장 활성화 (감사 추적)

### 5-6. v1 인프라 정리 (D+14 이후, 안정화 확인 후)

- [ ] v1 EC2 인스턴스 종료 (Terminate)
- [ ] v1 EIP 해제 (Release)
- [ ] v1 Security Group 정리
- [ ] v1 Terraform state 아카이브
- [ ] v1 CI/CD 워크플로우 삭제

---

## 롤백 절차 (비상 시)

> 상세: [rollback-runbook.md](../migration/07-rollback-runbook.md)

### 즉시 롤백 트리거 (판단 후 10초 내 실행)

| 조건 | 임계값 | 조치 |
|------|--------|------|
| 5xx 에러율 | > 5% 3분 지속 | 즉시 롤백 |
| RDS 연결 불가 | 모든 쿼리 실패 1분 | 즉시 롤백 |
| ALB Target 0개 healthy | 2분 지속 | 즉시 롤백 |
| 응답시간 p95 > 2초 | 5분 지속, 재시작 실패 | 롤백 |

### 롤백 실행 순서

```bash
# 1. Route53 → v1 EIP로 원복 (60초 이내)
aws route53 change-resource-record-sets --hosted-zone-id <zone-id> \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "www.billages.com",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [{"Value": "<v1-EIP>"}]
      }
    }]
  }'

# 2. v1 서비스 재시작
ssh ubuntu@<v1-eip>
sudo systemctl start nginx
sudo systemctl start billage-backend
sudo systemctl start billage-frontend
sudo systemctl start billage-ai

# 3. v1 정상 확인
curl https://www.billages.com/api/actuator/health
```

### 롤백 후 데이터 동기화

- v2 전환 후 RDS에 쓰여진 데이터가 있으면 Host MySQL로 역동기화 필요
- 판단: 전환 후 경과 시간, 쓰기 건수에 따라 결정
- 방법: `mysqldump --where` 조건부 export 또는 수동 병합

---

## 예상 소요 시간

| 단계 | 예상 시간 | 비고 |
|------|----------|------|
| Phase 0: 사전 준비 | 2~3시간 | D-7 ~ D-2에 분산 수행 |
| Phase 1: DB Replication 설정 | 1~2시간 | 덤프 크기에 따라, 사전 수행 가능 |
| Phase 1: Write Freeze & 컷오버 | **~10초** | Replica 기반 최소 중단 |
| Phase 2: 서비스 전환 | 5분 | v1 정지 + v2 확인 |
| Phase 3: DNS 전환 | 5~10분 | TTL 60초 사전 설정 완료 시 |
| Phase 4: 검증 | 30~60분 | E2E + 성능 + 모니터링 |
| **사용자 체감 중단 시간** | **~1분 이내** | Write Freeze(수 초) + DNS 전파(60초) |

---

## 역할 분담 (예시)

| 역할 | 담당 | 책임 |
|------|------|------|
| **총괄** | DevOps Lead | Go/No-Go 판단, 롤백 결정 |
| **DB 전환** | DevOps | Replication 설정, Write Freeze, 검증 |
| **DNS 전환** | DevOps | Route53 변경, 전파 확인 |
| **기능 테스트** | Backend/Frontend/AI | E2E 테스트, 이상 보고 |
| **모니터링** | DevOps | Grafana/CloudWatch 실시간 감시 |
| **커뮤니케이션** | PM/Lead | 팀 공지, 이해관계자 업데이트 |

---

## 부록 A: v1 Nginx 점검 페이지 스크립트

> Phase 2-2에서 사용하는 스크립트. v1 EC2에 미리 배치해둔다.

### maintenance-on.sh

```bash
#!/bin/bash
set -e

echo "🔧 점검 모드 활성화 중..."

# 1. 점검 페이지 HTML 생성
sudo mkdir -p /var/www/maintenance
sudo tee /var/www/maintenance/index.html > /dev/null << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Billage - 서비스 점검 중</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           display: flex; justify-content: center; align-items: center;
           height: 100vh; margin: 0; background: #f5f5f5; color: #333; }
    .box { text-align: center; padding: 48px; background: white;
           border-radius: 16px; box-shadow: 0 4px 12px rgba(0,0,0,0.08);
           max-width: 480px; }
    h1 { font-size: 24px; margin-bottom: 12px; }
    p { font-size: 16px; color: #666; line-height: 1.6; }
  </style>
</head>
<body>
  <div class="box">
    <h1>서비스 점검 중입니다</h1>
    <p>더 나은 서비스를 위해 시스템을 업데이트하고 있습니다.</p>
    <p>잠시 후 다시 접속해 주세요.</p>
  </div>
</body>
</html>
HTMLEOF

# 2. 기존 Nginx 설정 백업
sudo cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.pre-maintenance

# 3. 점검 모드 Nginx 설정으로 교체
sudo tee /etc/nginx/sites-available/default > /dev/null << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/letsencrypt/live/billages.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/billages.com/privkey.pem;

    # 모든 요청에 503 + 점검 페이지 반환
    location / {
        return 503;
    }

    # API 요청은 503 JSON 응답
    location /api/ {
        default_type application/json;
        return 503 '{"error":"Service under maintenance","message":"점검 중입니다"}';
    }

    # WebSocket 요청도 503
    location /ws {
        return 503;
    }

    error_page 503 /maintenance.html;
    location = /maintenance.html {
        root /var/www/maintenance;
        rewrite ^ /index.html break;
        internal;
    }
}
NGINXEOF

# 4. 설정 검증 및 적용
sudo nginx -t && sudo systemctl reload nginx
echo "✅ 점검 모드 활성화 완료 (Nginx reload)"
```

### maintenance-off.sh (롤백 시 사용)

```bash
#!/bin/bash
set -e

echo "🔄 점검 모드 해제 중..."

# 백업해둔 원본 Nginx 설정 복원
if [ -f /etc/nginx/sites-available/default.pre-maintenance ]; then
  sudo cp /etc/nginx/sites-available/default.pre-maintenance /etc/nginx/sites-available/default
  sudo nginx -t && sudo systemctl reload nginx
  echo "✅ 점검 모드 해제, 정상 모드 복원 완료"
else
  echo "❌ 백업 파일이 없습니다: /etc/nginx/sites-available/default.pre-maintenance"
  exit 1
fi
```