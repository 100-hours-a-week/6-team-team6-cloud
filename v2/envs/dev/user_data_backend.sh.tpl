#!/bin/bash
# v2/envs/dev/user_data_backend.sh.tpl
# Backend EC2 인스턴스 시작 시 실행되는 스크립트

set -e

# 로그 설정
exec > >(tee /var/log/user-data.log) 2>&1
echo "=== Backend User Data Script Started at $(date) ==="

# 환경 변수 설정 (Terraform에서 주입)
ENV="${env}"
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
ECR_REGISTRY="${ecr_registry}"
RDS_ENDPOINT="${rds_endpoint}"
REDIS_ENDPOINT="${redis_endpoint}"

echo "Environment: $ENV"
echo "Service: Backend"
echo "ECR Registry: $ECR_REGISTRY"

# ECR 로그인
echo "=== ECR Login ==="
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

# SSM에서 환경변수 가져오기
echo "=== Fetching SSM Parameters ==="
DB_PASSWORD=$(aws ssm get-parameter --name "/$PROJECT_NAME/$ENV/be/db-password" --with-decryption --query 'Parameter.Value' --output text --region $AWS_REGION 2>/dev/null || echo "")
JWT_SECRET=$(aws ssm get-parameter --name "/$PROJECT_NAME/$ENV/be/jwt-secret" --with-decryption --query 'Parameter.Value' --output text --region $AWS_REGION 2>/dev/null || echo "")

# Docker 실행
echo "=== Starting Backend Container ==="
docker pull $ECR_REGISTRY/$PROJECT_NAME-be:latest

docker run -d \
  --name billage-backend \
  --restart unless-stopped \
  -p 8080:8080 \
  -e SPRING_PROFILES_ACTIVE=$ENV \
  -e SPRING_DATASOURCE_URL=jdbc:mysql://$RDS_ENDPOINT/$PROJECT_NAME \
  -e SPRING_DATASOURCE_PASSWORD=$DB_PASSWORD \
  -e SPRING_REDIS_HOST=$REDIS_ENDPOINT \
  -e SPRING_REDIS_PORT=6379 \
  -e JWT_SECRET=$JWT_SECRET \
  $ECR_REGISTRY/$PROJECT_NAME-be:latest

# 상태 확인
echo "=== Container Status ==="
docker ps

echo "=== Backend User Data Script Completed at $(date) ==="
