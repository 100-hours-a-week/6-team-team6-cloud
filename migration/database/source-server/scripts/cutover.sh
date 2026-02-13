#!/bin/bash
# ==========================================
# 무중단 전환(Cutover) 스크립트
# EC2 MySQL → RDS MySQL
#
# 단일 EC2 환경:
#   - Nginx + Spring Boot(:8080, :8081) + MySQL이 같은 EC2에 공존
#   - 전환: Nginx upstream을 :8080 → :8081로 변경
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
APP_USER="${APP_USER:-app_user}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $(date '+%H:%M:%S') $1"; }

# ==========================================
# Pre-flight Checks
# ==========================================
preflight_check() {
    log_step "Running pre-flight checks..."

    if [ -z "$TARGET_HOST" ]; then
        log_error "TARGET_HOST is required"
        exit 1
    fi

    if [ -z "$SOURCE_PASSWORD" ] || [ -z "$TARGET_PASSWORD" ]; then
        log_error "SOURCE_PASSWORD and TARGET_PASSWORD are required"
        exit 1
    fi

    # Check nginx
    if ! command -v nginx &> /dev/null; then
        log_error "nginx not found"
        exit 1
    fi

    log_info "Pre-flight checks passed"
}

# ==========================================
# Step 1: Check Replication Lag
# ==========================================
check_replication_lag() {
    log_step "Step 1: Checking replication lag..."

    local lag=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master:" | awk '{print $2}')

    if [ "$lag" == "NULL" ] || [ -z "$lag" ]; then
        log_error "Replication is not running or lag is NULL"
        log_error "Cannot proceed with cutover"
        exit 1
    fi

    if [ "$lag" -ne 0 ]; then
        log_warn "Replication lag is ${lag}s, waiting for sync..."

        local max_wait=60
        local waited=0

        while [ "$lag" -ne 0 ] && [ "$waited" -lt "$max_wait" ]; do
            sleep 1
            waited=$((waited + 1))
            lag=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master:" | awk '{print $2}')
            echo -ne "\rWaiting for lag=0... current: ${lag}s (${waited}/${max_wait}s)   "
        done
        echo ""

        if [ "$lag" -ne 0 ]; then
            log_error "Timeout waiting for replication to catch up"
            exit 1
        fi
    fi

    log_info "Replication lag is 0. Ready for cutover."
}

# ==========================================
# Step 2: Check App User Permissions
# ==========================================
check_app_user_permissions() {
    log_step "Step 2: Checking app user permissions (SUPER check)..."

    local grants=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SHOW GRANTS FOR '${APP_USER}'@'%'" 2>/dev/null || true)

    if echo "$grants" | grep -qi "SUPER"; then
        log_warn "App user has SUPER privilege!"
        log_warn "read_only=ON will NOT block writes from this user"
        log_warn "Consider blocking via Nginx first"

        read -p "Continue anyway? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            exit 1
        fi
    else
        log_info "App user does NOT have SUPER privilege. read_only will work."
    fi
}

# ==========================================
# Step 3: Set Source to Read-Only
# ==========================================
set_source_readonly() {
    log_step "Step 3: Setting source DB to read_only..."

    local start_time=$(date +%s%3N)

    mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -e "SET GLOBAL read_only = ON;"

    log_info "Source DB is now read_only"
    echo "READONLY_START=$start_time" >> /tmp/cutover_timing.txt
}

# ==========================================
# Step 4: Wait for Active Transactions
# ==========================================
wait_for_transactions() {
    log_step "Step 4: Waiting for active transactions to complete..."

    local max_wait=30
    local waited=0

    while [ "$waited" -lt "$max_wait" ]; do
        local active=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_state='RUNNING'")

        if [ "$active" -eq 0 ]; then
            log_info "No active transactions"
            break
        fi

        log_warn "Active transactions: $active, waiting..."
        sleep 1
        waited=$((waited + 1))
    done

    if [ "$waited" -ge "$max_wait" ]; then
        log_warn "Timeout waiting for transactions, proceeding anyway"
    fi
}

