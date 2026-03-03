# v2 마이그레이션 체크리스트 (Dev 환경)

> 작성일: 2026-02-27
> **실행일: 2026-03-01**
> 대상: v1 (단일 EC2) → v2 (ALB + ASG + RDS)
> 도메인: `dev.billages.com`
> 참고: [migration overview](../migration/00-migration-overview.md) | [db-migration](../migration/01-db-migration.md) | [cutover-runbook](../migration/08-cutover-runbook.md)

---

## 전제 조건 (이미 완료된 항목)

- [x] v2 Terraform 인프라 배포 완료 (ALB, ASG, RDS, RabbitMQ, NAT)
- [x] ECR 리포지토리 생성 및 이미지 푸시 확인
- [x] CI/CD (GitHub Actions) 워크플로우 검증 완료
- [x] v2.dev.billages.com → ALB 정상 응답 확인
- [x] DB 마이그레이션 리허설 완료

---

## Phase 0: 사전 점검 (D-1)

### 0-1. v2 인프라 상태 확인

- [x] ALB 헬스체크 정상 (BE/FE healthy, AI unhealthy — 별도 이슈)
  ```bash
  aws elbv2 describe-target-health --target-group-arn <be-tg-arn>
  aws elbv2 describe-target-health --target-group-arn <fe-tg-arn>
  aws elbv2 describe-target-health --target-group-arn <ai-tg-arn>
  ```
- [x] ASG 인스턴스 상태 확인 (BE/FE 각 1대 InService)
  ```bash
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names billage-dev-v2-be-asg billage-dev-v2-fe-asg billage-dev-v2-ai-asg \
    --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState}}'
  ```
- [x] RDS 상태 `available` 확인 (MySQL 8.0.44)
  ```bash
  aws rds describe-db-instances --db-instance-identifier billage-dev-v2-mysql \
    --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}'
  ```
- [x] v2.dev.billages.com 접속 → 기본 페이지 로딩 확인
- [x] v2 Backend 헬스체크: `api-v2.billages.com/actuator/health` → `{"status":"UP"}`
- [ ] ~~v2 AI 헬스체크~~ — AI TG unhealthy (별도 확인 필요)

### 0-2. SSM 파라미터 확인

- [ ] Backend SSM 파라미터 확인 (RDS endpoint가 올바르게 설정되었는지)
  ```bash
  aws ssm get-parameters-by-path --path /billage/dev/be/ --with-decryption \
    --query 'Parameters[].{Name:Name,Value:Value}'
  ```
- [ ] Frontend SSM 파라미터 확인 (API URL이 dev.billages.com으로 설정되어 있는지)
  ```bash
  aws ssm get-parameters-by-path --path /billage/dev/fe/ --with-decryption \
    --query 'Parameters[].{Name:Name,Value:Value}'
  ```
- [ ] AI SSM 파라미터 확인
  ```bash
  aws ssm get-parameters-by-path --path /billage/dev/ai/ --with-decryption \
    --query 'Parameters[].{Name:Name,Value:Value}'
  ```

### 0-3. 현재 v1 상태 기록

- [x] v1 EC2 Elastic IP 기록: `43.200.94.221` (i-094a7254ce5407eaa, t4g.medium)
- [x] Route 53 현재 레코드 확인: `dev.billages.com` → `43.200.94.221` (A, TTL 300)
- [x] v1 MySQL 데이터 건수 스냅샷:
  | 테이블 | 건수 |
  |--------|------|
  | users | 59 |
  | post | 74 |
  | chatroom | 35 |
  | chat_message | 2,066 |

---

## Phase 1: 팀 공지 & v1 서비스 중단

> v1 서비스를 먼저 정지해야 DB dump 이후 새로운 쓰기가 발생하지 않는다.
> 순서: 공지 → Nginx 점검 모드 → 애플리케이션 정지 → DB 이관

### 1-1. 팀 공지

