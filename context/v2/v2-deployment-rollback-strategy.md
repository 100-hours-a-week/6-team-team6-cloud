# v2 배포 및 롤백 전략 설계서

> 작성일: 2026-03-01
> 상태: 검토 중
> 관련 인프라: v2/envs/prod (ALB + ASG + ECR + Docker)

---

## 1. v1에서 v2로 오면서 달라진 점

v1은 단일 EC2에 모든 서비스를 올리고, Nginx 리버스 프록시로 트래픽을 분배하는 구조였다.
배포는 서버에 SSH 접속해서 직접 하거나, 스크립트 한 번 돌리면 끝이었다. 단순했다.

v2는 다르다. AWS의 ALB를 통해 **트래픽 분산, 스케일링, 롤링 배포**를 위임한다.
서비스별로 ASG를 분리하고 (Backend, Frontend, AI), ECR에서 Docker 이미지를 pull하는 구조다.

이 구조에서는 "어떻게 배포할 것인가"가 단순하지 않다.
인스턴스가 여러 대이고, 무중단이어야 하고, 롤백도 가능해야 한다.

---

## 2. 처음 도입한 방식: Instance Refresh

### 왜 이 방식을 선택했나

처음에는 가장 단순한 방법을 택했다. Instance Refresh.

이 방식은 Launch Template의 user_data 스크립트를 기반으로,
ASG가 인스턴스를 하나씩 새로 만들고 기존 것을 terminate하면서
롤링 업데이트를 해나가는 것이다.

```
GitHub Actions → ECR push (prod-latest) → Instance Refresh 트리거
  → 새 EC2 생성 → user_data 실행 (docker pull + run)
  → ALB health check 통과 → 이전 EC2 terminate
  → 다음 인스턴스로...
```

**선택 이유:**
- CD 트리거만 실행하면 됨. 스크립트 하나만 있으면 된다
- AWS가 알아서 순차 배포해줌 (ALB drain/register 자동)
- 추가 도구나 에이전트 설치가 필요 없음
- 운영 복잡도가 낮고 개발 비용이 적게 든다

서버 1~2대 정도만 유지한다면 이 방식으로도 별 문제가 없다.

### 문제가 보이기 시작했다

#### 문제 1: 배포가 느리다

Instance Refresh는 **컨테이너 이미지를 교체하는 것이 아니라 인스턴스 자체를 교체**한다.

EC2 부팅 → Docker pull → 컨테이너 시작 → ALB health check 통과까지
인스턴스 한 대당 **5~10분**이 걸린다.

서버가 4대면? 20~40분이다.

운영하는 서버 대수에 비례해서 배포 시간이 증가한다.

- 배포 시간 증가 → 변경사항을 빠르게 반영하지 못함 → 유연하지 못함
- GitHub Actions 러너 사용 시간 증가 → 과금 요소
- 헬스체크 대기, 드레이닝 대기 등 작업 대기 시간이 쌓임

컨테이너만 바꾸면 30초~1분이면 되는 일을, EC2를 통째로 갈아끼우느라 10분씩 쓰고 있는 것이다.

#### 문제 2: 롤백이 어렵다

이게 더 심각한 문제다.

현재 user_data 스크립트는 이렇게 되어 있다:
```bash
IMAGE="$ECR_REGISTRY/billage-be:prod-latest"
docker pull $IMAGE
docker run -d ... $IMAGE
```

**무조건 `prod-latest`를 기준으로 refresh하도록 되어 있다.**

그런데 CI/CD에서 새 버전을 빌드하면 ECR의 `prod-latest` 태그가 덮어씌워진다.
이전 버전의 이미지는 태그가 사라져서 찾을 수가 없다.

롤백을 하려면?
- 이전 버전의 이미지를 ECR에 다시 `prod-latest`로 등록하거나
- user_data 스크립트를 임시로 수정하거나
- Launch Template을 새로 만들거나

어떤 방법이든 **즉시 롤백이 불가능**하다.
배포에 문제가 생겼을 때 빠르게 대응할 수 없다는 것은 프로덕션에서 치명적이다.

---

## 3. ECR 이미지 태그 전략 - 배포 방식보다 먼저 해결해야 할 문제

배포 방식을 Instance Refresh로 하든, SSM으로 하든, CodeDeploy로 하든
**이미지 태그 전략이 먼저 갖춰져야 롤백이 가능하다.**

### 고민한 옵션들

| 옵션 | 태그 형식 | 스케일링 호환 | 롤백 편의성 | 추적성 |
|------|----------|-------------|-----------|--------|
| A. latest + commit SHA | `prod-latest`, `prod-a1b2c3d` | O | re-tag 필요 | SHA로 추적 |
| B. latest + 날짜-SHA | `prod-latest`, `prod-20260228-a1b2c3d` | O | re-tag 필요 | 날짜+SHA 한눈에 |
| C. latest + 빌드번호 | `prod-latest`, `prod-build-42` | O | re-tag 필요 | 번호 관리 필요 |
| D. commit SHA만 | `prod-a1b2c3d` | X | 태그 지정만 | 정확함 |

