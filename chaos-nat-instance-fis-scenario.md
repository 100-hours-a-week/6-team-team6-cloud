# NAT Instance 카오스 엔지니어링 — AWS FIS 실험 설계서

> **실험 대상**: Billage NAT Instance (t3.nano, 단일 장애 지점)
> **실험 도구**: AWS Fault Injection Simulator (FIS)
> **관련 인프라**: ECR, RunPod(외부 AI), RDS, ALB, K8s 워커노드 3대
> **실제 장애 경험**: AI 추천 API 실패 → 전체 물품대여 리스트 조회 불가 (장애 전파 확인됨)

---

## 왜 NAT Instance인가?

Billage v2는 비용 최적화를 위해 NAT Gateway($32+/월) 대신 NAT Instance(t3.nano, $3.80/월)를 선택했다.
이 인스턴스는 Private Subnet의 **모든 아웃바운드 트래픽**을 중계하는 유일한 경로이며,
현재 이중화/자동 복구가 구성되어 있지 않은 **단일 장애 지점(SPOF)**이다.

### NAT를 경유하는 트래픽 목록

| 출발지 | 목적지 | 용도 | 빈도 |
|--------|--------|------|------|
| AI Pod | RunPod API (외부) | 임베딩 생성, 추천 추론 | 사용자 요청마다 |
| Backend Pod | 카카오 OAuth (외부) | 소셜 로그인 | 로그인 시 |
| 워커노드 kubelet | ECR (AWS) | 컨테이너 이미지 Pull | 배포 시 |
| 워커노드 | SSM Parameter Store (AWS) | 환경변수/시크릿 조회 | Pod 시작 시 |
| Promtail | Loki (Management VPC) | 로그 전송 | **VPC Peering → NAT 불필요** |
| Backend Pod | RDS (Private Subnet) | DB 쿼리 | **내부 통신 → NAT 불필요** |
| Backend Pod | AI Pod (K8s 내부) | 추천 API 호출 | **클러스터 내부 → NAT 불필요** |

> **핵심 인사이트**: NAT가 죽으면 사용자 인바운드 트래픽(ALB → Pod)과 내부 서비스 간 통신은 정상이지만,
> 외부 API 호출(RunPod, 카카오)과 인프라 오퍼레이션(ECR pull, SSM)이 전면 차단된다.

---

## 실험 전체 구조 (4개 시나리오)

```
시나리오 A: NAT 완전 중단 — 장애 범위 측정 (Before)
    ↓
시나리오 B: NAT 대역폭 포화 — 동시 배포 + 트래픽 부하
    ↓
[개선 적용]
    ↓
시나리오 C: 개선 후 NAT 완전 중단 — 동일 실험 재수행 (After)
    ↓
시나리오 D: 개선 후 NAT 대역폭 포화 — 동일 실험 재수행 (After)
```

---

## 시나리오 A — NAT 완전 중단: 장애 범위 전수 조사

### 가설
> "NAT Instance가 완전히 중단되면, 외부 API 의존 기능(AI 추천, 소셜 로그인)이 실패한다.
> 단, 핵심 기능(물품대여 리스트 조회, CRUD)은 외부 의존이 없으므로 정상 동작할 것이다."

### 가설의 반증 (실제 경험)
> **실제로는 AI 추천 실패가 물품대여 리스트 전체를 죽였다.**
> 이는 Backend 코드에서 AI 호출 예외가 격리되지 않고 상위로 전파되기 때문이다.
> 이 실험은 이 장애 전파 현상을 정량적으로 재현하고, 영향 범위를 전수 조사한다.

### FIS 실험 템플릿

```json
{
  "description": "Billage NAT Instance 완전 중단 - 장애 범위 측정",
  "targets": {
    "natInstance": {
      "resourceType": "aws:ec2:instance",
      "resourceTags": {
        "Name": "billage-dev-nat",
        "Role": "nat"
      },
      "selectionMode": "ALL"
    }
  },
  "actions": {
    "stopNatInstance": {
      "actionId": "aws:ec2:stop-instances",
      "description": "NAT Instance 강제 중단",
      "parameters": {
        "startInstancesAfterDuration": "PT10M"
      },
      "targets": {
        "Instances": "natInstance"
      }
    }
  },
  "stopConditions": [
    {
      "source": "aws:cloudwatch:alarm",
      "value": "arn:aws:cloudwatch:ap-northeast-2:ACCOUNT:alarm:billage-emergency-stop"
    }
  ],
  "roleArn": "arn:aws:iam::ACCOUNT:role/billage-fis-role",
  "tags": {
    "Experiment": "nat-spof-scenario-a",
    "Environment": "dev"
  }
}
```

