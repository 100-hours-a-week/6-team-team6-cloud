# Billage Kubernetes (Kubeadm) 마이그레이션 계획

---

## 1. 현재 상태 분석 (AS-IS: v2 Docker Compose + ASG)

### 1.1 현재 서비스 구조

```
┌─────────────────────────────────────────────────────────┐
│                   v2 Architecture (현재)                  │
│                                                          │
│  ALB (HTTPS:443)                                        │
│    ├── / → Frontend ASG (Next.js :3000)                  │
│    ├── /api/* → Backend ASG (Spring Boot :8080)          │
│    ├── /ws/* → Backend ASG (WebSocket, idle 300s)        │
│    └── /ai/* → AI ASG (FastAPI :5000)                    │
│                                                          │
│  외부 서비스:                                             │
│    ├── RDS MySQL 8.0 (db.t4g.micro)                     │
│    ├── ElastiCache Redis (미연동)                         │
│    ├── ECR (billage-be, billage-fe, billage-ai)          │
│    └── S3 (이미지 저장)                                   │
│                                                          │
│  네트워크:                                                │
│    ├── Dev VPC: 10.0.0.0/16                              │
│    ├── Prod VPC: 10.1.0.0/16                             │
│    └── Management VPC: 10.2.0.0/16 (VPN + 모니터링)      │
└─────────────────────────────────────────────────────────┘
```

### 1.2 v2의 한계 (4단계 → 5단계 전환 동기)

| 문제 영역 | v2 한계 | Kubernetes 해결 방식 |
| --- | --- | --- |
| **스케일링 속도** | ASG Instance Refresh 20~30분 | HPA Pod 확장 2~3분 |
| **리소스 효율성** | 서비스별 EC2 고정 할당 | Pod 단위 동적 배치, bin-packing |
| **배포 복잡도** | 3개 ASG × 각 인스턴스 개별 관리 | `kubectl apply` 선언적 배포 |
| **장애 복구** | 수동 인스턴스 재시작 5~10분 | Self-healing 자동 재시작 < 1분 |
| **서비스 디스커버리** | ALB 타겟그룹 수동 관리 | Kubernetes Service/DNS 자동 관리 |

### 1.3 목표 트래픽 (MAU 100만)

| 지표 | v2 (현재) | v3 Kubeadm (목표) |
| --- | --- | --- |
| MAU | 30만명 | 100만명 |
| DAU | 6만명 | 20만명 |
| 피크 동접 | 18,000명 | 60,000명 |
| 피크 RPS | 900 | 3,000 |
| 스파이크 RPS | 1,800 | 6,000 |

---

## 2. 서비스 아키텍처 정의 (TO-BE)

### 2.1 빌리지 서비스는 MSA가 아니다

현재 Billage는 **멀티모달 모놀리스** 구조다:

```
[빌리지 서비스 구조]

├── Next.js (Web Server)
│   └── SSR/CSR, 정적 자산 서빙
│
├── Spring Boot (WAS — 모놀리스)
│   ├── 물품 CRUD, 그룹 관리, 인증 (REST)
│   ├── 1:1 채팅 (WebSocket)
│   └── 알림센터 (WebSocket)
│
├── FastAPI (AI Server)
│   ├── 비슷한 물품 추천, 개인화 리스트
│   ├── 이미지 분석 → 게시글 자동 작성, 금액 추천
│   └── (모델 추론은 RunPod 호출, 로컬은 오케스트레이션만)
│
├── RabbitMQ (메시지 브로커)
│   └── 비동기 메시지 전달
│
├── Qdrant (벡터 DB)
│   └── 추천/검색용 벡터 저장 및 유사도 검색
│
└── MySQL → RDS 외부화 (클러스터 외부)
```

**핵심 구분**: 3개 애플리케이션(Stateless) + 2개 상태 저장 컴포넌트(Stateful). MySQL은 RDS로 클러스터 외부.

### 2.2 워크로드 성격 분류

**같이 죽어도 되는 것끼리 묶고, 같이 죽으면 안 되는 것은 분리한다.**

| 컴포넌트 | 성격 | 스케일 방식 | 실패 시 영향 | 메모리 특성 |
| --- | --- | --- | --- | --- |
| Next.js | Stateless | Replica 증가 | 페이지 로딩 실패 | 예측 가능, 낮음 |
| Spring Boot | Stateless* | Replica 증가 | 전체 서비스 중단 | JVM 힙 + 커넥션 풀 |
| FastAPI | Stateless | Replica 증가 | AI 기능 불가 | 낮음 (오케스트레이션) |
| RabbitMQ | **Stateful** | 수동/고정 | 비동기 메시지 유실 | Watermark 민감 |
| Qdrant | **Stateful** | 벡터 수에 비례 | 추천/검색 불가 | 벡터 × 차원 × 4B × 1.5 |

