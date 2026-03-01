#!/bin/bash
# v2/envs/dev/user_data_ai.sh.tpl
# AI EC2 인스턴스 시작 시 실행되는 스크립트

set -e

# 로그 설정
exec > >(tee /var/log/user-data.log) 2>&1
echo "=== AI User Data Script Started at $(date) ==="

# 부트스트랩 변수 (Terraform에서 주입 - 인프라 정보만)
ENV="${env}"
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
ECR_REGISTRY="${ecr_registry}"
SERVICE="ai"
CONTAINER_NAME="billage-ai"
CONTAINER_PORT=5000
IMAGE="$ECR_REGISTRY/$PROJECT_NAME-$SERVICE:latest"

echo "Environment: $ENV"
echo "Service: $SERVICE"
echo "ECR Registry: $ECR_REGISTRY"

# ECR 인증: Golden AMI에 docker-credential-ecr-login이 설치되어 있어
# credsStore=ecr-login 설정으로 IAM Role 기반 자동 인증 (docker login 불필요)
echo "=== ECR Auth: using credential helper (ecr-login) ==="

# SSM Parameter Store에서 환경변수 일괄 조회
echo "=== Fetching SSM Parameters ==="
SSM_PATH="/$PROJECT_NAME/$ENV/$SERVICE/"

DOCKER_ENV_ARGS=""
while IFS=$'\t' read -r name value; do
  [ -z "$name" ] && continue
  key=$(basename "$name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  DOCKER_ENV_ARGS="$DOCKER_ENV_ARGS -e $key=$value"
  echo "  Loaded: $key"
done < <(aws ssm get-parameters-by-path \
  --path "$SSM_PATH" \
  --with-decryption \
  --query 'Parameters[*].[Name,Value]' \
  --output text \
  --region $AWS_REGION 2>/dev/null || true)

# Docker 실행
echo "=== Starting $CONTAINER_NAME ==="
docker pull $IMAGE

eval docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p $CONTAINER_PORT:$CONTAINER_PORT \
  $DOCKER_ENV_ARGS \
  $IMAGE

# 상태 확인
echo "=== Container Status ==="
docker ps

echo "=== AI User Data Script Completed at $(date) ==="
