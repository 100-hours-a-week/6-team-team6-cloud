# Billage 마이그레이션 통합 롤백 런북 (Unified Rollback Runbook)

## 이것만 기억하세요 (Critical Checklist)

**비상 상황 발생 시 30초 안에 확인할 사항:**

| 확인 항목 | 임계값 | 조치 | 300K MAU 기준 |
|---------|--------|------|----------------|
| 에러율 (5xx) | > 5% 지속 3분 | **즉시 롤백** | 45+ RPS (5% of 900) 에러 |
| 응답시간 (p95) | > 2초 | 재시작 시도, 5분 내 미복구 시 롤백 | 정상: 200ms, 임계: 2초 |
| RDS 연결 불가 | 모든 쿼리 실패 | **즉시 Host MySQL로 롤백** | 모든 900 RPS 영향 |
| 인스턴스 Unhealthy | 모든 ASG 인스턴스 | **즉시 롤백** | 최대 6개 backend 모두 실패 |

**롤백 권한:**
- 팀 리더, DevOps 엔지니어, 온콜(on-call) 엔지니어는 즉시 롤백 결정 가능
- CTO 통보: 5분 이내 (병렬 진행, 롤백과 동시 진행)
- Slack #billage-incident 채널에 즉시 공지

**빠른 명령어:**
- Route 53 v1로 복귀: `terraform apply -var="v1_weight=100" -var="v2_weight=0"` (1분)
- SSM DB 복구: AWS Console → Parameter Store → `/billage/prod/db/endpoint` → v1 값으로 수정 (1분)
- Instance Refresh 취소: `aws autoscaling cancel-instance-refresh --auto-scaling-group-name billage-backend-asg-v2` (30초)

---

## 1. 개요 (문서 목적 및 기본 원칙)

### 1.1 이 문서의 목적

이것은 **비상 상황에서 참조하는 문서**입니다. 평시에 정독하고 숙지해두어야 하며, 장애 발생 시 팀원들이 혼란 없이 동일한 절차를 따를 수 있도록 구성되었습니다.

**목표:**
- 장애 감지 후 3분 안에 올바른 롤백 절차 특정
- 불필요한 롤백 방지 (자가 복구 시스템 신뢰)
- 데이터 무결성 우선 (성능 저하보다 데이터 손실을 더 심각하게 평가)
- 포스트모템을 통한 지속적 개선

### 1.2 기본 원칙

**롤백은 최후의 수단:** 단순히 인스턴스 재시작이나 재연결로 해결 가능한 문제를 먼저 시도합니다. 특히 일시적 네트워크 지연이나 단일 인스턴스 장애는 ASG의 자동 교체 메커니즘을 활용합니다.

**데이터 우선 원칙:** 성능 저하(느린 응답)는 용인 가능하지만, 데이터 손실 위험이 있는 상황은 즉시 롤백합니다. 예: RDS 연결 불가 상태에서 계속 운영하면 v1과 v2 간 데이터 불일치 발생.

**병렬 커뮤니케이션:** 롤백 실행 중에 CTO, 팀 리더에게 통보합니다. 대기하지 말고 병렬로 진행합니다.

### 1.3 인시던트 에스컬레이션 경로

```
감지 (모니터링 alert)
  ↓ (1분)
DevOps/온콜 엔지니어 즉시 대응
  ↓ (판단: 롤백 필요)
Slack #billage-incident 공지 + CTO 통보 (병렬)
  ↓ (실행)
롤백 절차 시작
  ↓ (완료)
재확인 (헬스체크, E2E 테스트)
  ↓ (1-2시간 후)
포스트모템 회의 시작
```

**연락처:**
- 온콜 DevOps: DevOps Slack channel `/who-is-oncall`
- CTO: @cto (Slack mention)
- 런북 담당자: @devops-team

---

## 2. 롤백 판단 기준 (언제 롤백할 것인가?)

### 2.1 자동 롤백 트리거 (알림만 받으면 즉시 실행)

이 조건 중 하나라도 충족되면 **10초 이내에 롤백 결정**:

| 메트릭 | 임계값 | 지속 시간 | 조치 | 300K MAU 기준 |
|--------|--------|----------|------|----------------|
| ALB 5xx 에러 | > 10건/5분 | 3분 연속 | 즉시 롤백 | 일반적으로 5분당 0-1건 |
| ASG 인스턴스 Unhealthy | 100% (모든 인스턴스) | 1분 | 즉시 롤백 | max 6개 backend 모두 |
| RDS 연결 불가 | 모든 쿼리 timeout | 1분 | 즉시 Host MySQL로 롤백 | 900 RPS 모두 영향 |
| ALB Target Health | 0개 healthy | 2분 | 즉시 Route 53 v1로 복귀 | 완전 서비스 중단 |

**자동 롤백을 동작하도록 설정:**
- CloudWatch Alarm이 `billage-rollback-trigger` SNS 토픽으로 발행
- Lambda 함수가 자동 롤백 실행 (현재 수동, Phase 06 완료 후 자동화 예정)

### 2.2 수동 판단이 필요한 경우 (5분 내 재시작으로 복구 여부 판단) - 300K MAU 기준

이 경우는 즉시 롤백하지 않고, 5분 대기 후 상황 재평가:

| 메트릭 | 영향도 | 확인 사항 | 판단 기준 | 300K MAU 영향 |
|--------|--------|----------|----------|----------------|
| 응답시간 p95 > 2초 | 중간 | 에러율 동시 증가? | p50이 정상이고 피크 시간대라면 대기 | ~1000 DAU 중 일부만 영향 |
| 특정 기능만 오류 | 낮음 | 타 기능 정상? | 채팅만 오류 = Redis 이슈, 다른 기능 영향 없으면 대기 | 채팅: 250-300개 방 중 일부 |
| DB 쿼리 지연 (> 500ms) | 중간 | RDS CPU/메모리? | 일시적 스파이크라면 대기, 지속이면 롤백 | 900 RPS의 일부만 지연 |
| 메모리 누수 의심 | 낮음 | 인스턴스 재시작 후 복구? | 재시작으로 복구되면 배포 이슈 아님 | 최대 6개 백엔드 중 일부 |

**5분 재시작 시도 절차:**
1. `kubectl rollout restart deployment/billage-backend` 또는 ASG 인스턴스 재시작
2. 5분 대기 후 메트릭 재확인
3. 개선 없으면 해당 Phase 롤백 실행

### 2.3 롤백하지 않는 경우 (ASG와 자가 복구에 맡김)

| 시나리오 | 이유 | 대기 시간 |
|---------|------|----------|
| 단일 인스턴스 Unhealthy | ASG가 자동으로 새 인스턴스 시작 | 3-5분 |
| 일시적 네트워크 지연 (p50 정상, p99만 증가) | 로드 밸런싱으로 자동 복구 | 5분 |
| 단일 엔드포인트만 slow (e.g. `/api/analytics`) | 해당 기능 격리 재시작 가능 | 10분 |

**모니터링 방법:**
- Prometheus Dashboard: `billage-realtime` (30초 업데이트)
- Grafana: `Billage Migration Dashboard` → v1 vs v2 비교 패널
- Loki: tail -100 logs from `service=billage-v2-backend` 과 `service=billage-v1`

---

## 3. Phase별 롤백 시나리오

Billage 마이그레이션은 6단계로 진행되며, 각 단계마다 다른 롤백 절차를 적용합니다.

### 3.1 Phase 1: DB 마이그레이션 (01-db-migration) 롤백

**목적:** v1의 Host MySQL에서 RDS로 데이터 마이그레이션, SSM Parameter로 엔드포인트 관리

**상황:**
- v1: EC2에 MySQL 설치, 모든 앱 연결
- v2 준비: RDS 생성 (db.t4g.micro), 초기 데이터 복제
- 현재: 앱은 아직 v1 사용 중

**Point of No Return (PNR):**
- **PNR 시점:** SSM Parameter Store `/billage/prod/db/endpoint`를 RDS로 변경하고, 앱을 재시작한 순간
- **PNR 이후:** 신규 데이터는 RDS에만 존재 (Host MySQL에는 미동기)