*Spring Boot의 WebSocket 세션은 메모리에 있지만, 재연결으로 복구 가능하므로 Stateless에 가깝게 운영.

---

## 3. Kubeadm 선택 근거

### 3.1 왜 EKS가 아닌 Kubeadm인가

| 비교 | Kubeadm (Self-managed) | EKS (AWS Managed) |
| --- | --- | --- |
| Control Plane 비용 | EC2 비용만 (t3.medium: 월 ~5.5만원) | 클러스터당 월 $73 + EC2 |
| 커스터마이징 | 완전한 제어 (CNI, 스토리지, 인증) | AWS 정책 내 제한적 |
| 학습 가치 | K8s 내부 구조 직접 경험 | 추상화된 관리 |
| 운영 부담 | 높음 | 낮음 |

**선택 이유**:
1. **Kubernetes 내부 동작 원리를 직접 경험** — API Server 인증/인가, etcd 상태 저장, Scheduler 배치 로직, Controller Manager reconcile, CNI 네트워크, PKI 인증서
2. **Control Plane 비용 절감** — EKS 대비 월 약 4.5만원 절감

**실무 환경이라면 EKS를 선택한다** — Control Plane HA 보장, etcd 자동 관리, 인증서 자동 갱신.

### 3.2 핵심 기술 스택

| 기술 | 역할 | 선택 이유 |
| --- | --- | --- |
| **Kubeadm** | 클러스터 부트스트랩 | K8s 공식 도구, 내부 구조 학습 |
| **Calico** | CNI (Pod 네트워크) | BGP L3 라우팅, NetworkPolicy L3-L4 지원, 프로덕션 검증 |
| **containerd** | 컨테이너 런타임 | K8s 표준 CRI, Docker 대비 경량 |
| **metrics-server** | 리소스 메트릭 수집 | HPA 필수 의존성 |
| **ArgoCD** | GitOps 배포 | 선언적 배포, 자동 Drift 복구 |
| **Helm** | 패키지 매니저 | 환경별 values 분리, 템플릿 재사용 |
| **Prometheus + Grafana** | 모니터링 | 기존 v2 모니터링 스택 재활용 |
| **Loki** | 로그 수집 | Grafana 통합, Promtail DaemonSet |
| **cert-manager** | TLS 인증서 관리 | Let's Encrypt 자동 갱신 |
| **ingress-nginx** | Ingress Controller | L7 라우팅, WebSocket 지원 |

---

## 4. 클러스터 아키텍처 설계

### 4.1 네임스페이스 설계

네임스페이스는 서비스 이름이 아니라 **운영 경계**로 나눈다.

| 네임스페이스 | 포함 리소스 | 분리 이유 |
| --- | --- | --- |
| **village-app** | Next.js, Spring Boot, FastAPI Deployment/Service/HPA | 같은 릴리즈 흐름, stateless |
| **village-data** | RabbitMQ StatefulSet, Qdrant StatefulSet | 배포 주기 다름, 재시작 영향 큼 |
| **village-edge** | ingress-nginx, cert-manager | TLS/라우팅은 앱과 무관한 별도 책임 |
| **village-ops** | ArgoCD, Prometheus, Grafana, Loki, metrics-server | 운영 도구는 장애 분석에 필수 |

**분리 효과**:
- ArgoCD Application을 네임스페이스별 별도 구성 → Spring Boot 배포가 RabbitMQ에 영향 없음
- RBAC 네임스페이스 단위 → CI/CD 서비스 어카운트가 data Secret 접근 불가
- ResourceQuota/LimitRange 별도 → Stateless는 HPA 탄력적, Stateful은 보수적
- PDB 정책 분리 → app은 최소 가용 replica, data는 quorum 보호

### 4.2 노드 그룹 설계

#### Control Plane (3대)

| 항목 | 스펙 | 근거 |
| --- | --- | --- |
| 수량 | 3대 | etcd Raft 합의: 과반수(quorum), 1대 장애 허용 |
| 인스턴스 | m7i.large (2 vCPU, 8Gi) | etcd/API Server는 예측 가능한 성능 필요 |
| 디스크 | gp3 50GB | etcd 데이터 저장 |
| 가용영역 | 2a, 2b, 2c 분산 | AZ 장애 대비 |

