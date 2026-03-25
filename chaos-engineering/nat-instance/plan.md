# NAT Instance 카오스 엔지니어링 — 실행 계획서

> **대상 환경**: Billage kubeadm 클러스터 (10.30.0.0/16)
> **실험 대상**: NAT Instance (NAT Gateway → NAT Instance 전환 후)
> **실험 도구**: AWS FIS + k6 + Prometheus/Grafana
> **실험자**: 김유찬
> **작성일**: 2026-03-25

---

## 0. 아키텍처 분석

### 0.1 현재 상태 (AS-IS) — NAT Gateway

```
┌─────────────────────────────────────────────────────────────────────┐
│                    kubeadm VPC (10.30.0.0/16)                       │
│                                                                     │
│  ┌──────────── Public Subnets ────────────┐                        │
│  │  NAT Gateway ($32/월) ──→ IGW ──→ Internet                      │
│  │  (AWS managed, AZ 내 HA)              │                         │
│  └────────────────────────────────────────┘                        │
│          ▲                                                          │
│          │ 0.0.0.0/0 (all private route tables)                     │
│  ┌──────────── Private Subnets ───────────┐                        │
│  │  CP: cp-01~03  (control-plane)         │                        │
│  │  App: app-01~04 (workload)             │──── VPC Peering ──┐    │
│  │  Data: data-01~03 (data)               │                   │    │
│  └────────────────────────────────────────┘                   │    │
└─────────────────────────────────────────────────────────────────────┘
                                                                │
┌───────────────────────────────────────────────────────────────▼─────┐
│                    dev v2 VPC (10.0.0.0/16)                         │
│  ┌──────────── Private Subnets ───────────┐                        │
│  │  RDS MySQL 8.0 / RabbitMQ / Kafka      │                        │
│  └────────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────┘
```

> **현재 문제**: NAT Gateway는 FIS `aws:ec2:stop-instances`로 중단할 수 없다.
> NAT Instance 카오스 실험을 위해서는 먼저 **kubeadm VPC 내에 NAT Instance를 구축**해야 한다.

### 0.2 목표 상태 (TO-BE) — NAT Instance (실험 대상)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    kubeadm VPC (10.30.0.0/16)                       │
│                                                                     │
│  ┌──────────── Public Subnet (2a) ────────┐                        │
│  │  ★ NAT Instance (t3.nano, $3.80/월)    │                        │
│  │    - source_dest_check = false          │                        │
│  │    - iptables MASQUERADE                │──→ IGW ──→ Internet   │
│  │    - Role=nat 태그 (FIS 타겟)           │                        │
│  └────────────────────────────────────────┘                        │
│          ▲                                                          │
│          │ 0.0.0.0/0 → NAT Instance ENI                             │
│  ┌──────────── Private Subnets ───────────┐                        │
│  │  CP: cp-01~03    ──→ ECR, SSM          │                        │
│  │  App: app-01~04  ──→ RunPod, Kakao OAuth│──── VPC Peering ──┐   │
│  │  Data: data-01~03 ──→ ECR              │                   │    │
│  └────────────────────────────────────────┘                   │    │
└─────────────────────────────────────────────────────────────────────┘
                                                                │
┌───────────────────────────────────────────────────────────────▼─────┐
│                    dev v2 VPC (10.0.0.0/16)                         │
│  ┌──────────── Private Subnets ───────────┐                        │
│  │  RDS MySQL 8.0 / RabbitMQ / Kafka      │ ← VPC Peering (NAT 무관)│
│  └────────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────┘
```

> **이 전환을 통해**: FIS `aws:ec2:stop-instances`로 NAT를 중단시켜
> ECR pull, RunPod, Kakao OAuth 장애를 의도적으로 발생시키고 영향 범위를 측정한다.

### 0.3 트래픽 경로 매핑 — 무엇이 NAT를 경유하는가?

| 출발지 | 목적지 | 경로 | NAT 필요 |
|--------|--------|------|----------|
| Backend Pod | RDS MySQL | VPC Peering (10.30 → 10.0) | **No** |
| Backend Pod | RabbitMQ | VPC Peering (10.30 → 10.0) | **No** |
| Backend/AI Pod | Kafka | VPC Peering (10.30 → 10.0) | **No** |
| AI Pod | RunPod API (외부) | NAT → IGW → Internet | **Yes** |
| Backend Pod | Kakao OAuth (외부) | NAT → IGW → Internet | **Yes** |
| containerd | ECR (AWS) | NAT → IGW → Internet | **Yes** |
| kubelet | SSM Parameter Store | NAT → IGW → Internet | **Yes** |
| Promtail | Loki (Mgmt VPC) | VPC Peering | **No** |
| ALB | ingress-nginx → Pod | Inbound (NAT 무관) | **No** |
| Pod ↔ Pod | Calico overlay | 클러스터 내부 | **No** |

> **핵심 인사이트**: kubeadm 환경은 v2 dev보다 NAT 의존도가 **낮다**.
> 데이터 경로(RDS, RabbitMQ, Kafka)가 VPC Peering으로 분리되어 있어
> NAT 장애 시에도 핵심 데이터 통신은 영향 없음.
> 그러나 **외부 API(RunPod, Kakao)와 인프라 오퍼레이션(ECR, SSM)**은 전면 차단된다.

### 0.4 NAT Gateway → NAT Instance 전환 (비용 최적화)

| 항목 | NAT Gateway | NAT Instance (t3.nano) |
|------|-------------|------------------------|
| 월 비용 | ~$32 + 데이터 처리비 | ~$3.80 |
| 가용성 | AZ 내 HA (AWS managed) | **SPOF** (단일 인스턴스) |
| 대역폭 | 최대 100Gbps | 베이스라인 ~32Mbps (burst 가능) |
| 장애 복구 | 자동 | **수동 (기본값)** |

> **전환 동기**: 월 $28 절감. 단, SPOF가 되므로 카오스 엔지니어링으로 영향 범위를 검증하고
> 개선 조치(ASG 자동 복구, VPC Endpoint, 격벽 패턴)를 적용하여 리스크를 통제한다.

---

## 1. 전체 실행 플로우

```
Phase 1: NAT Instance 구축      ← kubeadm VPC에 NAT GW → NAT Instance 전환 (Terraform)
    ↓
Phase 2: 모니터링 구축          ← 실험 전 필수 (관측 없이 실험 불가)
    ↓