### 결정: 옵션 B (latest + 날짜-commit SHA)

```
prod-latest              ← 뮤터블 태그. 항상 최신을 가리킴 (배포 + 스케일링용)
prod-20260228-a1b2c3d    ← 이뮤터블 태그. 롤백용. 언제, 어떤 커밋인지 한눈에 보임
```

**이유:**
- `prod-latest`를 유지하므로 user_data를 수정할 필요가 없다 (ASG 스케일링과 호환)
- 날짜가 포함되어 있어서 ECR 콘솔에서 "어제 배포한 것"을 바로 찾을 수 있다
- 이뮤터블 태그가 남아있으니 롤백 대상을 선택할 수 있다
- 어떤 배포 방식을 쓰든 이 태그 전략은 그대로 가져간다

**롤백 흐름:**
```bash
# 1. 이전 이미지에 prod-latest 태그를 다시 붙임
MANIFEST=$(aws ecr batch-get-image --repository-name billage-be \
  --image-ids imageTag=prod-20260227-f4e5d6c \
  --query 'images[0].imageManifest' --output text)

aws ecr put-image --repository-name billage-be \
  --image-tag prod-latest --image-manifest "$MANIFEST"

# 2. 배포 재실행 (어떤 방식이든)
```

**ECR Lifecycle Policy:**
- `prod-latest`는 항상 유지
- 버전 태그(`prod-YYYYMMDD-*`)는 최근 10개만 유지 → 스토리지 비용 관리

---

## 4. 그래서 배포 방식을 바꿔야 하나?

Instance Refresh의 느린 배포 속도를 해결하려면,
**인스턴스를 교체하지 않고 컨테이너만 교체하는 방식**으로 전환해야 한다.

이 시점에서 여러 선택지를 검토하게 됐다:
- AWS CodeDeploy
- AWS ECS
- AWS EKS + ArgoCD
- SSM Run Command + 직접 스크립트
- Ansible

### 4-1. Instance Refresh (현재 방식)

```
ASG가 EC2를 순차적으로 교체
  → 새 인스턴스 launch → user_data 실행 → health check 통과 → 이전 인스턴스 terminate
```

| 항목 | 평가 |
|------|------|
| 배포 속도 | 느림 (5~10분/대) |
| 롤백 | 느림 (refresh 재실행) |
| 자동 롤백 | 미지원 |
| 운영 복잡도 | 매우 낮음 |
| 추가 도구 | 없음 |
| 적합한 경우 | AMI 변경, 인프라 변경, 배포 빈도 낮을 때 |

### 4-2. SSM Run Command + 배포 스크립트

```
GitHub Actions → SSM으로 각 인스턴스에 순차적으로:
  ALB deregister → docker stop/pull/run → health check → ALB re-register
```

| 항목 | 평가 |
|------|------|
| 배포 속도 | 빠름 (30초~1분/대) |
| 롤백 | 빠름 (이전 태그로 재실행) |
| 자동 롤백 | 직접 구현 필요 |
| 운영 복잡도 | 높음 (스크립트 직접 관리) |
| 추가 도구 | 없음 (SSM Agent 이미 있음) |
| 적합한 경우 | 배포 로직을 100% 이해/제어하고 싶을 때 |

**주의점: 헬스체크 오작동 문제**
```
컨테이너 교체 중 (docker stop → docker run 사이 30초 다운)
  → ALB health check 실패
  → ASG (health_check_type = "ELB")가 인스턴스를 unhealthy로 판단
  → ASG가 인스턴스를 terminate!
  → 배포하려고 컨테이너 바꿨는데 ASG가 인스턴스를 죽여버리는 상황
```

해결: **반드시 ALB에서 먼저 deregister한 후** 컨테이너를 교체해야 한다.
또는 배포 중 ASG의 `ReplaceUnhealthy` 프로세스를 일시 중지해야 한다.

### 4-3. AWS CodeDeploy

```
GitHub Actions → CodeDeploy 트리거
  → Agent가 appspec.yml lifecycle hooks 실행
  → ALB deregister + drain (자동) → docker 교체 → health check → ALB register (자동)
  → 실패 시 자동 롤백
```

| 항목 | 평가 |
|------|------|
| 배포 속도 | 빠름 (컨테이너만 교체) |
| 롤백 | 자동 (health check 실패 시) |
| 운영 복잡도 | 중간 |
| 추가 도구 | CodeDeploy Agent 설치 필요 |
| AWS 종속 | 높음 (appspec.yml, lifecycle hooks 전부 AWS 전용) |
| 적합한 경우 | 자동 롤백이 필수일 때 |