- [ ] Slack/Discord 공지 (예시)
  ```
  @channel [Dev 환경 점검 안내]
  - 일시: YYYY-MM-DD HH:MM ~ HH:MM (약 30분)
  - 내용: dev.billages.com v2 인프라로 전환
  - 영향: Dev 환경 일시 접속 불가
  - 완료 후 재공지 예정
  ```

### 1-2. v1 Nginx 점검 모드 전환

> Nginx는 정지하지 않고 점검 페이지를 반환하도록 전환한다.
> DNS 전파 완료 전까지 v1으로 접속하는 유저에게 "점검 중" 메시지를 보여준다.

- [ ] 점검 페이지 배치 및 Nginx 설정 교체
  ```bash
  # v1 EC2 SSH
  ./maintenance-on.sh
  # 스크립트가 없으면 Prod 체크리스트 부록 A 참고하여 생성
  ```
- [ ] 점검 모드 확인
  ```bash
  curl -I https://dev.billages.com
  # HTTP/1.1 503 Service Temporarily Unavailable 반환 확인
  ```

### 1-3. v1 애플리케이션 정지

> Nginx는 점검 페이지를 계속 서빙하므로 정지하지 않는다.

- [ ] v1 Backend 정지
  ```bash
  sudo systemctl stop billage-backend
  ```
- [ ] v1 Frontend 정지
  ```bash
  sudo systemctl stop billage-frontend
  ```
- [ ] v1 AI 정지
  ```bash
  sudo systemctl stop billage-ai
  ```
- [ ] **⚠️ v1 Nginx는 정지하지 않음** (DNS 전파 완료 후 Phase 3-2에서 정지)

---

## Phase 2: DB 마이그레이션 (MySQL → RDS)

> v1 서비스가 정지된 상태이므로 새로운 쓰기가 없다.
> dump 시점의 데이터가 최종 데이터임이 보장된다.

### Option A: mysqldump 직접 이관 (권장, 간단) — ✅ 완료 (2026-03-01)

- [x] v1 EC2 SSH 접속 (`ssh -i ~/.ssh/billage-keypair.pem ubuntu@43.200.94.221`)
- [x] mysqldump 실행 → `/tmp/billage-dev-20260301.sql.gz` (44KB)
  ```bash
  sudo mysqldump --single-transaction \
    --routines --triggers --events \
    --set-gtid-purged=OFF \
    billage | gzip > /tmp/billage-dev-20260301.sql.gz
  ```
- [x] v1과 RDS가 같은 VPC(10.0.0.0/16)이므로 v1에서 직접 RDS import (별도 복사 불필요)
- [x] RDS에 import 완료
  ```bash
  gunzip -c /tmp/billage-dev-20260301.sql.gz | \
    mysql -h billage-dev-v2-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com \
          -u billage_admin -p billage
  ```
- [x] 데이터 건수 검증 — v1과 RDS 100% 일치 확인
  | 테이블 | v1 | RDS | 결과 |
  |--------|-----|-----|------|
  | users | 59 | 59 | 일치 |
  | post | 74 | 74 | 일치 |
  | chatroom | 35 | 35 | 일치 |
  | chat_message | 2,066 | 2,066 | 일치 |

### Option B: Replica 기반 전환 (리허설 완료된 방식)

> Replica 방식은 v1 서비스 정지 전에 사전 동기화를 수행할 수 있어 중단 시간을 더 줄일 수 있다.
> 상세 절차는 [db-migration-runbook.md](../migration/db-migration-runbook.md) 및 [cutover-runbook.md](../migration/08-cutover-runbook.md) 참고

- [ ] Host MySQL GTID 설정 확인
- [ ] mysqldump + GTID 기준점 확보
- [ ] RDS를 Host MySQL의 external replica로 설정
- [ ] `Seconds_Behind_Source=0` 도달 확인
- [ ] Write Freeze → Replication 정리

---

## Phase 3: DNS 스위칭

### 3-1. Route 53 레코드 변경 — ✅ 완료 (2026-03-01)