Phase 3: Steady State 정의      ← 정상 상태 기준선 24시간 수집
    ↓
Phase 4: 실험 A — NAT 완전 중단  ← FIS 장애 주입 (Before)
    ↓
Phase 5: 실험 B — NAT 대역폭 포화 ← 동시 배포 + 부하 (Before)
    ↓
Phase 6: 개선 적용              ← VPC Endpoint + ASG + 격벽 패턴
    ↓
Phase 7: 재실험 (After)         ← 동일 조건으로 Before/After 비교
    ↓
Phase 8: 보고서 작성            ← SLO 달성 여부 판정
```

---

## Phase 1: kubeadm VPC에 NAT Instance 구축

> **Why**: 현재 kubeadm VPC는 NAT Gateway를 사용 중이다.
> NAT Gateway는 AWS managed 서비스로 FIS `aws:ec2:stop-instances`가 불가능하다.
> 카오스 실험을 위해 먼저 **NAT Gateway를 NAT Instance로 교체**해야 한다.
> 이 전환 자체가 비용 최적화($32/월 → $3.80/월)이기도 하다.

### 1.1 변경 대상 파일

```
kubeadm/envs/prod/modules/network/main.tf
```

### 1.2 제거할 리소스 (NAT Gateway)

현재 `main.tf`의 line 158~189에 있는 3개 리소스를 제거한다:

```hcl
# ❌ 제거: NAT Gateway 관련 (3개 리소스)

resource "aws_eip" "nat" {                    # line 158-167 → 제거
  domain = "vpc"
  tags = { Name = "${var.cluster_name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {           # line 169-181 → 제거
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.availability_zones[0]].id
  ...
}

resource "aws_route" "private_default" {      # line 183-189 → 교체
  ...
  nat_gateway_id = aws_nat_gateway.this.id    # ← 이 참조를 변경
}
```

### 1.3 추가할 리소스 (NAT Instance)

```hcl
# ✅ 추가: NAT Instance 관련 리소스

# --- AMI ---
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Security Group ---
resource "aws_security_group" "nat" {
  name_prefix = "${var.cluster_name}-nat-"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "All traffic from private subnets (CP + Worker)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = concat(
      values(local.control_plane_subnet_cidrs),
      values(local.worker_subnet_cidrs)
    )
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-sg"
  })
}

# --- NAT Instance ---
resource "aws_instance" "nat" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.nano"                                    # ~$3.80/월
  subnet_id              = aws_subnet.public[var.availability_zones[0]].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false                                        # NAT 필수

  user_data = <<-USERDATA
    #!/bin/bash
    set -e
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1

    PUB_IF=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o $PUB_IF -s ${var.vpc_cidr} -j MASQUERADE
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -s ${var.vpc_cidr} -o $PUB_IF -j ACCEPT

    yum install -y iptables-services 2>/dev/null || true
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    systemctl enable iptables 2>/dev/null || true
  USERDATA

  monitoring = true   # Detailed Monitoring (CloudWatch 1분 간격)

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat"
    Role = "nat"      # ★ FIS 타겟팅용 태그 — 이 태그로 실험 대상을 식별
  })
}

# --- Private Route → NAT Instance ENI (교체) ---
resource "aws_route" "private_default" {
  for_each = toset(var.availability_zones)

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id  # ★ 핵심 변경
  # 기존: nat_gateway_id = aws_nat_gateway.this.id
}
```

### 1.4 Output 변경

```hcl
# 기존 output 교체
output "nat_instance_id" {        # 기존: nat_gateway_id
  value = aws_instance.nat.id
}

output "nat_instance_private_ip" {
  value = aws_instance.nat.private_ip
}
```

### 1.5 전환 실행 절차

```bash
# 1. Plan — 변경 사항 확인 (NAT GW destroy + NAT Instance create)
cd kubeadm/envs/prod
terraform plan

# 예상 출력:
#   - aws_eip.nat                → destroy
#   - aws_nat_gateway.this       → destroy
#   - aws_route.private_default  → update (nat_gateway_id → network_interface_id)
#   + aws_instance.nat           → create
#   + aws_security_group.nat     → create

# 2. Apply
terraform apply

# ⚠️ 주의: 전환 중 ~2분간 Private Subnet의 아웃바운드가 끊김
# 기존 Pod는 영향 없음 (이미 실행 중), ECR pull만 일시 차단

# 3. 전환 직후 검증 (워커노드에서 외부 연결 확인)
aws ssm start-session --target <APP_01_INSTANCE_ID>

# 외부 연결 테스트
curl -s -o /dev/null -w "%{http_code}" https://api.ecr.ap-northeast-2.amazonaws.com/
# → 200 이면 정상

# RunPod 연결 테스트 (AI Pod가 사용하는 외부 API)
curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://api.runpod.ai/health
# → 200 이면 정상

# 4. ECR pull 검증
kubectl run ecr-test \
  --image=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-backend:latest \
  --restart=Never --rm -it -- echo "ECR pull OK"

# 5. VPC Peering 통신 확인 (NAT 무관이어야 함)
kubectl run db-test --image=busybox --restart=Never --rm -it -- \
  nc -zv <RDS_ENDPOINT> 3306
