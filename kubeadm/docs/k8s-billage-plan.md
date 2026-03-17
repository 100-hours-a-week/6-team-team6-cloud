# Kubeadm 오케스트레이션 설계

## 근본 목적

- MAU 100만명 규모 서비스를 위해 kubeadm 기반 자체 관리 Kubernetes 클러스터 설계 결정을 기록한다.
- 인프라 구성, 네트워크, 노드 배치, 플랫폼 컴포넌트 선택의 근거를 고정해 이후 운영자가 같은 결정을 반복 검토하지 않도록 한다.

## 비목적

- 실제 구축 절차(runbook)를 이 문서에서 기술하지 않는다.
- 개별 컴포넌트의 상세 운영 방법을 여기서 다루지 않는다.

---

## 1. Kubernetes 도입

### 1.1 4단계 Docker Compose의 한계

4단계 Docker Compose 아키텍처는 MAU 30만명(피크 동접 18,000명)까지 성공적으로 서비스를 운영했습니다. 그러나 서비스가 수도권을 넘어 전국으로 확장되면서 다음과 같은 운영상의 한계에 직면했습니다.

| 문제 영역 | 4단계 한계 | 영향 |
| --- | --- | --- |
| **스케일링 속도** | 수동 인스턴스 추가 → 20~30분 소요 | 피크 트래픽 대응 지연, 사용자 이탈 |
| **리소스 효율성** | 서비스별 EC2 인스턴스 고정 할당 | 유휴 리소스 발생, 비용 낭비 |
| **배포 복잡도** | 6개 서비스 × 2~3대 = 최대 18대 개별 관리 | 배포 시간 증가, 휴먼 에러 가능성 |
| **장애 복구** | 수동 인스턴스 재시작 → 5~10분 | 서비스 가용성 저하 |
| **서비스 디스커버리** | Nginx 설정 수동 변경 | 동적 스케일링 제한 |

### 1.2 트래픽 산정: MAU 100만명 기준

당근마켓의 성장 패턴(2018년 기준 +3년)을 벤치마킹하여 목표 트래픽을 산정했습니다.

| 지표 | 산정 근거 | 예상 값 |
| --- | --- | --- |
| MAU | 당근마켓 +3년 기준 (2018년) | 1,000,000명 |
| DAU | MAU의 20% (필요 시 사용하는 서비스 특성) | 200,000명 |
| 피크 동시접속 | DAU의 30% (점심/퇴근 시간대 집중) | 60,000명 |
| 스파이크 | 피크의 2배 (이벤트, 바이럴 시) | ~120,000명 |

**요청량 산정 (RPS)**

동시접속 60,000명 기준:

- 평균 체류 시간: 5분
- 분당 요청 수: 3회 (페이지 이동, API 호출)
- **초당 요청(RPS): 60,000 × 3 / 60 = 3,000 RPS**

스파이크 시 (동시접속 120,000명):

- **초당 요청(RPS): 120,000 × 3 / 60 = 6,000 RPS**

### 1.3 4단계 대비 트래픽 증가

| 지표 | 4단계 (Docker) | 5단계 (Kubeadm) |
| --- | --- | --- |
| MAU | 30만명 | 100만명 |
| DAU | 6만명 | 20만명 |
| 피크 동접 | 18,000명 | 60,000명 |
| 피크 RPS | 900 RPS | 3,000 RPS |
| 스파이크 RPS | 1,800 RPS | 6,000 RPS |

### 1.4 성능 목표

| 항목 | 목표 | 근거 |
| --- | --- | --- |
| 응답시간 (p95) | < 300ms | 사용자 체감 성능 향상 |
| 가용성 | 99.9% | 월 ~43분 다운타임 허용 |
| 피크 RPS | 3,000 | 동접 60,000명 기준 |
| 스파이크 RPS | 6,000 | 동접 120,000명 기준 |

---

## 2. Kubeadm 도입 이유 및 기대 효과

### 2.1 왜 Kubeadm인가? (vs EKS/GKE)

| 비교 항목 | Kubeadm (Self-managed) | EKS (AWS Managed) |
| --- | --- | --- |
| **컨트롤 플레인 비용** | EC2 비용만 (월 ~10만원) | 클러스터당 월 $73 (~10만원) + EC2 |
| **커스터마이징** | 완전한 제어 (CNI, 스토리지, 인증) | AWS 정책 내 제한적 |
| **학습 가치** | Kubernetes 내부 구조 이해 | 추상화된 관리 |
| **운영 부담** | 높음 (컨트롤 플레인 관리 필요) | 낮음 (AWS가 관리) |
| **장애 복구** | 수동 대응 필요 | 자동 복구 |

#### 본 설계에서의 선택: Kubeadm

본 프로젝트에서는 EKS가 아닌 Kubeadm으로 클러스터를 직접 구성합니다. 그 이유는 다음 두 가지입니다.

**첫째, Kubernetes 내부 동작 원리를 직접 경험하기 위해서입니다.**

EKS는 Control Plane을 AWS가 관리하기 때문에 사용자 입장에서는 블랙박스입니다. Kubeadm으로 직접 구성하면 다음을 실제로 경험할 수 있습니다:

- API Server가 요청을 어떻게 인증/인가하는지
- etcd에 클러스터 상태가 어떻게 저장되는지
- Scheduler가 Pod를 어떤 기준으로 노드에 배치하는지
- Controller Manager가 Desired State와 Current State를 어떻게 reconcile하는지
- CNI(Calico)가 Pod 네트워크를 어떻게 구성하는지
- 인증서 체계(PKI)가 컴포넌트 간 통신을 어떻게 보호하는지

이러한 이해과정을 직접 경험 하며 장애 상황에서 문제의 레이어를 빠르게 판별할 수 있습니다.

**둘째, EKS Control Plane 비용을 절감합니다.**

| 항목 | Kubeadm | EKS |
| --- | --- | --- |
| Control Plane 비용 | Master EC2 비용만 (t3.medium: 월 ~5.5만원) | 클러스터당 월 $73 (~10만원) + Worker EC2 |
| 월 차이 | - | 약 4.5만원 추가 |

#### 실무 환경이라면: EKS

실제 프로덕션 서비스라면 EKS를 선택할 것입니다.