# ==========================================
# Step 5: Final Lag Check
# ==========================================
final_lag_check() {
    log_step "Step 5: Final replication lag check..."

    sleep 1  # Brief wait for final binlog events

    local lag=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master:" | awk '{print $2}')

    if [ "$lag" -ne 0 ]; then
        log_warn "Lag is ${lag}s, waiting..."
        sleep 2
        lag=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master:" | awk '{print $2}')
    fi

    # Get binlog positions
    local source_pos=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SHOW MASTER STATUS" | awk '{print $1":"$2}')
    local target_pos=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SHOW SLAVE STATUS\G" | grep "Relay_Master_Log_File\|Exec_Master_Log_Pos" | awk '{print $2}' | tr '\n' ':' | sed 's/:$//')

    log_info "Source position: $source_pos"
    log_info "Target position: $target_pos"
    log_info "Final lag: ${lag}s"
}

# ==========================================
# Step 6: Switch Nginx Upstream
# ==========================================
switch_nginx() {
    log_step "Step 6: Switching Nginx upstream to target..."

    local switch_time=$(date +%s%3N)

    # Backup current config
    cp "${NGINX_CONF_DIR}/upstream.conf" "${NGINX_CONF_DIR}/upstream.conf.backup.$(date +%Y%m%d_%H%M%S)"

    # Switch to target upstream
    cp "${NGINX_CONF_DIR}/upstream-target.conf" "${NGINX_CONF_DIR}/upstream.conf"

    # Reload nginx
    nginx -s reload

    local reload_time=$(date +%s%3N)
    local switch_duration=$((reload_time - switch_time))

    log_info "Nginx switched in ${switch_duration}ms"
    echo "NGINX_SWITCH=$switch_time" >> /tmp/cutover_timing.txt
    echo "NGINX_RELOAD=$reload_time" >> /tmp/cutover_timing.txt
}

# ==========================================
# Step 7: Verify Traffic
# ==========================================
verify_traffic() {
    log_step "Step 7: Verifying traffic on target..."

    sleep 2

    # Check RDS connections
    local connections=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SHOW STATUS LIKE 'Threads_connected'" | awk '{print $2}')

    log_info "Target RDS connections: $connections"

    # Simple health check
    local http_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/actuator/health 2>/dev/null || echo "000")

    if [ "$http_status" == "200" ]; then
        log_info "Application health check: OK"
    else
        log_warn "Application health check returned: $http_status"
    fi
}

# ==========================================
# Step 8: Stop Replication
# ==========================================
stop_replication() {
    log_step "Step 8: Stopping replication on target..."

    mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "CALL mysql.rds_stop_replication;"

    log_info "Replication stopped"
}

# ==========================================
# Summary
# ==========================================
print_summary() {
    local end_time=$(date +%s%3N)

    echo ""
    echo "=========================================="
    echo -e "${GREEN}CUTOVER COMPLETED${NC}"
    echo "=========================================="
    echo "Timing breakdown:"

    if [ -f /tmp/cutover_timing.txt ]; then
        cat /tmp/cutover_timing.txt
        rm /tmp/cutover_timing.txt
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Monitor K6 error rate"
    echo "  2. Check Grafana dashboard"
    echo "  3. Verify data integrity: ./verify-data.sh"
    echo "  4. If rollback needed: ./rollback.sh"
    echo "=========================================="
}

# ==========================================
# Main
# ==========================================
main() {
    echo "=========================================="
    echo "DATABASE MIGRATION CUTOVER"
    echo "=========================================="
    echo "Architecture: Single EC2"
    echo "  - Nginx :80 → Spring Boot :8080 (Source DB)"
    echo "  - Nginx :80 → Spring Boot :8081 (Target RDS) [after cutover]"
    echo ""
    echo "Source DB: $SOURCE_HOST:$SOURCE_PORT (Local MySQL)"
    echo "Target DB: $TARGET_HOST:$TARGET_PORT (RDS)"
    echo "=========================================="
    echo ""

    read -p "Are you ready to proceed with cutover? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Cutover cancelled"
        exit 0
    fi

    preflight_check
    check_replication_lag
    check_app_user_permissions
    set_source_readonly
    wait_for_transactions
    final_lag_check
    switch_nginx
    verify_traffic
    stop_replication
    print_summary
}

# ==========================================
# Usage
# ==========================================
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "Usage: $0"
    echo ""
    echo "Environment variables:"
    echo "  SOURCE_HOST, SOURCE_PORT, SOURCE_USER, SOURCE_PASSWORD"
    echo "  TARGET_HOST, TARGET_PORT, TARGET_USER, TARGET_PASSWORD"
    echo "  NGINX_CONF_DIR  (default: /etc/nginx/conf.d)"
    echo "  APP_USER        App database user (default: app_user)"
    exit 0
fi

main "$@"