# → Connection succeeded 이면 정상
```

### 1.6 Rollback 계획

```bash
# NAT Instance에 문제 발생 시 → NAT Gateway로 즉시 복귀
# git revert로 Terraform 변경 취소 후 apply
git revert HEAD
terraform apply
```

---

## Phase 2: 모니터링 구축

> **현재 상태**: 모니터링(Prometheus/Grafana/Loki) 미설치.
> 카오스 실험의 전제 조건은 **관측 가능성**이다. 측정 없이는 장애를 정량화할 수 없다.

### 2.0 모니터링 전략 — 왜 CloudWatch + Prometheus 둘 다 필요한가

카오스 실험에서 측정해야 하는 것은 **3가지 계층**이다:

```
┌──────────────────────────────────────────────────────────────────┐
│                     관측해야 하는 3가지 계층                        │
│                                                                  │
│  ① 원인 계층 (CloudWatch)                                        │
│     "NAT가 죽었는가? 대역폭이 포화됐는가?"                          │
│     → EC2 메트릭: StatusCheck, NetworkOut, CPUCredit              │
│     → NAT Instance는 K8s 밖의 EC2이므로 Prometheus로 수집 불가      │
│                                                                  │
│  ② 결과 계층 (Prometheus — 애플리케이션 메트릭)                     │
│     "어떤 API가 죽었는가? 장애가 전파됐는가?"                        │
│     → API별 HTTP 상태 코드, 응답시간, 에러율                        │
│     → Pod 내부 메트릭: Tomcat 스레드, HikariCP, CircuitBreaker     │
│     → CloudWatch는 Pod 내부를 볼 수 없으므로 Prometheus 필수         │
│                                                                  │
│  ③ 플랫폼 계층 (Prometheus — K8s 메트릭)                           │
│     "Pod가 정상인가? 배포가 가능한가?"                               │
│     → Pod status, ImagePullBackOff, Deployment available replicas │
│     → kube-state-metrics + node-exporter (kube-prometheus-stack)  │
└──────────────────────────────────────────────────────────────────┘
```

| 도구 | 관측 대상 | 카오스 실험에서의 역할 |
|------|----------|---------------------|
| **CloudWatch** | NAT Instance (EC2) | **원인 확인** — NAT가 죽었는지, 대역폭이 포화됐는지 |
| **Prometheus** | Backend/AI/Frontend Pod | **결과 확인** — 어떤 API가 영향받았는지, 장애 전파 여부 |
| **Prometheus** | K8s 리소스 (kube-state-metrics) | **플랫폼 확인** — Pod 상태, ECR pull 실패 여부 |

> **핵심**: 시스템 메트릭(CPU, Network)만으로는 "NAT가 죽었다"만 알 수 있다.
> 카오스 실험의 진짜 목적은 **"NAT가 죽었을 때 어떤 API가 영향받고, 장애가 어디까지 전파되는가"**를 측정하는 것이다.
> 이를 위해 **API별 성공/실패율**, **응답시간**, **스레드 풀 상태** 등 애플리케이션 메트릭이 반드시 필요하다.

### 2.1 CloudWatch — 원인 계층 (NAT Instance 상태)

NAT Instance는 K8s 클러스터 **밖**의 EC2 인스턴스다. Prometheus exporter를 설치할 수 없으므로
AWS CloudWatch로만 관측 가능하다.

| CloudWatch 메트릭 | 의미 | 카오스 실험에서 보는 포인트 |
|-------------------|------|--------------------------|
| `StatusCheckFailed` | 인스턴스 장애 여부 | FIS stop-instances 트리거 시 1로 전환되는 시점 |
| `NetworkOut` (bytes) | 아웃바운드 트래픽량 | 시나리오 B에서 32Mbps 포화 시점 확인 |
| `NetworkPacketsOut` | 초당 패킷 수 | 포화 시 패킷 드롭 발생 여부 |
| `CPUUtilization` | iptables NAT 변환 부하 | 대역폭 포화 시 CPU도 같이 올라가는지 |
| `CPUCreditBalance` | t3.nano burst 크레딧 | 크레딧 고갈 → 성능 급락 시점 |

```bash
# CloudWatch Alarm — FIS Stop Condition용 (실험 안전장치)
aws cloudwatch put-metric-alarm \
  --alarm-name billage-kubeadm-nat-status-check \
  --namespace AWS/EC2 \
  --metric-name StatusCheckFailed \
  --dimensions Name=InstanceId,Value=<NAT_INSTANCE_ID> \
  --statistic Maximum \
  --period 60 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --alarm-actions arn:aws:sns:ap-northeast-2:ACCOUNT:billage-alerts
```

### 2.2 Prometheus — 결과 계층 (API별 장애 & 장애 전파)

> **이 계층이 카오스 실험의 핵심이다.**
> "NAT가 죽으면 어떤 API가 죽는가?" → API별 HTTP 메트릭
> "AI 실패가 물품 리스트까지 죽이는가?" → 장애 전파 감지
> "Tomcat 스레드가 AI 타임아웃 대기로 고갈되는가?" → 런타임 메트릭

#### Prometheus + Grafana 설치

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
  --set grafana.adminPassword=<GRAFANA_PASSWORD> \
  --set grafana.service.type=NodePort \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=5Gi
```

#### Spring Boot (Backend) — 메트릭 노출

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health,prometheus,metrics
  metrics:
    export:
      prometheus:
        enabled: true
    tags:
      application: billage-backend
```

#### FastAPI (AI) — 메트릭 노출

```python
# main.py
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI()
Instrumentator().instrument(app).expose(app)
```

#### 수집 메트릭과 카오스 실험에서의 의미

**API 가용성 메트릭 (장애 범위 측정)**:

| 메트릭 | PromQL 예시 | 카오스 실험에서 보는 것 |
|--------|------------|----------------------|
| API별 성공률 | `rate(http_server_requests_seconds_count{status=~"2.."}[1m]) / rate(http_server_requests_seconds_count[1m])` | `/api/rentals`는 살아있는데 `/api/rentals/recommend`만 죽는지, 아니면 **둘 다 죽는지** (장애 전파) |
| API별 에러율 | `rate(http_server_requests_seconds_count{status=~"5.."}[1m])` | 어떤 API에서 5xx가 발생하는지 — uri 라벨로 구분 |
| API별 p99 응답시간 | `histogram_quantile(0.99, rate(http_server_requests_seconds_bucket[1m]))` | AI 추천 API가 타임아웃(30s)까지 늘어나는지, 그게 물품 리스트 응답시간도 같이 올리는지 |

**장애 전파 감지 메트릭 (핵심)**:

| 메트릭 | 의미 | 왜 중요한가 |
|--------|------|------------|
| `tomcat_threads_busy_threads` | 현재 요청 처리 중인 스레드 수 | AI 호출이 30초 타임아웃으로 대기하면 스레드가 쌓여서 **전체 API가 먹통** |
| `tomcat_threads_config_max_threads` | 스레드 풀 최대값 (기본 200) | busy가 max에 도달하면 새 요청을 받지 못함 = **장애 전파 확정** |
| `hikaricp_connections_active` | DB 커넥션 사용 수 | NAT 장애와 무관하게 안정적이어야 함 (VPC Peering) |
| `resilience4j_circuitbreaker_state` | 0=CLOSED, 1=OPEN, 2=HALF_OPEN | 개선 후: AI 호출 5회 실패 → OPEN → fallback = 장애 전파 **차단** |
| `resilience4j_bulkhead_available_concurrent_calls` | Bulkhead 남은 슬롯 | 개선 후: AI 호출을 별도 스레드풀(5개)로 격리 → Tomcat 200스레드 보호 |

**K8s 플랫폼 메트릭 (배포 영향)**:

| 메트릭 | 의미 | 카오스 실험에서 보는 것 |
|--------|------|----------------------|
| `kube_deployment_status_replicas_available` | Deployment의 가용 Pod 수 | 배포 중 0이 되는 구간이 있는지 |
| `kube_pod_container_status_waiting_reason` | Pod 대기 이유 | `ImagePullBackOff` 발생 = NAT 장애로 ECR 차단 |
| `kube_pod_status_phase` | Pod 상태 | NAT 장애 중에도 기존 Running Pod는 유지되는지 |

### 2.3 ServiceMonitor — Prometheus가 애플리케이션 메트릭을 수집하도록 연결

```yaml
# monitoring/servicemonitor-backend.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: billage-backend
  namespace: monitoring
  labels:
    release: kube-prometheus