| 관점 | Kubeadm의 한계 | EKS의 이점 |
| --- | --- | --- |
| **Control Plane 가용성** | Master 단일 장애점(SPOF), 장애 시 수동 복구 5~30분 | AWS 관리형 HA, 자동 복구, 99.95% SLA |
| **etcd 관리** | 백업/복구를 직접 운영, 데이터 손실 리스크 | AWS가 자동 관리 |
| **K8s 버전 업그레이드** | kubeadm upgrade 직접 실행, 실패 시 롤백 어려움 | 콘솔 클릭 또는 API 호출로 관리형 업그레이드 |
| **인증서 관리** | 수동 갱신 필요 (1년 만료), 누락 시 클러스터 중단 | AWS가 자동 관리 |
| **운영 인력** | 인프라 전담 인력 필요 | DevOps 팀이 워크로드에 집중 가능 |

MAU 100만, 피크 동접 60,000명 규모에서 Master HA(3대)를 구성하면 EKS 대비 오히려 비용이 비싸지며 etcd 장애로 클러스터 전체 상태를 잃는 리스크는 비즈니스에 치명적입니다.

| 구분 | 선택 | 이유 |
| --- | --- | --- |
| **본 설계** | Kubeadm | K8s 내부 구조 직접 경험, Control Plane 비용 절감 |
| **실무 전환 시** | EKS | Control Plane HA 보장, 운영 부담 감소, AWS 생태계 통합 |

### 2.2 Kubeadm 도입으로 해결되는 문제

| 4단계 문제 | Kubeadm 솔루션 | 기대 효과 |
| --- | --- | --- |
| 수동 스케일링 (20~30분) | HPA 자동 스케일링 | **2~3분 내 Pod 확장** |
| 고정 리소스 할당 | Pod 단위 동적 배치 | **리소스 효율 40% 향상** |
| 개별 서버 관리 (18대) | 선언적 배포 (kubectl apply) | **배포 복잡도 80% 감소** |
| 수동 장애 복구 (5~10분) | Self-healing (자동 재시작) | **MTTR 1분 이내** |
| 수동 서비스 디스커버리 | Kubernetes Service/DNS | **동적 엔드포인트 관리** |

### 2.3 기대 효과 정량화

| 지표 | 4단계 (Docker) | 5단계 (Kubeadm) | 개선율 |
| --- | --- | --- | --- |
| 스케일링 시간 | 20~30분 | 2~3분 | **90% 단축** |
| 배포 시간 | 15분/서비스 | 3분/전체 | **80% 단축** |
| 장애 복구 시간 (MTTR) | 5~10분 | < 1분 | **90% 단축** |
| 리소스 활용률 | 50~60% | 70~80% | **30% 향상** |
| 인프라 비용 (월) | 약 150만원 | 약 120만원 | **20% 절감** |

---

## 3. 클러스터 아키텍처 설계