#### 3.1.1 PNR 이전 (SSM 아직 Host MySQL 가리킴) 롤백

**상황:** RDS 생성 과정에서 문제 발생 (e.g. RDS 인스턴스 생성 실패, 네트워크 문제)

**트리거:** RDS 헬스 체크 실패

**절차:**
1. Terraform 롤백: `cd /mnt/terraform/phase-01 && terraform destroy -target="aws_db_instance.billage_rds"` (데이터는 최종 스냅샷으로 보존)
2. SSM Parameter 확인: `/billage/prod/db/endpoint` → 아직 Host MySQL이어야 함
3. 모든 인스턴스 정상 재시작: `aws autoscaling start-instance-refresh --auto-scaling-group-name billage-backend-asg-v1`
4. 헬스 체크: RDS 대신 Host MySQL 연결 성공 확인

**RTO:** 5분 (Terraform destroy + 인스턴스 헬스 복구)

**확인 방법:**
```
SELECT 1 FROM information_schema.tables LIMIT 1;  -- Host MySQL에서 실행 가능
```

#### 3.1.2 PNR 이후 (SSM이 RDS 가리킴) 롤백 - 중요함

**상황:** RDS로 전환 후, RDS 장애 발생 (e.g. 스토리지 부족, 성능 저하, 연결 불가)

**트리거:** RDS 연결 불가 > 1분 (ALB 헬스 체크 실패)

**단계적 절차:**

**Step 1: 긴급 복구 (RTO 1-2분)**
1. CloudWatch Logs 확인: RDS connection timeout 확인
2. AWS RDS 콘솔에서 RDS 상태 점검 (CPU, Storage, Connections)
3. **5분 이내 복구 가능하면:** RDS 재부팅 또는 파라미터 조정
4. **복구 불가능하면:** 즉시 다음 단계 진행

**Step 2: Host MySQL 복구 시작 (병렬 진행)**
1. SSM Parameter 수정: `/billage/prod/db/endpoint` 값을 v1 EC2 Private IP로 변경
   ```
   aws ssm put-parameter --name "/billage/prod/db/endpoint" \
     --value "10.100.10.5:3306" --overwrite
   ```
2. v1 인스턴스의 Host MySQL 상태 확인:
   ```
   ssh ec2-user@10.100.10.5
   sudo systemctl status mysql
   ```
3. MySQL이 다운되어 있으면 재시작:
   ```
   sudo systemctl start mysql
   ```

**Step 3: 앱 재시작**
1. ASG 인스턴스 refresh (Host MySQL 연결로 시작):
   ```
   aws autoscaling start-instance-refresh --auto-scaling-group-name billage-backend-asg-v2 \
     --preferences '{"MinHealthyPercentage": 50}'
   ```
2. 10분 대기 (50% 인스턴스가 Host MySQL로 재시작)

**Step 4: 데이터 동기화 검증**
1. RDS와 Host MySQL 간 데이터 비교:
   ```
   mysql -h 10.100.10.5 -e "SELECT COUNT(*) FROM users;" -- Host MySQL
   mysql -h billage-rds.xxxxx.rds.amazonaws.com -e "SELECT COUNT(*) FROM users;" -- RDS
   ```
2. **만약 행 개수 다르면:** RDS에만 신규 데이터 존재 (데이터 유실 위험)
3. **복구 전략:**
   - 옵션 A: RDS에서 신규 데이터 dump → Host MySQL로 restore (데이터 충돌 가능)
   - 옵션 B: RDS 스냅샷에서 특정 시간대 데이터 복구 (시간 소요, 안전)
   - 옵션 C: 데이터 유실 수용 후, 사용자에게 재입력 요청 (최후의 수단)

**Step 5: 최종 확인**
1. App 로그에서 DB 연결 에러 없음 확인:
   ```
   grep -i "database connection" /var/log/billage/app.log | tail -20
   ```
2. E2E 테스트 실행: 로그인, 채팅, 파일 업로드 등 기본 기능 확인

**RTO:** 10-15분 (Host MySQL 복구 + 앱 재시작 + 동기화 검증)

**확인 방법:**
```
curl -s http://ALB-DNS/api/health | jq .database_status
# 응답: {"database_status": "connected", "database_type": "host_mysql"}
```

#### 3.1.3 Host MySQL 유지 정책

**중요:** Phase 1 완료 후 2주간 Host MySQL을 실행 상태로 유지합니다.
- 이유: 데이터 검증 기간, RDS 이슈 시 신속한 복구
- 비용: t4g.medium EC2는 이미 v1 운영 중이므로 추가 비용 없음
- 2주 후: Host MySQL 전폐 (RDS 안정성 확인 후)

**Host MySQL 상태 모니터링:**
- Prometheus: `mysql_up{instance="10.100.10.5:3306"}` = 1
- CloudWatch: `/aws/ec2/billage-v1/cpu-utilization` < 20%

---

### 3.2 Phase 2: RabbitMQ 도입 (02-inmemory) 롤백

**목적:** RabbitMQ 생성, 채팅 서버의 메시지 브로커를 Redis Pub/Sub (아님) → RabbitMQ로 변경

**상황:**
- v1: 채팅은 메모리 내 메시지 큐 사용 (같은 인스턴스 내에서만 전달)
- v2: RabbitMQ로 크로스 인스턴스 채팅 지원 (At Least Once 보장)
- 현재: RabbitMQ는 신규 도입, 없어도 채팅이 부분적으로 동작 (graceful degradation)

**특징:** RabbitMQ는 메시지 브로커이므로, 장애 시 로컬 메모리 모드로 폴백 가능. 즉시 롤백할 필요 없고 graceful degradation 선택.

#### 3.2.1 RabbitMQ 생성 실패 시 롤백

**트리거:** RabbitMQ 클러스터 생성 실패, 또는 생성 후 연결 불가

**절차:**
1. Terraform 확인:
   ```
   cd /mnt/terraform/phase-02 && terraform plan -destroy -target="aws_mq_broker.billage_rabbitmq"
   ```
2. RabbitMQ 삭제 (메시지 브로커이므로 미처리 메시지는 손실, 이미 저장된 메시지는 DB에 있음):
   ```
   terraform apply -target="aws_mq_broker.billage_rabbitmq" -destroy
   ```
3. v2 앱 환경 변수에서 RabbitMQ 연결 비활성화:
   ```
   aws ssm put-parameter --name "/billage/prod/rabbitmq/enabled" --value "false" --overwrite
   ```
4. v2 인스턴스 재시작:
   ```
   aws autoscaling start-instance-refresh --auto-scaling-group-name billage-backend-asg-v2
   ```

**RTO:** 5분 (Terraform destroy + 앱 재시작)

**확인 방법:**
- 앱 로그에서 "RabbitMQ connection disabled, using in-memory mode" 메시지 확인
- 채팅 기능은 같은 인스턴스 내에서만 동작 (partial service, graceful degradation)

#### 3.2.2 RabbitMQ 연결 장애 시 롤백 (서비스 지속)

**상황:** RabbitMQ는 정상 생성, 하지만 앱에서 연결 불가 (보안그룹, 네트워크 문제)

**트리거:** Prometheus `rabbitmq_connection_errors_total` > 50/5분

**절차:**
1. **옵션 A: 네트워크 문제 해결 시도 (5분 내)**
   - v2 ASG의 보안그룹에 RabbitMQ 보안그룹 허용 규칙 추가
   - v2 서브넷이 RabbitMQ 서브넷과 같은 VPC에 있는지 확인
   - VPC 라우팅 테이블 확인

2. **옵션 B: 네트워크 복구 불가 → RabbitMQ 비활성화**
   ```
   aws ssm put-parameter --name "/billage/prod/rabbitmq/enabled" --value "false" --overwrite
   aws autoscaling start-instance-refresh --auto-scaling-group-name billage-backend-asg-v2
   ```