spec:
  namespaceSelector:
    matchNames: [billage]
  selector:
    matchLabels:
      app: billage-backend
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
---
# monitoring/servicemonitor-ai.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: billage-ai
  namespace: monitoring
  labels:
    release: kube-prometheus
spec:
  namespaceSelector:
    matchNames: [billage]
  selector:
    matchLabels:
      app: billage-ai
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

### 2.4 카오스 실험 전용 Grafana 대시보드

> 한 대시보드에서 **원인(NAT) → 결과(API) → 전파(스레드/커넥션)** 을 한눈에 봐야 한다.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Row 1: 실험 타임라인 (Annotations)                                    │
│ [Steady State] ──── [★ NAT 중단] ──── [장애 구간] ──── [복구] ──── [정상화] │
├─────────────────────────────────────────────────────────────────────┤
│ Row 2: API별 가용률 (Gauge × 5)          ← ② 결과 계층              │
│ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐            │
│ │물품리스트│ │AI 추천  │ │카카오인증│ │WebSocket│ │헬스체크  │           │
│ │  ???%  │ │  ???%  │ │  ???%  │ │  ???%  │ │  ???%  │            │
│ └────────┘ └────────┘ └────────┘ └────────┘ └────────┘            │
│                                                                     │
│ "물품리스트와 AI추천이 동시에 0%면 → 장애 전파 확인"                     │
│ "물품리스트 100%, AI추천 0%면 → 격벽 패턴 정상 동작"                    │
├─────────────────────────────────────────────────────────────────────┤
│ Row 3: API 응답시간 (Time Series)        ← ② 결과 계층              │
│ ─── /api/rentals p99       ─── /api/rentals/recommend p99          │
│ ─── /api/auth/kakao p99    ─── 5xx error rate                      │
│                                                                     │
│ "AI 추천 p99이 30s(타임아웃)까지 올라가면서                             │
│  물품 리스트 p99도 같이 올라가면 → 장애 전파 경로 확인"                  │
├─────────────────────────────────────────────────────────────────────┤
│ Row 4: 장애 전파 감지 (Time Series)      ← ② 결과 계층 (핵심!)       │
│ ─── Tomcat busy threads / max (200)                                │
│ ─── HikariCP active / max                                          │
│ ─── CircuitBreaker state (CLOSED/OPEN/HALF_OPEN)                   │
│                                                                     │
│ "Tomcat 스레드가 200/200에 도달하면 = 모든 API 먹통 (장애 전파 확정)"   │
│ "HikariCP는 안정적이면 = DB 경로(VPC Peering)는 NAT 무관 증명"        │
├─────────────────────────────────────────────────────────────────────┤
│ Row 5: NAT Instance 상태 (Time Series)   ← ① 원인 계층              │
│ ─── NetworkOut (bytes/sec)  ─── CPUUtilization                     │
│ ─── CPUCreditBalance        ─── StatusCheckFailed                  │
│                                                                     │
│ "StatusCheck=1 된 시점과 API 에러 시작 시점의 차이 = 장애 감지 시간"     │
├─────────────────────────────────────────────────────────────────────┤
│ Row 6: K8s Pod 상태 (Stat)               ← ③ 플랫폼 계층            │
│ Backend: ?/? | Frontend: ?/? | AI: ?/? | ImagePullBackOff 여부       │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.5 AlertManager 규칙 — 장애 전파 자동 감지

```yaml
# monitoring/alerts-chaos-nat.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: chaos-nat-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus
spec:
  groups:
    - name: nat-chaos-experiment
      rules:

        # ★ 장애 전파 감지 — AI 실패가 물품 리스트까지 죽이는가?
        - alert: RentalListDegradedByAI
          expr: |
            (
              sum(rate(http_server_requests_seconds_count{uri="/api/rentals",status=~"5.."}[2m]))
              /
              sum(rate(http_server_requests_seconds_count{uri="/api/rentals"}[2m]))
            ) > 0.1
          for: 30s
          labels:
            severity: critical
          annotations:
            summary: "물품 리스트 API 에러율 10% 초과 — AI 장애 전파 발생"
            description: |
              NAT 장애 → AI 추천 실패 → 물품 리스트 전체 장애 전파 확인.
              Tomcat 스레드 풀 상태도 확인 필요.

        # ★ Tomcat 스레드 고갈 — 장애 전파의 메커니즘
        - alert: TomcatThreadPoolExhaustion
          expr: |
            tomcat_threads_busy_threads / tomcat_threads_config_max_threads > 0.8
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Tomcat 스레드 풀 80% 초과 — 장애 전파 임박"
            description: |
              AI 호출 타임아웃(30s) 대기 스레드가 누적되어 스레드 풀 고갈 중.
              max(200)에 도달하면 모든 API(물품 리스트 포함)가 응답 불가.

        # AI 추천 API 자체 장애 (외부 의존이므로 예상된 장애)
        - alert: AIRecommendDown
          expr: |
            (
              sum(rate(http_server_requests_seconds_count{uri="/api/rentals/recommend",status=~"5.."}[2m]))
              /
              sum(rate(http_server_requests_seconds_count{uri="/api/rentals/recommend"}[2m]))
            ) > 0.5
          for: 30s
          labels:
            severity: warning
          annotations:
            summary: "AI 추천 API 에러율 50% 초과 — NAT 장애로 RunPod 연결 불가"

        # ECR pull 실패 — 배포 영향
        - alert: ImagePullFailure
          expr: |
            increase(kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"}[5m]) > 0
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "ImagePullBackOff 발생 — NAT 장애로 ECR pull 불가"

        # VPC Peering 경로 정상 확인 (NAT 장애와 무관해야 함)
        - alert: DBConnectionDegraded
          expr: |
            hikaricp_connections_active / hikaricp_connections_max > 0.8
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "DB 커넥션 풀 80% 초과 — VPC Peering 경로 문제 가능성 (NAT 무관이어야 함)"
```