### 3.1 빌리지 서비스 구조
[빌리지 서비스 구조 — 멀티모달 모놀리스]
```
├── Next.js (Web Server)
│   └── 프론트엔드 SSR/CSR, 정적 자산 서빙
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

총 3개 애플리케이션 (Next.js, Spring Boot, FastAPI) + 2개 상태 저장 컴포넌트 (RabbitMQ, Qdrant). MySQL은 RDS이므로 클러스터 내 사이징 대상에서 제외한다.

### 3.2 워크로드 성격 분류

**같이 죽어도 되는 것끼리 묶고, 같이 죽으면 안 되는 것은 분리한다.** 
(stateless와 stateful 로 분리한다)

| 컴포넌트 | 성격 | 스케일 방식 | 실패 시 영향 | 메모리 특성 |
| --- | --- | --- | --- | --- |
| Next.js | Stateless | Replica 증가 | 페이지 로딩 실패 | 예측 가능, 낮음 |
| Spring Boot | Stateless (WebSocket 세션은 메모리) | Replica 증가 | 전체 서비스 중단 | JVM 힙 + 커넥션 풀 |
| FastAPI | Stateless | Replica 증가 | AI 기능 불가 | 낮음 (오케스트레이션) |
| RabbitMQ | **Stateful** | 수동/고정 | 비동기 메시지 유실 | Watermark 민감 |
| Qdrant | **Stateful** | 벡터 수에 비례 | 추천/검색 불가 | 벡터 수 × 차원 × 4B × 1.5 |

Next.js, Spring Boot, FastAPI는 공통적으로 stateless에 가깝고, HPA/rolling update/auto-healing의 대상이며, scale-out 방향이 "replica 증가"다. 
반면 RabbitMQ와 Qdrant는 stateful하며, 단순한 replica 증가로 해결되지 않는다
이들을 섞으면 scaleout되는 app Pod 들에 의해서 data pod들의 자원 사용에 영향을 끼칠 수 있다.
request와 limit을 잘 관리하면 QoS에 의해서 OOM killer가 app pod를 우선으로 내보내겠지만, 그 이전까진 영향을 받는 것은 마찬가지이다.

---

## 4. 네임스페이스 설계

### 4.1 namespace 목적
네임스페이스로 할 수 있는 것은 크게 네 가지다.

**1) 배포 경계**: 같은 네임스페이스 안의 리소스는 같은 ArgoCD Application으로 관리할 수 있다. 배포 단위가 곧 네임스페이스 단위가 된다. 앱만 수정해서 배포해야 하는데 RabbitMQ 설정이 같은 배포 범위 안에 있으면, 단순한 앱 릴리즈가 stateful 컴포넌트의 재적용 위험까지 가져온다.

**2) 권한 경계**: RBAC은 네임스페이스 단위로 적용된다. 앱 배포를 수행하는 CI/CD 서비스 어카운트가 데이터 계층의 Secret(DB 비밀번호, RabbitMQ 인증정보)까지 접근할 수 있으면 안 된다.

**3) 리소스 정책 경계**: ResourceQuota, LimitRange, NetworkPolicy는 네임스페이스 단위로 적용된다. Stateless 앱은 HPA로 탄력적으로 확장되어야 하지만, RabbitMQ는 보수적인 자원 설정이 필요하다.

**4) 운영 절차 경계**: 앱 Pod는 재시작과 롤링 업데이트에 유연하지만, RabbitMQ는 재시작 순서와 디스크 상태를 고려해야 한다. 모니터링 도구는 장애 시 가장 먼저 확인해야 할 대상이므로, 사용자 서비스와 같은 경계에 섞으면 안 된다.

### 4.2 네임스페이스 구조

이 네 가지 기준을 적용하면, 네임스페이스는 **앱 / 데이터 / 외부 진입점 / 운영 도구** 4개로 나뉜다.

| 네임스페이스 | 포함 리소스 | 분리 이유 |
| --- | --- | --- |
| **billage-app** | Next.js, Spring Boot, FastAPI Deployment/Service/HPA | 같은 릴리즈 흐름, 같은 배포 파이프라인, stateless 운영 전략 |
| **billage-data** | RabbitMQ StatefulSet, Qdrant StatefulSet | 배포 주기가 다르고, 재시작 영향이 크며, 스토리지/백업 절차가 별도 |
| **billage-edge** | ingress-nginx, cert-manager | TLS 인증서, 라우팅 정책은 앱 코드와 무관한 별도 책임 |
| **billage-ops** | ArgoCD, Prometheus, Grafana, Loki, metrics-server | 운영 도구는 사용자 트래픽을 처리하지 않지만, 장애 분석에 필수 |

**실제 운영에서 이 분리가 효과를 발휘하는 사례:**

ArgoCD로 앱을 배포할 때, `billage-app`에 대한 Application과 `billage-data`에 대한 Application을 별도로 구성한다. Spring Boot 코드를 수정해서 배포할 때 RabbitMQ StatefulSet이 재적용되는 일이 없다. 반대로 RabbitMQ 설정을 변경할 때도 앱 Deployment가 영향받지 않는다.

노드 드레인 시, `billage-data`의 PDB는 RabbitMQ quorum을 보호하는 설정이고, `billage-app`의 PDB는 최소 가용 replica를 보장하는 설정이다. 같은 네임스페이스에 있으면 이 정책을 서로 다르게 적용하기 어렵다.

---

## 5. 리소스 계산:
### 5.1 컴포넌트별 리소스 산정

| 컴포넌트 | CPU request | Memory request | CPU limit | Memory limit | 산정 근거 |
| --- | --- | --- | --- | --- | --- |
| **Spring Boot** | 750m | 1Gi | 2000m | 2Gi | 실측 566MB idle × 1.8, JVM 힙 + 커넥션 풀 + WebSocket 세션 |
| **Next.js** | 300m | 512Mi | 1000m | 1Gi | SSR은 CPU보다 메모리, Node.js 기본 힙 ~300MB + SSR 버퍼 |
| **FastAPI** | 300m | 512Mi | 1000m | 1Gi | 오케스트레이션만 수행, 모델 추론은 RunPod |
| **RabbitMQ** | 250m | 1Gi | 500m | 1.5Gi | 공식 권장: 컨테이너 환경에서 absolute threshold 사용, 최소 256Mi 여유 |
| **Qdrant** | 500m | 2Gi | 1000m | 4Gi | 768d 기준 10만 벡터 ~0.43Gi, 초기 여유 포함 |
| **Ingress Controller** | 100m | 128Mi | 200m | 256Mi | Nginx ingress 기본 요구량 |

### 5.2 최소 Replica 수 산정

Pod 수를 정하기 전에, 먼저 각 컴포넌트의 특성을 고려해야 한다.

**Spring Boot (3 Replicas)**

핵심 서비스이므로 단일 Pod 장애 시에도 서비스가 유지되어야 한다. MAU 100만 기준 피크 RPS 3,000 중 REST + WebSocket이 차지하는 비율이 약 70%라고 보면 2,100 RPS. Pod당 처리량을 500 RPS로 잡으면 4.2 → 5개가 필요하지만, 이건 피크 시점이다. **최소 replica는 평시 기준으로 잡고, 피크는 HPA가 처리한다.** 평시(새벽~오전)는 피크의 30% 수준이므로 630 RPS → 2 Pod면 충분하지만, HA를 위해 **최소 3 Pod**. 1개가 죽어도 2개가 트래픽을 감당한다.

**Next.js (2 Replicas)**

SSR 요청은 전체 트래픽의 약 25%. 평시 225 RPS → Pod당 300 RPS 처리 가능하면 1 Pod로도 되지만, HA를 위해 **최소 2 Pod**. Next.js의 cold start는 5~10초 수준으로 빠르므로, 1 Pod 장애 시 auto-healing으로 빠르게 복구된다.

**FastAPI (2 Replicas)**

AI 오케스트레이션은 RunPod 호출 대기가 대부분이라 CPU 부하가 낮다. 하지만 멀티모달 기능(이미지 분석 → 자동 게시글 작성)이 UX 경로에 있으므로 완전히 죽으면 사용자 경험에 직접 영향을 준다. **최소 2 Pod**.

**RabbitMQ (3 Replicas)**

프로덕션에서 quorum queue를 쓰려면 3노드가 필요하다. 이건 자원 때문이 아니라 **구조 때문에 3개**다.

**Qdrant (1 Replica)**

초기에는 벡터 수가 10만 미만이므로 single replica로 시작한다. snapshot 백업 전략으로 데이터를 보호하고, 벡터가 70만을 넘어가면 replica 또는 별도 노드 풀 분리를 검토한다.

**Ingress Controller (2 Replicas)**

외부 트래픽 진입점이므로 단일 장애점이면 안 된다. **최소 2 Pod**.

### 5.3 전체 리소스 합산

**App plane baseline (최소 운영 상태)**

| 컴포넌트 | Replicas | CPU request 합계 | Memory request 합계 |
| --- | --- | --- | --- |
| Spring Boot | 3 | 2,250m | 3Gi |
| Next.js | 2 | 600m | 1Gi |
| FastAPI | 2 | 600m | 1Gi |
| Ingress | 2 | 200m | 256Mi |
| **App 합계** | **9** | **3,650m (3.65 vCPU)** | **5,256Mi (~5.25Gi)** |

**Data plane baseline**

| 컴포넌트 | Replicas | CPU request 합계 | Memory request 합계 |
| --- | --- | --- | --- |
| RabbitMQ | 3 | 750m | 3Gi |
| Qdrant | 1 | 500m | 2Gi |
| **Data 합계** | **4** | **1,250m (1.25 vCPU)** | **5Gi** |

**전체 baseline: 13 Pods, CPU 4.9 vCPU, Memory 10.25Gi**

이전 문서의 "최소 11개 Pod에 7.5 CPU, 15Gi"와 비교하면 상당히 줄었다. 이유는 두 가지다. 첫째, MSA가 아닌 모놀리스 구조를 반영하여 Chat Server, Notification Server, Search Server가 별도 Deployment로 존재하지 않는다. 둘째, 실측 기반으로 request를 산정하여 과도한 할당을 줄였다.

---

## 6. 노드 사이징: allocatable이 진짜 숫자다

### 6.1 Raw spec이 아니라 allocatable을 봐야 한다

Kubernetes 스케줄러는 노드의 raw spec이 아니라 **allocatable** 기준으로 Pod를 배치한다. kubelet, OS 데몬, kube-proxy, CNI 에이전트 등이 자원을 예약하기 때문이다.

self-managed kubeadm에는 AWS처럼 "이만큼 예약"이라는 고정 공식이 없다. 여기서는 GKE가 공개한 reservation 공식을 planning proxy로 쓴다. 보수적이지만, 계획 단계에서 안전한 추정치를 제공한다.

**GKE 기준 allocatable 추정:**

| 노드 raw spec | Allocatable CPU | Allocatable Memory | 비고 |
| --- | --- | --- | --- |
| 2 vCPU / 4Gi | ~1.93 vCPU | ~2.9Gi | kubelet/OS 예약 후 |
| 2 vCPU / 8Gi | ~1.93 vCPU | ~6.1Gi |  |
| 4 vCPU / 16Gi | ~3.92 vCPU | ~13.3Gi |  |

이게 중요한 이유는, **작은 노드를 여러 개 두면 kubelet/OS/eviction reserve가 노드마다 중복**되기 때문이다. 2 × medium(4Gi)은 allocatable memory 합계 5.8Gi지만, 1 × large(8Gi)는 6.1Gi다. 같은 돈인데 큰 노드 하나가 allocatable memory가 더 남는다.

### 6.2 인스턴스 타입 비교: 서울 리전 기준

가격은 AWS 서울 리전(ap-northeast-2) 온디맨드 Linux 기준이다.

| 인스턴스 | vCPU | Memory | 월 비용 (USD) | 특성 |
| --- | --- | --- | --- | --- |
| **t3.medium** | 2 | 4Gi | ~$37.96 | Burstable, credit 기반 |
| **t3.large** | 2 | 8Gi | ~$75.92 | Burstable, credit 기반 |
| **t3.xlarge** | 4 | 16Gi | ~$151.84 | Burstable, credit 기반 |
| **m7i-flex.large** | 2 | 8Gi | ~$85.93 | 95% CPU 시간 보장, credit 아님 |
| **m7i.large** | 2 | 8Gi | ~$90.45 | 전용 CPU, 예측 가능 |
| **m7i.xlarge** | 4 | 16Gi | ~$180.89 | 전용 CPU |
| **c7i.large** | 2 | 4Gi | ~$73.58 | Compute-optimized, 메모리 적음 |
| **c7i.xlarge** | 4 | 8Gi | ~$147.17 | Compute-optimized |

### 6.3 인스턴스 계열 선택 논리

**T3 시리즈**

싸다. 하지만 burst/credit 모델이라서 sustained high CPU가 길어지면 비용과 성능 예측이 흐려진다. AWS도 T3를 "moderate CPU with temporary spikes" 용도로 설명한다. 피크 시간대에 CPU가 지속적으로 높아지는 우리 서비스의 app pool 기본 선택지로는 애매하다. 단, 새벽 시간대 트래픽이 거의 없는 특성을 고려하면 credit이 충분히 축적되므로 budget-first 대안으로는 고려할 수 있다.

**M7i-flex 시리즈**

app pool에 가장 먼저 보는 계열이다. 우리 app plane은 완전한 CPU-bound가 아니고, Spring/WebSocket/SSR/FastAPI orchestration처럼 **메모리 바닥이 있는 general-purpose workload**다. M7i-flex는 T3처럼 credit billing이 아니면서도, "항상 CPU 100%를 꽉 쓰지 않는" 워크로드에 맞게 설계되어 full CPU를 95% 시간 동안 낼 수 있다.

**M7i 시리즈**

control-plane이나 RabbitMQ처럼 더 예측 가능해야 하는 계층에 적합하다. M7i-flex 대비 월 ~$4.52/노드 차이. control-plane과 stateful data 노드에서는 그 차이를 내는 편이 낫다.

**C7i 시리즈**

지금은 아니다. c7i.large는 t3.large보다 거의 안 싼데 메모리가 절반(4Gi vs 8Gi)이다. 서울 기준 c7i.large $73.58, t3.large $75.92로 월 $2 차이. 우리 서비스는 노드 선택에서 memory-to-vCPU ratio가 더 중요하다. Spring Boot Pod 하나가 1Gi request인 상황에서 4Gi raw / 2.9Gi allocatable 노드는 너무 빡빡하다. C는 지금 false economy다.

### 6.4 medium vs large vs xlarge 비교

**2 × t3.medium vs 1 × t3.large**

가격이 정확히 같다: $75.92/월.

- 2 × medium → allocatable memory 2.9 × 2 = **5.8Gi**
- 1 × large → allocatable memory **6.1Gi**

같은 돈인데 큰 노드 하나가 allocatable이 더 남는다. 반대로 medium 두 개는 failure domain이 2개로 늘어나는 장점이 있다. 하지만 우리 워크로드는 Spring Boot 1Gi + 다른 Pod들이 한 노드에 들어가야 하므로, 2.9Gi allocatable인 medium은 너무 빡빡하다. **medium은 main pool에 부적합.**

**2 × m7i-flex.large vs 1 × m7i-flex.xlarge**

가격이 거의 같다: ~$171.86 vs ~$171.78/월.

- 2 × large → allocatable memory **12.2Gi**, CPU **3.86 vCPU**
- 1 × xlarge → allocatable memory **13.3Gi**, CPU **3.92 vCPU**

큰 노드 하나가 메모리는 조금 더 효율적이다. 하지만 두 large는 **HA와 autoscaling agility**가 더 좋다. 노드 하나가 죽어도 나머지 하나가 버틴다. 그래서 결론은:

- **replica가 많은 app plane → many large** (HA와 scale-down 민첩성)
- **단일 memory-heavy pod가 중요한 경우 → xlarge** (한 노드의 allocatable을 키우는 이득)

---

## 7. 노드 그룹 설계

### 7.1 분리 원칙: 실패 모드가 다른 계층만 분리한다

노드 그룹을 서비스마다 나누면 bin-packing 효율이 떨어지고, idle cost가 올라가고, ASG/affinity 규칙이 복잡해진다. 분리는 **failure mode가 다른 계층에만** 해야 한다.

**분리해서 얻는 것:**

- **가용성**: app 노드의 spike가 RabbitMQ/Qdrant를 흔들지 않는다. Qdrant compaction이나 RabbitMQ memory alarm이 app latency에 전이되지 않는다.
- **리소스 격리성**: memory-sensitive workload를 따로 두면 node pressure가 국소화된다.
- **운영 단순성**: stateful과 stateless의 lifecycle이 다르다. app는 HPA/CA로, data는 주로 fixed capacity + 수동 확장으로 운영한다.

**분리해서 잃는 것:**

- bin-packing 효율 저하. 어떤 풀은 남고 어떤 풀은 찰 수 있다.
- idle cost 증가.
- ASG/node group/affinity 규칙 증가로 운영 복잡도 상승.

이 트레이드오프를 감안하면, 분리할 경계는 **app ↔ data**, 그리고 나중에 **data ↔ vector**까지다.

### 7.2 컨트롤 플레인

| 항목 | 스펙 | 근거 |
| --- | --- | --- |
| 수량 | 3대 | etcd Raft 합의: 과반수(quorum) 필요, 1대 장애 허용 |
| 인스턴스 | m7i.large (2 vCPU, 8Gi) | etcd/API Server는 예측 가능한 성능 필요 → M7i |
| 디스크 | gp3 50GB | etcd 데이터 저장 |
| 가용영역 | 2a, 2b, 2c 분산 | AZ 장애 대비 |

5대는 99.9% SLO 기준으로 오버스펙이다. 2대 장애를 동시에 허용해야 할 시나리오가 아니라면 3대가 적정하다.

### 7.3 App Node Group

| 항목 | 스펙 | 근거 |
| --- | --- | --- |
| 수량 | 최소 4대, 최대 8대 (ASG) | CPU 기준 노드 수 산정 (아래 계산) |
| 인스턴스 | m7i-flex.large (2 vCPU, 8Gi) | General-purpose, credit 아닌 95% CPU 보장 |

**왜 4대인가**

App baseline request: CPU 3.65 vCPU, Memory 5.25Gi

m7i-flex.large 1대의 allocatable: ~1.93 vCPU, ~6.1Gi

여분을 "항상 30% 남긴다" 식의 퍼센트로 잡는 것은 여기서 최적이 아니다. app plane에서 CPU headroom은 **HPA/CA 반응 지연을 버티는 운영점**으로 잡아야 한다. HPA는 새 Pod를 만들고, Cluster Autoscaler는 unschedulable Pod가 생긴 뒤 새 노드를 만든다. 둘 다 request 기반으로 움직인다. 그래서 **steady state에서 allocatable CPU의 60% 안쪽**을 목표로 둔다.

- CPU 기준 필요 노드: ceil(3.65 / (1.93 × 0.6)) = ceil(3.65 / 1.158) = **4대**
- Memory 기준 필요 노드: ceil(5.25 / (6.1 × 0.7)) = ceil(5.25 / 4.27) = **2대**

즉 app plane은 **CPU-driven**이고, 그래서 4 × large가 맞다. 4대의 총 allocatable은 약 7.72 vCPU / 24.4Gi. Baseline에서 CPU 약 47%, Memory 약 21%. 이건 "놀고 있다"가 아니라, Spring cold start + WebSocket reconnect + HPA/CA 반응 지연을 감안한 운영점으로 적당하다. **baseline부터 70~80%로 채우는 설계가 오히려 더 위험하다.** CA는 unschedulable Pod가 생겨야 반응하므로.

**Next.js와 Spring Boot를 같은 pool에 두는 이유:**

둘 다 외부 요청을 처리하는 stateless serving tier다. 둘 다 replica 기반 scale-out이다. 굳이 따로 node group으로 나누면 capacity fragmentation만 늘어난다. 단, 같은 node group이라는 말이지, 한쪽 Pod가 한 노드에 몰리면 안 된다. **topologySpreadConstraints**로 zone/hostname 기준으로 퍼뜨린다.

### 7.4 Data Node Group

| 항목 | 스펙 | 근거 |
| --- | --- | --- |
| 수량 | 3대 고정 | RabbitMQ 3노드 quorum (자원이 아니라 구조 때문) |
| 인스턴스 | m7i.large (2 vCPU, 8Gi) | Stateful 워크로드는 예측 가능한 성능 필요 → M7i |

Data baseline request: CPU 1.25 vCPU, Memory 5Gi

자원만 보면 2노드도 가능하지만, RabbitMQ는 prod에서 3노드 quorum이 자연스럽다. 그래서 data pool은 **자원 때문에 3개가 아니라, 구조 때문에 3개**다.

Data plane에서 memory headroom은 퍼센트가 아니라 **절대 envelope**로 잡아야 한다. RabbitMQ는 absolute memory threshold를 권장하고, 최소 256Mi는 항상 남겨두라고 한다. Qdrant working set + RabbitMQ watermark + node reserve가 한 노드에서 감당 가능한지가 핵심이다. 3노드 × 6.1Gi allocatable = 18.3Gi. Baseline 5Gi. 충분하다.

**Qdrant 분리 기준:**

Qdrant 공식 rough formula: `memory = vector_count × dimension × 4 bytes × 1.5`

768차원 기준:

- 10만 벡터 → ~0.43Gi
- 30만 벡터 → ~1.29Gi
- 70만 벡터 → ~3.0Gi
- 100만 벡터 → ~4.29Gi

70만~100만 벡터 구간에서 Qdrant는 "data pool 안에서 RabbitMQ와 같이 두기엔" 압박이 커진다. 이 시점부터 **vector pool = m7i.xlarge**로 분리한다. 단일 큰 Pod는 노드 수를 늘리는 것보다 한 노드의 allocatable을 키우는 것의 이득을 받는다.

### 7.5 노드 배치 전략 (Affinity / Taint / TopologySpread)

Kubernetes의 노드 배치 제어 수단은 세 가지다: **taint는 "막는 것"**, **affinity는 "가게 하는 것"**, **topology spread는 "퍼뜨리는 것"**.

**App plane:**

- Spring/Next/FastAPI → `nodeAffinity.required`로 app 노드만 보게 한다.
- `topologySpreadConstraints`로 `topology.kubernetes.io/zone`, `kubernetes.io/hostname` 기준으로 퍼뜨린다.
- hard anti-affinity를 남발하기보다 topology spread가 HA와 효율적 자원 활용에 더 유리하다.

**Data plane:**

- data 노드는 **taint**하고, data workload에만 **toleration**을 준다.
- 단, toleration만으로는 "거기로 간다"가 보장되지 않는다. toleration은 스케줄을 허용할 뿐 보장하지 않으므로, **toleration + nodeAffinity(required)를 함께** 써야 한다.
- RabbitMQ는 `podAntiAffinity.required`로 hostname 기준 분리한다 (3 Pod를 3노드에 1개씩).
- Qdrant는 초기엔 data pool에서 돌리되, RabbitMQ와는 soft anti-affinity로 시작한다.

```yaml
# Spring Boot Deployment 예시
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spring-boot
  namespace: billage-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: spring-boot
  template:
    metadata:
      labels:
        app: spring-boot
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role
                operator: In
                values: ["app"]
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: spring-boot
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: spring-boot
      containers:
      - name: spring-boot
        image: billage/spring-boot:v1.0.0
        resources:
          requests:
            cpu: "750m"
            memory: "1Gi"
          limits:
            cpu: "2000m"
            memory: "2Gi"
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 20
```

**Spring Boot Liveness 초기 지연 60초 이유:** JVM 웜업 시간(30초~1분) + DB 커넥션 풀 초기화. 너무 짧으면 정상 기동 중 재시작 루프가 발생한다. Next.js와 FastAPI는 cold start가 5~15초로 빠르므로 30초면 충분하고, auto-healing으로 빠르게 복구된다.

### Qdrant

| 비교 항목 | 클러스터 내부 (StatefulSet) | 외부 (Qdrant Cloud) |
| --- | --- | --- |
| **비용** | PVC(EBS gp3) 비용만: 월 ~5,000원 | 유료 월 ~$35(~5만원)부터 |
| **레이턴시** | 클러스터 내부 통신, < 1ms | 외부 네트워크 경유, 5~20ms |
| **운영 부담** | 직접 관리 (백업, 버전 업그레이드) | 관리형, 자동 백업 |

RDS와 ElastiCache를 외부화한 이유는 데이터 손실이 비즈니스에 치명적이기 때문입니다. Qdrant의 임베딩 벡터는 원본 데이터(물품 텍스트/이미지)와 모델이 있으면 재생성 가능합니다

| 데이터 | 손실 시 영향 | 복구 방법 | 외부화 필요성 |
| --- | --- | --- | --- |
| MySQL (물품, 유저) | 서비스 불가 | 백업 복원 외 방법 없음 | **높음 → RDS** |
| Qdrant (임베딩 벡터) | 추천 일시 중단 | 원본 데이터로 재임베딩 | **낮음 → 클러스터 내부** |

### Stateful 노드에 격리 배치하는 이유

Qdrant를 general 노드에 같이 배치하면 다음 문제가 발생합니다:

- **Cluster Autoscaler 충돌**: CA가 노드 축소 시 PVC(EBS)가 특정 AZ에 묶여 있어 재스케줄링 불가
- **노드 drain 시 다운타임**: PVC detach → 새 노드에서 attach → 기동에 1~3분 소요
- **피크 시 리소스 경합**: HPA가 Pod를 늘릴 때 Qdrant의 벡터 캐시가 디스크로 밀려남

따라서 Stateful 전용 노드(고정, CA 대상 제외)에 격리 배치합니다.

### 백업 전략

- Qdrant Snapshot API로 스냅샷 생성 (CronJob, 주 1회) → S3 업로드
- 장애 시: 스냅샷 복원 or 전체 재임베딩 (물품 10만 건 기준 약 2~3시간)

### 3.3 네트워크 설정

### CNI 비교 분석

#### CNI(Container Network Interface)란?

Kubernetes에서 Pod 간 네트워크 통신을 담당하는 플러그인입니다. CNI 선택은 클러스터의 **보안**, **성능**, **운영 복잡도**에 직접적인 영향을 미칩니다.

#### 후보 CNI 상세 비교

| 비교 항목 | **Cilium** | **Flannel** | **Calico** |
| --- | --- | --- | --- |
| **핵심 철학** | eBPF 기반 차세대 네트워킹 | 단순함, 최소 기능 | 엔터프라이즈급 네트워크 제어 |
| **네트워크 방식** | eBPF (커널 레벨 직접 실행) | VXLAN 오버레이 | BGP 기반 L3 라우팅 |
| **Network Policy** |  L3-L7 지원 | 미지원 | L3-L4 지원 |
| **성능** | 최상 (iptables 우회) | 중간 | 상 (오버레이 없음) |
| **트래픽 암호화** | WireGuard 내장 | 미지원 | WireGuard 지원 |
| **관찰성(Observability)** | Hubble 내장 | 없음 | 별도 구성 필요 |
| **서비스 메시** | 내장 (Istio 대체 가능) | 없음 | 없음 |
| **멀티 클러스터** | Cluster Mesh | 미지원 | 별도 구성 |
| **커널 요구사항** | Linux 5.4+ 필요 | 제약 없음 | 제약 없음 |
| **학습 곡선** | 높음 | 낮음 | 중간 |
| **레퍼런스** | 급성장 중 | 많음 (초보자용) | 가장 많음 (프로덕션) |

#### 각 CNI 상세 분석

**Cilium**

- **강점**: iptables/kube-proxy를 우회하여 커널 레벨에서 네트워크 로직 직접 실행 → 고성능
- **기능**: L7 네트워크 정책, Hubble 실시간 트래픽 관찰, 서비스 메시 내장
- **약점**: Linux 커널 5.4+ 필수, 운영 복잡도 높음, 문제 발생 시 디버깅 어려움

**Flannel**

- **강점**: 설치 직후 별도 설정 없이 Pod 간 통신 가능, 가장 단순하고 가벼움
- **용도**: "Pod 간 통신만 되면 된다"는 단순한 환경에 적합
- **약점**: Network Policy 미지원, 트래픽 암호화 없음, 프로덕션 부적합

**Calico**

- **강점**: 순수 L3 라우팅(BGP)으로 오버레이 캡슐화 없이 효율적 네트워크 경로 제공
- **동작**: 각 노드가 BGP 라우터처럼 동작하여 자신의 Pod IP 대역을 다른 노드에 광고
- **약점**: 네트워크에 대한 이해 필요, 초기 설정 복잡도 있음

---

### Calico 선택 이유

**빌리지 서비스는 Calico를 선택합니다.**

#### 선택 근거

| 요구사항 | Calico의 충족 방식 |
| --- | --- |
| **1. Network Policy 필수** | 서비스 간 통신 제어 가능 (AI Server → RunPod만 외부 허용, Chat → Main만 내부 허용) |
| **2. 검증된 안정성** | 가장 널리 사용되는 프로덕션 CNI] |
| **3. 성능** | BGP 기반 라우팅으로 오버레이 오버헤드 최소화 |
| **4. 적절한 학습 곡선** | Cilium보다 단순하면서도 Flannel보다 기능 충분 |
| **5. 커널 호환성** | AWS EC2 기본 커널에서 바로 사용 가능 (Cilium은 커널 업그레이드 필요) |

---

### Calico 선택으로 잃는 것

| 포기 항목 | 영향 | 대안/완화 방안 |
| --- | --- | --- |
| **eBPF 기반 고성능** | Cilium 대비 10~20% 낮은 처리량 (대규모 트래픽에서 차이 발생) | 현재 MAU 100만 규모에서는 Calico로 충분, 6단계 EKS 전환 시 Cilium 재검토 |
| **L7 Network Policy** | HTTP 메서드/경로 기반 세밀한 정책 불가 (L3-L4만 가능) | Ingress Controller(Nginx)에서 L7 제어, 또는 Istio 별도 도입 |
| **내장 Observability** | Hubble 같은 실시간 트래픽 시각화 없음 | Prometheus + Grafana로 별도 모니터링 스택 구성 |
| **서비스 메시 내장** | mTLS, 트래픽 분할 등 서비스 메시 기능 없음 | 필요 시 Istio/Linkerd 별도 도입 (현재 규모에서는 불필요) |
| **멀티 클러스터 연결** | Cluster Mesh 같은 간편한 멀티 클러스터 연결 없음 | 6단계 EKS 전환 시 AWS VPC Peering 또는 Cilium 전환으로 해결 |

### Calico NetworkPolicy 설계

#### 설계 원칙: Default Deny → 필요한 통신만 Whitelist 허용

Kubernetes 기본 동작은 모든 Pod 간 통신 허용입니다. 한 서비스가 침해되면 다른 서비스로의 lateral movement(횡이동)가 가능합니다. Default Deny로 잠그고 필요한 통신만 명시적으로 허용합니다.

```
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: billage
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

