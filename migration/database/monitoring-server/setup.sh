#!/bin/bash
# ==========================================
# Monitoring Server Setup Script
# 환경변수 기반으로 설정 파일 생성
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_DIR="${SCRIPT_DIR}/prometheus/targets"
TEMPLATES_DIR="${TARGETS_DIR}/templates"

# .env 파일 로드
if [ -f "${SCRIPT_DIR}/.env" ]; then
    export $(grep -v '^#' "${SCRIPT_DIR}/.env" | xargs)
fi

# 필수 환경변수 확인
: "${SOURCE_SERVER_IP:?SOURCE_SERVER_IP is required}"
: "${RDS_HOST:?RDS_HOST is required}"
: "${PROBE_BASE_URL:?PROBE_BASE_URL is required}"

echo "=== Monitoring Server Setup ==="
echo "SOURCE_SERVER_IP: ${SOURCE_SERVER_IP}"
echo "RDS_HOST: ${RDS_HOST}"
echo "PROBE_BASE_URL: ${PROBE_BASE_URL}"
echo ""

# targets 파일 생성
echo "Generating targets files..."
for template in "${TEMPLATES_DIR}"/*.template; do
    filename=$(basename "${template}" .template)
    envsubst < "${template}" > "${TARGETS_DIR}/${filename}"
    echo "  Created: ${filename}"
done

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Start monitoring stack:"
echo "  docker-compose up -d"
echo ""
echo "Access:"
echo "  Grafana:    http://localhost:3000 (admin/admin)"
echo "  Prometheus: http://localhost:9090"