- [x] `dev.billages.com` A 레코드를 EC2 EIP → ALB Alias로 변경 (AWS CLI 사용)
  ```bash
  # Change ID: C09887371D76VJ54EH66K
  aws route53 change-resource-record-sets --hosted-zone-id Z00048363AHGKAIPSRTJT \
    --change-batch '{
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "dev.billages.com",
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": "ZWKZPGTI48KDX",
            "DNSName": "billage-dev-v2-alb-2051104089.ap-northeast-2.elb.amazonaws.com",
            "EvaluateTargetHealth": true
          }
        }
      }]
    }'
  ```
- [x] DNS 전파 확인 완료 (INSYNC)
  ```bash
  dig dev.billages.com +short
  # → 52.78.239.249, 43.203.94.64 (ALB IPs)
  ```
- [x] v2.dev.billages.com 레코드는 유지 (테스트용)

### 3-2. v1 Nginx 최종 정지

> DNS 전파가 완료되어 v1으로의 트래픽이 거의 없어진 후 정지한다.

- [ ] DNS 전파 확인 (ALB DNS가 반환되는지)
  ```bash
  dig dev.billages.com +short
  ```
- [ ] v1 Nginx 정지
  ```bash
  sudo systemctl stop nginx
  ```

### 3-3. Frontend SSM 파라미터 업데이트 (필요 시)

> v2 Frontend의 `NEXT_PUBLIC_API_URL` 등이 `v2.dev.billages.com`으로 되어 있다면 `dev.billages.com`으로 변경 필요

- [ ] SSM 파라미터 확인 및 업데이트
  ```bash
  # 현재 값 확인
  aws ssm get-parameter --name /billage/dev/fe/next-public-api-url --with-decryption

  # 필요 시 업데이트
  aws ssm put-parameter --name /billage/dev/fe/next-public-api-url \
    --value "https://dev.billages.com" --overwrite

  aws ssm put-parameter --name /billage/dev/fe/nextauth-url \
    --value "https://dev.billages.com" --overwrite
  ```
- [ ] Backend CORS 설정 확인
  ```bash
  aws ssm get-parameter --name /billage/dev/be/cors-allowed --with-decryption
  # dev.billages.com이 포함되어 있는지 확인
  ```
- [ ] SSM 변경 시 ASG Instance Refresh 트리거 (새 파라미터 반영)
  ```bash
  # Frontend 재배포
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name billage-dev-v2-fe-asg \
    --preferences '{"MinHealthyPercentage":0}'

  # Backend 재배포 (CORS 변경 시)
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name billage-dev-v2-be-asg \
    --preferences '{"MinHealthyPercentage":0}'
  ```

---

## Phase 4: 전환 후 검증

### 4-1. 기능 검증

- [x] `https://dev.billages.com` 접속 → 프론트엔드 로딩 (HTTP 307 리다이렉트 정상)
- [ ] 로그인 테스트 (JWT 발급 확인)
- [x] API 호출 테스트: `curl https://api-v2.billages.com/actuator/health` → `{"status":"UP"}`
  > 참고: Backend는 `api-v2.billages.com` 서브도메인으로 host 기반 라우팅
- [ ] ~~AI 호출 테스트~~ — AI TG unhealthy (별도 확인 필요)
- [ ] DB 연결 확인 (게시글 목록 조회 등 실제 데이터 조회)
- [ ] 이미지 업로드 테스트 (S3 Presigned URL)
- [ ] WebSocket 연결 테스트 (채팅 기능, `/ws/*` 경로)

### 4-2. 인프라 검증

- [x] ALB Target Group — BE/FE healthy (AI unhealthy, 별도 이슈)
- [x] RDS 연결 정상 (`available`, 데이터 검증 완료)
- [ ] 모니터링 확인 (Prometheus → v2 인스턴스 메트릭 수집 확인)
- [ ] 로그 수집 확인 (Promtail → Loki)

### 4-3. 팀 완료 공지