**RTO:** 즉시 (앱이 RabbitMQ 연결 실패를 우아하게 처리하면)

**확인 방법:**
- 채팅이 같은 인스턴스 내에서만 동작 (다른 인스턴스 사용자끼리는 실시간 채팅 불가, REST API polling으로 지연 전달)
- 에러 로그에 "RabbitMQ unavailable, using in-memory queue fallback" 메시지

#### 3.2.3 RabbitMQ 성능 저하 시 (부분 롤백 아님, 모니터링)

**상황:** RabbitMQ 메시지 처리 지연 > 5초 (채팅 지연), 하지만 연결은 정상

**트리거:** Prometheus `rabbitmq_message_latency_seconds_p95` > 5

**절차:**
1. **5분 재시작:** RabbitMQ 재부팅 (메모리 정제, 큐 플러시)
   ```
   aws mq reboot-broker --broker-id billage-rabbitmq
   ```
2. **5분 후 미복구:** 메모리 부족 검토
   - CloudWatch Metric: `AmazonMQ/BrokerCPUUtilization`, `BrokerStorageUtilization`
   - 필요 시 RabbitMQ 인스턴스 타입 업그레이드 (mq.t3.micro → mq.t3.small)
   - 큐 정리: 오래된 메시지 수동 삭제

**RTO:** 5분 (재부팅), 업그레이드 시 10-20분

**확인 방법:**
```
aws mq describe-broker --broker-id billage-rabbitmq | jq '.BrokerState'
# 응답: "RUNNING"
```

---

### 3.3 Phase 3: WAS 마이그레이션 (03-was-migration) 롤백

**목적:** v2 ASG 생성, v1과 병렬 운영 시작 (트래픽은 아직 v1 사용)

**상황:**
- v1: 기존 t4g.medium EC2에서 Spring Boot, Next.js, FastAPI 운영
- v2: ALB, 3개 ASG (Backend, Frontend, AI) 신규 생성
- 트래픽: Route 53 weight 100:0 (v1:v2) — 사용자 영향 없음

**특징:** v2는 아직 검증 단계이고, v1이 실시간 서비스 중이므로 v2 문제는 v2만 정리. 사용자 영향 제로.

#### 3.3.1 컨테이너 시작 실패 시 롤백

**트리거:** ASG 인스턴스가 Unhealthy 상태 → ALB 헬스 체크 실패

**원인 예시:**
- Docker 이미지 pull 실패 (ECR 인증 문제)
- user_data 스크립트 에러 (다운로드 실패, 문법 오류)
- 보안그룹 설정 오류 (앱이 시작되지만 ALB와 통신 불가)

**절차:**

**Step 1: 인스턴스 로그 확인 (2분)**
```
aws ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=billage-backend-asg-v2" \
  | jq '.Reservations[0].Instances[0].InstanceId'
# 받은 ID: i-0abc1234...

aws ssm start-session --target i-0abc1234
sudo tail -100 /var/log/user-data.log
```

**Step 2: user_data 문제 식별 및 수정**
- Docker pull 실패: ECR 인증 정보 확인 (`/root/.docker/config.json`)
- 스크립트 다운로드 실패: S3 버킷 접근 권한 확인 (IAM role)
- 환경 변수 미설정: SSM Parameter 값 확인

**Step 3: Launch Template 수정**
```
cd /mnt/terraform/phase-03
vim terraform.tfvars  # user_data 수정
terraform apply -target="aws_launch_template.billage_backend_v2"
```

**Step 4: Instance Refresh 재시작**
```
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-backend-asg-v2 \
  --preferences '{"MinHealthyPercentage": 50}'
```

**Step 5: 인스턴스 상태 모니터링 (5-10분)**
```
watch -n 5 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names billage-backend-asg-v2 \
  | jq ".AutoScalingGroups[0] | {Desired: .DesiredCapacity, Running: .Instances | length, Healthy: (.Instances | map(select(.HealthStatus=="Healthy")) | length)}"'
```

**RTO:** 5-10분 (Launch Template 수정 + 인스턴스 교체)

**확인 방법:**
```
curl -s http://ALB-DNS/api/health | jq .
# 응답: {"status": "ok", "service": "billage-backend-v2"}
```

#### 3.3.2 Instance Refresh 실패 시 롤백

**상황:** Instance Refresh 진행 중, 인스턴스 재시작 후 문제 발생

**트리거:** Refresh 중단, 일부 인스턴스만 교체됨, 나머지는 old Launch Template 유지

**절차:**
1. 현재 Refresh 상태 확인:
   ```
   aws autoscaling describe-instance-refresh \
     --auto-scaling-group-name billage-backend-asg-v2
   ```

2. Refresh 취소 (old 버전 유지, 교체 중단):
   ```
   aws autoscaling cancel-instance-refresh \
     --auto-scaling-group-name billage-backend-asg-v2
   ```

3. 문제 원인 파악 및 Launch Template 수정 (Step 3 참조)

4. Refresh 재시작:
   ```
   aws autoscaling start-instance-refresh \
     --auto-scaling-group-name billage-backend-asg-v2
   ```

**RTO:** 10분 (Refresh 취소 + 문제 수정 + 재시작)

**확인 방법:**
- 모든 인스턴스가 new Launch Template 사용 중:
  ```
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names billage-backend-asg-v2 \
    | jq '.AutoScalingGroups[0].Instances[].LaunchTemplate'
  ```

#### 3.3.3 v2 문제 시 v1으로 전체 롤백 (극단적 상황)

**상황:** v2 여러 컴포넌트가 동시에 실패, 원인 파악 어려움

**트리거:** v2 에러율 > 10%, 응답시간 p95 > 3초 (v1과 비교 5배 느림)

**절차:**
1. Route 53 weight 즉시 복구 (트래픽 v1로 100% 전환):
   ```
   aws route53 change-resource-record-sets --hosted-zone-id Z0123456789ABC \
     --change-batch '{
       "Changes": [{
         "Action": "UPSERT",
         "ResourceRecordSet": {
           "Name": "dev.billages.com",
           "Type": "A",
           "SetIdentifier": "v1",
           "Weight": 100,
           "TTL": 60,
           "AliasTarget": {
             "HostedZoneId": "Z0987654321XYZ",
             "DNSName": "billage-ec2-v1.compute.amazonaws.com",
             "EvaluateTargetHealth": true
           }
         }
       }, {
         "Action": "UPSERT",
         "ResourceRecordSet": {
           "Name": "dev.billages.com",
           "Type": "A",
           "SetIdentifier": "v2",
           "Weight": 0,
           "TTL": 60,
           "AliasTarget": {
             "HostedZoneId": "Z0987654321XYZ",
             "DNSName": "billage-alb-v2.us-east-1.elb.amazonaws.com",
             "EvaluateTargetHealth": true
           }
         }
       }]
     }'
   ```
   또는 Terraform:
   ```
   cd /mnt/terraform/phase-05 && terraform apply -var="v1_weight=100" -var="v2_weight=0"
   ```

2. v2 ASG 정리 (비용 절감, 검증 재시작):
   ```
   cd /mnt/terraform/phase-03 && terraform destroy
   ```

3. v1 상태 확인:
   ```
   curl -s http://dev.billages.com/api/health | jq .
   ```

**RTO:** 1-5분 (Route 53 weight 변경 + DNS 캐시 갱신)

**확인 방법:**
- Prometheus: `billage_requests_v1` 급증, `billage_requests_v2` 0으로 떨어짐
- Grafana: "Billage Migration Dashboard" → v1 트래픽 100%

#### 3.3.4 단일 인스턴스 장애 (롤백 불필요)

**상황:** v2 ASG의 단일 인스턴스가 Unhealthy

**트리거:** CloudWatch Alarm "billage-backend-asg-v2-UnhealthyHostCount > 0"

**조치:** 아무것도 하지 않음. ASG가 자동으로 새 인스턴스 시작 (3-5분).