#### 서비스 간 통신 허용 매트릭스

| 출발 → 도착 | Web | Main | Chat | Noti | Search | AI | Qdrant | RabbitMQ | RDS | Redis | 외부 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Ingress Controller** | ✅ | ✅ | ✅ | ✗ | ✗ | ✅ | ✗ | ✗ | - | - | - |
| **Web Server** | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **Main Server** | ✗ | - | ✗ | ✅ | ✗ | ✗ | ✗ | ✗ | ✅ | ✅ | ✗ |
| **Chat Server** | ✗ | ✅ | - | ✗ | ✗ | ✗ | ✗ | ✅ | ✗ | ✅ | ✗ |
| **Notification** | ✗ | ✗ | ✗ | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✅ | ✅(FCM) |
| **Search Server** | ✗ | ✗ | ✗ | ✗ | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **AI Server** | ✗ | ✗ | ✗ | ✗ | ✗ | - | ✅ | ✗ | ✅ | ✗ | ✅(RunPod) |

**트레이드오프:**

- 얻는 것: 공격 표면 최소화, lateral movement 제한, 명시적 보안 경계
- 잃는 것: 운영 복잡도 증가 (새 서비스/통신 경로 변경 시 정책 수정 필요), 디버깅 난이도 상승 (DNS port 53 허용 빼먹기 빈번), L3-L4 한계
- 완화: 모든 정책에 DNS 허용 기본 포함, ArgoCD로 GitOps 관리, L7 제어는 Ingress annotation으로 보완

