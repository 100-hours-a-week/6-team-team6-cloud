#!/bin/bash
# shared/vector-db/db/user_data_qdrant.sh.tpl

set -euo pipefail

exec > >(tee /var/log/user-data-qdrant.log | logger -t user-data-qdrant -s 2>/dev/console) 2>&1

echo "=== Qdrant bootstrap started: $(date -Is) ==="

CONTAINER_NAME="qdrant"
CONTAINER_IMAGE="${qdrant_container_image}"
STORAGE_DIR="/qdrant/storage"
QDRANT_API_KEY="${qdrant_api_key}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Check Golden AMI." >&2
  exit 1
fi

systemctl enable docker
systemctl start docker

mkdir -p "$STORAGE_DIR"
chown -R ubuntu:ubuntu "$STORAGE_DIR" || true

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME"
fi

docker pull "$CONTAINER_IMAGE"

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p 6333:6333 \
  -p 6334:6334 \
  -v "$STORAGE_DIR:/qdrant/storage" \
  -e QDRANT__SERVICE__API_KEY="$QDRANT_API_KEY" \
  "$CONTAINER_IMAGE"

docker ps --filter "name=$CONTAINER_NAME"

echo "=== Qdrant bootstrap completed: $(date -Is) ==="