**모니터링:**
```
watch -n 5 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names billage-backend-asg-v2 \
  | jq ".AutoScalingGroups[0].Instances | map({id: .InstanceId, health: .HealthStatus})"'
```

---

### 3.4 Phase 4: 채팅 서버 마이그레이션 (04-chat-migration) 롤백

**목적:** 채팅 기능을 v2로 마이그레이션, RabbitMQ 사용

**상황:**
- v1: 채팅은 메모리 기반, 같은 인스턴스 내에서만 메시지 전달
- v2: WebSocket + RabbitMQ (STOMP Relay), 크로스 인스턴스 채팅 지원
- 트래픽: v1 사용 중, v2는 테스트 단계

**특징:** 채팅은 비즈니스 크리티컬이지만 수동으로 recovery 가능 (메시지 재입력). 우아한 성능 저하(graceful degradation)를 선호.

#### 3.4.1 WebSocket 연결 장애 시 (자동 재연결)

**상황:** v2 채팅 서버의 WebSocket 포트(8765)가 응답 안 함

**트리거:** Prometheus `websocket_connections_failed_total` > 50/5분

**절차:**

**옵션 A: 자동 재연결 (1-10초, 사용자는 인지하지 못함)**
- 클라이언트는 자동으로 다른 인스턴스로 재연결 시도
- 앱 설정: `ws.reconnect.enabled=true`, `ws.reconnect.max_attempts=3`
- 예상 복구: 10초 이내

**옵션 B: 수동 인스턴스 재시작 (30초)**
```
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-chat-asg-v2 \
  --preferences '{"MinHealthyPercentage": 50}'
```

**옵션 C: WebSocket 폴링으로 폴백 (60초, UX 저하)**
1. 앱 환경 변수 변경:
   ```
   aws ssm put-parameter --name "/billage/prod/chat/use_websocket" \
     --value "false" --overwrite
   ```
2. 앱은 REST API polling 사용 (5초 주기)
3. 앱 재시작:
   ```
   aws autoscaling start-instance-refresh \
     --auto-scaling-group-name billage-chat-asg-v2
   ```

**RTO:** 10초 (자동 재연결) 또는 1분 (수동 조치)

**확인 방법:**
```
curl -i ws://ALB-DNS/chat/ws
# 응답: 101 Switching Protocols
```

#### 3.4.2 RabbitMQ 장애 시 (Graceful Degradation)

**상황:** RabbitMQ 연결은 정상, 하지만 메시지 전달 실패

**트리거:** Prometheus `rabbitmq_connection_errors_total` > 10/5분, 또는 `rabbitmq_message_latency_seconds_p95` > 5초

**절차:**

**Step 1: RabbitMQ 상태 확인 (1분)**
```
aws mq describe-broker --broker-id billage-rabbitmq \
  | jq '.BrokerState'
```

**Step 2: 메시지 지연 시 RabbitMQ 재시작**
```
aws mq reboot-broker --broker-id billage-rabbitmq
```
(메모리 정제, 메시지 큐 플러시)

**Step 3: 5분 후 미복구 시 RabbitMQ 비활성화**
```
aws ssm put-parameter --name "/billage/prod/rabbitmq/enabled" \
  --value "false" --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name billage-chat-asg-v2
```

**Graceful Degradation 동작:**
- 각 인스턴스는 로컬 메모리에서만 메시지 전달
- 같은 인스턴스 사용자끼리만 실시간 채팅 가능
- 다른 인스턴스 사용자끼리는 REST API polling으로 전달 (지연)

**RTO:** 5분 (RabbitMQ 재시작) 또는 10분 (RabbitMQ 비활성화 + 앱 재시작)

**확인 방법:**
- Prometheus `chat_degradation_mode` = 1 (활성화)
- 로그: "Chat degradation mode enabled, using in-memory queue"

#### 3.4.3 채팅 전체 불가 시 (최후의 수단)

**상황:** WebSocket, Redis, 로컬 메모리 모두 장애

**트리거:** 사용자가 채팅 메시지 전송 불가 (모든 채팅 기능 비작동)

**절차:**

**Step 1: v1 채팅 기능 재활성화**
```
aws ssm put-parameter --name "/billage/prod/chat/enabled" \
  --value "v1_only" --overwrite
```

**Step 2: v2 채팅 서버 중지**
```
cd /mnt/terraform/phase-04 && terraform destroy -target="aws_autoscaling_group.chat_asg_v2"
```

**Step 3: 클라이언트가 v1 채팅으로 재연결**
- 같은 인스턴스 내에서만 실시간 채팅 가능
- 다른 인스턴스 사용자끼리는 메시지 지연

**RTO:** 2-3분 (v1 재활성화 + 클라이언트 재연결)

**확인 방법:**
```
curl -s http://dev.billages.com/api/chat/status | jq .mode
# 응답: "v1_only"
```

---

### 3.5 Phase 5: 로드 밸런서 & 트래픽 전환 (05-lb-traffic-migration) 롤백

**목적:** Route 53 weighted routing을 이용해 단계적으로 트래픽을 v2로 전환

**상황:**
- 초기: v1=100%, v2=0%
- Stage 1: v1=95%, v2=5% (5% 트래픽만 v2로 전달)
- Stage 2: v1=50%, v2=50%
- Stage 3: v1=0%, v2=100% (전체 전환)
- 각 Stage 사이에 4-24시간 모니터링

**특징:** Route 53 weight 변경은 즉시 적용, DNS TTL 60초이므로 1-5분 내 대부분 사용자가 전환됨.

#### 3.5.1 Stage 1 (5% 트래픽) 롤백

**상황:** v2로 5% 트래픽 전달 후, 문제 발생

**트리거:** v2 에러율 > 1% (v1 에러율 0.1%보다 10배), 응답시간 v2 p95 > 1초 (v1 p95 100ms)

**절차:**

**즉시 트래픽 v1로 복귀:**
```
cd /mnt/terraform/phase-05
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```
또는 AWS Console:
```
aws route53 change-resource-record-sets --hosted-zone-id Z0123456789ABC \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "dev.billages.com",
        "Type": "A",
        "SetIdentifier": "v1",
        "Weight": 100,
        "TTL": 60,
        "AliasTarget": {...}
      }
    }, {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "dev.billages.com",
        "Type": "A",
        "SetIdentifier": "v2",
        "Weight": 0,
        "TTL": 60,
        "AliasTarget": {...}
      }
    }]
  }'
```

**RTO:** 1-5분 (DNS 캐시 갱신)

**확인 방법:**
```
# 명령어: DNS 질의 후 v1 응답만 받는지 확인
dig dev.billages.com +short
# 응답: 10.100.10.5 (v1 EC2 private IP)

# Prometheus: v2 트래픽 급락
prometheus_query "rate(billage_requests_v2[1m])" # → 0 요청/초
```

**문제 분석 (병렬 진행, 롤백과 동시):**
1. v2 로그 수집: `Loki → service=billage-v2`
2. v2 메트릭 분석: `Grafana → Billage v2 Dashboard`
3. 에러 패턴 식별: "어떤 엔드포인트에서 실패하는가?"

#### 3.5.2 Stage 2 (50% 트래픽) 롤백

**상황:** v1/v2 50:50 운영 중, v2 장애 감지

**트리거:** 5분 내 에러율 급증, 응답시간 저하

**절차:**

**옵션 A: v1로 완전 복귀 (빠름)**
```
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```
**RTO:** 1-5분 | **사용자 영향:** 중간 (50% 사용자가 v1로 이동 시 트래픽 급증 가능)

**옵션 B: v1으로 단계적 복귀 (안전)**
```
# Step 1: v1=75%, v2=25%
terraform apply -var="v1_weight=75" -var="v2_weight=25"

# 3분 대기, 메트릭 모니터링

# Step 2: v1=100%, v2=0%
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```
**RTO:** 6-10분 | **사용자 영향:** 낮음 (점진적 전환)

**선택 기준:**
- 에러율 > 5%: 옵션 A (즉시 복귀)
- 에러율 1-5%: 옵션 B (안전한 복귀)

**RTO:** 1-10분

