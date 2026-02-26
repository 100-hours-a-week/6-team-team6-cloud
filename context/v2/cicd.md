# v2 CI/CD 가이드

## 개요

v2 Dev 환경은 **ASG Instance Refresh** 기반 배포를 사용한다.
GitHub Actions에서 Docker 이미지를 빌드/Push하고, ASG Instance Refresh를 트리거하면 새 EC2가 자동으로 최신 이미지를 Pull해서 실행한다.

## 아키텍처

```
GitHub Actions                          AWS
──────────────                          ───
1. Checkout
2. Build & Test
3. Docker Build
4. ECR Login & Push ──────────────→  ECR (billage-be:latest)
5. ASG Instance Refresh 트리거 ───→  ASG
                                        │
                                   새 EC2 부팅 (Private Subnet)
                                        │
                                   user_data 실행
                                        ├─ ECR Login
                                        ├─ SSM Parameter Store에서 환경변수 조회
                                        ├─ Docker Pull
                                        └─ Docker Run
                                        │
                                   ALB Health Check 통과
                                        │
                                   기존 EC2 종료
```

## 서비스별 정보

| 서비스 | ECR 리포지토리 | 컨테이너 포트 | ASG 이름 | Health Check |
|--------|---------------|-------------|----------|-------------|
| Backend | `billage-be` | 8080 | `billage-dev-v2-be-asg` | `/actuator/health` |
| Frontend | `billage-fe` | 3000 | `billage-dev-v2-fe-asg` | `/` |
| AI | `billage-ai` | 5000 | `billage-dev-v2-ai-asg` | `/health` |

## GitHub Actions 워크플로우 작성 가이드

### AWS 인증: OIDC (키 없이 역할 기반)

GitHub Actions ↔ AWS 연동은 **OIDC**를 사용한다. Access Key 대신 IAM Role을 Assume하는 방식이라 키 노출 위험이 없다.

```
OIDC Provider: arn:aws:iam::988319239270:oidc-provider/token.actions.githubusercontent.com
IAM Role:      arn:aws:iam::988319239270:role/billage-github-actions-role
```

GitHub Secrets에 AWS 키를 등록할 필요 없음.

### 워크플로우 예시 (Backend)

```yaml
name: Deploy Backend

on:
  push:
    branches: [main]
    paths:
      - 'backend/**'

permissions:
  id-token: write   # OIDC 토큰 발급에 필요
  contents: read

env:
  AWS_REGION: ap-northeast-2
  ECR_REPOSITORY: billage-be
  ASG_NAME: billage-dev-v2-be-asg

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::988319239270:role/billage-github-actions-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build & Push Docker image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
                        -t $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.sha }} .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.sha }}

      - name: Trigger ASG Instance Refresh
        run: |
          aws autoscaling start-instance-refresh \
            --auto-scaling-group-name $ASG_NAME \
            --strategy Rolling \
            --preferences '{"MinHealthyPercentage": 0}'
```

### 주요 포인트

- **이미지 태그**: `latest`와 `git sha` 두 개를 Push한다. `latest`는 user_data에서 Pull용, `sha`는 롤백/추적용.
- **MinHealthyPercentage: 0**: Dev 환경은 인스턴스 1대라서 0으로 설정. 기존 EC2를 먼저 종료하고 새로 띄운다 (다운타임 발생).
- **Prod에서는**: `MinHealthyPercentage: 50` 이상으로 설정해서 무중단 배포.

## 환경변수 관리 (SSM Parameter Store)

### 구조

```
/billage/dev/{service}/
  ├── key-name-here  →  value
  └── ...
```

SSM 키 이름이 Docker 환경변수로 자동 변환된다:
```
/billage/dev/be/spring-datasource-url  →  SPRING_DATASOURCE_URL
/billage/dev/fe/next-public-api-url    →  NEXT_PUBLIC_API_URL
```

변환 규칙: `basename` → 하이픈을 언더스코어로 → 대문자

### 환경변수 추가/변경 방법

```bash
# 추가
aws ssm put-parameter \
  --name "/billage/dev/be/new-variable" \
  --value "value" \
  --type String  # 또는 SecureString (비밀번호 등)

# 변경
aws ssm put-parameter \
  --name "/billage/dev/be/existing-variable" \
  --value "new-value" \
  --overwrite

# 확인
aws ssm get-parameters-by-path \
  --path "/billage/dev/be/" \
  --with-decryption
```