### 실험 전 준비

```bash
# 1. Stop Condition용 CloudWatch Alarm 생성 (안전장치)
#    - Backend 5xx 에러율이 95% 초과 시 실험 자동 중단
aws cloudwatch put-metric-alarm \
  --alarm-name billage-emergency-stop \
  --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --statistic Sum \
  --period 60 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1

# 2. 부하 생성기 배포 (실험 중 실제 사용자 트래픽 시뮬레이션)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-script
  namespace: billage
data:
  load-test.js: |
    import http from 'k6/http';
    import { check, sleep } from 'k6';
    import { Rate, Trend } from 'k6/metrics';

    const errorRate = new Rate('errors');
    const rentalListDuration = new Trend('rental_list_duration');
    const recommendDuration = new Trend('recommend_duration');

    export const options = {
      vus: 30,
      duration: '15m',
      thresholds: {
        errors: ['rate<0.01'],
      },
    };

    const BASE_URL = 'http://backend-svc.billage:8080';

    export default function () {
      // 핵심 기능: 물품대여 리스트 조회
      const rentalRes = http.get(`${BASE_URL}/api/rentals`);
      rentalListDuration.add(rentalRes.timings.duration);
      check(rentalRes, {
        'rental_list_200': (r) => r.status === 200,
      }) || errorRate.add(1);

      // 부가 기능: AI 추천 게시글
      const recommendRes = http.get(`${BASE_URL}/api/rentals/recommend`);
      recommendDuration.add(recommendRes.timings.duration);
      check(recommendRes, {
        'recommend_200': (r) => r.status === 200,
      });

      // 인증 기능: 카카오 로그인 (토큰 검증)
      const authRes = http.get(`${BASE_URL}/api/auth/health`);
      check(authRes, {
        'auth_healthy': (r) => r.status === 200,
      });

      sleep(1);
    }
EOF
```

### 측정할 API 전수 목록

| API | 외부 의존 | NAT 필요 | 예상 결과 |
|-----|----------|----------|----------|
| `GET /api/rentals` (물품 리스트) | AI 추천 내부 호출 | 간접 (AI→RunPod) | **장애 전파로 실패 (검증 필요)** |
| `GET /api/rentals/{id}` (상세) | 없음 | No | 정상 |
| `POST /api/rentals` (등록) | 없음 | No | 정상 |
| `GET /api/rentals/recommend` (AI 추천) | RunPod | Yes | 실패 (타임아웃) |
| `POST /api/auth/kakao` (카카오 로그인) | 카카오 OAuth | Yes | 실패 |
| `GET /api/users/me` (내 정보) | 없음 | No | 정상 (JWT 기반) |
| `WebSocket /ws/**` (채팅) | 없음 | No | 정상 (RabbitMQ 내부) |
| `GET /actuator/health` (헬스체크) | DB + Redis 체크 | No | 정상 |
| `POST /api/images/upload` (이미지) | S3 | **VPC Endpoint 여부에 따라 다름** | 확인 필요 |

### 실험 실행 타임라인

```
T+0:00  k6 부하 테스트 시작 (Steady State 확인, 3분간)
T+3:00  ★ FIS 실험 트리거 — NAT Instance 중단
T+3:00  Prometheus Alert 감지 시간 측정 시작
T+3:30  [예상] AI 추천 API 타임아웃 시작 (RunPod 연결 불가)
T+4:00  [예상] 물품대여 리스트 API 장애 전파 시작 ← 핵심 관찰 포인트
T+4:00  [예상] 카카오 로그인 실패 시작
T+5:00  장애 범위 안정화 (어떤 API가 살고 어떤 게 죽었는지 확정)
T+8:00  장애 지속 상태에서의 시스템 안정성 확인
        - Backend Pod CPU/Memory 변화 (타임아웃 대기 스레드 누적?)
        - HikariCP 커넥션 풀 상태 (영향 없어야 함)
        - Tomcat 스레드 풀 점유율 (AI 타임아웃으로 고갈 가능성)
T+10:00 FIS 자동 복구 (NAT Instance 재시작)
T+10:30 [예상] NAT Instance 부팅 완료
T+11:00 [예상] 라우팅 테이블 경유 트래픽 정상화
T+11:30 [예상] AI 추천 API 복구
T+12:00 [예상] 전체 서비스 정상화 확인
T+15:00 k6 부하 테스트 종료
```