**확인 방법:**
```
prometheus_query "rate(billage_requests{version='v1'}[1m])"
# 응답: 1000 요청/초 (v1 100% 시)
```

#### 3.5.3 Stage 3 (100% 트래픽) 롤백

**상황:** v1=0%, v2=100% (완전 전환 후), v2 심각한 장애

**트리거:** 모든 사용자가 v2 영향 (에러율 > 10%, 응답시간 > 5초)

**절차:**

**Step 1: 즉시 v1로 복귀 (5초 이내 결정)**
```
cd /mnt/terraform/phase-05
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```

**Step 2: v2 ASG 중지 (선택, 비용 절감)**
```
cd /mnt/terraform/phase-03
terraform apply -target="aws_autoscaling_group.backend_asg_v2" \
  -var="desired_capacity=0"
```

**Step 3: 인시던트 대응**
- CTO 통보: "v2 완전 장애, v1로 롤백 완료"
- Slack #billage-incident: 상황 공지
- 포스트모템: 2시간 내 시작

**RTO:** 1-5분 (Route 53 전환)

**확인 방법:**
```
prometheus_query "rate(billage_requests_v1[1m])"
# 응답: 모든 트래픽이 v1로
```

#### 3.5.4 ALB 장애 (v2 불가, Route 53만 사용)

**상황:** ALB 자체 장애 (AWS 인프라 이슈), v2 인스턴스는 정상이지만 ALB가 응답 안 함

**트리거:** CloudWatch Alarm "ALB TargetResponseTime > 30초" + "HTTP 503 > 90%"

**절차:**

**옵션 A: ALB 재생성 (10-15분)**
```
cd /mnt/terraform/phase-05
terraform destroy -target="aws_lb.billage_alb_v2"
terraform apply -target="aws_lb.billage_alb_v2"
```

**옵션 B: Route 53 v1로 완전 복귀 (즉시)**
```
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```
(ALB 복구 대기 중에 v1에서 서비스)

**RTO:** 옵션 B는 1-5분, 옵션 A는 10-15분

**선택:** 대부분 옵션 B (빠른 복구) → 병렬로 옵션 A 진행

---

### 3.6 Phase 6: 모니터링 전환 (06-monitoring) 롤백

**목적:** Prometheus, Grafana, Loki를 Management VPC에서 운영, 모든 메트릭 수집

**상황:**
- v1 모니터링: CloudWatch만 사용
- v2 모니터링: Prometheus + Grafana + Loki 신규 도입
- 현재: 두 시스템 병렬 운영

**특징:** 모니터링 장애는 **서비스 장애가 아님**. 사용자는 영향받지 않음. 대체 수단 사용.

#### 3.6.1 Prometheus 다운

**상황:** Prometheus 서버 (Management VPC의 EC2) 다운, 메트릭 수집 중단

**트리거:** "Prometheus up" 상태 1분 이상 = 0

**절차:**

**Step 1: Prometheus 재시작 (1분)**
```
ssh -i /path/to/key.pem ec2-user@management-vpc-prometheus-ip
sudo systemctl restart prometheus
sudo systemctl status prometheus
```

**Step 2: 5분 내 미복구 시 CloudWatch로 대체**
- Prometheus가 중단되어도 v1/v2 앱은 여전히 CloudWatch로 메트릭 전송
- CloudWatch Console에서 메트릭 확인 가능
- Grafana 대신 CloudWatch Dashboard 사용

**RTO:** 1분 (재시작) 또는 즉시 (CloudWatch 대체)

**확인 방법:**
```
prometheus_query "up{job='prometheus'}"
# 응답: 1 (정상)

# 또는 CloudWatch Console
# → Metrics → Custom Namespaces → Billage
```

#### 3.6.2 Grafana 다운

**상황:** Grafana 대시보드 UI 접근 불가, 하지만 Prometheus 데이터는 정상

**트리거:** `curl https://grafana.billage.internal/api/health` 실패

**절차:**

**옵션 A: Grafana 재시작 (1분)**
```
ssh -i /path/to/key.pem ec2-user@management-vpc-grafana-ip
sudo systemctl restart grafana-server
sudo systemctl status grafana-server
```

**옵션 B: Prometheus API 직접 조회**
```
curl -s 'http://prometheus-ip:9090/api/v1/query?query=rate(billage_requests[5m])' | jq .
```

**옵션 C: CloudWatch Console 사용**

**RTO:** 1분 (재시작) 또는 즉시 (API 직접 조회)

#### 3.6.3 Loki 다운 (로그 수집 중단)

**상황:** Loki (로그 저장소) 다운, 신규 로그가 저장되지 않음

**트리거:** `curl http://loki-ip:3100/ready` 실패

**절차:**

**옵션 A: Loki 재시작 (2분)**
```
ssh -i /path/to/key.pem ec2-user@management-vpc-loki-ip
sudo systemctl restart loki
```

**옵션 B: 인스턴스 로그 직접 확인**
```
# v2 인스턴스에 SSH 접속
ssh -i /path/to/key.pem ec2-user@v2-instance-ip
sudo tail -100 /var/log/billage/app.log
sudo journalctl -u docker -n 50
```

**옵션 C: CloudWatch Logs (앱에서 동시 전송 중인 경우)**
```
aws logs tail /aws/billage/backend --follow
```

**RTO:** 2분 (Loki 재시작) 또는 즉시 (로그 직접 확인)

#### 3.6.4 모니터링 단계적 비활성화 (권장되지 않음)

**상황:** Management VPC 전체 장애, Prometheus/Grafana/Loki 모두 불가

**절차:**
1. CloudWatch만 사용 (기본 제공)
2. v1/v2 앱의 로그를 CloudWatch Logs로 전송 (이미 설정되어 있음)
3. EC2 인스턴스 직접 SSH 접속해 로그 확인

**RTO:** 즉시 (대체 수단 사용)

---

## 4. 복합 장애 시나리오 (여러 컴포넌트 동시 장애) - 300K MAU 기준

실제 인시던트는 단일 컴포넌트 장애보다 여러 컴포넌트가 동시에 장애나는 경우가 많습니다. 300K MAU 규모 (900 RPS, ~1000 DAU)에서 우선순위를 파악하고 단계적으로 대응해야 합니다.

### 4.1 시나리오 A: v2 ASG + RDS 동시 장애 (300K MAU 기준)

**상황:** v2 인스턴스 교체 중에 RDS가 다운 (동시성 재수 없음)

**증상:**
- v2 인스턴스 시작 후 DB 연결 실패 (최대 6개 백엔드 인스턴스)
- ALB 헬스 체크 실패, 모든 v2 인스턴스 Unhealthy
- v1은 정상 (Host MySQL 사용)
- 사용자: 모두 v1으로 자동 라우팅 (Route 53 weighted routing 덕분)
- 영향: 900 RPS 트래픽이 v1로 집중 → v1 로드 증가 (통상 800-900 RPS → 1500+ RPS 가능)

**우선순위:** RDS 복구 > v2 정리

**절차:**

**Step 1: RDS 긴급 상태 확인 (1분)**
```
aws rds describe-db-instances --db-instance-identifier billage-rds | jq '.DBInstances[0] | {Status: .DBInstanceStatus, Endpoint: .Endpoint, EngineVersion: .EngineVersion}'
```

**Step 2: RDS 복구 시도**
- RDS 상태가 "rebooting"이면 복구 대기 (3-5분)
- RDS 상태가 "available"이지만 연결 불가면:
  - 보안그룹 규칙 확인 (포트 3306 열려있는가?)
  - v2 서브넷 라우팅 확인
  - RDS 모니터링: CPU/메모리/연결 수

**Step 3: 5분 내 미복구 시 Host MySQL로 앱 복구**
```
aws ssm put-parameter --name "/billage/prod/db/endpoint" \
  --value "10.100.10.5:3306" --overwrite
```

**Step 4: v2 인스턴스 정리 (선택)**
```
cd /mnt/terraform/phase-03
terraform apply -var="desired_capacity=0"
```