**단점:**
- Agent가 죽으면 배포 자체가 안 됨 (silent failure)
- 디버깅이 번거로움 (CodeDeploy 로그 추적)
- 관리 포인트 증가 (Application, Deployment Group, IAM Role)

### 4-4. ECS

```
GitHub Actions → ECR push → Task Definition 업데이트 → ECS가 자동 롤링
```

| 항목 | 평가 |
|------|------|
| 배포 속도 | 빠름 (1~2분) |
| 롤백 | 원클릭 (이전 Task Definition으로) |
| 운영 복잡도 | 낮음 (관리 위임) |
| 추가 도구 | ECS 클러스터 구축 |
| AWS 종속 | 매우 높음 |
| 적합한 경우 | 장기적으로 컨테이너 네이티브 환경을 원할 때 |

지금 EC2에서 하고 있는 것(docker pull + docker run)을 AWS가 대신 관리해주는 것이다.
배포/롤백/스케일링이 전부 하나로 통합된다.
하지만 인프라를 재구축해야 한다.

### 4-5. EKS + ArgoCD

**현재 규모에서는 오버엔지니어링.**

서비스 3개, 인스턴스 2~4대 규모에서 K8s 클러스터를 관리하는 것은 과하다.
클러스터 비용 (~$73/월) + 학습 곡선까지 고려하면,
서비스가 10개 이상으로 늘어나기 전까지는 도입할 이유가 없다.

---

## 5. 종합 비교

```
                    배포속도    롤백         운영부담     AWS종속    현재인프라호환
                    ────────  ──────────  ──────────  ────────  ────────────
Instance Refresh    ✗ 느림     ✗ 수동/느림  ◎ 매우 낮음  중간       ◎ 그대로
SSM + 스크립트       ◎ 빠름    △ 수동/빠름  △ 높음      낮음       ◎ 그대로
CodeDeploy          ◎ 빠름    ◎ 자동       ○ 중간      높음       ○ Agent 추가
ECS                 ◎ 빠름    ◎ 자동       ◎ 낮음      매우 높음   ✗ 재구축
EKS + ArgoCD        ◎ 빠름    ◎ GitOps     ✗ 높음      낮음       ✗ 전면 교체
```

---

## 6. 여기서 한 발 더: 벤더 종속(Lock-in)에 대한 고민

배포 방식을 검토하면서, 더 근본적인 질문이 떠올랐다.

**"특정 벤더에 깊게 Lock-in되는 것은 괜찮은 걸까?"**

현재 우리 인프라를 보면:
- 컴퓨팅: EC2 + ASG
- 네트워크: ALB + VPC
- 스토리지: ECR + S3
- DB: RDS
- 배포: Instance Refresh (ASG 기능)
- 시크릿: SSM Parameter Store
- DNS: Route53
- 인증서: ACM

이미 AWS에 깊이 종속되어 있다.
여기에 CodeDeploy, ECS까지 추가하면 종속은 더 심해진다.

### 벤더 종속이 문제가 되는 이유

1. **비용 상승에 대한 대처가 힘듬**
   - AWS가 가격을 올려도 마이그레이션 비용이 너무 크면 그냥 감수할 수밖에 없다
   - 비즈니스 비용 협상에서 우리 쪽 카드가 없다

2. **전환이 어렵고 복잡함**
   - ALB → 다른 LB, RDS → 다른 DB, ECR → 다른 레지스트리...
   - 하나하나 전부 바꿔야 한다. 현실적으로 매우 어렵다

3. **유연성 및 통제성 감소**
   - 특정 벤더의 통제력이 올라가고, 우리의 통제력은 감소
   - AWS 서비스의 제약사항에 맞춰서 아키텍처를 설계하게 됨
   - 장애가 AWS 쪽에서 발생하면 우리가 할 수 있는 게 없음

### 멀티 클라우드 vs 퍼블릭 클라우드 단일 사용

그렇다면 멀티 클라우드를 해야 하는 건가?

**멀티 클라우드의 현실:**
- 같은 서비스를 AWS + GCP 양쪽에서 운영? → 운영 비용 2배
- 클라우드마다 네트워크, IAM, 스토리지 전부 다름 → 추상화 레이어 필요
- Terraform으로 코드를 작성해도 provider별 리소스는 전혀 다름
- 현재 팀 규모에서 멀티 클라우드는 비현실적

**현실적인 접근:**
- 멀티 클라우드를 "지금 당장" 하는 것은 오버엔지니어링
- 다만 **"이식 가능한 부분"은 최대한 벤더 중립적으로 유지**하는 것이 현명하다

### 어디까지가 Lock-in이고, 어디까지가 합리적인 선택인가

