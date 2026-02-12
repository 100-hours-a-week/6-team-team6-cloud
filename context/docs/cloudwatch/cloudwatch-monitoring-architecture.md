# CloudWatch 모니터링 아키텍처 문서

> Billage 프로젝트의 AWS CloudWatch 기반 모니터링 및 장애 알림 시스템

## 목차

1. [개요](#1-개요)
2. [아키텍처 다이어그램](#2-아키텍처-다이어그램)
3. [모듈 구조](#3-모듈-구조)
4. [리소스 상세](#4-리소스-상세)
5. [알림 흐름](#5-알림-흐름)
6. [환경별 설정](#6-환경별-설정)
7. [변수 레퍼런스](#7-변수-레퍼런스)
8. [출력값 레퍼런스](#8-출력값-레퍼런스)

---

## 1. 개요

### 1.1 목적

- EC2 인스턴스의 상태 및 성능 모니터링
- 장애 발생 시 이메일/Discord로 즉시 알림
- Dev/Prod 환경 분리 모니터링

### 1.2 모니터링 대상

| 대상 | 메트릭 | 임계값 | 설명 |
|------|--------|--------|------|
| EC2 CPU | `CPUUtilization` | > 80% | 서버 과부하 감지 |
| EC2 인스턴스 상태 | `StatusCheckFailed_Instance` | > 0 | OS/소프트웨어 장애 |
| EC2 시스템 상태 | `StatusCheckFailed_System` | > 0 | AWS 하드웨어/네트워크 장애 |

### 1.3 알림 채널

| 채널 | 용도 | 필수 여부 |
|------|------|-----------|
| Email (SNS) | 기본 알림 채널 | 필수 |
| Discord (Lambda + Webhook) | 팀 협업 채널 알림 | 선택 |

---

## 2. 아키텍처 다이어그램

### 2.1 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            AWS Cloud (ap-northeast-2)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         Dev VPC (10.0.0.0/16)                        │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │  EC2: billage-dev-main-server (t4g.medium)                  │    │    │
│  │  │  ├── Spring Boot (8080)                                      │    │    │
│  │  │  ├── Next.js (3000)                                          │    │    │
│  │  │  ├── FastAPI (5000)                                          │    │    │
│  │  │  └── MySQL (3306)                                            │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                    │                                         │
│                                    │ 메트릭 수집                              │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         CloudWatch                                   │    │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │    │
│  │  │ CPU Alarm       │  │ Instance Status │  │ System Status   │     │    │
│  │  │ > 80% (5분x2)   │  │ Failed Alarm    │  │ Failed Alarm    │     │    │
│  │  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘     │    │
│  └───────────┼────────────────────┼────────────────────┼───────────────┘    │
│              └────────────────────┼────────────────────┘                    │
│                                   ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    SNS Topic: billage-dev-cloudwatch-alarms          │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │                      Subscriptions                           │    │    │
│  │  │  ┌─────────────────┐        ┌─────────────────────────┐     │    │    │
│  │  │  │ Email Protocol  │        │ Lambda Protocol         │     │    │    │
│  │  │  │ → your@email    │        │ → discord-notifier      │     │    │    │
│  │  │  └────────┬────────┘        └────────────┬────────────┘     │    │    │
│  │  └───────────┼──────────────────────────────┼──────────────────┘    │    │
│  └──────────────┼──────────────────────────────┼───────────────────────┘    │
│                 │                              │                             │
│                 ▼                              ▼                             │
│  ┌──────────────────────┐      ┌────────────────────────────────────┐       │
│  │     Email Inbox      │      │  Lambda: billage-dev-discord-notifier │    │
│  │  (알림 메일 수신)     │      │  ├── Runtime: Python 3.12            │    │
│  └──────────────────────┘      │  ├── Timeout: 30s                    │    │
│                                │  └── Env: DISCORD_WEBHOOK_URL        │    │
│                                └──────────────────┬─────────────────────┘   │
│                                                   │                          │
└───────────────────────────────────────────────────┼──────────────────────────┘
                                                    │ HTTPS POST
                                                    ▼
                                    ┌───────────────────────────┐
                                    │      Discord Server       │
                                    │  ┌─────────────────────┐  │
                                    │  │  #alerts 채널       │  │
                                    │  │  Webhook Endpoint   │  │
                                    │  └─────────────────────┘  │
                                    └───────────────────────────┘
```

### 2.2 Prod 환경 구조 (동일)

```
Prod VPC (10.1.0.0/16)
└── EC2: billage-prod-main-server
    └── CloudWatch Alarms
        └── SNS: billage-prod-cloudwatch-alarms
            ├── Email Subscription
            └── Lambda → Discord
```

---

## 3. 모듈 구조

### 3.1 디렉토리 구조

```
terraform/
├── modules/
│   └── cloudwatch/
│       ├── main.tf           # SNS Topic, CloudWatch Alarms 정의
│       ├── lambda.tf         # Discord Lambda 함수 (선택적)
│       ├── variables.tf      # 입력 변수 정의
│       └── outputs.tf        # 출력값 정의
│
├── envs/
│   ├── dev/
│   │   ├── main.tf           # cloudwatch 모듈 호출
│   │   ├── variables.tf      # 모니터링 변수 선언
│   │   └── terraform.tfvars  # 실제 값 설정
│   │
│   └── prod/
│       ├── main.tf           # cloudwatch 모듈 호출
│       ├── variables.tf      # 모니터링 변수 선언
│       └── terraform.tfvars  # 실제 값 설정
│
└── docs/
    └── cloudwatch-monitoring-architecture.md  # 이 문서
```

### 3.2 모듈 의존성

```
┌─────────────────┐
│   VPC Module    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   EC2 Module    │──────────────┐
└────────┬────────┘              │
         │                       │ instance_id
         ▼                       ▼
┌─────────────────┐    ┌─────────────────┐
│ Security Group  │    │ CloudWatch      │
│    Module       │    │    Module       │
└─────────────────┘    └─────────────────┘
```

---

## 4. 리소스 상세

### 4.1 SNS Topic

| 속성 | 값 |
|------|-----|
| 이름 | `billage-{env}-cloudwatch-alarms` |
| 프로토콜 | Email, Lambda |
| 리전 | ap-northeast-2 |

**Terraform 리소스:**
```hcl
resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-cloudwatch-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
```

### 4.2 CloudWatch Alarms

#### 4.2.1 CPU 사용률 알람

| 속성 | 값 |
|------|-----|
| 이름 | `billage-{env}-cpu-utilization-high` |
| 메트릭 | `AWS/EC2` > `CPUUtilization` |
| 조건 | Average > 80% |
| 평가 기간 | 5분 × 2회 = 10분 |
| 누락 데이터 처리 | notBreaching (알람 미발생) |

**발생 시나리오:**
- 트래픽 급증으로 서버 과부하
- 무한 루프 또는 메모리 누수
- 배치 작업 실행 중

#### 4.2.2 인스턴스 상태 체크 알람

| 속성 | 값 |
|------|-----|
| 이름 | `billage-{env}-status-check-failed-instance` |
| 메트릭 | `AWS/EC2` > `StatusCheckFailed_Instance` |
| 조건 | Maximum > 0 |
| 평가 기간 | 1분 × 2회 = 2분 |
| 누락 데이터 처리 | breaching (알람 발생) |

**발생 시나리오:**
- OS 커널 패닉
- 네트워크 설정 오류
- 파일시스템 손상
- 메모리 부족 (OOM)

#### 4.2.3 시스템 상태 체크 알람

| 속성 | 값 |
|------|-----|
| 이름 | `billage-{env}-status-check-failed-system` |
| 메트릭 | `AWS/EC2` > `StatusCheckFailed_System` |
| 조건 | Maximum > 0 |
| 평가 기간 | 1분 × 2회 = 2분 |
| 누락 데이터 처리 | breaching (알람 발생) |

**발생 시나리오:**
- AWS 하드웨어 장애
- 호스트 시스템 문제
- 네트워크 연결 손실 (AWS 측)

### 4.3 Lambda 함수 (Discord 알림)

| 속성 | 값 |
|------|-----|
| 이름 | `billage-{env}-discord-notifier` |
| 런타임 | Python 3.12 |
| 핸들러 | `discord_notifier.lambda_handler` |
| 타임아웃 | 30초 |
| 메모리 | 128MB (기본) |

**환경 변수:**
| 변수명 | 설명 |
|--------|------|
| `DISCORD_WEBHOOK_URL` | Discord 웹훅 URL |

**IAM 권한:**
- `AWSLambdaBasicExecutionRole` (CloudWatch Logs 쓰기)

**메시지 포맷 (Discord Embed):**
```json
{
  "embeds": [{
    "title": "🚨 billage-prod-cpu-utilization-high",
    "description": "[PROD] 서버 CPU 사용률이 80%를 초과했습니다.",
    "color": 16711680,  // Red for ALARM
    "fields": [
      {"name": "상태", "value": "ALARM", "inline": true},
      {"name": "시간", "value": "2026-01-31T15:30:00", "inline": true},
      {"name": "상세 정보", "value": "Threshold crossed...", "inline": false}
    ],
    "footer": {"text": "AWS CloudWatch Alarm"}
  }]
}
```

---

## 5. 알림 흐름

### 5.1 알람 발생 → 알림 수신 흐름

```
시간 T+0분: EC2 CPU 85% 도달
     │
     ▼
시간 T+5분: CloudWatch 첫 번째 데이터 포인트 수집 (85% > 80%)
     │
     ▼
시간 T+10분: 두 번째 데이터 포인트 수집 (여전히 > 80%)
     │        → 평가 기간 2회 충족
     ▼
CloudWatch Alarm 상태 변경: OK → ALARM
     │
     ├──────────────────────────────────────┐
     ▼                                      ▼
SNS Topic 메시지 발행              Lambda 함수 트리거
     │                                      │
     ▼                                      ▼
Email 전송                         Discord API 호출
     │                                      │
     ▼                                      ▼
이메일 수신함                       Discord 채널
(약 1-2분 지연)                    (약 3-5초 지연)
```

### 5.2 알람 상태 전이

```
        ┌─────────────────────────────────────────┐
        │                                         │
        ▼                                         │
┌───────────────┐    임계값 초과    ┌───────────────┐
│      OK       │ ───────────────▶ │     ALARM     │
│  (정상 상태)   │                  │  (경보 상태)   │
└───────────────┘ ◀─────────────── └───────────────┘
        │           임계값 복귀            │
        │                                  │
        │    데이터 없음     ┌─────────────┘
        │  ┌────────────────▶│
        ▼  │                 ▼
┌───────────────┐    ┌───────────────┐
│INSUFFICIENT   │    │ (알림 발송)   │
│    DATA       │    │ - OK 복귀 시  │
│ (데이터 부족)  │    │ - ALARM 시    │
└───────────────┘    └───────────────┘
```

---

## 6. 환경별 설정

### 6.1 Dev 환경

**파일:** `envs/dev/terraform.tfvars`

```hcl
# CloudWatch 모니터링 설정
alarm_email         = "dev-team@billage.com"
enable_discord      = true
discord_webhook_url = "https://discord.com/api/webhooks/xxx/yyy"
cpu_threshold       = 80
```

**특징:**
- 개발 중 빈번한 알람 가능
- 테스트용 알림 채널 권장

### 6.2 Prod 환경

**파일:** `envs/prod/terraform.tfvars`

```hcl
# CloudWatch 모니터링 설정
alarm_email         = "ops-team@billage.com"
enable_discord      = true
discord_webhook_url = "https://discord.com/api/webhooks/aaa/bbb"
cpu_threshold       = 80
```

**특징:**
- 24/7 모니터링 필수
- 운영팀 공용 채널로 알림

---

## 7. 변수 레퍼런스

### 7.1 필수 변수

| 변수명 | 타입 | 설명 |
|--------|------|------|
| `environment` | string | 환경 (dev, prod) |
| `instance_id` | string | 모니터링할 EC2 인스턴스 ID |
| `alarm_email` | string | 알람 수신 이메일 |

### 7.2 선택 변수

| 변수명 | 타입 | 기본값 | 설명 |
|--------|------|--------|------|
| `project_name` | string | `"billage"` | 프로젝트 이름 |
| `instance_name` | string | `""` | 알람 설명에 표시될 인스턴스 이름 |
| `cpu_threshold` | number | `80` | CPU 알람 임계값 (%) |
| `cpu_evaluation_periods` | number | `2` | CPU 평가 횟수 |
| `cpu_period` | number | `300` | CPU 측정 주기 (초) |
| `enable_discord` | bool | `false` | Discord 알림 활성화 |
| `discord_webhook_url` | string | `""` | Discord 웹훅 URL |

---

## 8. 출력값 레퍼런스

| 출력명 | 타입 | 설명 |
|--------|------|------|
| `sns_topic_arn` | string | SNS 토픽 ARN |
| `sns_topic_name` | string | SNS 토픽 이름 |
| `cpu_alarm_arn` | string | CPU 알람 ARN |
| `instance_status_alarm_arn` | string | 인스턴스 상태 알람 ARN |
| `system_status_alarm_arn` | string | 시스템 상태 알람 ARN |
| `discord_lambda_arn` | string | Discord Lambda ARN (enable_discord=true 시) |
| `alarm_names` | list(string) | 생성된 알람 이름 목록 |

---

## 부록

### A. 비용 예상

| 리소스 | 무료 티어 | 예상 비용 |
|--------|-----------|-----------|
| CloudWatch Alarms | 10개 무료 | 3개 → $0 |
| SNS | 첫 100만 요청 무료 | $0 |
| Lambda | 월 100만 요청 무료 | $0 |
| CloudWatch Logs | 5GB 무료 | $0 |

**예상 월 비용: $0** (무료 티어 범위 내)

### B. 트러블슈팅

#### 이메일이 오지 않는 경우
1. AWS SNS 콘솔에서 구독 상태 확인
2. "Pending confirmation" 상태면 이메일 확인 필요
3. 스팸 폴더 확인

#### Discord 알림이 오지 않는 경우
1. Lambda 함수 CloudWatch Logs 확인
2. 웹훅 URL 유효성 확인
3. Discord 채널 권한 확인

#### 알람이 너무 자주 발생하는 경우
1. `cpu_threshold` 값 상향 조정
2. `cpu_evaluation_periods` 값 증가
3. `cpu_period` 값 증가 (측정 간격 늘림)