**Step 5: RDS 복구 후 v2 재시작**
- RDS 복구 완료 확인
- 데이터 동기화 검증 (Host MySQL vs RDS)
- v2 인스턴스 재시작

**RTO:** 5-15분 (RDS 복구 대기 + Host MySQL 복원)

**사용자 영향:** 없음 (v1이 정상 운영 중)

### 4.2 시나리오 B: Redis + WebSocket 동시 장애 (300K MAU 기준)

**상황:** Redis와 WebSocket 동시 장애, 채팅 전체 불가

**증상:**
- Redis 연결 불가 (250-300개 활성 채팅방)
- WebSocket 연결 불가 (최대 300-500 동시 연결)
- 채팅 기능 0% 가용성 (채팅만 영향, 다른 API는 정상)

**우선순위:** WebSocket 자동 재연결 (클라이언트) > Redis 복구 > 폴링 모드 전환

**절차:**

**Step 1: WebSocket 재연결 대기 (10초)**
- 클라이언트는 자동으로 다른 인스턴스로 재연결 시도
- 어느 순간 성공할 때까지 대기

**Step 2: Redis 상태 확인 (1분)**
```
aws elasticache describe-cache-clusters --cache-cluster-id billage-redis-001 | jq '.CacheClusters[0].CacheClusterStatus'
```

**Step 3: Redis 재부팅**
```
aws elasticache reboot-cache-cluster --cache-cluster-id billage-redis-001
```

**Step 4: 5분 후 미복구 시 폴링 모드로 전환**
```
aws ssm put-parameter --name "/billage/prod/chat/use_websocket" --value "false" --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name billage-chat-asg-v2
```

**RTO:** 10초 (자동 재연결) + 5분 (Redis 복구) = 5-10분

### 4.3 시나리오 C: ALB + v2 인스턴스 동시 장애 (300K MAU 기준)

**상황:** ALB가 자체 장애 (AWS 인프라), 동시에 v2 인스턴스도 비정상

**증상:**
- ALB DNS 응답 불가 또는 응답 시간 > 30초
- v2 인스턴스 건강하지 않음 (최대 6개 백엔드 모두 영향)
- Route 53 weighted routing이 v2로 라우팅하려 하지만 도달 불가 (900 RPS 손실)

**우선순위:** Route 53을 v1로 복귀 > ALB 복구

**절차:**

**Step 1: 즉시 Route 53 v1로 복귀**
```
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```

**Step 2: ALB 상태 확인**
```
aws elbv2 describe-load-balancers --names billage-alb-v2 | jq '.LoadBalancers[0].State'
```

**Step 3: ALB 재생성 (병렬로 진행, 대기 X)**
```
cd /mnt/terraform/phase-05
terraform destroy -target="aws_lb.billage_alb_v2"
terraform apply -target="aws_lb.billage_alb_v2"
```
(10-15분 소요)

**Step 4: ALB 복구 후 Route 53 v2로 복귀**
```
terraform apply -var="v1_weight=0" -var="v2_weight=100"
```

**RTO:** 1-5분 (Route 53 복귀) + 10-15분 (ALB 복구)

### 4.4 시나리오 D: Route 53 장애 (가장 심각)

**상황:** Route 53 자체 장애 (DNS 응답 불가), AWS 리전 레벨 장애 가능성

**증상:**
- `dig dev.billages.com` 응답 없음
- 모든 사용자가 dev.billages.com에 접근 불가

**원인:**
- AWS Route 53 서비스 장애 (매우 드문, AWS SLA 문제)
- 도메인 등록 기관 장애
- 로컬 DNS resolver 문제

**대응 제한:** Route 53 자체가 AWS 서비스이므로 사용자는 대응 불가. AWS 상태 대시보드 확인 및 대기만 가능.

**절차:**

**Step 1: 상태 확인**
- AWS Status Page: https://status.aws.amazon.com/
- 로컬 DNS 테스트: `nslookup dev.billages.com 8.8.8.8` (Google DNS 사용)

**Step 2: 임시 우회 방법 (사용자):**
- 클라이언트가 IP 주소 직접 사용 (`curl http://10.100.10.5/api/...`)
- 모바일 앱에서 API 엔드포인트를 IP로 변경

**Step 3: AWS 복구 대기**

**RTO:** AWS에 의존, 예상 15-30분 (SLA 기준)

**예방:**
- 초기 DNS TTL 60초로 설정하여 캐시 최소화
- 클라이언트 측에서 Route 53 실패 시 폴백 IP 주소 사용 가능하도록 설정

---

## 5. 롤백 실행 체크리스트 (인쇄 가능)

**인시던트 발생 시 이 체크리스트를 인쇄해 옆에 두고 따릅니다.**

### 5.1 Step 0: 장애 확인 (무엇이, 언제, 영향 범위)

- [ ] **무엇이:** 어떤 컴포넌트가 장애인가?
  - [ ] 데이터베이스 (RDS/Host MySQL)
  - [ ] 캐시 (Redis)
  - [ ] 앱 서버 (v1/v2 인스턴스)
  - [ ] 로드 밸런서 (ALB)
  - [ ] DNS (Route 53)
  - [ ] 모니터링 (Prometheus/Grafana/Loki)

- [ ] **언제:** 장애가 시작된 시각
  - [ ] 감지 시각 (alert 발생): ____시 ____분
  - [ ] 실제 장애 시작 (추정): ____시 ____분

- [ ] **영향 범위:** 몇 명의 사용자가 영향받는가? (300K MAU 기준: ~1000 DAU, 900 RPS)
  - [ ] 에러율: ____% (정상: < 0.1%, 임계: > 5%)
  - [ ] 응답시간 p95: ____ms (정상: < 200ms, 임계: > 2000ms)
  - [ ] 영향받는 기능: 전체 / 채팅만 (250-300개 방) / 특정 엔드포인트만
  - [ ] 영향받는 사용자 수 (추정): ____명 (총 DAU: ~1000명, 동시 접속: ~500명)

### 5.2 Step 1: 즉시 조치 필요? (판단 기준)

**YES라면 Step 2로 바로 이동. NO라면 5분 대기 후 재평가.**

| 조건 | 즉시 조치? |
|------|----------|
| 에러율 > 5% (3분 지속) | **YES** |
| 응답시간 p95 > 2초 | 재시작 시도, 5분 내 미복구면 YES |
| RDS 연결 불가 (모든 쿼리) | **YES** |
| 모든 인스턴스 Unhealthy | **YES** |
| 채팅만 오류, 타 기능 정상 | NO (5분 대기) |
| 메모리 누수 의심 | NO (5분 대기, 재시작 시도) |

- [ ] 즉시 롤백 필요: **YES / NO**

### 5.3 Step 2: 해당 Phase 롤백 절차 실행