#### App Node Group (4~8대, ASG)

| 항목 | 스펙 | 근거 |
| --- | --- | --- |
| 수량 | 최소 4대, 최대 8대 | CPU-driven: ceil(3.65 / (1.93 × 0.6)) = 4대 |
| 인스턴스 | m7i-flex.large (2 vCPU, 8Gi) | 95% CPU 보장, credit 아님 |

**App baseline**: CPU 3.65 vCPU, Memory 5.25Gi → 4대 총 allocatable ~7.72 vCPU / 24.4Gi

#### Data Node Group (3대, 고정)

| 항목 | 스펙 | 근거 |
| --- | --- | --- |
| 수량 | 3대 고정 | RabbitMQ 3노드 quorum (구조 때문) |
| 인스턴스 | m7i.large (2 vCPU, 8Gi) | Stateful은 예측 가능한 성능 필요 |

### 4.3 리소스 산정 (실측 기반)

실측 데이터: Spring Boot idle 566MB (2 CPU / 4GB RAM EC2 기준)

| 컴포넌트 | Replicas | CPU req | Mem req | CPU limit | Mem limit | 산정 근거 |
| --- | --- | --- | --- | --- | --- | --- |
| Spring Boot | 3 | 750m | 1Gi | 2000m | 2Gi | 566MB idle × 1.8, JVM 힙 + WebSocket |
| Next.js | 2 | 300m | 512Mi | 1000m | 1Gi | Node.js 힙 ~300MB + SSR |
| FastAPI | 2 | 300m | 512Mi | 1000m | 1Gi | 오케스트레이션만, 추론은 RunPod |
| RabbitMQ | 3 | 250m | 1Gi | 500m | 1.5Gi | 공식 권장 absolute threshold |
| Qdrant | 1 | 500m | 2Gi | 1000m | 4Gi | 768d 10만 벡터 ~0.43Gi + 여유 |
| Ingress | 2 | 100m | 128Mi | 200m | 256Mi | nginx 기본 요구량 |

**전체 baseline: 13 Pods, CPU 4.9 vCPU, Memory 10.25Gi**

### 4.4 전체 아키텍처 다이어그램

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Village Kubeadm Cluster                         │
│                                                                      │
│  ┌────────────────── Control Plane (3 × m7i.large) ───────────────┐│
│  │  Master-1 (AZ:2a)    Master-2 (AZ:2b)    Master-3 (AZ:2c)    ││
│  │  API Server / etcd    API Server / etcd    API Server / etcd    ││
│  │  Scheduler / CM       Scheduler / CM       Scheduler / CM       ││
│  └─────────────────────────────┬──────────────────────────────────┘│
│                                │ kube-apiserver                     │
│  ┌────────── App Nodes (4~8 × m7i-flex.large) ──────────────────┐ │
│  │  [village-app]                                                 │ │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐                      │ │
│  │  │Spring ×3 │ │Next.js ×2│ │FastAPI ×2│                      │ │
│  │  │:8080     │ │:3000     │ │:5000     │                      │ │
│  │  └──────────┘ └──────────┘ └──────────┘                      │ │
│  │  [village-edge]                                                │ │
│  │  ┌────────────────┐ ┌──────────────┐                          │ │
│  │  │ingress-nginx ×2│ │cert-manager  │                          │ │
│  │  └────────────────┘ └──────────────┘                          │ │
│  └────────────────────────────────────────────────────────────────┘ │
│  ┌────────── Data Nodes (3 × m7i.large, 고정) ──────────────────┐ │
│  │  [village-data]                                                │ │
│  │  ┌──────────────┐ ┌──────────────┐                            │ │
│  │  │RabbitMQ ×3   │ │Qdrant ×1     │                            │ │
│  │  │(StatefulSet) │ │(StatefulSet) │                            │ │
│  │  └──────────────┘ └──────────────┘                            │ │
│  └────────────────────────────────────────────────────────────────┘ │
│  ┌────────── Ops (village-ops, app 노드에 배치) ─────────────────┐ │
│  │  ArgoCD / Prometheus / Grafana / Loki / metrics-server        │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  [외부 서비스]                                                       │
│  AWS ALB → ingress-nginx → Service → Pod                            │
│  RDS MySQL (클러스터 외부)                                           │
│  S3 (이미지 저장)                                                    │
│  ECR (컨테이너 이미지)                                               │
│  RunPod (AI 모델 추론)                                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. 핵심 기술 상세

