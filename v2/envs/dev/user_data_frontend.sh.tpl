#!/bin/bash
# v2/envs/dev/user_data_frontend.sh.tpl
# Frontend EC2 인스턴스 시작 시 실행되는 스크립트

set -e

# 로그 설정
exec > >(tee /var/log/user-data.log) 2>&1
echo "=== Frontend User Data Script Started at $(date) ==="

# 환경 변수 설정 (Terraform에서 주입)
ENV="${env}"
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
ECR_REGISTRY="${ecr_registry}"
BACKEND_URL="${backend_url}"

echo "Environment: $ENV"
echo "Service: Frontend"
echo "ECR Registry: $ECR_REGISTRY"

# ECR 로그인
echo "=== ECR Login ==="
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

# SSM에서 환경변수 가져오기
echo "=== Fetching SSM Parameters ==="
NEXTAUTH_SECRET=$(aws ssm get-parameter --name "/$PROJECT_NAME/$ENV/fe/nextauth-secret" --with-decryption --query 'Parameter.Value' --output text --region $AWS_REGION 2>/dev/null || echo "")

# Docker 실행
echo "=== Starting Frontend Container ==="
docker pull $ECR_REGISTRY/$PROJECT_NAME-fe:latest

docker run -d \
  --name billage-frontend \
  --restart unless-stopped \
  -p 3000:3000 \
  -e NODE_ENV=production \
  -e NEXT_PUBLIC_API_URL=$BACKEND_URL \
  -e NEXTAUTH_SECRET=$NEXTAUTH_SECRET \
  $ECR_REGISTRY/$PROJECT_NAME-fe:latest

# 상태 확인
echo "=== Container Status ==="
docker ps

echo "=== Frontend User Data Script Completed at $(date) ==="