---

## Phase 3: Steady State 정의

> NAT 전환 후 최소 **24시간** 안정 운영 확인 후 실험 진행.

### 3.1 SLI 기준선 수집

```yaml
# Prometheus Recording Rules — Steady State 기준선
groups:
  - name: chaos_nat_steady_state
    interval: 15s
    rules:
      # 물품 리스트 API 가용률
      - record: sli:rental_list:availability
        expr: |
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals", status=~"2.."
          }[5m])) /
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals"
          }[5m]))

      # AI 추천 API 가용률
      - record: sli:recommend:availability
        expr: |
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals/recommend", status=~"2.."
          }[5m])) /
          sum(rate(http_server_requests_seconds_count{
            uri="/api/rentals/recommend"
          }[5m]))

      # 전체 5xx 에러율
      - record: sli:overall:error_rate
        expr: |
          sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) /
          sum(rate(http_server_requests_seconds_count[5m]))

      # Tomcat 스레드 사용률
      - record: sli:tomcat:thread_utilization
        expr: |
          tomcat_threads_busy_threads /
          tomcat_threads_config_max_threads
```

### 3.2 SLI/SLO 매트릭스

| SLI | SLO 기준 | Steady State (예상) |
|-----|---------|-------------------|
| 물품 리스트 가용률 | ≥ 99.9% | ~100% |
| AI 추천 가용률 | ≥ 95% | ~99% |
| 카카오 로그인 성공률 | ≥ 99% | ~100% |
| 물품 리스트 p99 응답시간 | < 500ms | ~100ms |
| AI 추천 p99 응답시간 | < 5s | ~2s |
| Tomcat 스레드 사용률 | < 50% | ~10% |
| HikariCP 활성 커넥션 | < 50% | ~10% |
| ECR pull 성공률 | 100% | 100% |

---

## Phase 4: 실험 A — NAT Instance 완전 중단 (Before)

### 4.1 가설

> **"NAT Instance가 완전히 중단되면:**
> 1. 외부 API 의존 기능(AI 추천, 카카오 로그인)이 실패한다.
> 2. 핵심 기능(물품 리스트 CRUD)은 DB가 VPC Peering 경유이므로 **정상 동작할 것이다.**
> 3. 단, AI 추천 실패가 물품 리스트 응답에 장애 전파될 가능성이 있다. (v2에서 확인된 버그)
> 4. 기존 Pod는 계속 동작하지만, 새 Pod 배포(ECR pull)는 실패한다."

### 4.2 FIS IAM 역할 준비

```bash
# FIS 서비스 역할 생성
cat > fis-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "fis.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name billage-kubeadm-fis-role \
  --assume-role-policy-document file://fis-trust-policy.json

# EC2 인스턴스 중지/시작 권한
cat > fis-ec2-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:StopInstances",
        "ec2:StartInstances",
        "ec2:DescribeInstances"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Role": "nat"
        }
      }
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name billage-kubeadm-fis-role \
  --policy-name fis-ec2-stop-nat \
  --policy-document file://fis-ec2-policy.json
```

### 4.3 Stop Condition (안전장치)

```bash
# 긴급 중단 알람 — 핵심 API 완전 장애 시 실험 자동 중단
aws cloudwatch put-metric-alarm \
  --alarm-name billage-kubeadm-chaos-emergency-stop \
  --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --statistic Sum \
  --period 60 \
  --threshold 200 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --treat-missing-data notBreaching
```

### 4.4 FIS 실험 템플릿

```json
{
  "description": "Billage kubeadm NAT Instance 완전 중단 - Before 측정",
  "targets": {
    "natInstance": {
      "resourceType": "aws:ec2:instance",
      "resourceTags": {
        "Name": "billage-kubeadm-prod-nat",
        "Role": "nat"
      },
      "selectionMode": "ALL"
    }
  },
  "actions": {
    "stopNatInstance": {
      "actionId": "aws:ec2:stop-instances",
      "description": "NAT Instance 강제 중단 (10분 후 자동 재시작)",
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
      "value": "arn:aws:cloudwatch:ap-northeast-2:ACCOUNT:alarm:billage-kubeadm-chaos-emergency-stop"
    }
  ],
  "roleArn": "arn:aws:iam::ACCOUNT:role/billage-kubeadm-fis-role",
  "tags": {
    "Experiment": "nat-instance-stop-before",
    "Environment": "kubeadm-prod",
    "Phase": "before-improvement"
  }
}
```

### 4.5 부하 생성기 (k6)

