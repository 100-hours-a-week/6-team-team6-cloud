#!/bin/bash
# v2/envs/dev/user_data_ai.sh.tpl
# AI EC2 인스턴스 시작 시 실행되는 스크립트

set -e

# 로그 설정
exec > >(tee /var/log/user-data.log) 2>&1
echo "=== AI User Data Script Started at $(date) ==="

# 환경 변수 설정 (Terraform에서 주입)
ENV="${env}"
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
ECR_REGISTRY="${ecr_registry}"

echo "Environment: $ENV"
echo "Service: AI"
echo "ECR Registry: $ECR_REGISTRY"

# ECR 로그인
echo "=== ECR Login ==="
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

# Docker 실행
echo "=== Starting AI Container ==="
docker pull $ECR_REGISTRY/$PROJECT_NAME-ai:latest

docker run -d \
  --name billage-ai \
  --restart unless-stopped \
  -p 5000:5000 \
  -e ENV=$ENV \
  $ECR_REGISTRY/$PROJECT_NAME-ai:latest

# 상태 확인
echo "=== Container Status ==="
docker ps

echo "=== AI User Data Script Completed at $(date) ==="
