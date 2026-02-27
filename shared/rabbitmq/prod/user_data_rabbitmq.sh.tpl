#!/bin/bash
set -euxo pipefail

exec > >(tee /var/log/user-data.log) 2>&1
echo "=== RabbitMQ bootstrap started at $(date) ==="

dnf update -y
dnf install -y docker
systemctl enable --now docker

mkdir -p /opt/rabbitmq
mkdir -p /var/lib/rabbitmq

cat > /opt/rabbitmq/enabled_plugins <<'PLUGINS'
[rabbitmq_management,rabbitmq_stomp].
PLUGINS

docker rm -f billage-rabbitmq || true

docker run -d \
  --name billage-rabbitmq \
  --restart unless-stopped \
  -p 5672:5672 \
  -p 61613:61613 \
  -p 15672:15672 \
  -e RABBITMQ_DEFAULT_USER='${rabbitmq_username}' \
  -e RABBITMQ_DEFAULT_PASS='${rabbitmq_password}' \
  -v /var/lib/rabbitmq:/var/lib/rabbitmq \
  -v /opt/rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro \
  rabbitmq:3.13-management

for i in {1..30}; do
  if docker exec billage-rabbitmq rabbitmq-diagnostics -q ping; then
    echo "RabbitMQ is healthy"
    break
  fi
  sleep 5
done

echo "=== RabbitMQ bootstrap completed at $(date) ==="