### 노드 간 통신 방식

```
[클러스터 내부 통신]

                    ┌─────────────────────────────────────────┐
                    │            Kubernetes Cluster           │
                    │                                         │
                    │   ┌─────────┐  ┌─────────┐  ┌─────────┐│
                    │   │Master-1 │  │Master-2 │  │Master-3 ││
                    │   │(etcd)   │  │(etcd)   │  │(etcd)   ││
                    │   └────┬────┘  └────┬────┘  └────┬────┘│
                    │        │            │            │      │
                    │        └────────────┼────────────┘      │
                    │                     │                    │
                    │              ┌──────┴──────┐            │
                    │              │ kube-apiserver           │
                    │              └──────┬──────┘            │
                    │                     │                    │
                    │   ┌─────────────────┼─────────────────┐ │
                    │   │                 │                 │ │
                    │ ┌─┴───┐  ┌─────┐  ┌─┴───┐  ┌─────┐   │ │
                    │ │Node1│  │Node2│  │Node3│  │Node4│...│ │
                    │ └─────┘  └─────┘  └─────┘  └─────┘   │ │
                    │                                       │ │
                    │   Calico BGP Mesh (Pod Network)       │ │
                    └───────────────────────────────────────┘ │
                    └─────────────────────────────────────────┘

[외부 통신]
Internet → ALB (Ingress) → Ingress Controller → Service → Pod

```