### 측정 지표 (SLI)

```yaml
# Prometheus Recording Rules
groups:
  - name: chaos_nat_sli
    interval: 10s
    rules:
      # SLI 1: 물품대여 리스트 가용률
      - record: sli:rental_list:availability
        expr: |
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals", status=~"2.."
          }[1m])) /
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals"
          }[1m]))

      # SLI 2: AI 추천 가용률
      - record: sli:recommend:availability
        expr: |
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals/recommend", status=~"2.."
          }[1m])) /
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals/recommend"
          }[1m]))

      # SLI 3: 전체 서비스 에러율
      - record: sli:overall:error_rate
        expr: |
          sum(rate(http_server_requests_seconds_count{
            status=~"5.."
          }[1m])) /
          sum(rate(http_server_requests_seconds_count[1m]))

      # SLI 4: Tomcat 스레드 사용률 (장애 전파 감지)
      - record: sli:tomcat:thread_utilization
        expr: |
          tomcat_threads_busy_threads /
          tomcat_threads_config_max_threads

      # SLI 5: 장애 감지 시간 (TTD)
      - record: sli:nat:time_to_detect
        expr: |
          # AlertManager가 firing한 시점 - NAT 중단 시점
          # (실험 후 수동 계산)
```

### 수집할 데이터 매트릭스

| 카테고리 | 지표 | 수집 도구 | Before (Steady) | During (Chaos) | After (Recovery) |
|---------|------|----------|----------------|----------------|------------------|
| **가용성** | 물품 리스트 API 성공률 | Prometheus | __%  | __% | __% |
| **가용성** | AI 추천 API 성공률 | Prometheus | __% | __% | __% |
| **가용성** | 카카오 로그인 성공률 | Prometheus | __% | __% | __% |
| **가용성** | WebSocket 연결 유지율 | Prometheus | __% | __% | __% |
| **성능** | 물품 리스트 p99 응답시간 | Prometheus | __ms | __ms | __ms |
| **성능** | AI 추천 p99 응답시간 | Prometheus | __ms | __ms (timeout) | __ms |
| **리소스** | Tomcat 활성 스레드 수 | Prometheus | __/200 | __/200 | __/200 |
| **리소스** | HikariCP active connections | Prometheus | __/10 | __/10 | __/10 |
| **리소스** | Backend Pod CPU 사용률 | Prometheus | __% | __% | __% |
| **리소스** | Backend Pod Memory 사용률 | Prometheus | __% | __% | __% |
| **감지** | 장애 감지 시간 (TTD) | AlertManager | - | __초 | - |
| **복구** | 서비스 복구 시간 (TTR) | 수동 기록 | - | - | __초 |

---

## 시나리오 B — NAT 대역폭 포화: 동시 배포 + 사용자 트래픽

### 가설
> "3개 서비스(AI 4GB + Backend 1GB + Frontend 1GB)를 동시에 롤링 업데이트하면서,
> AI 추천 API에 사용자 트래픽이 유입되면,
> NAT Instance(t3.nano, 베이스라인 32Mbps)의 대역폭이 포화되어
> ECR pull 지연 → Pod ImagePullBackOff → 서비스 가용 Pod 감소 → 장애가 발생할 것이다."

### 왜 FIS가 아닌 직접 실험인가
> NAT 대역폭 포화는 FIS로 주입하는 게 아니라, **실제 운영 조건을 재현**해서 발생시킨다.
> FIS의 `aws:ec2:send-spot-instance-interruptions` 같은 액션은 있지만
> "대역폭 제한"은 FIS 기본 액션에 없다. 대신 실제 배포 + 부하로 자연 발생시킨다.