```yaml
# chaos-engineering/nat-instance/k6-load-test.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-nat-chaos-script
  namespace: billage
data:
  nat-chaos-test.js: |
    import http from 'k6/http';
    import { check, sleep } from 'k6';
    import { Rate, Trend, Counter } from 'k6/metrics';

    // Custom metrics
    const rentalListErrors = new Rate('rental_list_errors');
    const recommendErrors = new Rate('recommend_errors');
    const rentalListDuration = new Trend('rental_list_duration');
    const recommendDuration = new Trend('recommend_duration');
    const authErrors = new Counter('auth_errors');

    export const options = {
      stages: [
        { duration: '3m', target: 30 },   // Steady State 확인
        { duration: '12m', target: 30 },   // NAT 중단 구간 (T+3에 FIS 트리거)
        { duration: '5m', target: 30 },    // 복구 확인
      ],
      thresholds: {
        // Steady State에서의 기준 (실험 중에는 위반 예상)
        rental_list_errors: [{ threshold: 'rate<0.001', abortOnFail: false }],
      },
    };

    const BASE_URL = 'http://billage-backend-svc.billage.svc.cluster.local:8080';

    export default function () {
      // 1. 핵심 기능: 물품 리스트 조회 (DB는 VPC Peering → NAT 무관이어야 함)
      const rentalRes = http.get(`${BASE_URL}/api/rentals`, { timeout: '10s' });
      rentalListDuration.add(rentalRes.timings.duration);
      const rentalOk = check(rentalRes, {
        'rental_list_2xx': (r) => r.status >= 200 && r.status < 300,
      });
      if (!rentalOk) rentalListErrors.add(1);
      else rentalListErrors.add(0);

      // 2. AI 추천 (RunPod 외부 호출 → NAT 필요 → 실패 예상)
      const recommendRes = http.get(`${BASE_URL}/api/rentals/recommend`, { timeout: '10s' });
      recommendDuration.add(recommendRes.timings.duration);
      const recOk = check(recommendRes, {
        'recommend_2xx': (r) => r.status >= 200 && r.status < 300,
      });
      if (!recOk) recommendErrors.add(1);
      else recommendErrors.add(0);

      // 3. 헬스체크 (DB + Redis → VPC Peering → NAT 무관)
      const healthRes = http.get(`${BASE_URL}/actuator/health`, { timeout: '5s' });
      check(healthRes, {
        'health_ok': (r) => r.status === 200,
      });

      sleep(1);
    }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-nat-chaos-load
  namespace: billage
spec:
  template:
    spec:
      containers:
        - name: k6
          image: grafana/k6:latest
          command: ['k6', 'run', '/scripts/nat-chaos-test.js']
          volumeMounts:
            - name: k6-script
              mountPath: /scripts
      volumes:
        - name: k6-script
          configMap:
            name: k6-nat-chaos-script
      restartPolicy: Never
      nodeSelector:
        node-role: app
  backoffLimit: 0
```

### 4.6 실행 타임라인

```
T+0:00   k6 부하 테스트 시작 (30 VU ramp-up)
T+3:00   ★ Steady State 확인 완료 — 기준선 기록
T+3:00   ★ FIS 실험 트리거 — NAT Instance 강제 중단
         ┌─────────────────────────────────────────────────────┐
T+3:10   │ [예상] RunPod 연결 타임아웃 시작 (AI 추천 실패)       │
T+3:10   │ [예상] Kakao OAuth 연결 실패                         │
T+3:30   │ [관찰] 물품 리스트 API: 정상 vs 장애 전파? ← 핵심!    │
T+4:00   │ [관찰] Tomcat 스레드: AI 타임아웃 대기로 누적?         │
T+5:00   │ [관찰] 장애 범위 안정화 — 어떤 API가 살고 죽었는지     │
T+8:00   │ [관찰] 장기 장애 시 리소스 변화                       │
         │         - Pod CPU/Memory 트렌드                      │
         │         - HikariCP 커넥션 풀 (영향 없어야 함)          │
         │         - Tomcat 스레드 점유율 (고갈 가능성)            │
T+10:00  │ [관찰] ECR pull 시도 시 ImagePullBackOff 확인         │
         └─────────────────────────────────────────────────────┘
T+13:00  FIS 자동 복구 — NAT Instance 재시작
T+13:30  [예상] NAT Instance 부팅 완료, iptables 복원
T+14:00  [예상] 라우팅 트래픽 정상화
T+14:30  [예상] RunPod/Kakao OAuth 연결 복구
T+15:00  [예상] 전체 서비스 정상화 확인
T+20:00  k6 부하 테스트 종료
```

### 4.7 실험 실행 명령

```bash
# ===== Pre-flight 체크리스트 =====

# 1. 모니터링 정상 확인
kubectl get pods -n monitoring | grep -E "prometheus|grafana|alertmanager"

# 2. 현재 Pod 상태 기록
kubectl get pods -n billage -o wide > /tmp/chaos-pre-pod-status.txt

# 3. Grafana 대시보드 열기 (별도 터미널)
kubectl port-forward svc/kube-prometheus-grafana 3000:80 -n monitoring &

# 4. k6 부하 테스트 시작
kubectl apply -f chaos-engineering/nat-instance/k6-load-test.yaml

# 5. 3분 대기 — Steady State 수집
sleep 180

# ===== 실험 트리거 =====

# 6. FIS 실험 시작
aws fis create-experiment-template \
  --cli-input-json file://chaos-engineering/nat-instance/fis-template-a.json

# 템플릿 ID 확인 후 실험 시작
aws fis start-experiment \
  --experiment-template-id <TEMPLATE_ID> \
  --tags Phase=before

# ===== 실시간 모니터링 (별도 터미널) =====

# 7. Pod 상태 실시간 감시
watch -n 5 'echo "=== Pod Status ===" && \
  kubectl get pods -n billage -o wide && \
  echo "" && echo "=== Recent Events ===" && \
  kubectl get events -n billage --sort-by=.lastTimestamp | tail -10'

# 8. NAT Instance 상태 확인
watch -n 10 'aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=nat" \
  --query "Reservations[].Instances[].{State:State.Name,Id:InstanceId}" \
  --output table'

# ===== 실험 종료 후 =====

# 9. 결과 수집
kubectl logs job/k6-nat-chaos-load -n billage > /tmp/chaos-k6-results.txt
kubectl get events -n billage --sort-by=.lastTimestamp > /tmp/chaos-events.txt

# 10. Grafana 스크린샷 저장 (대시보드에서 수동)
```

### 4.8 측정 데이터 매트릭스

| 카테고리 | 지표 | Steady State | During Chaos | Recovery | 수집 도구 |
|---------|------|-------------|-------------|----------|----------|
| **가용성** | 물품 리스트 API 성공률 | ___% | ___% | ___% | Prometheus |
| **가용성** | AI 추천 API 성공률 | ___% | ___% | ___% | Prometheus |
| **가용성** | 카카오 로그인 성공률 | ___% | ___% | ___% | Prometheus |
| **가용성** | WebSocket 연결 유지율 | ___% | ___% | ___% | Prometheus |
| **가용성** | 헬스체크 성공률 | ___% | ___% | ___% | Prometheus |
| **성능** | 물품 리스트 p99 응답시간 | ___ms | ___ms | ___ms | Prometheus |
| **성능** | AI 추천 p99 응답시간 | ___ms | ___ms (timeout) | ___ms | Prometheus |
| **리소스** | Tomcat busy threads / max | ___/200 | ___/200 | ___/200 | Prometheus |
| **리소스** | HikariCP active / max | ___/10 | ___/10 | ___/10 | Prometheus |
| **리소스** | Backend Pod CPU | ___% | ___% | ___% | Prometheus |
| **리소스** | Backend Pod Memory | ___% | ___% | ___% | Prometheus |
| **NAT** | NetworkOut (bytes/sec) | ___ | 0 (중단) | ___ | CloudWatch |
| **NAT** | StatusCheckFailed | 0 | 1 | 0 | CloudWatch |
| **감지** | 장애 감지 시간 (TTD) | - | ___초 | - | AlertManager |
| **복구** | 서비스 복구 시간 (TTR) | - | - | ___초 | 수동 기록 |
| **배포** | ECR pull 성공 여부 | OK | **FAIL** | OK | kubectl events |

