# v2 CI/CD 가이드 (공통)

> 환경별 상세 가이드: [cicd-dev.md](./cicd-dev.md) | [cicd-prod.md](./cicd-prod.md)

## 개요

v2 환경은 **ASG Instance Refresh** 기반 배포를 사용한다.
GitHub Actions에서 Docker 이미지를 빌드/Push하고, ASG Instance Refresh를 트리거하면 새 EC2가 자동으로 최신 이미지를 Pull해서 실행한다.

Dev와 Prod는 **동일한 ECR 레포지토리를 공유**하되, **환경별 태그**로 이미지를 분리한다.

## 아키텍처

```
GitHub Actions                          AWS
──────────────                          ───
1. Checkout
2. Build & Test
3. Docker Build
4. ECR Login & Push ──────────────→  ECR (billage-be:{env}-latest)
5. ASG Instance Refresh 트리거 ───→  ASG
                                        │
                                   새 EC2 부팅 (Private Subnet)
                                        │
                                   user_data 실행
                                        ├─ ECR Login
                                        ├─ SSM Parameter Store에서 환경변수 조회
                                        ├─ Docker Pull (:{env}-latest)
                                        └─ Docker Run
                                        │
                                   ALB Health Check 통과
                                        │
                                   기존 EC2 종료
```

## ECR 이미지 태그 전략

**ECR 레포지토리**는 dev/prod 공용이다 (billage-be, billage-fe, billage-ai).
**환경 분리는 태그**로 한다:

```
billage-be:dev-latest     ← Dev 환경 user_data에서 Pull
billage-be:prod-latest    ← Prod 환경 user_data에서 Pull
billage-be:{git-sha}      ← 롤백/추적용 (환경 무관)
```

CI/CD에서 이미지 Push 시 반드시 환경별 태그를 붙여야 한다:

```bash
# Dev 배포
docker tag billage-be:build $ECR_REGISTRY/billage-be:dev-latest
docker tag billage-be:build $ECR_REGISTRY/billage-be:$GITHUB_SHA
docker push $ECR_REGISTRY/billage-be:dev-latest
docker push $ECR_REGISTRY/billage-be:$GITHUB_SHA

# Prod 배포
docker tag billage-be:build $ECR_REGISTRY/billage-be:prod-latest
docker tag billage-be:build $ECR_REGISTRY/billage-be:$GITHUB_SHA
docker push $ECR_REGISTRY/billage-be:prod-latest
docker push $ECR_REGISTRY/billage-be:$GITHUB_SHA
```

## 서비스별 정보

| 서비스 | ECR 리포지토리 | 컨테이너 포트 | Health Check |
|--------|---------------|-------------|-------------|
| Backend | `billage-be` | 8080 | `/actuator/health` |
| Frontend | `billage-fe` | 3000 | `/` |
| AI | `billage-ai` | 5000 | `/health` |

### 환경별 리소스 이름

| 항목 | Dev | Prod |
|------|-----|------|
| ASG (Backend) | `billage-dev-v2-be-asg` | `billage-prod-v2-be-asg` |
| ASG (Frontend) | `billage-dev-v2-fe-asg` | `billage-prod-v2-fe-asg` |
| ASG (AI) | `billage-dev-v2-ai-asg` | `billage-prod-v2-ai-asg` |
| ECR 태그 | `:dev-latest` | `:prod-latest` |
| SSM 경로 | `/billage/dev/{service}/` | `/billage/prod/{service}/` |
| 도메인 | `v2.dev.billages.com` | `v2.billages.com` |
| IAM Role | `billage-dev-v2-app-role` | `billage-prod-v2-app-role` |
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` |

## AWS 인증: OIDC (키 없이 역할 기반)

GitHub Actions ↔ AWS 연동은 **OIDC**를 사용한다. Access Key 대신 IAM Role을 Assume하는 방식이라 키 노출 위험이 없다.

```
OIDC Provider: arn:aws:iam::988319239270:oidc-provider/token.actions.githubusercontent.com
IAM Role:      arn:aws:iam::988319239270:role/billage-github-actions-role
```

GitHub Secrets에 AWS 키를 등록할 필요 없음.

## 환경변수 관리 (SSM Parameter Store)

### 구조

```
/billage/{env}/{service}/
  ├── key-name-here  →  value
  └── ...
```

SSM 키 이름이 Docker 환경변수로 자동 변환된다:

```
SSM 키: /billage/{env}/be/spring-datasource-url
                              │
                        basename 추출
                              │
                    spring-datasource-url
                              │
                    하이픈 → 언더스코어
                              │
                    spring_datasource_url
                              │
                         대문자 변환
                              │
                    SPRING_DATASOURCE_URL
```

### 환경변수 추가/변경 방법

```bash
# 추가 (dev 예시, prod는 경로만 변경)
aws ssm put-parameter \
  --name "/billage/{env}/be/new-variable" \
  --value "value" \
  --type String  # 또는 SecureString (비밀번호 등)