### 5.1 CNI: Calico

**선택 이유**: BGP 기반 L3 라우팅, NetworkPolicy L3-L4, 프로덕션 검증

| Flannel (탈락) | Cilium (탈락) | **Calico (선택)** |
| --- | --- | --- |
| NetworkPolicy 미지원 | Linux 5.4+ 필수, 학습 곡선 높음 | L3-L4 NetworkPolicy 지원 |
| 트래픽 암호화 없음 | 운영 복잡도 높음 | BGP 오버레이 오버헤드 최소 |
| 프로덕션 부적합 | eBPF 디버깅 어려움 | AWS EC2 기본 커널 호환 |

**NetworkPolicy 원칙**: Default Deny → 필요한 통신만 Whitelist

```yaml
# Default Deny 적용 후, 서비스별 필요 통신만 허용
# Spring Boot → RDS (3306), RabbitMQ (5672)
# FastAPI → Qdrant (6333), RunPod (외부)
# Next.js → Spring Boot (8080)
# Ingress → Next.js (3000), Spring Boot (8080), FastAPI (5000)
```

### 5.2 노드 배치 전략

| 수단 | 역할 | 적용 대상 |
| --- | --- | --- |
| **Taint** | "막는 것" — 일반 Pod 진입 차단 | Data 노드에 적용 |
| **NodeAffinity** | "가게 하는 것" — 특정 노드로 유도 | App/Data 워크로드 |
| **TopologySpread** | "퍼뜨리는 것" — AZ/hostname 분산 | App 워크로드 |
| **PodAntiAffinity** | "같은 곳 금지" | RabbitMQ (3 Pod → 3 노드) |

**핵심**: Toleration만으로는 "거기로 간다"가 보장되지 않는다. **Toleration + NodeAffinity(required)를 함께** 써야 한다.

### 5.3 HPA (Horizontal Pod Autoscaler)

| 서비스 | Min | Max | CPU 임계값 | Scale-down 안정화 | 비고 |
| --- | --- | --- | --- | --- | --- |
| Spring Boot | 3 | 10 | 70% | 300초 | 핵심 서비스 |
| Next.js | 2 | 6 | 70% | 300초 | SSR 기반 |
| FastAPI | 2 | 5 | 50% | 300초 | RunPod 호출 대기 |

**의존성**: metrics-server가 설치되어야 HPA 동작.

### 5.4 배포 전략: Rolling Update

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%
    maxUnavailable: 0    # 항상 100% 가용성 유지
```

### 5.5 Probe 설계

| 서비스 | Liveness 경로 | Readiness 경로 | 초기 지연 | 주기 |
| --- | --- | --- | --- | --- |
| Spring Boot | /actuator/health | /actuator/health | 60초 | 20초 |
| Next.js | / | / | 15초 | 10초 |
| FastAPI | /ai/health | /ai/health | 30초 | 15초 |

**Spring Boot 60초 이유**: JVM 웜업(30s~1m) + DB 커넥션 풀 초기화. 짧으면 재시작 루프.

### 5.6 PDB (Pod Disruption Budget)

| 서비스 | minAvailable | 근거 |
| --- | --- | --- |
| Spring Boot | 66% | 핵심 서비스, 1개 드레인해도 2개 유지 |
| Next.js | 50% | 빠른 cold start로 복구 |
| FastAPI | 50% | 비동기, 지연 허용 |
| RabbitMQ | 66% | quorum 유지 (2/3) |

### 5.7 GitOps: ArgoCD

```
Developer → Git Push → GitHub Repository
                            │
                            ▼
                       ArgoCD Sync
                            │
                  ┌─────────┼─────────┐
                  ▼         ▼         ▼
            village-app  village-data  village-edge
            (Application) (Application) (Application)