---

## Phase 5: 실험 B — NAT 대역폭 포화

### 5.1 가설

> **"3개 서비스(AI 4GB + Backend 1GB + Frontend 1GB)를 동시 롤링 업데이트하면서
> AI 추천 API 트래픽이 유입되면, NAT Instance(t3.nano, 32Mbps)의 대역폭이 포화되어
> ECR pull 지연 → ImagePullBackOff → 서비스 중단이 발생할 것이다."**

> kubeadm 환경에서는 RDS/RabbitMQ/Kafka 트래픽이 VPC Peering으로 분리되어
> v2 dev 대비 NAT 대역폭 경합이 **적을 것으로** 예상되지만, ECR pull 간 경합은 여전히 존재.

### 5.2 실행 방법

```bash
# Step 1: k6 부하 시작 (AI 추천 API에 외부 트래픽 유발)
kubectl apply -f chaos-engineering/nat-instance/k6-load-test.yaml

# Step 2: 3분 대기 (Steady State)
sleep 180

# Step 3: 3개 서비스 동시 롤링 업데이트 트리거
kubectl set image deployment/billage-backend \
  backend=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-backend:chaos-test-tag \
  -n billage &

kubectl set image deployment/billage-frontend \
  frontend=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-frontend:chaos-test-tag \
  -n billage &

kubectl set image deployment/billage-ai \
  ai=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-ai:chaos-test-tag \
  -n billage &

# Step 4: 실시간 모니터링
watch -n 5 'echo "=== Pod Status ===" && \
  kubectl get pods -n billage -o wide && \
  echo "" && echo "=== ECR Pull Events ===" && \
  kubectl get events -n billage --field-selector reason=Pulling --sort-by=.lastTimestamp | tail -10 && \
  echo "" && echo "=== ImagePullBackOff ===" && \
  kubectl get events -n billage --field-selector reason=Failed --sort-by=.lastTimestamp | tail -5'
```

### 5.3 측정 포인트

| 지표 | 측정 방법 | 관찰 포인트 |
|------|----------|------------|
| NAT NetworkOut (bytes/sec) | CloudWatch | 32Mbps 초과 시점 |
| CPUCreditBalance | CloudWatch | burst 크레딧 소진 여부 |
| ECR pull 소요시간 (서비스별) | kubectl events 타임스탬프 | AI(4GB) vs Backend(1GB) |
| ImagePullBackOff 발생 여부 | kubectl events | pull 타임아웃 |
| AI 추천 응답시간 변화 | Prometheus | 배포 중 RunPod 호출 지연 |
| 서비스별 가용 Pod 수 | kube_deployment_status | 0이 되는 구간 존재 여부 |

---

## Phase 6: 개선 적용

### 6.1 개선 1: ECR VPC Endpoint (인프라)

> ECR 이미지 pull을 NAT 경로에서 완전 분리. 배포 파이프라인이 NAT 장애와 독립.

```hcl
# kubeadm/envs/prod/modules/network/vpc-endpoints.tf (신규)

# ECR API Endpoint (이미지 메타데이터)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.ap-northeast-2.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(aws_subnet.worker)
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ecr-api-vpce"
  })
}

# ECR Docker Endpoint (이미지 레이어 다운로드)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.ap-northeast-2.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(aws_subnet.worker)
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ecr-dkr-vpce"
  })
}

# S3 Gateway Endpoint (ECR 이미지 레이어는 S3에 저장)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-s3-vpce"
  })
}

# VPC Endpoint 보안그룹
resource "aws_security_group" "vpc_endpoint" {
  name_prefix = "${var.cluster_name}-vpce-"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpce-sg"
  })
}
```

**비용**: ECR API + DKR = Interface Endpoint 2개 × $7.2/월 = **$14.4/월**, S3 Gateway = **무료**

### 6.2 개선 2: NAT Instance ASG 자동 복구 (인프라)

> NAT Instance가 죽으면 ASG가 자동으로 새 인스턴스를 띄우고, 라우팅을 복구한다.

```hcl
# kubeadm/envs/prod/modules/network/nat-asg.tf (신규)

resource "aws_launch_template" "nat" {
  name_prefix   = "${var.cluster_name}-nat-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.nano"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.nat.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.nat.name
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # NAT 설정
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1

    PUB_IF=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o $PUB_IF -s ${var.vpc_cidr} -j MASQUERADE
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -s ${var.vpc_cidr} -o $PUB_IF -j ACCEPT

    yum install -y iptables-services 2>/dev/null || true
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    systemctl enable iptables 2>/dev/null || true

    # source/dest check 비활성화
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" -s)
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    aws ec2 modify-instance-attribute \
      --instance-id $INSTANCE_ID \
      --no-source-dest-check \
      --region ap-northeast-2

    # 라우팅 테이블 업데이트 (모든 Private RT)
    for RT_ID in ${join(" ", [for rt in aws_route_table.private : rt.id])}; do
      aws ec2 replace-route \
        --route-table-id $RT_ID \
        --destination-cidr-block 0.0.0.0/0 \
        --instance-id $INSTANCE_ID \
        --region ap-northeast-2 || true
    done
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-nat"
      Role = "nat"
    })
  }
}

resource "aws_autoscaling_group" "nat" {
  name                = "${var.cluster_name}-nat-asg"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.public[var.availability_zones[0]].id]

  launch_template {
    id      = aws_launch_template.nat.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-nat"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "nat"
    propagate_at_launch = true
  }
}

# NAT Instance IAM — 라우팅 테이블 수정 + source/dest check 변경
resource "aws_iam_role" "nat" {
  name = "${var.cluster_name}-nat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "nat_route_update" {
  name = "${var.cluster_name}-nat-route-update"
  role = aws_iam_role.nat.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:ReplaceRoute",
        "ec2:CreateRoute",
        "ec2:ModifyInstanceAttribute",
        "ec2:DescribeRouteTables"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "nat" {
  name = "${var.cluster_name}-nat-profile"
  role = aws_iam_role.nat.name
}
```