### 실험 방법

```bash
# Step 1: 부하 테스트 시작 (AI 추천 API에 트래픽 유입 상태 유지)
kubectl run k6-load --image=grafana/k6 --restart=Never -- run - <<'EOF'
import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  vus: 50,
  duration: '20m',
};

export default function () {
  // AI 추천 호출 (Backend → AI Pod → RunPod 외부 호출 유발)
  http.get('http://backend-svc.billage:8080/api/rentals/recommend');
  // 물품 리스트 조회 (AI 추천 결과 포함)
  http.get('http://backend-svc.billage:8080/api/rentals');
  sleep(0.5);
}
EOF

# Step 2: 3분 후, 모든 서비스 동시 롤링 업데이트 트리거
sleep 180

kubectl set image deployment/backend \
  backend=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-backend:new-tag \
  -n billage &

kubectl set image deployment/frontend \
  frontend=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-frontend:new-tag \
  -n billage &

kubectl set image deployment/ai \
  ai=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-ai:new-tag \
  -n billage &

# Step 3: 실시간 모니터링
watch -n 5 'echo "=== Pod Status ===" && \
  kubectl get pods -n billage -o wide && \
  echo "=== ECR Pull Events ===" && \
  kubectl get events -n billage --field-selector reason=Pulling --sort-by=.lastTimestamp | tail -5'
```

### 측정 포인트

```
타임라인:

T+0:00   k6 부하 시작 (Steady State)
T+3:00   ★ 3개 서비스 동시 롤링 업데이트 트리거
T+3:10   ECR 이미지 pull 시작 (3노드 × 3서비스 = 최대 9개 동시 pull)
         NAT Instance NetworkOut 급증 시작
T+3:30   [관찰] NAT 네트워크 크레딧 소진 시작 여부
         [관찰] ECR pull 속도 저하 여부
T+5:00   [예상] Frontend/Backend 이미지 pull 완료 (각 1GB, 비교적 빠름)
         [관찰] AI 이미지 (4GB) pull 진행률
T+5:00   [관찰] 기존 AI Pod 종료 여부 (maxUnavailable 설정에 따라)
         → 기존 Pod 먼저 죽고 새 Pod가 아직 pull 중이면 AI 서비스 중단
T+8:00   [예상] AI 이미지 pull 지연 중, RunPod 호출도 NAT 경합으로 지연
T+10:00  [예상 worst case] AI Pod ImagePullBackOff + RunPod 타임아웃 동시 발생
T+15:00  [예상] 모든 이미지 pull 완료, 서비스 정상화
T+20:00  부하 테스트 종료
```

### 핵심 측정 지표

| 지표 | 측정 방법 | 관찰 포인트 |
|------|----------|------------|
| NAT NetworkOut (bytes/sec) | CloudWatch `NetworkOut` | 베이스라인 32Mbps 초과 시점 |
| NAT NetworkPacketsOut | CloudWatch `NetworkPacketsOut` | 패킷 드롭 발생 여부 |
| NAT CPU 사용률 | CloudWatch `CPUUtilization` | iptables NAT 변환 부하 |
| ECR pull 소요 시간 (서비스별) | kubectl events 타임스탬프 | AI(4GB) pull 시간 vs 정상 시 비교 |
| ImagePullBackOff 발생 여부 | kubectl get events | 타임아웃으로 pull 실패 |
| AI 추천 API 응답시간 변화 | Prometheus | 배포 중 RunPod 호출 지연 |
| 서비스별 가용 Pod 수 추이 | Prometheus kube_deployment_status | 0이 되는 구간 존재 여부 |

---

## 개선 방안 적용

### 개선 1: ECR VPC Endpoint (인프라)

> ECR 이미지 pull을 NAT 경로에서 완전히 분리한다.

