#!/bin/bash
set -euxo pipefail

exec > >(tee /var/log/user-data.log) 2>&1
echo "=== Kafka bootstrap started at $(date) ==="

PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

dnf update -y
dnf install -y docker
systemctl enable --now docker

docker rm -f billage-kafka || true

docker run -d \
  --name billage-kafka \
  --restart unless-stopped \
  -p 9092:9092 \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://$PRIVATE_IP:9092 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  -e KAFKA_LOG_DIRS=/var/lib/kafka/data \
  -e CLUSTER_ID=billage-dev-kafka-cluster \
  -v /var/lib/kafka:/var/lib/kafka/data \
  apache/kafka:3.8.0

for i in {1..30}; do
  if docker exec billage-kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1; then
    echo "Kafka is healthy"
    break
  fi
  sleep 5
done

# Kafka UI - 토픽/consumer group/메시지 웹 관리 도구
echo "=== Starting Kafka UI ==="
docker rm -f kafka-ui || true

docker run -d \
  --name kafka-ui \
  --restart unless-stopped \
  -p 8989:8080 \
  -e DYNAMIC_CONFIG_ENABLED=true \
  -e KAFKA_CLUSTERS_0_NAME=billage-dev \
  -e KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS=$PRIVATE_IP:9092 \
  provectuslabs/kafka-ui:latest

echo "=== Kafka bootstrap completed at $(date) ==="