---

## 5. 스케일 전략

### 5.1 HPA 설정

### 메트릭 서버 구성

```yaml
# metrics-server 설치
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-server
  namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      containers:
      - name: metrics-server
        image: k8s.gcr.io/metrics-server/metrics-server:v0.6.1
        args:
        - --kubelet-insecure-tls
        - --kubelet-preferred-address-types=InternalIP

```

### 서비스별 HPA 설정

| 서비스 | Min | Max | CPU 임계값 | 메모리 임계값 | Scale-up 안정화 | Scale-down 안정화 |
| --- | --- | --- | --- | --- | --- | --- |
| Web Server | 3 | 10 | 70% | 80% | 0초 | 300초 |
| Main Server | 4 | 15 | 70% | 80% | 0초 | 300초 |
| Chat Server | 3 | 8 | 60% | 70% | 0초 | 600초 |
| Notification | 2 | 6 | 70% | 80% | 0초 | 300초 |
| Search Server | 2 | 6 | 70% | 80% | 0초 | 300초 |
| AI Server | 2 | 5 | 50% | 70% | 0초 | 300초 |

**Chat Server 특수 설정 이유:**

- WebSocket 연결은 Pod 종료 시 재연결 필요 → Scale-down 600초로 보수적
- CPU 임계값 60%로 낮춰 빠른 Scale-up 유도