```hcl
# terraform/shared/vpc-endpoints/main.tf

# ECR API Endpoint (이미지 메타데이터 조회)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.ap-northeast-2.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "billage-${var.env}-ecr-api-endpoint"
  }
}

# ECR Docker Endpoint (이미지 레이어 다운로드)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.ap-northeast-2.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "billage-${var.env}-ecr-dkr-endpoint"
  }
}

# S3 Gateway Endpoint (ECR 이미지 레이어는 S3에 저장됨)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = {
    Name = "billage-${var.env}-s3-endpoint"
  }
}

# VPC Endpoint 보안그룹
resource "aws_security_group" "vpc_endpoint" {
  name_prefix = "billage-${var.env}-vpce-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]   # VPC 내부에서만 접근
  }

  tags = {
    Name = "billage-${var.env}-vpce-sg"
  }
}
```

**비용**: ECR API + ECR DKR = Interface Endpoint 2개 × $7.2/월 = **$14.4/월**, S3 Gateway = **무료**

### 개선 2: NAT Instance ASG 자동 복구 (인프라)

> NAT Instance가 죽으면 ASG가 자동으로 새 인스턴스를 띄운다.

```hcl
# terraform/shared/network/nat-ha/main.tf

resource "aws_autoscaling_group" "nat" {
  name                = "billage-${var.env}-nat-asg"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [var.public_subnet_id]

  launch_template {
    id      = aws_launch_template.nat.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = "billage-${var.env}-nat"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "nat"
    propagate_at_launch = true
  }
}

resource "aws_launch_template" "nat" {
  name_prefix   = "billage-${var.env}-nat-"
  image_id      = data.aws_ami.nat_ami.id      # NAT 설정된 AMI
  instance_type = "t3.nano"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.nat_sg_id]
  }

  # source/dest check 비활성화는 인스턴스 레벨에서 설정
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # NAT 설정
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE

    # source/dest check 비활성화 (자기 자신에 대해)
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    aws ec2 modify-instance-attribute \
      --instance-id $INSTANCE_ID \
      --no-source-dest-check \
      --region ap-northeast-2

    # 라우팅 테이블 업데이트 (새 NAT Instance로 연결)
    aws ec2 replace-route \
      --route-table-id ${var.private_route_table_id} \
      --destination-cidr-block 0.0.0.0/0 \
      --instance-id $INSTANCE_ID \
      --region ap-northeast-2
  EOF
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.nat.name
  }
}

# NAT Instance가 라우팅 테이블을 수정할 수 있는 IAM 역할
resource "aws_iam_role_policy" "nat_route_update" {
  name = "billage-${var.env}-nat-route-update"
  role = aws_iam_role.nat.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:ReplaceRoute",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeRouteTables"
        ]
        Resource = "*"
      }
    ]
  })
}
```

**예상 복구 시간(MTTR)**: ASG 감지(~1분) + 인스턴스 부팅(~1분) + user-data 실행(~30초) = **약 2.5~3분**

### 개선 3: 격벽 패턴 — AI 장애 격리 (애플리케이션)

> AI 추천 실패가 물품대여 리스트 전체를 죽이는 장애 전파를 차단한다.

```java
// Backend: RentalService.java

@Service
@RequiredArgsConstructor
public class RentalService {

    private final RentalRepository rentalRepository;
    private final AIRecommendClient aiRecommendClient;

    /**
     * 물품대여 리스트 조회
     * - AI 추천은 부가 기능이므로, 실패해도 핵심 리스트는 반드시 반환
     */
    public RentalListResponse getRentalItems(Long userId, Pageable pageable) {
        // 1. 핵심 기능: DB에서 물품 리스트 조회 (NAT 불필요, 절대 실패하면 안 됨)
        Page<RentalItem> items = rentalRepository.findAllActive(pageable);

        // 2. 부가 기능: AI 추천 (RunPod 외부 호출 → NAT 필요 → 실패 가능)
        List<Long> recommendedIds = getRecommendationsSafely(userId);

        // 3. 조합: AI 실패해도 리스트는 정상 반환, 추천 마크만 빠짐
        return RentalListResponse.of(items, recommendedIds);
    }

    /**
     * AI 추천 호출을 격벽으로 격리
     * - CircuitBreaker: AI 서비스 5회 연속 실패 시 회로 차단, 30초 후 재시도
     * - TimeLimiter: 3초 내 응답 없으면 타임아웃
     * - Bulkhead: AI 호출용 스레드를 별도 풀(5개)로 격리 → Tomcat 메인 스레드 보호
     */
    @CircuitBreaker(name = "aiRecommend", fallbackMethod = "emptyRecommendations")
    @TimeLimiter(name = "aiRecommend")
    @Bulkhead(name = "aiRecommend", type = Bulkhead.Type.THREADPOOL)
    private CompletableFuture<List<Long>> getRecommendationsSafely(Long userId) {
        return CompletableFuture.supplyAsync(() ->
            aiRecommendClient.getRecommendations(userId)
        );
    }

    /**
     * Fallback: AI 실패 시 빈 추천 리스트 반환
     * - 로그에 경고 남기되, 사용자에게는 추천 영역만 비워서 보여줌
     */
    private CompletableFuture<List<Long>> emptyRecommendations(Long userId, Throwable t) {
        log.warn("[Bulkhead] AI 추천 서비스 일시 불가 - userId: {}, reason: {}",
                 userId, t.getMessage());
        return CompletableFuture.completedFuture(Collections.emptyList());
    }
}
```