- [ ] Phase 1 (DB): [섹션 3.1 참조](#311-pnr-이전-ssm-아직-host-mysql-가리킴-롤백)
- [ ] Phase 2 (Redis): [섹션 3.2 참조](#321-redis-생성-실패-시-롤백)
- [ ] Phase 3 (WAS): [섹션 3.3 참조](#331-컨테이너-시작-실패-시-롤백)
- [ ] Phase 4 (채팅): [섹션 3.4 참조](#341-websocket-연결-장애-시-자동-재연결)
- [ ] Phase 5 (LB): [섹션 3.5 참조](#351-stage-1-5-트래픽-롤백)
- [ ] Phase 6 (모니터링): [섹션 3.6 참조](#361-prometheus-다운)

**실행 시각:** ____시 ____분

### 5.4 Step 3: 롤백 완료 확인

**롤백 명령어 실행 후 5분 내에 확인:**

- [ ] 헬스 체크 통과
  ```
  curl -s http://dev.billages.com/api/health | jq .status
  # 예상: "ok"
  ```

- [ ] 에러율 정상화
  ```
  # Prometheus 확인
  rate(billage_errors_total[5m]) < 0.1%
  ```

- [ ] 응답시간 정상화
  ```
  # Prometheus 확인
  billage_request_duration_seconds{quantile="0.95"} < 0.2
  ```

- [ ] E2E 테스트
  - [ ] 로그인 가능?
  - [ ] 채팅 가능?
  - [ ] 파일 업로드 가능?

**롤백 완료 확인 시각:** ____시 ____분

### 5.5 Step 4: 원인 분석 (병렬 진행, 대기 X)

롤백과 동시에 진행:

- [ ] 로그 수집
  ```
  Loki: service=billage-v2, 장애 시간대 로그 확인
  ```

- [ ] 메트릭 분석
  ```
  Grafana: 해당 시간대 그래프 저장 (나중에 포스트모템용)
  ```

- [ ] 에러 패턴 식별
  - [ ] 어떤 엔드포인트에서 실패?
  - [ ] 어떤 에러 메시지?
  - [ ] 언제부터 시작?

**원인 분석 완료 시각:** ____시 ____분

### 5.6 Step 5: 포스트모템 작성

**2시간 내에 회의 시작, 48시간 내에 완료:**

[섹션 7 (포스트모템 템플릿) 참조](#7-포스트모템-템플릿)

- [ ] 회의 일정: ____년 ____월 ____일 ____시
- [ ] 참석자: CTO, DevOps Lead, 해당 엔지니어, 테스트 엔지니어
- [ ] 포스트모템 문서: (링크)

### 5.7 Step 6: 수정 후 재시도 계획

**포스트모템 완료 후 24시간 내 수정사항 결정:**

- [ ] 근본 원인 수정 필요?
  - [ ] Code 버그 수정
  - [ ] 인프라 설정 수정
  - [ ] 모니터링 추가

- [ ] 수정 예정 시각: ____년 ____월 ____일
- [ ] 검증: Dev 환경에서 충분히 테스트?
- [ ] v2 Phase부터 재시작 또는 특정 Phase부터 재시작?

---

## 6. 롤백 리허설 계획

**이론보다 실습이 중요합니다. 최소 1회 리허설을 모든 Phase에서 진행합니다.**

### 6.1 리허설 항목

각 Phase별로 Dev 환경에서 다음을 리허설합니다:

| Phase | 리허설 항목 | 소요 시간 | 담당자 |
|-------|----------|---------|-------|
| 1 (DB) | Host MySQL ↔ RDS 전환, 데이터 동기화 검증 | 30분 | DevOps Lead |
| 2 (RabbitMQ) | RabbitMQ 생성/삭제, 앱 재시작 | 15분 | 백엔드 엔지니어 |
| 3 (WAS) | ASG 생성/삭제, Instance Refresh 취소 | 20분 | DevOps Lead |
| 4 (채팅) | WebSocket 재연결, RabbitMQ 폴링 전환 | 20분 | 채팅 서버 엔지니어 |
| 5 (LB) | Route 53 weight 변경, DNS 캐시 갱신 확인 | 15분 | DevOps Lead |
| 6 (모니터링) | Prometheus/Grafana/Loki 다운, 대체 수단 사용 | 15분 | 인프라 엔지니어 |

### 6.2 리허설 결과 기록

**리허설 후 다음을 기록:**

```
리허설 일시: ____년 ____월 ____일
Phase: [1/2/3/4/5/6]
담당자: ____
소요 시간: ____분 (예상: ____분)

체크리스트:
- [ ] 롤백 명령어 모두 정상 실행
- [ ] 예상 시간 내 완료
- [ ] 헬스 체크 통과
- [ ] 데이터 무결성 유지 (DB 롤백의 경우)
- [ ] 문서에서 누락된 사항 없음

발견사항:
- 명령어 수정 필요 사항: ____
- 시간 예상 오류: ____
- 운영 난관: ____
- 문서 보완 필요: ____

다음 리허설 예정:
- Phase [X]: ____년 ____월 ____일
```

### 6.3 리허설 스케줄 (권장)

- **Phase 1 (DB):** 마이그레이션 1주 전 1회, 마이그레이션 후 1회
- **Phase 2 (Redis):** 배포 2주 전 1회, 배포 후 1회
- **Phase 3 (WAS):** 배포 3주 전 1회, 배포 후 1회
- **Phase 4 (채팅):** 배포 2주 전 1회, 배포 후 1회
- **Phase 5 (LB):** 배포 1주 전 2회 (Stage별), 배포 후 1회
- **Phase 6 (모니터링):** 배포 2주 전 1회, 배포 후 1회

---

## 7. 포스트모템 템플릿

**인시던트가 발생했을 때 48시간 내에 이 템플릿을 작성합니다. 회고와 학습 문화를 장려합니다.**

### 7.1 포스트모템 헤더

```
인시던트 ID: INC-2025-001
발생 시각: 2025-02-15 14:30:00 UTC+9
감지 시각: 2025-02-15 14:32:00 UTC+9 (감지 지연: 2분)
복구 시각: 2025-02-15 14:47:00 UTC+9 (복구 시간: 17분)
영향 범위: 전체 사용자 (1000명), 모든 기능

심각도: [P1 / P2 / P3]
- P1: 서비스 완전 중단, 데이터 손실 위험
- P2: 주요 기능 일부 불가, 수동 복구 필요
- P3: 부분 기능 저하, 사용자 우회 가능

타임라인 (분 단위):
```

### 7.2 타임라인 (MTTD, MTTR, 단계별 기록)

```
14:30 - RDS 스토리지 부족으로 인해 쓰기 쿼리 실패 시작
14:32 - CloudWatch Alert "RDS FreeStorageSpace < 100MB" 발생
14:33 - DevOps 엔지니어 (@on-call) Slack 알림 받음, 대응 시작
14:35 - RDS 콘솔 확인, 스토리지 부족 확인
14:37 - RDS Auto-scaling 불활성화 발견 (이전 설정 오류)
14:39 - SSM Parameter를 Host MySQL로 변경 (병렬로 RDS 용량 증대)
14:42 - 앱 인스턴스 재시작 시작
14:47 - 모든 인스턴스가 Host MySQL로 정상 연결 확인
14:50 - RDS 스토리지 300GB로 증대 완료
15:00 - E2E 테스트 통과, 모든 기능 정상 확인
```

### 7.3 영향 범위 상세

```
영향 받은 기능:
- API 응답: 100% 실패 (모든 쿼리가 데이터베이스 접근)
- 채팅: 부분 장애 (same-instance 메시지만 전달)
- 파일 업로드: 완전 장애
- 사용자 로그인: 완전 장애

영향 받은 사용자:
- 온라인 사용자: ~200명 (즉시 영향)
- 오프라인 모바일 사용자: 재접속 시 영향

데이터 손실:
- 없음 (Host MySQL로 롤백하여 데이터 유지)
- RDS에만 저장된 신규 데이터: 없음 (RDS와 Host MySQL이 동기 상태였음)

재정적 영향:
- 예상 매출 손실: $XXXX (17분 × 사용자 당 평균 거래액)
- 고객 신뢰도: 영향 있음 (사과 이메일 필요)
```

### 7.4 근본 원인 분석 (RCA)

```
직접 원인:
- RDS 스토리지가 자동 확장되지 않아 100% 도달
- RDS Auto-scaling 설정이 비활성화된 상태로 방치됨

근본 원인:
1. 설정 오류: Terraform 구성에서 RDS auto-scaling이 기본값 false로 설정
2. 리뷰 부실: Code Review 시 auto-scaling 설정 누락 감지 실패
3. 모니터링 미흡: RDS FreeStorageSpace가 점진적으로 감소하는데 사전 알림 없음

기여 요인:
- RDS 초기 용량 100GB가 부족했음 (Dev 환경 기준으로 계획)
- 모니터링이 P3 기능으로 평가되어 낮은 우선순위로 배포
- 온콜 엔지니어가 RDS 롤백 절차를 미숙해서 대응에 17분 소요
```

### 7.5 타이밍 분석

```
MTTD (Mean Time To Detect): 2분
- Alert 트리거 기준: RDS 스토리지 < 100MB
- 개선 방안: 스토리지 < 500MB 시 Early Alert 추가

MTTR (Mean Time To Recovery): 15분
- 실제 조치: 2분 (Host MySQL 변경)
- 검증 시간: 3분 (앱 재시작 및 헬스 체크)
- 추가 시간: 10분 (온콜이 절차 숙지 미흡해서 낭비)
- 개선 방안: 온콜 리허설 강화

총 영향 시간: 17분
- 목표: < 5분 (대응 즉시 시작 가정)
- 현실적 목표: < 10분 (온콜 반응 지연 2분 + 대응 5분 + 검증 3분 포함)
```

### 7.6 재발 방지 조치

**이 섹션이 가장 중요합니다. 같은 장애가 다시 발생하지 않도록 합니다.**

| 번호 | 조치 | 우선순위 | 담당자 | 예정일 |
|------|------|---------|-------|--------|
| 1 | RDS auto-scaling 활성화 (200GB → 1000GB max) | P0 | DevOps | 2025-02-16 |
| 2 | 스토리지 < 500MB 시 P1 Alert 추가 | P0 | 인프라 | 2025-02-16 |
| 3 | 온콜 리허설: Phase 1 DB 롤백 절차 (30분) | P1 | DevOps Lead | 2025-02-17 |
| 4 | Terraform 검증: auto-scaling 필드 필수화 | P1 | 아키텍트 | 2025-02-20 |
| 5 | Code Review checklist에 인프라 설정 항목 추가 | P2 | QA | 2025-02-21 |

### 7.7 교훈 및 학습

```
팀 차원의 학습:
1. 모니터링은 "나중에 추가"하는 부가 기능이 아니라 핵심 인프라다.
   → 향후 모든 배포에서 모니터링을 필수 항목으로 포함한다.

2. 온콜 엔지니어는 실제 상황에서 대응할 때만 배우는 게 아니라,
   사전 리허설을 통해 숙련도를 높여야 한다.
   → 월 1회 롤백 리허설을 의무화한다.

3. 자동화는 런타임(runtime)만이 아니라 리커버리(recovery)에도 필수다.
   → Host MySQL ↔ RDS 전환을 자동화할 필요 있음 (Lambda 함수).

문화 차원의 개선:
1. 포스트모템은 "누구 탓인가"가 아니라 "시스템 탓"이다.
   → 개인 비난 없이 프로세스 개선에 집중한다.

2. 장애 대응 경험은 팀의 자산이다.
   → 이 포스트모템을 런북과 함께 공유하고 정기적으로 리뷰한다.

3. "충분한 인프라"는 "최소한의 인프라"가 아니다.
   → 피크 트래픽의 2배 이상의 여유 용량을 항상 준비한다.
```

### 7.8 포스트모템 회의 기록

```
회의 일시: 2025-02-15 16:00-17:00 UTC+9
참석자:
- @cto (최고 기술 책임자)
- @devops-lead (DevOps 리더)
- @oncall (대응 엔지니어)
- @backend-lead (백엔드 팀 리더)
- @qa-lead (QA 리더)

논의 사항:
1. 근본 원인이 "설정 오류"라는 것이 확실한가? → YES, Terraform 구성 확인
2. 왜 리뷰 단계에서 놓쳤나? → Code Review 체크리스트에 인프라 설정 항목 없었음
3. 재발 방지를 위해 즉시 무엇을 해야 하는가? → auto-scaling 활성화 (1시간 내)
4. 온콜 대응 시간을 개선할 수 있나? → 리허설 강화, 자동화 추진

결정사항:
- RDS auto-scaling 즉시 적용 (오늘)
- Code Review checklist 업데이트 (내일)
- 월 1회 롤백 리허설 시작 (다음주부터)
```

---

## 8. 부록: 참고 자료

### 8.1 SSM Parameter Store 경로

```
/billage/prod/db/endpoint              → RDS or Host MySQL endpoint (phase 1)
/billage/prod/rabbitmq/enabled        → true/false (phase 2)
/billage/prod/rabbitmq/endpoint        → RabbitMQ endpoint (phase 2)
/billage/prod/chat/use_websocket       → true/false (phase 4)
/billage/prod/chat/rabbitmq_enabled    → true/false (phase 4)
/billage/prod/chat/enabled             → v1_only / v2 / disabled (phase 4)
```

### 8.2 CloudWatch Alarms (자동 롤백 트리거)

```
billage-5xx-errors-high
  → Metric: ALB 5xx > 10건/5분, 3분 지속
  → Action: SNS billage-rollback-trigger 발행

billage-unhealthy-hosts
  → Metric: ALB 비정상 호스트 100%
  → Action: SNS billage-rollback-trigger 발행

billage-rds-connection-error
  → Metric: RDS 연결 실패 > 50%
  → Action: SNS billage-rollback-trigger 발행
```

### 8.3 Slack Channels

```
#billage-incident        → 인시던트 공지 (모든 팀)
#billage-dev             → 개발 논의
#billage-oncall          → 온콜 관련 메시지
#billage-alerts          → 모니터링 알림 (자동)
#devops-runbook          → 런북 문서 관리
```

### 8.4 중요 연락처

```
CTO: @cto (Slack)
DevOps Lead: @devops-lead
On-call DevOps: /who-is-oncall (Slack slash command)
Incident Commander: 온콜 엔지니어가 자임
```

### 8.5 외부 리소스

```
AWS 상태 대시보드: https://status.aws.amazon.com/
Route 53 설정: AWS Console → Route 53 → Hosted Zone "billages.com"
Terraform 코드: /mnt/terraform/phase-01 ~ phase-06
```

---

## 체크리스트: 이 런북을 배포하기 전에

**이 문서를 프로덕션 환경에 적용하기 전에 다음을 확인하세요:**

- [ ] 모든 Phase의 롤백 절차를 Dev 환경에서 최소 1회 리허설 완료
- [ ] 모든 온콜 엔지니어가 이 문서를 정독하고 자신이 담당하는 Phase 숙지
- [ ] Terraform 명령어가 현재 인프라와 일치하는지 검증
- [ ] SSM Parameter 경로가 정확한지 확인
- [ ] Slack 채널과 CloudWatch Alarms가 올바르게 설정되었는지 확인
- [ ] 포스트모템 템플릿을 팀의 incident response tool (e.g. Jira, Notion)에 등록
- [ ] 모니터링 대시보드 (Grafana)에서 각 메트릭의 임계값 재확인
- [ ] CTO와 DevOps Lead 승인 받음

---

**문서 작성일:** 2025-02-11
**마지막 수정일:** 2025-02-11 → 2025-02-11 (300K MAU 스케일 기준 업데이트)
**담당자:** @devops-team
**다음 리뷰 예정:** 2025-03-11 (월 1회 리뷰 정책)

---

## 부록: 300K MAU 스케일 기준 요약

이 런북은 다음 스케일을 기준으로 작성되었습니다:
- **300,000 MAU** → 약 10,000 DAU → 약 1,000 동시 접속 사용자 (피크 시간대)
- **Peak RPS:** 약 900 요청/초
- **WebSocket 동시 연결:** 300-500개 (채팅)
- **활성 채팅방:** 250-300개
- **메시지 처리량:** 50-200 msg/sec (피크)
- **Backend ASG:** min 2 / max 6 인스턴스
- **Frontend ASG:** min 2 / max 3 인스턴스
- **AI ASG:** min 1 / max 2 인스턴스

**임계값 (Thresholds):**
- 에러율: > 5% (3분 지속) → 즉시 롤백
- 응답시간 p95: > 2초 → 재시작 시도, 5분 미복구 시 롤백
- 인스턴스 Unhealthy: 100% (모든 ASG 인스턴스) → 즉시 롤백
- RDS 연결 불가: 모든 쿼리 실패 → 즉시 Host MySQL로 롤백

이 스케일이 변경되면 (예: 1M MAU 이상), 런북의 임계값과 RPS 기준을 재조정해야 합니다.