```

네임스페이스별 ArgoCD Application 분리 → Spring Boot 배포 시 RabbitMQ 영향 없음.

### 5.8 모니터링 스택

| 도구 | 역할 | 배치 |
| --- | --- | --- |
| Prometheus | 메트릭 수집 (retention 15d) | village-ops |
| Grafana | 대시보드 | village-ops |
| Loki | 로그 수집 | village-ops |
| Promtail | 로그 전송 (DaemonSet) | 모든 노드 |
| metrics-server | HPA 메트릭 제공 | kube-system |

기존 v2 Management VPC의 Prometheus/Grafana/Loki 스택을 클러스터 내부로 이전.

---

## 6. Terraform 인프라 코드 구조 (IaC)

### 6.1 신규 모듈 구조

Kubeadm 클러스터의 AWS 인프라를 Terraform으로 관리한다.

```
terraform/
├── modules/
│   ├── (기존 모듈 유지)
│   └── kubernetes/              # 신규
│       ├── vpc/                 # K8s 전용 VPC 또는 기존 VPC 확장
│       ├── master/              # Control Plane EC2 × 3
│       ├── worker-app/          # App Node Group ASG
│       ├── worker-data/         # Data Node Group (고정)
│       ├── nlb/                 # API Server용 내부 NLB
│       ├── security-group/      # K8s 전용 SG (etcd, kubelet, CNI 등)
│       └── iam/                 # K8s 노드 IAM Role (ECR pull, SSM 등)
│
├── v3-kubeadm/                  # 신규 환경
│   └── envs/
│       ├── dev/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── terraform.tfvars
│       └── prod/
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           └── terraform.tfvars
│
└── plan/
    └── kubernetes/
        └── plan.md              # 이 문서
```

### 6.2 K8s 매니페스트 저장소 (별도 Git 리포지토리)

ArgoCD가 바라보는 K8s 매니페스트는 별도 리포지토리로 관리한다.

```
billage-k8s-manifests/           # 별도 GitHub 리포
├── base/                        # 공통 리소스
│   ├── namespaces.yaml
│   └── network-policies/
│       ├── default-deny.yaml
│       ├── village-app.yaml
│       └── village-data.yaml
│
├── apps/                        # village-app 네임스페이스
│   ├── spring-boot/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml
│   │   └── pdb.yaml
│   ├── nextjs/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml
│   │   └── pdb.yaml
│   └── fastapi/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── hpa.yaml
│       └── pdb.yaml
│
├── data/                        # village-data 네임스페이스
│   ├── rabbitmq/
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   └── pdb.yaml
│   └── qdrant/
│       ├── statefulset.yaml
│       ├── service.yaml
│       └── cronjob-backup.yaml
│
├── edge/                        # village-edge 네임스페이스
│   ├── ingress-nginx/
│   ├── cert-manager/
│   └── ingress.yaml
│
├── ops/                         # village-ops 네임스페이스
│   ├── argocd/
│   ├── prometheus/
│   ├── grafana/
│   └── loki/
│
└── argocd/                      # ArgoCD Application 정의
    ├── app-village-app.yaml
    ├── app-village-data.yaml
    ├── app-village-edge.yaml
    └── app-village-ops.yaml