```yaml
# application.yml - Resilience4j 설정
resilience4j:
  circuitbreaker:
    instances:
      aiRecommend:
        slidingWindowSize: 10
        failureRateThreshold: 50
        waitDurationInOpenState: 30s
        slowCallDurationThreshold: 3s
        slowCallRateThreshold: 80
        permittedNumberOfCallsInHalfOpenState: 3

  timelimiter:
    instances:
      aiRecommend:
        timeoutDuration: 3s
        cancelRunningFuture: true

  bulkhead:
    instances:
      aiRecommend:
        maxConcurrentCalls: 5         # AI 호출은 최대 5개 동시 → Tomcat 200 스레드 보호
        maxWaitDuration: 500ms        # 5개 초과 시 500ms 대기 후 fallback
```

### 개선 4: 배포 전략 개선 (K8s)

> 동시 배포로 인한 NAT 대역폭 경합을 방지한다.

```yaml
# Backend Deployment - 순차 배포, 기존 Pod 유지
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: billage
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0        # 기존 Pod를 먼저 죽이지 않음
      maxSurge: 1              # 새 Pod 1개 먼저 띄움
  template:
    spec:
      containers:
        - name: backend
          image: ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-backend:TAG
          imagePullPolicy: IfNotPresent   # 태그가 같으면 pull 안 함

---
# AI Deployment - 이미지가 크므로 더 보수적으로
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ai
  namespace: billage
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    spec:
      containers:
        - name: ai
          image: ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-ai:TAG
          # AI는 항상 최신 태그를 사용하므로 Always
          # 단, 이미지 태그를 git SHA로 관리하면 IfNotPresent도 가능
          imagePullPolicy: IfNotPresent
```

```yaml
# GitHub Actions - 순차 배포 파이프라인
# .github/workflows/deploy.yml

jobs:
  deploy-backend:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy Backend
        run: kubectl set image deployment/backend ...

      - name: Wait for rollout
        run: kubectl rollout status deployment/backend -n billage --timeout=300s

  deploy-frontend:
    needs: deploy-backend          # Backend 완료 후 시작
    runs-on: ubuntu-latest
    steps:
      - name: Deploy Frontend
        run: kubectl set image deployment/frontend ...

      - name: Wait for rollout
        run: kubectl rollout status deployment/frontend -n billage --timeout=300s

  deploy-ai:
    needs: deploy-frontend         # Frontend 완료 후 시작 (AI가 가장 크므로 마지막)
    runs-on: ubuntu-latest
    steps:
      - name: Deploy AI
        run: kubectl set image deployment/ai ...

      - name: Wait for rollout
        run: kubectl rollout status deployment/ai -n billage --timeout=600s   # 10분 (이미지 크기 고려)
```

---

## 시나리오 C — 개선 후 NAT 완전 중단 재실험 (After)

### 가설
> "ECR VPC Endpoint + NAT ASG 자동 복구 + 격벽 패턴이 적용된 상태에서
> NAT Instance가 중단되면:
> - 핵심 기능(물품 리스트, CRUD, WebSocket)은 100% 가용
> - AI 추천은 CircuitBreaker가 동작하여 빈 결과 반환 (graceful degradation)
> - CI/CD(ECR pull)는 VPC Endpoint로 정상 동작
> - NAT는 ASG가 ~3분 내 자동 복구
> - 복구 후 AI 추천도 30초 내 정상화"

