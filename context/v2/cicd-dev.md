# v2 CI/CD 가이드 - Dev 환경

> 공통 가이드: [cicd.md](./cicd.md) | Prod 가이드: [cicd-prod.md](./cicd-prod.md)

## Dev 환경 요약

| 항목 | 값 |
|------|-----|
| 도메인 | `v2.dev.billages.com` |
| VPC CIDR | `10.0.0.0/16` |
| ECR 태그 | `:dev-latest` |
| SSM 경로 | `/billage/dev/{service}/` |
| MinHealthyPercentage | `0` (다운타임 허용) |
| ASG 인스턴스 수 | 각 서비스 1대 (min=1/max=1) |

## 서비스별 정보

| 서비스 | ECR 이미지 태그 | ASG 이름 | Health Check |
|--------|---------------|----------|-------------|
| Backend | `billage-be:dev-latest` | `billage-dev-v2-be-asg` | `/actuator/health` |
| Frontend | `billage-fe:dev-latest` | `billage-dev-v2-fe-asg` | `/` |
| AI | `billage-ai:dev-latest` | `billage-dev-v2-ai-asg` | `/health` |

## GitHub Actions 워크플로우 (Backend 예시)

```yaml
name: Deploy Backend (Dev)

on:
  push:
    branches: [develop]
    paths:
      - 'backend/**'

permissions:
  id-token: write   # OIDC 토큰 발급에 필요
  contents: read

env:
  AWS_REGION: ap-northeast-2
  ECR_REPOSITORY: billage-be
  ASG_NAME: billage-dev-v2-be-asg
  DEPLOY_ENV: dev

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
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$DEPLOY_ENV-latest \
                        -t $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.sha }} .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$DEPLOY_ENV-latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.sha }}

      - name: Trigger ASG Instance Refresh
        run: |
          aws autoscaling start-instance-refresh \
            --auto-scaling-group-name $ASG_NAME \
            --strategy Rolling \
            --preferences '{"MinHealthyPercentage": 0}'
```

### 주요 포인트

- **이미지 태그**: `dev-latest`와 `git sha` 두 개를 Push한다. `dev-latest`는 user_data에서 Pull용, `sha`는 롤백/추적용.
- **MinHealthyPercentage: 0**: Dev 환경은 인스턴스 1대라서 0으로 설정. 기존 EC2를 먼저 종료하고 새로 띄운다 (다운타임 발생).
- **트리거 브랜치**: `develop` 브랜치 push 시 자동 배포.

## SSM 파라미터

### 현재 등록 필요한 파라미터

**Backend (`/billage/dev/be/`)**

| SSM Key | 환경변수 | 타입 | 예시 |
|---------|---------|------|------|
| `spring-profiles-active` | SPRING_PROFILES_ACTIVE | String | `dev` |
| `spring-datasource-url` | SPRING_DATASOURCE_URL | String | `jdbc:mysql://billage-dev-v2-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com:3306/billage` |
| `spring-datasource-username` | SPRING_DATASOURCE_USERNAME | String | `billage_admin` |
| `spring-datasource-password` | SPRING_DATASOURCE_PASSWORD | SecureString | (직접 입력) |
| `jwt-secret` | JWT_SECRET | SecureString | (직접 입력) |
| `rabbitmq-enabled` | RABBITMQ_ENABLED | String | `true` (자동 등록) |
| `rabbitmq-stomp-host` | RABBITMQ_STOMP_HOST | String | (자동 등록) |
| `rabbitmq-stomp-port` | RABBITMQ_STOMP_PORT | String | `61613` (자동 등록) |
| `rabbitmq-amqp-host` | RABBITMQ_AMQP_HOST | String | (자동 등록) |
| `rabbitmq-amqp-port` | RABBITMQ_AMQP_PORT | String | `5672` (자동 등록) |
| `rabbitmq-username` | RABBITMQ_USERNAME | String | `billage` (자동 등록) |
| `rabbitmq-password` | RABBITMQ_PASSWORD | SecureString | (자동 등록) |

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

### 환경변수 관리

```bash
# 파라미터 추가
aws ssm put-parameter \
  --name "/billage/dev/be/new-variable" \
  --value "value" \
  --type String

# 파라미터 변경
aws ssm put-parameter \
  --name "/billage/dev/be/existing-variable" \
  --value "new-value" \
  --overwrite

# 전체 확인
aws ssm get-parameters-by-path \
  --path "/billage/dev/be/" \
  --with-decryption

# 변경 후 반드시 Instance Refresh 트리거
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-dev-v2-be-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage": 0}'
```

## 네트워크 구조

```
Dev VPC (10.0.0.0/16)
├── Public Subnet (10.0.1.0/24, 10.0.2.0/24)
│   ├── ALB (v2.dev.billages.com)
│   └── NAT Instance (t3.nano)
│
├── Private Subnet - EC2 (10.0.20.0/24, 10.0.21.0/24)
│   ├── BE EC2 → billage-be:dev-latest
│   ├── FE EC2 → billage-fe:dev-latest
│   └── AI EC2 → billage-ai:dev-latest
│   Route: 0.0.0.0/0 → NAT Instance
│
├── Private Subnet - RDS (10.0.12.0/24, 10.0.13.0/24)
│   └── RDS MySQL (billage-dev-v2-mysql)
│
└── Private Subnet - RabbitMQ (10.0.20.0/24)
    └── RabbitMQ (billage-dev-rabbitmq)
```

## 롤백

이전 버전으로 롤백하려면:

```bash
ECR_REGISTRY=988319239270.dkr.ecr.ap-northeast-2.amazonaws.com

# dev-latest 태그를 이전 sha로 재지정
MANIFEST=$(aws ecr batch-get-image \
  --repository-name billage-be \
  --image-ids imageTag=<이전-sha> \
  --query 'images[0].imageManifest' --output text)

aws ecr put-image \
  --repository-name billage-be \
  --image-tag dev-latest \
  --image-manifest "$MANIFEST"

# Instance Refresh 트리거
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-dev-v2-be-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage": 0}'
```

## 디버깅

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
