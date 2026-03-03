#!/bin/bash
# Rehearsal BE launch template user data

set -e

exec > >(tee /var/log/user-data.log) 2>&1

echo "===== Rehearsal Backend UserData Start: $(date) ====="

ENV="${env}"
APP_PROFILE="${app_profile}"
PROJECT_NAME="${project_name}"
AWS_REGION="${aws_region}"
ECR_REGISTRY="${ecr_registry}"
SSM_PATH="${ssm_path}"
DB_HOST="${db_host}"
DB_PORT="${db_port}"
DB_NAME="${db_name}"
SERVICE="${service_name}"
CONTAINER_PORT="${container_port}"
IMAGE="${container_image}"

if [ -z "$IMAGE" ]; then
  IMAGE="${ecr_registry}/$PROJECT_NAME-$SERVICE:latest"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found"
  exit 1
fi

systemctl enable --now docker

DOCKER_ENV_ARGS=""
while IFS=$'\t' read -r name value; do
  [ -z "$name" ] && continue
  key=$(basename "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  DOCKER_ENV_ARGS="$DOCKER_ENV_ARGS -e $key=$value"
  echo "loaded ssm var: $key"
done < <(aws ssm get-parameters-by-path \
  --path "$SSM_PATH" \
  --with-decryption \
  --query 'Parameters[*].[Name,Value]' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || true)

DOCKER_ENV_ARGS="$DOCKER_ENV_ARGS -e SPRING_DATASOURCE_URL=jdbc:mysql://$DB_HOST:$DB_PORT/$DB_NAME?serverTimezone=Asia/Seoul&useSSL=false&allowPublicKeyRetrieval=true"

echo "docker pull: $IMAGE"
docker pull "$IMAGE"

docker run -d \
  --name "$PROJECT_NAME-rehearsal-be" \
  --restart unless-stopped \
  -p "$CONTAINER_PORT:$CONTAINER_PORT" \
  $DOCKER_ENV_ARGS \
  -e SPRING_PROFILES_ACTIVE="$APP_PROFILE" \
  "$IMAGE"

echo "===== Rehearsal Backend UserData End: $(date) ====="