### 동일 FIS 실험 수행 (시나리오 A와 동일 조건)

```json
{
  "description": "Billage NAT Instance 완전 중단 - 개선 후 검증 (After)",
  "targets": {
    "natInstance": {
      "resourceType": "aws:ec2:instance",
      "resourceTags": {
        "Name": "billage-dev-nat",
        "Role": "nat"
      },
      "selectionMode": "ALL"
    }
  },
  "actions": {
    "stopNatInstance": {
      "actionId": "aws:ec2:stop-instances",
      "parameters": {
        "startInstancesAfterDuration": "PT10M"
      },
      "targets": {
        "Instances": "natInstance"
      }
    }
  }
}
```

### Before / After 비교표

| SLI | SLO | Before (시나리오 A) | After (시나리오 C) | 판정 |
|-----|-----|--------------------|--------------------|------|
| 물품 리스트 가용률 | 99.9% | __% (장애 전파로 0% 예상) | __% (100% 예상) | ○ / × |
| AI 추천 가용률 | 95% | __% (0% 예상) | __% (0%, but graceful) | 예상됨 |
| 사용자 체감 영향 | - | 전체 서비스 불가 | 추천만 빈 칸 | ○ / × |
| CI/CD ECR pull | 정상 동작 | 실패 | 정상 (VPC Endpoint) | ○ / × |
| 장애 감지 시간 (TTD) | < 60s | __초 | __초 | ○ / × |
| NAT 복구 시간 (TTR) | < 5min | 수동 (∞) | __초 (ASG 자동) | ○ / × |
| AI 추천 복구 시간 | < 60s | NAT 수동 복구 후 __초 | NAT 자동 복구 후 __초 | ○ / × |
| Tomcat 스레드 점유율 | < 50% | __% (고갈 가능) | __% (Bulkhead 격리) | ○ / × |

---

## 시나리오 D — 개선 후 동시 배포 + 부하 재실험 (After)

### 가설
> "ECR VPC Endpoint가 적용된 상태에서 3개 서비스를 순차 배포하면,
> NAT 대역폭 포화가 발생하지 않고, 배포 중 서비스 가용률 100%를 유지할 것이다."

### Before / After 비교표

| 지표 | Before (시나리오 B) | After (시나리오 D) |
|------|--------------------|--------------------|
| ECR pull 경로 | NAT Instance (경합) | VPC Endpoint (직통) |
| AI 이미지(4GB) pull 시간 | __분 (NAT 경합) | __분 (대역폭 제한 없음) |
| NAT NetworkOut 피크 | __Mbps | __Mbps (ECR 트래픽 제거) |
| 배포 중 AI 가용 Pod 최소값 | __개 (0 가능) | __개 (최소 1 유지) |
| 배포 중 물품 리스트 가용률 | __% | __% |
| 배포 중 RunPod 응답시간 변화 | __ms (경합 지연) | __ms (영향 없음) |

---

## Grafana 대시보드 설계

### 대시보드: NAT Instance Chaos Experiment

```
┌─────────────────────────────────────────────────────────────────┐
│ Row 1: 실험 타임라인 (Annotations)                                │
│ [NAT 중단] ──────── [장애 구간] ──────── [NAT 복구] ─── [정상화]   │
├─────────────────────────────────────────────────────────────────┤
│ Row 2: 서비스 가용률 (Gauge × 4)                                  │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│ │물품 리스트│ │AI 추천   │ │카카오 인증│ │WebSocket │            │
│ │  100%    │ │   0%     │ │   0%     │ │  100%    │            │
│ └──────────┘ └──────────┘ └──────────┘ └──────────┘            │
├─────────────────────────────────────────────────────────────────┤
│ Row 3: API 응답시간 (Time Series)                                │
│ ─── 물품 리스트 p99                                              │
│ ─── AI 추천 p99                                                  │
│ ─── 전체 에러율                                                   │
├─────────────────────────────────────────────────────────────────┤
│ Row 4: NAT Instance 메트릭 (Time Series)                         │
│ ─── NetworkOut (bytes/sec)                                      │
│ ─── NetworkPacketsOut                                           │
│ ─── CPUUtilization                                              │
├─────────────────────────────────────────────────────────────────┤
│ Row 5: Backend 내부 상태 (Time Series)                            │
│ ─── Tomcat 활성 스레드 수 / max                                   │
│ ─── HikariCP active / max                                       │
│ ─── CircuitBreaker 상태 (CLOSED/OPEN/HALF_OPEN)                 │
├─────────────────────────────────────────────────────────────────┤
│ Row 6: K8s Pod 상태 (Stat)                                       │
│ Backend: 2/2 Running | Frontend: 2/2 Running | AI: 0/2 Pending │
└─────────────────────────────────────────────────────────────────┘
```

