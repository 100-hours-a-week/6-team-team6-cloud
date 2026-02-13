# CloudWatch 모니터링 수동 설정 가이드

> Terraform 없이 AWS 콘솔과 CLI로 CloudWatch 모니터링을 설정하는 상세 가이드

## 목차

1. [사전 준비 체크리스트](#1-사전-준비-체크리스트)
2. [Step 1: SNS 토픽 생성](#step-1-sns-토픽-생성)
3. [Step 2: SNS 이메일 구독 설정](#step-2-sns-이메일-구독-설정)
4. [Step 3: CloudWatch 알람 생성](#step-3-cloudwatch-알람-생성)
5. [Step 4: Discord 알림 설정 (선택)](#step-4-discord-알림-설정-선택)
6. [Step 5: 알람 테스트](#step-5-알람-테스트)
7. [전체 체크리스트](#전체-체크리스트)
8. [트러블슈팅](#트러블슈팅)

---

## 1. 사전 준비 체크리스트

### 1.1 AWS 계정 준비

- [ ] AWS 계정 로그인 가능
- [ ] IAM 권한 확인 (CloudWatch, SNS, Lambda 접근 권한)
- [ ] 리전 설정: **서울 (ap-northeast-2)**

### 1.2 필요한 정보 수집

| 항목 | Dev 환경 | Prod 환경 | 확인 |
|------|----------|-----------|------|
| EC2 Instance ID | i-xxxxxxxxx | i-yyyyyyyyy | [ ] |
| EC2 Instance Name | billage-dev-main-server | billage-prod-main-server | [ ] |
| 알림 이메일 | | | [ ] |
| Discord Webhook URL | | | [ ] |

**EC2 Instance ID 확인 방법:**
```bash
# AWS CLI
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=billage-*-main-server" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# 또는 AWS 콘솔
# EC2 > 인스턴스 > 인스턴스 ID 컬럼 확인
```

### 1.3 Discord Webhook 생성 (선택)

- [ ] Discord 서버 관리 권한 확인
- [ ] 알림 전용 채널 생성 (예: `#aws-alerts`)

**Discord Webhook 생성 방법:**
1. Discord 서버 열기
2. 채널 설정 (톱니바퀴) 클릭
3. **연동** > **웹후크** 선택
4. **새 웹후크** 클릭
5. 이름 설정: `AWS CloudWatch`
6. **웹후크 URL 복사** 클릭
7. URL 저장 (예: `https://discord.com/api/webhooks/123456789/abcdefg...`)

---

## Step 1: SNS 토픽 생성

### 1.1 AWS 콘솔에서 생성

1. **AWS 콘솔** 접속 → **SNS** 검색 → 클릭
2. 좌측 메뉴 **주제(Topics)** 클릭
3. **주제 생성** 버튼 클릭

### 1.2 주제 설정

| 설정 항목 | Dev 환경 값 | Prod 환경 값 |
|-----------|-------------|--------------|
| 유형 | 표준 | 표준 |
| 이름 | `billage-dev-cloudwatch-alarms` | `billage-prod-cloudwatch-alarms` |
| 표시 이름 | `Billage Dev Alerts` | `Billage Prod Alerts` |

4. **주제 생성** 버튼 클릭
5. 생성된 **주제 ARN** 복사해두기

```
# 예시 ARN
arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms
```

### 1.3 CLI로 생성 (대안)

```bash
# Dev 환경
aws sns create-topic \
  --name billage-dev-cloudwatch-alarms \
  --region ap-northeast-2

# Prod 환경
aws sns create-topic \
  --name billage-prod-cloudwatch-alarms \
  --region ap-northeast-2
```

### 체크포인트
- [ ] Dev SNS 토픽 생성 완료
- [ ] Prod SNS 토픽 생성 완료
- [ ] 토픽 ARN 기록 완료

---

## Step 2: SNS 이메일 구독 설정

### 2.1 AWS 콘솔에서 설정

1. **SNS** > **주제** > 생성한 토픽 클릭
2. **구독 생성** 버튼 클릭

### 2.2 구독 설정

| 설정 항목 | 값 |
|-----------|-----|
| 프로토콜 | 이메일 |
| 엔드포인트 | `your-team@example.com` |

3. **구독 생성** 클릭

### 2.3 이메일 확인 (중요!)

1. 입력한 이메일 주소의 받은편지함 확인
2. **AWS Notification - Subscription Confirmation** 제목의 메일 찾기
3. 메일 본문의 **Confirm subscription** 링크 클릭
4. "Subscription confirmed!" 페이지 확인

```
⚠️ 주의: 이메일 확인을 하지 않으면 알림이 발송되지 않습니다!
```

### 2.4 CLI로 설정 (대안)

```bash
# 이메일 구독 추가
aws sns subscribe \
  --topic-arn arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms \
  --protocol email \
  --notification-endpoint your-team@example.com
```

### 체크포인트
- [ ] Dev 토픽에 이메일 구독 추가
- [ ] Dev 이메일 확인 완료 (Confirm 클릭)
- [ ] Prod 토픽에 이메일 구독 추가
- [ ] Prod 이메일 확인 완료 (Confirm 클릭)

---

## Step 3: CloudWatch 알람 생성

### 3.1 CPU 사용률 알람 생성

#### AWS 콘솔에서 생성

1. **AWS 콘솔** > **CloudWatch** 검색 → 클릭
2. 좌측 메뉴 **경보** > **모든 경보** 클릭
3. **경보 생성** 버튼 클릭

#### 3.1.1 지표 선택

1. **지표 선택** 클릭
2. **EC2** > **인스턴스별 지표** 클릭
3. 검색창에 Instance ID 입력 (예: `i-0123456789abcdef0`)
4. **CPUUtilization** 체크박스 선택
5. **지표 선택** 버튼 클릭

#### 3.1.2 조건 설정

| 설정 항목 | 값 | 설명 |
|-----------|-----|------|
| 통계 | 평균 | Average |
| 기간 | 5분 | 300초 |
| 임계값 유형 | 정적 | |
| 조건 | 보다 큼 | Greater than |
| 임계값 | 80 | CPU 80% 초과 시 |
| 추가 구성 > 경보를 알릴 데이터 포인트 | 2 / 2 | 2회 연속 초과 시 |
| 추가 구성 > 누락된 데이터 처리 | 누락 데이터를 양호로 처리 | notBreaching |

#### 3.1.3 작업 구성

| 설정 항목 | 값 |
|-----------|-----|
| 알림 | |
| 경보 상태 트리거 | 경보 상태 |
| SNS 주제 선택 | 기존 SNS 주제 선택 |
| 알림 전송 대상 | `billage-{env}-cloudwatch-alarms` |
| | |
| **추가 작업** | |
| 경보 상태 트리거 | 정상 (OK) |
| SNS 주제 선택 | 기존 SNS 주제 선택 |
| 알림 전송 대상 | `billage-{env}-cloudwatch-alarms` |

#### 3.1.4 이름 및 설명

| 설정 항목 | Dev 환경 값 | Prod 환경 값 |
|-----------|-------------|--------------|
| 경보 이름 | `billage-dev-cpu-utilization-high` | `billage-prod-cpu-utilization-high` |
| 경보 설명 | `[DEV] billage-dev-main-server CPU 사용률이 80%를 초과했습니다.` | `[PROD] billage-prod-main-server CPU 사용률이 80%를 초과했습니다.` |

5. **경보 생성** 클릭

---

### 3.2 인스턴스 상태 체크 알람 생성

#### 지표 선택
- **EC2** > **인스턴스별 지표** > Instance ID 검색
- **StatusCheckFailed_Instance** 선택

#### 조건 설정

| 설정 항목 | 값 |
|-----------|-----|
| 통계 | 최대 |
| 기간 | 1분 |
| 조건 | 보다 큼 |
| 임계값 | 0 |
| 경보를 알릴 데이터 포인트 | 2 / 2 |
| 누락된 데이터 처리 | 누락 데이터를 불량으로 처리 |

#### 이름

| 환경 | 값 |
|------|-----|
| Dev | `billage-dev-status-check-failed-instance` |
| Prod | `billage-prod-status-check-failed-instance` |

---

### 3.3 시스템 상태 체크 알람 생성

#### 지표 선택
- **EC2** > **인스턴스별 지표** > Instance ID 검색
- **StatusCheckFailed_System** 선택

#### 조건 설정

| 설정 항목 | 값 |
|-----------|-----|
| 통계 | 최대 |
| 기간 | 1분 |
| 조건 | 보다 큼 |
| 임계값 | 0 |
| 경보를 알릴 데이터 포인트 | 2 / 2 |
| 누락된 데이터 처리 | 누락 데이터를 불량으로 처리 |

#### 이름

| 환경 | 값 |
|------|-----|
| Dev | `billage-dev-status-check-failed-system` |
| Prod | `billage-prod-status-check-failed-system` |

---

### 3.4 CLI로 알람 생성 (대안)

```bash
# CPU 알람 생성 (Dev)
aws cloudwatch put-metric-alarm \
  --alarm-name "billage-dev-cpu-utilization-high" \
  --alarm-description "[DEV] CPU 사용률이 80%를 초과했습니다." \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=InstanceId,Value=i-0123456789abcdef0 \
  --evaluation-periods 2 \
  --alarm-actions arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms \
  --ok-actions arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms \
  --treat-missing-data notBreaching

# 인스턴스 상태 체크 알람 (Dev)
aws cloudwatch put-metric-alarm \
  --alarm-name "billage-dev-status-check-failed-instance" \
  --alarm-description "[DEV] 인스턴스 상태 체크 실패!" \
  --metric-name StatusCheckFailed_Instance \
  --namespace AWS/EC2 \
  --statistic Maximum \
  --period 60 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=InstanceId,Value=i-0123456789abcdef0 \
  --evaluation-periods 2 \
  --alarm-actions arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms \
  --ok-actions arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms \
  --treat-missing-data breaching

# 시스템 상태 체크 알람 (Dev)
aws cloudwatch put-metric-alarm \
  --alarm-name "billage-dev-status-check-failed-system" \
  --alarm-description "[DEV] 시스템 상태 체크 실패!" \
  --metric-name StatusCheckFailed_System \
  --namespace AWS/EC2 \
  --statistic Maximum \
  --period 60 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=InstanceId,Value=i-0123456789abcdef0 \
  --evaluation-periods 2 \
  --alarm-actions arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms \
  --ok-actions arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms \
  --treat-missing-data breaching
```

### 체크포인트
- [ ] Dev CPU 알람 생성 완료
- [ ] Dev Instance Status 알람 생성 완료
- [ ] Dev System Status 알람 생성 완료
- [ ] Prod CPU 알람 생성 완료
- [ ] Prod Instance Status 알람 생성 완료
- [ ] Prod System Status 알람 생성 완료

---

## Step 4: Discord 알림 설정 (선택)

> Discord 알림이 필요 없으면 이 단계를 건너뛰세요.

### 4.1 Lambda 함수 생성

#### 4.1.1 AWS 콘솔에서 생성

1. **AWS 콘솔** > **Lambda** 검색 → 클릭
2. **함수 생성** 클릭

#### 4.1.2 함수 기본 정보

| 설정 항목 | Dev 환경 값 | Prod 환경 값 |
|-----------|-------------|--------------|
| 함수 이름 | `billage-dev-discord-notifier` | `billage-prod-discord-notifier` |
| 런타임 | Python 3.12 | Python 3.12 |
| 아키텍처 | x86_64 | x86_64 |

3. **함수 생성** 클릭

#### 4.1.3 함수 코드 입력

1. **코드** 탭 선택
2. `lambda_function.py` 파일 내용을 아래 코드로 교체:

```python
import json
import urllib.request
import os

def lambda_handler(event, context):
    """
    Lambda function to forward SNS notifications to Discord webhook.
    """
    webhook_url = os.environ.get('DISCORD_WEBHOOK_URL')

    if not webhook_url:
        print("ERROR: DISCORD_WEBHOOK_URL not set")
        return {'statusCode': 500, 'body': 'Webhook URL not configured'}

    # Parse SNS message
    try:
        sns_message = event['Records'][0]['Sns']
        subject = sns_message.get('Subject', 'CloudWatch Alarm')
        message_str = sns_message.get('Message', '{}')

        # Try to parse as JSON (CloudWatch alarm format)
        try:
            alarm_data = json.loads(message_str)
            alarm_name = alarm_data.get('AlarmName', 'Unknown')
            new_state = alarm_data.get('NewStateValue', 'Unknown')
            reason = alarm_data.get('NewStateReason', 'No reason provided')
            description = alarm_data.get('AlarmDescription', '')
            timestamp = alarm_data.get('StateChangeTime', '')

            # Set color based on state
            if new_state == 'ALARM':
                color = 0xFF0000  # Red
                emoji = "🚨"
            elif new_state == 'OK':
                color = 0x00FF00  # Green
                emoji = "✅"
            else:
                color = 0xFFFF00  # Yellow
                emoji = "⚠️"

            # Build Discord embed
            embed = {
                "title": f"{emoji} {alarm_name}",
                "description": description,
                "color": color,
                "fields": [
                    {"name": "상태", "value": new_state, "inline": True},
                    {"name": "시간", "value": timestamp[:19] if timestamp else "N/A", "inline": True},
                    {"name": "상세 정보", "value": reason[:1000] if reason else "N/A", "inline": False}
                ],
                "footer": {"text": "AWS CloudWatch Alarm"}
            }

            payload = {"embeds": [embed]}

        except json.JSONDecodeError:
            # Plain text message
            payload = {
                "content": f"**{subject}**\n{message_str}"
            }

    except Exception as e:
        print(f"Error parsing message: {e}")
        payload = {"content": f"CloudWatch Alert: {str(event)}"}

    # Send to Discord
    try:
        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(
            webhook_url,
            data=data,
            headers={'Content-Type': 'application/json'}
        )

        with urllib.request.urlopen(req, timeout=10) as response:
            print(f"Discord response: {response.status}")
            return {'statusCode': 200, 'body': 'Message sent to Discord'}

    except Exception as e:
        print(f"Error sending to Discord: {e}")
        return {'statusCode': 500, 'body': str(e)}
```

3. **Deploy** 버튼 클릭

#### 4.1.4 환경 변수 설정

1. **구성** 탭 > **환경 변수** 클릭
2. **편집** 클릭
3. **환경 변수 추가** 클릭

| 키 | 값 |
|-----|-----|
| `DISCORD_WEBHOOK_URL` | `https://discord.com/api/webhooks/...` (복사한 URL) |

4. **저장** 클릭

#### 4.1.5 제한 시간 설정

1. **구성** 탭 > **일반 구성** > **편집**
2. 제한 시간: **30초**
3. **저장** 클릭

---

### 4.2 SNS 트리거 추가

1. Lambda 함수 페이지에서 **트리거 추가** 클릭
2. 소스 선택: **SNS**
3. SNS 주제: `billage-{env}-cloudwatch-alarms` 선택
4. **추가** 클릭

---

### 4.3 Lambda 권한 확인

Lambda 함수의 실행 역할에 아래 권한이 자동으로 추가됩니다:
- `AWSLambdaBasicExecutionRole` (CloudWatch Logs 쓰기)

추가 권한은 필요하지 않습니다.

### 체크포인트
- [ ] Dev Discord Lambda 함수 생성 완료
- [ ] Dev Lambda 환경 변수 설정 완료
- [ ] Dev Lambda SNS 트리거 추가 완료
- [ ] Prod Discord Lambda 함수 생성 완료
- [ ] Prod Lambda 환경 변수 설정 완료
- [ ] Prod Lambda SNS 트리거 추가 완료

---

## Step 5: 알람 테스트

### 5.1 CloudWatch 알람 수동 테스트

#### 방법 1: AWS CLI로 알람 상태 강제 변경

```bash
# 알람을 ALARM 상태로 변경 (테스트)
aws cloudwatch set-alarm-state \
  --alarm-name "billage-dev-cpu-utilization-high" \
  --state-value ALARM \
  --state-reason "Testing alarm notification"

# 잠시 후 OK 상태로 복구
aws cloudwatch set-alarm-state \
  --alarm-name "billage-dev-cpu-utilization-high" \
  --state-value OK \
  --state-reason "Test completed"
```

#### 방법 2: 실제 CPU 부하 발생 (EC2 내부)

```bash
# EC2 인스턴스에 SSH 접속 후
# CPU 부하 발생 (약 2분간)
stress --cpu 2 --timeout 120

# stress 도구가 없으면 설치
sudo apt-get update && sudo apt-get install -y stress
```

### 5.2 예상 결과

#### 이메일 알림
```
Subject: ALARM: "billage-dev-cpu-utilization-high" in Asia Pacific (Seoul)

You are receiving this email because your Amazon CloudWatch Alarm
"billage-dev-cpu-utilization-high" in the Asia Pacific (Seoul) region
has entered the ALARM state...
```

#### Discord 알림
```
🚨 billage-dev-cpu-utilization-high
─────────────────────────────────────
[DEV] billage-dev-main-server CPU 사용률이 80%를 초과했습니다.

상태: ALARM
시간: 2026-01-31T15:30:00
상세 정보: Threshold Crossed: 1 out of the last 2 datapoints...

AWS CloudWatch Alarm
```

### 5.3 Lambda 로그 확인 (Discord 알림 디버깅)

1. **AWS 콘솔** > **CloudWatch** > **로그 그룹**
2. `/aws/lambda/billage-{env}-discord-notifier` 클릭
3. 최신 로그 스트림 확인

### 체크포인트
- [ ] 테스트 알람 발생 완료
- [ ] 이메일 알림 수신 확인
- [ ] Discord 알림 수신 확인 (설정한 경우)
- [ ] 알람 OK 복구 알림 수신 확인

---

## 전체 체크리스트

### 사전 준비
- [ ] AWS 계정 접속 가능
- [ ] 리전: ap-northeast-2 (서울) 설정
- [ ] EC2 Instance ID 확인 (Dev)
- [ ] EC2 Instance ID 확인 (Prod)
- [ ] 알림 이메일 주소 준비
- [ ] Discord Webhook URL 생성 (선택)

### SNS 설정
- [ ] Dev SNS 토픽 생성: `billage-dev-cloudwatch-alarms`
- [ ] Dev SNS 이메일 구독 추가
- [ ] Dev SNS 이메일 확인 (Confirm 클릭)
- [ ] Prod SNS 토픽 생성: `billage-prod-cloudwatch-alarms`
- [ ] Prod SNS 이메일 구독 추가
- [ ] Prod SNS 이메일 확인 (Confirm 클릭)

### CloudWatch 알람 (Dev)
- [ ] `billage-dev-cpu-utilization-high` 생성
- [ ] `billage-dev-status-check-failed-instance` 생성
- [ ] `billage-dev-status-check-failed-system` 생성

### CloudWatch 알람 (Prod)
- [ ] `billage-prod-cpu-utilization-high` 생성
- [ ] `billage-prod-status-check-failed-instance` 생성
- [ ] `billage-prod-status-check-failed-system` 생성

### Discord Lambda (선택)
- [ ] Dev Lambda 함수 생성
- [ ] Dev Lambda 코드 배포
- [ ] Dev Lambda 환경 변수 설정
- [ ] Dev Lambda SNS 트리거 추가
- [ ] Prod Lambda 함수 생성
- [ ] Prod Lambda 코드 배포
- [ ] Prod Lambda 환경 변수 설정
- [ ] Prod Lambda SNS 트리거 추가

### 테스트
- [ ] Dev 알람 테스트 완료
- [ ] Dev 이메일 수신 확인
- [ ] Dev Discord 수신 확인 (설정한 경우)
- [ ] Prod 알람 테스트 완료
- [ ] Prod 이메일 수신 확인
- [ ] Prod Discord 수신 확인 (설정한 경우)

---

## 트러블슈팅

### 문제: 이메일이 오지 않음

**원인 1: SNS 구독 미확인**
```
해결: SNS > 구독 > 상태가 "Pending confirmation"인지 확인
     → 이메일 받은편지함에서 Confirm 링크 클릭
```

**원인 2: 스팸 폴더**
```
해결: 스팸/정크 폴더 확인
     → no-reply@sns.amazonaws.com 발신자 화이트리스트 추가
```

**원인 3: 알람 작업 미설정**
```
해결: CloudWatch > 경보 > 해당 알람 > 작업 탭 확인
     → SNS 주제가 올바르게 설정되었는지 확인
```

---

### 문제: Discord 알림이 오지 않음

**원인 1: Webhook URL 오류**
```
해결: Lambda > 구성 > 환경 변수 > DISCORD_WEBHOOK_URL 확인
     → URL이 https://discord.com/api/webhooks/로 시작하는지 확인
```

**원인 2: Lambda 실행 오류**
```
해결: CloudWatch > 로그 그룹 > /aws/lambda/billage-*-discord-notifier
     → 최신 로그 확인
     → ERROR 메시지 확인
```

**원인 3: SNS → Lambda 트리거 미설정**
```
해결: Lambda > 트리거 탭 확인
     → SNS 트리거가 추가되어 있는지 확인
```

**테스트 방법:**
```bash
# Lambda 직접 테스트 (AWS 콘솔)
# Lambda > 함수 > 테스트 탭 > 이벤트 JSON 입력:
{
  "Records": [
    {
      "Sns": {
        "Subject": "Test Alert",
        "Message": "{\"AlarmName\":\"test-alarm\",\"NewStateValue\":\"ALARM\",\"AlarmDescription\":\"Test description\",\"NewStateReason\":\"Test reason\",\"StateChangeTime\":\"2026-01-31T12:00:00.000Z\"}"
      }
    }
  ]
}
```

---

### 문제: 알람이 너무 자주 발생

**해결: 임계값 조정**
```
CloudWatch > 경보 > 해당 알람 > 편집
→ 임계값: 80 → 90으로 상향
→ 데이터 포인트: 2/2 → 3/3으로 증가
```

**해결: 평가 기간 증가**
```
CloudWatch > 경보 > 해당 알람 > 편집
→ 기간: 5분 → 10분으로 증가
```

---

### 문제: 알람 상태가 "INSUFFICIENT DATA"

**원인: EC2 인스턴스 중지 또는 Instance ID 오류**
```
해결 1: EC2 인스턴스가 실행 중인지 확인
해결 2: 알람의 차원(Dimension)에서 InstanceId 값 확인
```

---

## 부록: AWS 리소스 정리 (삭제)

테스트 후 리소스를 삭제하려면:

```bash
# CloudWatch 알람 삭제
aws cloudwatch delete-alarms \
  --alarm-names \
    "billage-dev-cpu-utilization-high" \
    "billage-dev-status-check-failed-instance" \
    "billage-dev-status-check-failed-system"

# Lambda 함수 삭제
aws lambda delete-function \
  --function-name billage-dev-discord-notifier

# SNS 토픽 삭제 (구독도 함께 삭제됨)
aws sns delete-topic \
  --topic-arn arn:aws:sns:ap-northeast-2:123456789012:billage-dev-cloudwatch-alarms
```

---

## 참고 자료

- [AWS CloudWatch 알람 문서](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html)
- [AWS SNS 문서](https://docs.aws.amazon.com/sns/latest/dg/welcome.html)
- [AWS Lambda 문서](https://docs.aws.amazon.com/lambda/latest/dg/welcome.html)
- [Discord Webhook 문서](https://discord.com/developers/docs/resources/webhook)
