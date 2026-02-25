#!/bin/bash
# ==========================================
# 롤백 스크립트
# RDS → EC2 MySQL (원본으로 복귀)
#
# 단일 EC2 환경:
#   - Nginx upstream을 :8081 → :8080으로 복귀
#   - 로컬 MySQL의 read_only 해제
# ==========================================

set -e

# ==========================================
# Configuration
# ==========================================
SOURCE_HOST="${SOURCE_HOST:-localhost}"
SOURCE_PORT="${SOURCE_PORT:-3306}"
SOURCE_USER="${SOURCE_USER:-root}"
SOURCE_PASSWORD="${SOURCE_PASSWORD:-}"

TARGET_HOST="${TARGET_HOST:-}"
TARGET_PORT="${TARGET_PORT:-3306}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PASSWORD="${TARGET_PASSWORD:-}"

NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1"; }

# ==========================================
# Main Rollback
# ==========================================
main() {
    echo "=========================================="
    echo -e "${RED}DATABASE MIGRATION ROLLBACK${NC}"
    echo "=========================================="
    echo ""
    echo -e "${YELLOW}WARNING: This will:${NC}"
    echo "  1. Switch traffic back to source (EC2 MySQL)"
    echo "  2. Re-enable writes on source"
    echo ""
    echo -e "${RED}DATA LOSS WARNING:${NC}"
    echo "  Any data written to RDS after cutover will be LOST!"
    echo ""

    # Check how much data might be lost
    if [ -n "$TARGET_HOST" ] && [ -n "$TARGET_PASSWORD" ]; then
        log_info "Checking potential data loss..."

        local cutover_time=$(cat /tmp/cutover_timing.txt 2>/dev/null | grep "NGINX_SWITCH" | cut -d= -f2 || echo "0")

        if [ "$cutover_time" != "0" ]; then
            # This is approximate - check recent inserts
            local recent_posts=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SELECT COUNT(*) FROM billage.post WHERE created_at > FROM_UNIXTIME($cutover_time/1000)" 2>/dev/null || echo "unknown")

            echo ""
            log_warn "Estimated data at risk (posts created after cutover): $recent_posts"
            echo ""
        fi
    fi

    read -p "Type 'ROLLBACK' to confirm: " confirm
    if [ "$confirm" != "ROLLBACK" ]; then
        log_info "Rollback cancelled"
        exit 0
    fi

    local start_time=$(date +%s%3N)

    # Step 1: Switch Nginx back to source
    log_info "Step 1: Switching Nginx back to source..."

    if [ -f "${NGINX_CONF_DIR}/upstream-source.conf" ]; then
        cp "${NGINX_CONF_DIR}/upstream-source.conf" "${NGINX_CONF_DIR}/upstream.conf"
        nginx -s reload
        log_info "Nginx switched to source"
    else
        log_error "upstream-source.conf not found!"
        exit 1
    fi

    # Step 2: Re-enable writes on source
    log_info "Step 2: Re-enabling writes on source..."

    mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -e "SET GLOBAL read_only = OFF;"

    log_info "Source DB writes enabled"

    # Step 3: Verify
    log_info "Step 3: Verifying..."

    sleep 2

    local http_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/actuator/health 2>/dev/null || echo "000")

    if [ "$http_status" == "200" ]; then
        log_info "Application health check: OK"
    else
        log_warn "Application health check returned: $http_status"
    fi

    local end_time=$(date +%s%3N)
    local duration=$((end_time - start_time))

    echo ""
    echo "=========================================="
    echo -e "${GREEN}ROLLBACK COMPLETED${NC}"
    echo "Duration: ${duration}ms"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Verify application is working"
    echo "  2. Check K6 metrics for recovery"
    echo "  3. Investigate what caused the rollback"
    echo "  4. Plan for re-migration if needed"
    echo "=========================================="
}

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "Usage: $0"
    echo ""
    echo "Environment variables:"
    echo "  SOURCE_HOST, SOURCE_PORT, SOURCE_USER, SOURCE_PASSWORD"
    echo "  NGINX_CONF_DIR (default: /etc/nginx/conf.d)"
    exit 0
fi

main "$@"