---

## 비용 분석 — 의사결정 근거

| 선택지 | 월 비용 | 가용성 수준 | MTTR | 복잡도 |
|--------|--------|------------|------|--------|
| 현행 (NAT Instance 단일) | $3.80 | SPOF, 수동 복구 | ∞ (수동) | 낮음 |
| NAT Gateway | $32 + 데이터 처리비 | AWS managed HA | 0 (자동) | 낮음 |
| NAT Instance 이중화 (2대) | $7.60 | Active-Standby | ~1분 | 높음 (Lambda 필요) |
| **NAT Instance ASG + VPC Endpoint** | **$18.20** | **자동 복구 + ECR 독립** | **~3분** | **중간** |

### 선정 근거

> **NAT Instance ASG + ECR VPC Endpoint를 채택한다.**
>
> 1. **비용**: NAT Gateway 대비 43% 절감 ($32 → $18.20)
> 2. **ECR 분리**: 배포 파이프라인이 NAT 장애와 완전히 독립
> 3. **자동 복구**: MTTR이 수동(∞) → 자동(~3분)으로 개선
> 4. **트래픽 특성**: Billage의 NAT 아웃바운드는 RunPod 호출 + 외부 OAuth 정도로,
>    t3.nano 베이스라인으로 충분하며 부하 분산 목적의 이중화는 불필요
> 5. **격벽 패턴 보완**: NAT 3분 중단 중에도 핵심 기능은 애플리케이션 레벨에서 보호

---

## 실험 결과 보고서 양식

```markdown
# Chaos Engineering Report — NAT Instance SPOF

## 실험 정보
- 일시: YYYY-MM-DD HH:MM ~ HH:MM
- 대상: billage-dev-nat (t3.nano)
- 도구: AWS FIS + k6 + Prometheus/Grafana
- 실험자: 김유찬

## Executive Summary
- 발견된 취약점: N개
- Critical: N개 / Warning: N개
- 전체 MTTR: Before __분 → After __분 (N% 개선)

## 실험별 결과
### 시나리오 A: NAT 완전 중단 (Before)
- [Before/After 비교표 삽입]
- [Grafana 스크린샷 삽입]
- 발견 사항:
  1. ...
  2. ...

### 시나리오 B: NAT 대역폭 포화 (Before)
- ...

## 적용한 개선 사항
1. ECR VPC Endpoint 도입 (PR #XX)
2. NAT Instance ASG 전환 (PR #XX)
3. Backend 격벽 패턴 적용 (PR #XX)
4. 배포 전략 순차화 (PR #XX)

### 시나리오 C: NAT 완전 중단 (After)
- ...

### 시나리오 D: 동시 배포 + 부하 (After)
- ...

## SLO 달성 여부
| SLI | SLO 기준 | Before | After | 달성 |
|-----|---------|--------|-------|------|
| 핵심 기능 가용률 | 99.9% | __% | __% | ○/× |
| 장애 감지 시간 | < 60s | __s | __s | ○/× |
| 장애 복구 시간 | < 5min | 수동 | __s | ○/× |

## 비용 영향
- 월 추가 비용: +$14.40 (VPC Endpoint)
- 가용성 개선: SPOF 제거, MTTR ∞ → 3분

## 후속 과제
- [ ] SSM Parameter Store VPC Endpoint 추가 검토
- [ ] S3 이미지 업로드 경로 확인 (VPC Endpoint 필요 여부)
- [ ] AI 서비스 RunPod 호출 Circuit Breaker 튜닝 (실측 기반)
```