```yaml
# Main Server HPA 예시
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: main-server-hpa
  namespace: billage
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: main-server
  minReplicas: 4
  maxReplicas: 15
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 4
        periodSeconds: 15
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60

```

### 5.2 스케일링 시나리오

### 평시 → 피크 전환 (점심시간 12:00)

```
[12:00] 트래픽 급증 감지
        ├── Main Server: CPU 75% 도달
        └── HPA 트리거

[12:00:15] Scale-up 시작
        ├── Main Server: 4 → 8 Pods (+4)
        └── Web Server: 3 → 5 Pods (+2)

[12:02:00] 신규 Pod Ready
        ├── Main Server: 8 Pods 운영 중
        └── 응답시간 정상화 (< 200ms)

총 소요시간: 약 2분

```

### 스파이크 대응 (바이럴 이벤트)

```
[이벤트 시작] RPS 3,000 → 6,000 급증
        ├── 모든 서비스 CPU 80% 초과
        └── HPA 동시 트리거

[+15초] 대규모 Scale-up
        ├── Main Server: 4 → 15 Pods (Max)
        ├── Web Server: 3 → 10 Pods (Max)
        └── Chat Server: 3 → 8 Pods (Max)

[+3분] 클러스터 안정화
        ├── 전체 Pod 수: 16 → 45
        └── 응답시간 < 300ms 유지

총 소요시간: 약 3분

```