# 변경
aws ssm put-parameter \
  --name "/billage/{env}/be/existing-variable" \
  --value "new-value" \
  --overwrite

# 확인
aws ssm get-parameters-by-path \
  --path "/billage/{env}/be/" \
  --with-decryption
```

환경변수 변경 후 **Instance Refresh를 트리거**해야 반영된다.

## User Data 스크립트 (EC2 부트스트랩)

### 파일 위치

| 환경 | 서비스 | 파일 |
|------|--------|------|
| Dev | Backend | `v2/envs/dev/user_data_backend.sh.tpl` |
| Dev | Frontend | `v2/envs/dev/user_data_frontend.sh.tpl` |
| Dev | AI | `v2/envs/dev/user_data_ai.sh.tpl` |
| Prod | Backend | `v2/envs/prod/user_data_backend.sh.tpl` |
| Prod | Frontend | `v2/envs/prod/user_data_frontend.sh.tpl` |
| Prod | AI | `v2/envs/prod/user_data_ai.sh.tpl` |

### 서비스별 차이점

3개 스크립트는 구조가 동일하고 아래 값만 다르다:

| 항목 | Backend | Frontend | AI |
|------|---------|----------|-----|
| `SERVICE` | `be` | `fe` | `ai` |
| `CONTAINER_NAME` | `billage-backend` | `billage-frontend` | `billage-ai` |
| `CONTAINER_PORT` | `8080` | `3000` | `5000` |
| ECR 이미지 | `billage-be:{env}-latest` | `billage-fe:{env}-latest` | `billage-ai:{env}-latest` |
| SSM 경로 | `/billage/{env}/be/` | `/billage/{env}/fe/` | `/billage/{env}/ai/` |

### 실행 흐름

```
EC2 부팅
  │
  ├─ 1. 로그 설정 (/var/log/user-data.log)
  ├─ 2. Terraform 주입 변수 설정 (ENV, PROJECT_NAME, AWS_REGION, ECR_REGISTRY)
  ├─ 3. ECR 로그인
  ├─ 4. SSM Parameter Store에서 환경변수 조회 → Docker -e 옵션으로 변환
  ├─ 5. Docker Pull ({env}-latest) & Run
  └─ 6. ALB Health Check 통과 → InService 전환
```

### 주의사항

- user_data는 **EC2 최초 부팅 시 1회만 실행**된다. 변경 사항을 반영하려면 Instance Refresh 필요.
- `set -e` 설정으로 어떤 단계든 실패하면 스크립트가 즉시 중단된다.
- ECR에 이미지가 없으면 `docker pull` 실패 → 컨테이너 미실행 → Health Check 실패.
- SSM 조회 실패 시 (`|| true`) 환경변수 없이 컨테이너가 뜨므로, 앱 자체가 시작 시 에러를 뱉을 수 있다.
- Terraform에서 주입하는 값은 **인프라 부트스트랩 정보**(region, registry 등)뿐. 애플리케이션 환경변수는 전부 SSM.

## 네트워크 구조

EC2 인스턴스는 **Private Subnet**에 배치된다. 외부 인터넷 접근(ECR Pull, SSM 조회)은 NAT Instance를 경유한다.

```
{env} VPC
├── Public Subnet (ALB, NAT Instance)
│   └── ALB (외부 트래픽 진입점)
│
├── Private Subnet - EC2
│   ├── BE EC2 (Public IP 없음)
│   ├── FE EC2 (Public IP 없음)
│   └── AI EC2 (Public IP 없음)
│   Route: 0.0.0.0/0 → NAT Instance
│
└── Private Subnet - RDS
    └── RDS MySQL (billage-{env}-v2-mysql)

Management VPC (10.2.0.0/16)
└── VPN Server + Monitoring
    Route: VPC Peering으로 Dev/Prod 접근
```

## 트러블슈팅

### EC2는 떴는데 컨테이너가 안 돌아감
```bash
# EC2에 SSH 접속 (VPN 필요)
ssh -i billage-keypair.pem ubuntu@<private-ip>

# user_data 로그 확인[cicd.md](cicd.md)
cat /var/log/user-data.log
```

### ECR Pull 실패
- IAM Role에 ECR 권한이 있는지 확인 (`billage-{env}-v2-app-role`)
- Private Subnet에서 인터넷 접근이 되는지 확인 (NAT Instance 경유)
- ECR에 `{env}-latest` 태그 이미지가 Push되어 있는지 확인

### 환경변수가 안 먹음
- SSM 파라미터 경로 확인: `/billage/{env}/{service}/` (마지막 슬래시 중요)
- IAM Role에 SSM 읽기 권한 확인
- Instance Refresh 후 새 EC2에서 확인 (기존 EC2는 반영 안 됨)

### ALB Health Check 실패
- Target Group에서 Health Check 상태 확인
- 컨테이너가 해당 포트에서 정상 응답하는지 확인
- Security Group에서 ALB → EC2 포트가 열려있는지 확인