환경변수 변경 후 **Instance Refresh를 트리거**해야 반영된다:
```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-dev-v2-be-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage": 0}'
```

### 현재 등록 필요한 파라미터

**Backend (`/billage/dev/be/`)**
| SSM Key | 환경변수 | 타입 | 예시 |
|---------|---------|------|------|
| `spring-profiles-active` | SPRING_PROFILES_ACTIVE | String | `dev` |
| `spring-datasource-url` | SPRING_DATASOURCE_URL | String | `jdbc:mysql://billage-dev-v2-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com:3306/billage` |
| `spring-datasource-username` | SPRING_DATASOURCE_USERNAME | String | `billage_admin` |
| `spring-datasource-password` | SPRING_DATASOURCE_PASSWORD | SecureString | (직접 입력) |
| `jwt-secret` | JWT_SECRET | SecureString | (직접 입력) |

**Frontend (`/billage/dev/fe/`)**
| SSM Key | 환경변수 | 타입 | 예시 |
|---------|---------|------|------|
| `node-env` | NODE_ENV | String | `production` |
| `next-public-api-url` | NEXT_PUBLIC_API_URL | String | `https://v2.dev.billages.com/api` |
| `nextauth-secret` | NEXTAUTH_SECRET | SecureString | (직접 입력) |

**AI (`/billage/dev/ai/`)**
| SSM Key | 환경변수 | 타입 | 예시 |
|---------|---------|------|------|
| `env` | ENV | String | `dev` |

## User Data 스크립트 (EC2 부트스트랩)

### 개요

EC2가 부팅되면 Launch Template에 지정된 user_data 스크립트가 자동 실행된다.
이 스크립트가 ECR에서 Docker 이미지를 Pull하고, SSM에서 환경변수를 가져와서, 컨테이너를 실행한다.

### 파일 위치

| 서비스 | 파일 | Terraform 리소스 |
|--------|------|-----------------|
| Backend | `v2/envs/dev/user_data_backend.sh.tpl` | `aws_launch_template.backend` |
| Frontend | `v2/envs/dev/user_data_frontend.sh.tpl` | `aws_launch_template.frontend` |
| AI | `v2/envs/dev/user_data_ai.sh.tpl` | `aws_launch_template.ai` |

AWS 콘솔에서 확인: **EC2 > Launch Templates > 버전 선택 > Advanced details > User data**

### 서비스별 차이점

3개 스크립트는 구조가 동일하고 아래 값만 다르다:

| 항목 | Backend | Frontend | AI |
|------|---------|----------|-----|
| `SERVICE` | `be` | `fe` | `ai` |
| `CONTAINER_NAME` | `billage-backend` | `billage-frontend` | `billage-ai` |
| `CONTAINER_PORT` | `8080` | `3000` | `5000` |
| ECR 이미지 | `billage-be:latest` | `billage-fe:latest` | `billage-ai:latest` |
| SSM 경로 | `/billage/dev/be/` | `/billage/dev/fe/` | `/billage/dev/ai/` |

### 실행 흐름 (Backend 기준)

```
EC2 부팅
  │
  ├─ 1. 로그 설정
  │     /var/log/user-data.log에 전체 로그 기록
  │
  ├─ 2. Terraform 주입 변수 설정 (인프라 정보만)
  │     ENV=dev, PROJECT_NAME=billage, AWS_REGION=ap-northeast-2
  │     ECR_REGISTRY=988319239270.dkr.ecr.ap-northeast-2.amazonaws.com
  │
  ├─ 3. ECR 로그인
  │     aws ecr get-login-password | docker login
  │
  ├─ 4. SSM Parameter Store에서 환경변수 조회
  │     경로: /billage/dev/be/
  │     변환: spring-datasource-url → SPRING_DATASOURCE_URL
  │     → Docker -e 옵션으로 변환
  │
  ├─ 5. Docker Pull & Run
  │     docker pull 988319239270.dkr.ecr...amazonaws.com/billage-be:latest
  │     docker run -d -p 8080:8080 -e SPRING_DATASOURCE_URL=... $IMAGE
  │
  └─ 6. ALB Health Check 대기
        /actuator/health 응답 시 InService 전환
```

### 환경변수 변환 규칙