---

## 6. 운영 전략

### 6.1 Rolling Update 정책

모든 Deployment에 Rolling Update 전략을 적용하여 무중단 배포를 보장합니다.

```yaml
# Deployment Strategy 설정
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%        # 최대 125% Pod 동시 운영
      maxUnavailable: 0    # 항상 100% 가용성 유지

```

| 서비스 | maxSurge | maxUnavailable | 근거 |
| --- | --- | --- | --- |
| Main Server | 25% | 0 | 핵심 서비스, 무중단 필수 |
| Web Server | 25% | 0 | 사용자 경험 직접 영향 |
| Chat Server | 50% | 0 | WebSocket 재연결 최소화 |
| Notification | 50% | 25% | 비동기, 일시적 지연 허용 |
| Search Server | 25% | 0 | 검색 기능 가용성 |
| AI Server | 50% | 25% | 비동기, 일시적 지연 허용 |

### 6.2 장애 시 재시작 정책

### Pod Restart Policy

```yaml
spec:
  restartPolicy: Always  # 모든 Pod에 적용

```

### Liveness/Readiness Probe 설정

| 서비스 | Liveness 경로 | Readiness 경로 | 초기 지연 | 주기 |
| --- | --- | --- | --- | --- |
| Main Server | /api/health | /api/health | 60초 | 20초 |
| Web Server | /health | /health | 30초 | 10초 |
| Chat Server | /health | /health | 15초 | 10초 |
| Notification | /api/health | /api/health | 60초 | 20초 |
| Search Server | /api/health | /api/health | 60초 | 20초 |
| AI Server | /health | /health | 30초 | 15초 |

**Main Server Liveness 초기 지연 60초 이유:**

- Spring Boot JVM 웜업 시간 필요 (30초~1분)
- DB 커넥션 풀 초기화 시간 포함
- 너무 짧으면 정상 기동 중 재시작 루프 발생

### 6.3 Pod Disruption Budget (PDB)

유지보수(노드 드레인) 시에도 최소 가용성을 보장합니다.

```yaml
# Main Server PDB
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: main-server-pdb
  namespace: billage
spec:
  minAvailable: 75%  # 최소 75% Pod 유지
  selector:
    matchLabels:
      app: main-server

```

| 서비스 | minAvailable | 근거 |
| --- | --- | --- |
| Main Server | 75% | 핵심 서비스, 높은 가용성 |
| Web Server | 66% | 2/3 이상 유지 |
| Chat Server | 66% | WebSocket 연결 유지 |
| Notification | 50% | 지연 허용 가능 |
| Search Server | 50% | 지연 허용 가능 |
| AI Server | 50% | 지연 허용 가능 |

### 6.4 ArgoCD 활용 계획

### GitOps 워크플로우

```
[GitOps 배포 흐름]

Developer → Git Push → GitHub Repository
                              │
                              ▼
                         ArgoCD Sync
                              │
                              ▼
                      Kubernetes Cluster
                              │
                    ┌─────────┼─────────┐
                    ▼         ▼         ▼
              Deployment  Service  ConfigMap

```

### ArgoCD 프로젝트 구조

```
billage-k8s-manifests/
├── apps/
│   ├── web-server/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml
│   ├── main-server/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml
│   │   └── configmap.yaml
│   ├── chat-server/
│   ├── notification-server/
│   ├── search-server/
│   └── ai-server/
├── base/
│   ├── namespace.yaml
│   ├── network-policy.yaml
│   └── secrets.yaml
└── argocd/
    └── application.yaml

```

### ArgoCD Application 설정

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: billage-production
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/billage/k8s-manifests.git
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: billage
  syncPolicy:
    automated:
      prune: true       # 삭제된 리소스 자동 정리
      selfHeal: true    # Drift 자동 복구
    syncOptions:
    - CreateNamespace=true

```

### 6.5 Helm Chart 활용 계획