- [ ] Slack/Discord 완료 공지
  ```
  @channel [Dev 환경 전환 완료]
  - dev.billages.com이 v2 인프라로 전환되었습니다
  - 이상 발견 시 즉시 알려주세요
  - 기존 v2.dev.billages.com도 동일하게 접속 가능합니다
  ```

---

## Phase 5: 정리 & 안정화

### 5-1. v1 인프라 유지 (롤백 대비)

- [x] v1 EC2 인스턴스 **running 상태로 유지** (롤백 대비, 당분간 삭제하지 않음)
- [x] v1 MySQL 데이터 보존 (롤백 시 필요)
- [ ] v1 EIP는 유지 또는 해제 결정
  - 유지: 롤백 시 DNS 원복 가능 (비용: 미사용 EIP $3.6/월)
  - 해제: 비용 절감, 롤백 시 새 IP 필요

### 5-2. CI/CD 연동 확인

- [ ] GitHub Actions develop 브랜치 push → v2 자동 배포 확인
  - Backend: develop push → ECR push → ASG Instance Refresh
  - Frontend: develop push → ECR push → ASG Instance Refresh
  - AI: develop push → ECR push → ASG Instance Refresh

### 5-3. 안정화 관찰 (1주일)

- [ ] 일 1회 ALB/ASG/RDS 상태 점검
- [ ] 팀원 피드백 수집 (속도, 기능 이상 등)
- [ ] 이슈 없으면 v1 인스턴스 종료 및 리소스 정리

---

## 전환 중 발견된 이슈 및 조치

### 이슈 1: CI/CD 배포 시 중단 발생 (Instance Refresh)

- **원인**: ASG max_size=1, MinHealthyPercentage=0 → Instance Refresh 시 기존 인스턴스를 먼저 종료하고 새 인스턴스를 띄우는 구조 (중단 배포)
- **조치**: Terraform 코드 수정 (2026-03-01)
  - `max_size`: 1 → **2** (배포 시 일시적으로 2대 허용, 평소 1대 유지)
  - `min_healthy_percentage`: 0 → **100** (새 인스턴스가 healthy 확인 후 기존 종료)
  - 대상: BE/FE/AI ASG 모두 적용
  - 파일: `v2/envs/dev/variables.tf`, `v2/envs/dev/main.tf`
- **효과**: 무중단 배포 달성, 비용은 배포 중 ~5분간만 추가 인스턴스 비용 발생

### 이슈 2: AI Target Group unhealthy

- **상태**: AI ASG 인스턴스가 TG 헬스체크 실패 (502 Bad Gateway)
- **영향**: AI 서비스 접속 불가 (`/ai/*` 경로)
- **조치**: 별도 확인 필요 (마이그레이션 자체와는 무관)

---

## 롤백 절차 (비상 시)

> 전환 후 심각한 문제 발생 시 즉시 v1으로 복귀

1. Route 53 `dev.billages.com` → v1 EC2 EIP로 원복
2. v1 서비스 재시작
   ```bash
   sudo systemctl start billage-backend
   sudo systemctl start billage-frontend
   sudo systemctl start billage-ai
   sudo systemctl start nginx
   ```
3. v1 → v2 사이 발생한 데이터 동기화 판단 (필요 시 RDS → Host MySQL 역동기화)
4. 원인 분석 후 재시도

---

## 예상 소요 시간

| 단계 | 예상 시간 | 비고 |
|------|----------|------|
| Phase 0: 사전 점검 | 30분 | D-1에 미리 수행 |
| Phase 1: 팀 공지 + v1 중단 | 5분 | Nginx 점검 모드 + 앱 정지 |
| Phase 2: DB 이관 (Option A) | 10~30분 | 서비스 정지 상태에서 깨끗한 dump |
| Phase 3: DNS 스위칭 | 5~10분 | TTL 전파 대기 |
| Phase 4: 검증 | 15~20분 | |
| **총 중단 시간** | **약 30~60분** | Dev 환경이므로 허용 가능 |