SSM 키 이름이 Docker 환경변수로 자동 변환된다:

```
SSM 키: /billage/dev/be/spring-datasource-url
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

### 디버깅

```bash
# 1. EC2 SSH 접속 (VPN 필요)
ssh -i billage-keypair.pem ubuntu@<private-ip>

# 2. user_data 실행 로그 확인
cat /var/log/user-data.log

# 3. 컨테이너 상태 확인
docker ps -a

# 4. 컨테이너 로그 확인
docker logs billage-backend

# 5. SSM 파라미터가 제대로 들어갔는지 확인
docker inspect billage-backend | grep -A 50 '"Env"'
```

### 주의사항

- user_data는 **EC2 최초 부팅 시 1회만 실행**된다. 변경 사항을 반영하려면 Instance Refresh 필요.
- `set -e` 설정으로 어떤 단계든 실패하면 스크립트가 즉시 중단된다.
- ECR에 이미지가 없으면 `docker pull` 실패 → 컨테이너 미실행 → Health Check 실패.
- SSM 조회 실패 시 (`|| true`) 환경변수 없이 컨테이너가 뜨므로, 앱 자체가 시작 시 에러를 뱉을 수 있다.
- Terraform에서 주입하는 값은 **인프라 부트스트랩 정보**(region, registry 등)뿐. 애플리케이션 환경변수는 전부 SSM.

## 네트워크 구조

EC2 인스턴스는 **Private Subnet**에 배치된다. 외부 인터넷 접근(ECR Pull, SSM 조회)은 VPC Peering을 통해 Management VPC의 VPN 서버(NAT Instance)를 경유한다.

```
Dev VPC (10.0.0.0/16)
├── Public Subnet (10.0.1.0/24, 10.0.2.0/24)
│   └── ALB (외부 트래픽 진입점)
│
├── Private Subnet - EC2 (10.0.20.0/24, 10.0.21.0/24)
│   ├── BE EC2 (Public IP 없음)
│   ├── FE EC2 (Public IP 없음)
│   └── AI EC2 (Public IP 없음)
│   Route: 0.0.0.0/0 → VPC Peering → VPN Server NAT
│
└── Private Subnet - RDS (10.0.12.0/24, 10.0.13.0/24)
    └── RDS MySQL (billage-dev-v2-mysql)

Management VPC (10.2.0.0/16)
└── VPN Server (NAT Instance 겸용)
    ├── iptables FORWARD: 10.0.0.0/16 허용
    └── iptables MASQUERADE: 10.0.0.0/16 → VPN Server IP
```

## 트러블슈팅

### EC2는 떴는데 컨테이너가 안 돌아감
```bash
# EC2에 SSH 접속 (VPN 필요)
ssh -i billage-keypair.pem ubuntu@<private-ip>

# user_data 로그 확인
cat /var/log/user-data.log
```

### ECR Pull 실패
- IAM Role에 ECR 권한이 있는지 확인 (`billage-dev-v2-app-role`)
- Private Subnet에서 인터넷 접근이 되는지 확인 (VPN NAT 경유)
- ECR에 이미지가 Push되어 있는지 확인

### 환경변수가 안 먹음
- SSM 파라미터 경로 확인: `/billage/dev/{service}/` (마지막 슬래시 중요)
- IAM Role에 SSM 읽기 권한 확인
- Instance Refresh 후 새 EC2에서 확인 (기존 EC2는 반영 안 됨)

### ALB Health Check 실패
- Target Group에서 Health Check 상태 확인
- 컨테이너가 해당 포트에서 정상 응답하는지 확인
- Security Group에서 ALB → EC2 포트가 열려있는지 확인

## 롤백

이전 버전으로 롤백하려면:
```bash
# 이전 이미지 태그로 되돌리기
ECR_REGISTRY=988319239270.dkr.ecr.ap-northeast-2.amazonaws.com

# latest 태그를 이전 sha로 재지정
MANIFEST=$(aws ecr batch-get-image \
  --repository-name billage-be \
  --image-ids imageTag=<이전-sha> \
  --query 'images[0].imageManifest' --output text)

aws ecr put-image \
  --repository-name billage-be \
  --image-tag latest \
  --image-manifest "$MANIFEST"

# Instance Refresh 트리거
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-dev-v2-be-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage": 0}'
```