```

---

## 7. 마이그레이션 단계별 개발 계획

### Phase 0: 사전 준비 (1주)

**목표**: Terraform 인프라 코드 기반 마련

| # | 작업 | 산출물 | 비고 |
| --- | --- | --- | --- |
| 0-1 | K8s 전용 네트워크 설계 | VPC/서브넷 CIDR, SG 규칙 문서 | 기존 VPC 확장 vs 신규 VPC 결정 |
| 0-2 | Terraform 모듈 스캐폴딩 | `modules/kubernetes/*` 디렉토리 | 빈 모듈 구조 생성 |
| 0-3 | K8s 매니페스트 리포 생성 | `billage-k8s-manifests` GitHub 리포 | ArgoCD 대상 |
| 0-4 | kubeadm/containerd AMI 준비 | Packer 템플릿 또는 user_data 스크립트 | 기존 v2 Packer 참고 |

**네트워크 결정 포인트**:
- **옵션 A**: 기존 Dev VPC(10.0.0.0/16) 내에 K8s 전용 서브넷 추가
  - 장점: RDS 접근 쉬움, VPC Peering 재사용
  - 단점: CIDR 충돌 가능, Pod CIDR(192.168.0.0/16)과 분리 필요
- **옵션 B**: K8s 전용 VPC 신규 생성 (10.3.0.0/16)
  - 장점: 깔끔한 격리, CIDR 충돌 없음
  - 단점: RDS 접근을 위한 추가 Peering 필요

### Phase 1: Control Plane 구축 (1주)

**목표**: 3-Master HA 클러스터 부팅

| # | 작업 | 상세 | 검증 방법 |
| --- | --- | --- | --- |
| 1-1 | Master SG 생성 | etcd(2379-2380), API(6443), kubelet(10250-10252) | SG 규칙 검증 |
| 1-2 | NLB 생성 | API Server 앞단 NLB (내부) | NLB 헬스체크 통과 |
| 1-3 | Master EC2 3대 프로비저닝 | m7i.large, AZ 분산, gp3 50GB | SSH 접속 확인 |
| 1-4 | kubeadm init (첫 번째 Master) | `--control-plane-endpoint`, `--upload-certs` | `kubectl get nodes` |
| 1-5 | 추가 Master 2대 Join | `kubeadm join --control-plane` | etcd 3멤버 확인 |
| 1-6 | Calico CNI 설치 | `kubectl apply -f calico.yaml` | `kubectl get pods -n calico-system` |

**핵심 설정**:
```bash
# kubeadm init 핵심 파라미터
sudo kubeadm init \
  --control-plane-endpoint "k8s-api-nlb.internal:6443" \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12
```

**검증 체크리스트**:
- [ ] `kubectl get nodes` — 3 Master Ready
- [ ] `kubectl get pods -n kube-system` — etcd, api-server, scheduler, controller-manager 정상
- [ ] `kubectl get pods -n calico-system` — Calico 정상
- [ ] etcd 클러스터 헬스: `etcdctl endpoint health`

### Phase 2: Worker Node 구축 (1주)

**목표**: App/Data 노드 추가 및 라벨/taint 설정

| # | 작업 | 상세 | 검증 방법 |
| --- | --- | --- | --- |
| 2-1 | Worker SG 생성 | kubelet, NodePort(30000-32767), Calico BGP(179) | SG 규칙 |
| 2-2 | App Node 4대 프로비저닝 | m7i-flex.large, AZ 분산 | SSH 접속 |
| 2-3 | Data Node 3대 프로비저닝 | m7i.large, AZ 분산 | SSH 접속 |
| 2-4 | Worker Join | `kubeadm join` | `kubectl get nodes` |
| 2-5 | 노드 라벨 적용 | `node-role=app`, `node-role=data` | `kubectl get nodes --show-labels` |
| 2-6 | Data Node Taint | `kubectl taint nodes ... dedicated=data:NoSchedule` | Taint 확인 |

**검증 체크리스트**:
- [ ] `kubectl get nodes` — 10 노드 (3 Master + 4 App + 3 Data) Ready
- [ ] App 노드 라벨: `node-role=app`
- [ ] Data 노드 라벨: `node-role=data`, Taint: `dedicated=data:NoSchedule`
- [ ] allocatable 확인: `kubectl describe node <name> | grep -A 5 Allocatable`

### Phase 3: 기반 인프라 배포 (1주)

**목표**: 네임스페이스, NetworkPolicy, Ingress, 모니터링 기반 구축

| # | 작업 | 상세 | 검증 방법 |
| --- | --- | --- | --- |
| 3-1 | 네임스페이스 4개 생성 | village-app, village-data, village-edge, village-ops | `kubectl get ns` |
| 3-2 | Default Deny NetworkPolicy | 각 네임스페이스별 | 통신 차단 확인 |
| 3-3 | ingress-nginx 설치 | Helm, village-edge, 2 replicas | `kubectl get pods -n village-edge` |
| 3-4 | cert-manager 설치 | Let's Encrypt ClusterIssuer | 인증서 발급 테스트 |
| 3-5 | metrics-server 설치 | kube-system | `kubectl top nodes` |
| 3-6 | ALB → ingress-nginx 연결 | AWS ALB Target Group → NodePort | 외부 접근 테스트 |
| 3-7 | StorageClass 설정 | gp3 기반 EBS CSI | PVC 생성 테스트 |

**핵심 결정**: EBS CSI Driver 설치 필요 (Kubeadm에는 기본 미포함)

```bash
# EBS CSI Driver 설치 (Helm)
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system
```

### Phase 4: Stateful 워크로드 배포 (1주)

**목표**: RabbitMQ, Qdrant를 village-data에 배포

| # | 작업 | 상세 | 검증 방법 |
| --- | --- | --- | --- |
| 4-1 | RabbitMQ StatefulSet 작성 | 3 replicas, PVC, quorum queue | 3 Pod Running |
| 4-2 | RabbitMQ PodAntiAffinity | hostname 기준 hard anti-affinity | 3 Pod → 3 노드 |
| 4-3 | RabbitMQ NetworkPolicy | Spring Boot → RabbitMQ(5672) 허용 | amqp 연결 테스트 |
| 4-4 | Qdrant StatefulSet 작성 | 1 replica, PVC, snapshot CronJob | Pod Running |
| 4-5 | Qdrant NetworkPolicy | FastAPI → Qdrant(6333/6334) 허용 | 벡터 검색 테스트 |
| 4-6 | Data PDB 설정 | RabbitMQ minAvailable 66% | PDB 확인 |

**RabbitMQ 핵심 설정**:
- `vm_memory_high_watermark.absolute`: 컨테이너 limit의 60%
- Quorum queue: 3노드 합의 기반 메시지 내구성
- PVC: gp3 20GB per node

**Qdrant 백업 전략**:
- CronJob: 주 1회 Snapshot API → S3 업로드
- 장애 시: 스냅샷 복원 또는 전체 재임베딩 (10만 건 기준 ~2-3시간)

### Phase 5: Stateless 앱 배포 (1주)

**목표**: Spring Boot, Next.js, FastAPI를 village-app에 배포

| # | 작업 | 상세 | 검증 방법 |
| --- | --- | --- | --- |
| 5-1 | Spring Boot Deployment | 3 replicas, ECR 이미지, SSM 환경변수 | Pod Running |
| 5-2 | Spring Boot Service/HPA | ClusterIP, HPA min:3 max:10 | `kubectl top pods` |
| 5-3 | Spring Boot Probe | liveness/readiness /actuator/health, 60초 초기 지연 | 헬스체크 통과 |
| 5-4 | Next.js Deployment | 2 replicas, ECR 이미지 | Pod Running |
| 5-5 | Next.js Service/HPA | ClusterIP, HPA min:2 max:6 | 응답 확인 |
| 5-6 | FastAPI Deployment | 2 replicas, ECR 이미지 | Pod Running |
| 5-7 | FastAPI Service/HPA | ClusterIP, HPA min:2 max:5 | /ai/health 응답 |
| 5-8 | App NetworkPolicy | 서비스간 필요 통신만 허용 | curl 테스트 |
| 5-9 | TopologySpread 적용 | zone/hostname 기준 | Pod 분산 확인 |
| 5-10 | Ingress 규칙 작성 | 도메인/경로 → 서비스 라우팅 | 외부 접근 테스트 |

**환경변수 관리**:
- 기존 SSM Parameter Store 활용 → ExternalSecrets Operator 또는 init container로 주입
- 대안: K8s Secret + SealedSecrets (GitOps 친화적)

### Phase 6: GitOps & 모니터링 (1주)

**목표**: ArgoCD, Prometheus/Grafana/Loki 구축

| # | 작업 | 상세 | 검증 방법 |
| --- | --- | --- | --- |
| 6-1 | ArgoCD 설치 | Helm, village-ops | ArgoCD UI 접근 |
| 6-2 | ArgoCD Application 생성 | 네임스페이스별 4개 Application | Sync 상태 확인 |
| 6-3 | Prometheus 설치 | kube-prometheus-stack Helm | 메트릭 수집 확인 |
| 6-4 | Grafana 대시보드 | K8s 클러스터/Pod/노드 대시보드 | 대시보드 조회 |
| 6-5 | Loki + Promtail 설치 | DaemonSet, 로그 수집 | 로그 검색 확인 |
| 6-6 | Alert 규칙 설정 | CPU/메모리/CrashLoop/노드 장애 | Alert 발생 테스트 |

### Phase 7: 트래픽 전환 & 검증 (1주)

**목표**: v2(ASG) → v3(Kubeadm) 점진적 전환

| # | 작업 | 상세 | 검증 방법 |
| --- | --- | --- | --- |
| 7-1 | Dev 환경 전환 | ALB 가중치: K8s 100% | 기능 테스트 |
| 7-2 | 부하 테스트 | 목표 RPS 3,000 ~ 6,000 | p95 < 300ms |
| 7-3 | HPA 동작 검증 | 부하 증가 → Pod 자동 확장 | Pod 수 변화 |
| 7-4 | 장애 복구 테스트 | Pod kill, 노드 drain | 자동 복구 확인 |
| 7-5 | Prod 환경 전환 | 단계적 가중치 이동 (10% → 50% → 100%) | 모니터링 관찰 |
| 7-6 | v2 인프라 정리 | ASG 축소 → 삭제 | 비용 절감 확인 |

---

## 8. 비용 분석

### 8.1 인프라 비용 (월간, 서울 리전)

| 리소스 | 수량 | 스펙 | 단가 (월) | 합계 |
| --- | --- | --- | --- | --- |
| Master Node | 3 | m7i.large | ~9만원 | ~27만원 |
| App Node (최소) | 4 | m7i-flex.large | ~8.6만원 | ~34.4만원 |
| Data Node | 3 | m7i.large | ~9만원 | ~27만원 |
| EBS (Master) | 150GB | gp3 | 1.5만원 | ~4.5만원 |
| EBS (Worker) | 350GB | gp3 | 3.5만원 | ~12.25만원 |
| EBS (Data PVC) | 120GB | gp3 | 1.2만원 | ~3.6만원 |
| ALB | 1 | - | ~3만원 | ~3만원 |
| **합계** | | | | **약 112만원** |

### 8.2 v2 대비 비용 비교

| 항목 | v2 (Docker/ASG) | v3 (Kubeadm) | 비고 |
| --- | --- | --- | --- |
| 인프라 비용 | 약 150만원 | 약 112만원 | bin-packing 효율화 |
| 개선율 | - | **25% 절감** | 리소스 활용률 향상 |

---

## 9. 리스크 & 완화 전략

| 리스크 | 영향 | 완화 전략 |
| --- | --- | --- |
| Master SPOF (1대 장애) | 클러스터 접근 불가 | 3대 HA + NLB, etcd 정기 백업 |
| etcd 데이터 손실 | 클러스터 전체 상태 유실 | etcd 스냅샷 CronJob → S3, 복구 절차 문서화 |
| 인증서 만료 (1년) | 컴포넌트 간 통신 중단 | kubeadm certs renew 자동화 (CronJob) |
| K8s 버전 업그레이드 실패 | 롤백 어려움 | 단계별 업그레이드 (drain → upgrade → uncordon) |
| CNI 장애 | Pod 간 통신 불가 | Calico 상태 모니터링, 재설치 절차 준비 |
| RabbitMQ quorum 깨짐 | 메시지 유실 | 3노드 AZ 분산, PDB 설정 |

---

## 10. 성능 목표 & 검증 기준

| 항목 | 목표 | 검증 방법 |
| --- | --- | --- |
| 응답시간 (p95) | < 300ms | k6/Locust 부하 테스트 |
| 가용성 | 99.9% | Prometheus uptime 메트릭 |
| 피크 RPS | 3,000 | 부하 테스트 |
| 스파이크 RPS | 6,000 | 부하 테스트 |
| 스케일링 시간 | < 3분 | HPA 트리거 → Pod Ready 시간 |
| 장애 복구 (MTTR) | < 1분 | Pod kill → 자동 복구 시간 |
| 배포 시간 | < 5분 | ArgoCD Sync → 전체 서비스 교체 완료 |

---

## 11. 전체 일정 요약

| Phase | 기간 | 핵심 산출물 |
| --- | --- | --- |
| **Phase 0**: 사전 준비 | 1주 | Terraform 모듈, 네트워크 설계, AMI |
| **Phase 1**: Control Plane | 1주 | 3-Master HA, Calico CNI |
| **Phase 2**: Worker Node | 1주 | 4 App + 3 Data 노드, 라벨/taint |
| **Phase 3**: 기반 인프라 | 1주 | Namespace, NetworkPolicy, Ingress, metrics-server |
| **Phase 4**: Stateful 배포 | 1주 | RabbitMQ 3노드, Qdrant |
| **Phase 5**: Stateless 배포 | 1주 | Spring Boot, Next.js, FastAPI + HPA |
| **Phase 6**: GitOps & 모니터링 | 1주 | ArgoCD, Prometheus/Grafana/Loki |
| **Phase 7**: 트래픽 전환 | 1주 | v2 → v3 전환, 부하 테스트, v2 정리 |
| **총 기간** | **8주** | |

---

## 12. 향후 진화 방향 (6단계 EKS 전환)

| 개선 사항 | 기대 효과 |
| --- | --- |
| EKS 관리형 Control Plane | Master 운영 부담 제거, 99.95% SLA |
| Karpenter | 노드 프로비저닝 분 → 초 |
| Cilium CNI | eBPF 기반 고성능, L7 NetworkPolicy |
| AWS ALB Ingress Controller | AWS 네이티브 로드밸런싱 |
| AWS Secrets Manager + ExternalSecrets | 시크릿 관리 중앙화 |
| Istio/Linkerd 서비스 메시 | mTLS, 트래픽 분할, 관찰성 |