**예상 복구 시간(MTTR)**: ASG 감지(~1분) + 인스턴스 부팅(~1분) + user-data(~30초) = **약 2.5~3분**

### 6.3 개선 3: 애플리케이션 격벽 패턴 (Backend)

> AI 추천 실패가 물품 리스트 전체를 죽이는 장애 전파를 차단.

```java
// Backend: RentalService.java — AI 호출 격리

@Service
@RequiredArgsConstructor
public class RentalService {

    private final RentalRepository rentalRepository;
    private final AIRecommendClient aiRecommendClient;

    public RentalListResponse getRentalItems(Long userId, Pageable pageable) {
        // 1. 핵심: DB 조회 (VPC Peering, NAT 무관 → 절대 실패하면 안 됨)
        Page<RentalItem> items = rentalRepository.findAllActive(pageable);

        // 2. 부가: AI 추천 (RunPod 외부 호출 → NAT 필요 → 실패 가능)
        List<Long> recommendedIds = getRecommendationsSafely(userId);

        // 3. 조합: AI 실패해도 리스트는 정상 반환
        return RentalListResponse.of(items, recommendedIds);
    }

    @CircuitBreaker(name = "aiRecommend", fallbackMethod = "emptyRecommendations")
    @TimeLimiter(name = "aiRecommend")
    @Bulkhead(name = "aiRecommend", type = Bulkhead.Type.THREADPOOL)
    private CompletableFuture<List<Long>> getRecommendationsSafely(Long userId) {
        return CompletableFuture.supplyAsync(() ->
            aiRecommendClient.getRecommendations(userId)
        );
    }

    private CompletableFuture<List<Long>> emptyRecommendations(Long userId, Throwable t) {
        log.warn("[Bulkhead] AI 추천 불가 - userId: {}, reason: {}", userId, t.getMessage());
        return CompletableFuture.completedFuture(Collections.emptyList());
    }
}
```

```yaml
# application.yml — Resilience4j 설정
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
        maxConcurrentCalls: 5
        maxWaitDuration: 500ms
```

### 6.4 개선 4: 순차 배포 전략

```yaml
# 각 Deployment — maxUnavailable: 0으로 기존 Pod 보호
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0   # 기존 Pod 먼저 안 죽임
      maxSurge: 1         # 새 Pod 1개씩만 추가
```

---

## Phase 7: 재실험 (After) — Before/After 비교

### 7.1 동일 FIS 실험 재수행

개선 사항(VPC Endpoint + NAT ASG + 격벽 패턴) 적용 후 Phase 4와 동일 조건으로 재실험.

### 7.2 Before / After 비교표

| SLI | SLO | Before (Phase 4) | After (Phase 7) | 판정 |
|-----|-----|------------------|-----------------|------|
| 물품 리스트 가용률 | ≥ 99.9% | ___% (장애 전파 시 0%) | ___% (100% 예상) | ○/× |
| AI 추천 가용률 | ≥ 95% | ___% (0%) | ___% (0%, graceful) | 예상됨 |
| 사용자 체감 영향 | - | 전체 서비스 불가 | 추천만 비어 표시 | ○/× |
| ECR pull | 정상 동작 | **FAIL** | 정상 (VPC Endpoint) | ○/× |
| 장애 감지 시간 (TTD) | < 60s | ___초 | ___초 | ○/× |
| NAT 복구 시간 (TTR) | < 5min | 수동 (∞) | ___초 (ASG 자동) | ○/× |
| AI 추천 복구 시간 | < 60s | NAT 수동복구 후 ___초 | NAT 자동복구 후 ___초 | ○/× |
| Tomcat 스레드 점유율 | < 50% | ___% (고갈 가능) | ___% (Bulkhead 격리) | ○/× |

### 7.3 대역폭 포화 Before / After 비교표

| 지표 | Before (Phase 5) | After (Phase 7) |
|------|-----------------|-----------------|
| ECR pull 경로 | NAT Instance (경합) | VPC Endpoint (직통) |
| AI 이미지(4GB) pull 시간 | ___분 | ___분 (대역폭 제한 없음) |
| NAT NetworkOut 피크 | ___Mbps | ___Mbps (ECR 트래픽 제거) |
| 배포 중 AI 가용 Pod 최소 | ___개 (0 가능) | ___개 (최소 1 유지) |
| 배포 중 물품 리스트 가용률 | ___% | ___% |

---

## Phase 8: 비용 요약

| 구성 요소 | Before (현재) | After (개선 후) |
|-----------|-------------|----------------|
| NAT Gateway | $32/월 | - (제거) |
| NAT Instance (t3.nano) | - | $3.80/월 |
| ECR VPC Endpoint (Interface × 2) | - | $14.40/월 |
| S3 VPC Endpoint (Gateway) | - | 무료 |
| **합계** | **$32/월** | **$18.20/월** |
| **절감** | | **$13.80/월 (43%)** |

> NAT Gateway 대비 43% 절감하면서, ECR 분리 + ASG 자동 복구 + 격벽 패턴으로
> 실질적인 가용성은 오히려 **향상**된다.

---

## 부록: Pre-flight 체크리스트

실험 시작 전 반드시 확인:

- [ ] Prometheus/Grafana 정상 동작 확인
- [ ] 카오스 대시보드에 Steady State 데이터 표시 확인
- [ ] AlertManager에 알림 규칙 등록 확인
- [ ] FIS IAM 역할 생성 및 정책 확인
- [ ] Stop Condition CloudWatch Alarm 생성 확인
- [ ] NAT Instance 태그(Role=nat) 확인
- [ ] VPC Peering 연결 정상 확인 (RDS/RabbitMQ/Kafka 접근)
- [ ] k6 부하 스크립트 dry-run 성공
- [ ] Grafana 스크린샷 캡처 준비 (Before 증거)
- [ ] 실험 시간대 공유 (팀원 사전 고지)
- [ ] Rollback 계획 준비 (NAT Gateway 재생성 Terraform)