```
바꾸기 어려운 것 (깊은 Lock-in) → 신중하게 선택
──────────────────────────────────────────────
- ECS, EKS          → 컨테이너 오케스트레이션 자체가 AWS 전용
- CodeDeploy        → 배포 파이프라인이 AWS 전용 스펙에 묶임
- RDS 고유 기능      → Aurora Serverless 등 AWS 전용 DB 기능

바꿀 수 있는 것 (얕은 Lock-in) → 적극 활용해도 괜찮음
──────────────────────────────────────────────
- EC2               → 어디든 VM은 있다
- ALB               → 다른 클라우드에도 LB는 있다
- ECR               → Docker Hub, GCR 등 대체 가능
- S3                → GCS, Azure Blob 등 대체 가능
- Docker            → 어디서든 동작
- Terraform         → 멀티 클라우드 지원
- GitHub Actions    → 클라우드와 무관

이식 가능하게 유지해야 할 것
──────────────────────────────────────────────
- 배포 스크립트     → 셸 스크립트로 유지하면 어디서든 실행 가능
- Docker 이미지     → 표준 컨테이너 이미지는 어디서든 동작
- 애플리케이션 코드  → 클라우드 SDK 직접 호출 최소화
```

### 이 고민이 배포 방식 선택에 주는 시사점

- **CodeDeploy**: AWS 전용 스펙(appspec.yml, lifecycle hooks)에 묶인다. 다른 클라우드로 가면 배포 파이프라인을 처음부터 다시 만들어야 한다.
- **ECS**: 컨테이너 실행 환경 자체가 AWS에 묶인다. GCP로 가면 Cloud Run이나 GKE로 전면 전환.
- **SSM Run Command**: AWS SSM이지만, 실제 배포 로직은 셸 스크립트다. 다른 클라우드에서는 SSH나 해당 클라우드의 원격 실행 도구로 같은 스크립트를 돌리면 된다.
- **Instance Refresh**: ASG 전용 기능이지만, 어차피 ASG 자체가 AWS 리소스이므로 추가 종속이 생기는 건 아니다.

---

## 7. 스케일링과 배포는 별개의 메커니즘이다

배포 방식을 변경해도 ASG 스케일링은 기존 Launch Template + user_data로 독립 동작한다.

```
┌─────────────────────────────────────────────────┐
│                    ASG                           │
│                                                  │
│  스케일링 (인스턴스 증감)    배포 (코드 변경)      │
│  ──────────────────────    ─────────────────      │
│  Launch Template           SSM / CodeDeploy      │
│  + user_data 스크립트       + 컨테이너만 교체      │
│                                                  │
│  새 인스턴스가 뜰 때:       기존 인스턴스에서:      │
│  user_data → docker pull   docker stop/pull/run  │
│  (prod-latest 태그)        (prod-latest 태그)    │
│                                                  │
│  → 두 메커니즘 모두 prod-latest를 참조하므로       │
│    ECR 태그 전략만 잘 관리하면 일관성 유지          │
└─────────────────────────────────────────────────┘
```

스케일링 시에는 기존 user_data 스크립트가 그대로 동작한다.
배포 시에만 컨테이너를 교체하는 별도 메커니즘이 작동한다.
두 메커니즘 모두 `prod-latest` 태그를 참조하므로, ECR 태그 전략만 잘 관리하면 일관성이 유지된다.

---

## 8. 단계적 도입 계획

### Phase 1: ECR 이미지 태그 전략 적용 (즉시, 배포 방식과 무관)
- CI/CD에서 `prod-latest` + `prod-YYYYMMDD-<sha>` 이중 태그 push
- ECR Lifecycle Policy 설정 (최근 10개 버전 유지)
- 롤백 스크립트 작성 및 테스트

### Phase 2: 배포 방식 결정 및 전환
- Instance Refresh 유지하면서 Phase 1 안정화
- 대안 방식 프로토타입 → dev에서 검증 → prod 적용
- 배포 중 ASG 헬스체크 오작동 방지 전략 확정

### Phase 3: 역할 분리
- Instance Refresh → AMI 변경, 인프라 변경 시에만 사용
- 일상 배포 → Phase 2에서 결정한 방식

---

## 9. 미결 사항

- [ ] CI/CD (GitHub Actions) 워크플로우에 이중 태그 push 적용
- [ ] ECR Lifecycle Policy terraform 리소스 추가
- [ ] 롤백 스크립트 작성 및 테스트
- [ ] 배포 방식 최종 결정 → dev 검증 후 확정
- [ ] 배포 중 ASG 헬스체크 오작동 방지 전략 확정
- [ ] 벤더 종속 수준 모니터링 - 새로운 AWS 서비스 도입 시 Lock-in 심화 여부 검토
