#!/bin/bash
# ==========================================
# MySQL Native Replication 설정 스크립트
# EC2 MySQL (Source) → RDS MySQL (Target)
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

REPL_USER="${REPL_USER:-repl_user}"
REPL_PASSWORD="${REPL_PASSWORD:-repl_password}"

DB_NAME="${DB_NAME:-billage}"
DUMP_FILE="/tmp/billage_dump_$(date +%Y%m%d_%H%M%S).sql"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==========================================
# Pre-flight Checks
# ==========================================
preflight_check() {
    log_info "Running pre-flight checks..."

    # Check required variables
    if [ -z "$TARGET_HOST" ]; then
        log_error "TARGET_HOST is required"
        exit 1
    fi

    # Check MySQL client
    if ! command -v mysql &> /dev/null; then
        log_error "mysql client not found"
        exit 1
    fi

    # Check mysqldump
    if ! command -v mysqldump &> /dev/null; then
        log_error "mysqldump not found"
        exit 1
    fi

    # Test source connection
    log_info "Testing source MySQL connection..."
    if ! mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -e "SELECT 1" &> /dev/null; then
        log_error "Cannot connect to source MySQL"
        exit 1
    fi

    # Test target connection
    log_info "Testing target MySQL (RDS) connection..."
    if ! mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "SELECT 1" &> /dev/null; then
        log_error "Cannot connect to target MySQL (RDS)"
        exit 1
    fi

    log_info "Pre-flight checks passed"
}

# ==========================================
# Step 1: Check Source binlog configuration
# ==========================================
check_source_binlog() {
    log_info "Checking source MySQL binlog configuration..."

    local binlog_status=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SHOW VARIABLES LIKE 'log_bin'")

    if [[ ! "$binlog_status" == *"ON"* ]]; then
        log_error "Binary logging is not enabled on source MySQL"
        log_error "Add these to my.cnf and restart MySQL:"
        echo "  log_bin = mysql-bin"
        echo "  binlog_format = ROW"
        echo "  server-id = 1"
        exit 1
    fi

    local binlog_format=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SHOW VARIABLES LIKE 'binlog_format'" | awk '{print $2}')

    if [ "$binlog_format" != "ROW" ]; then
        log_warn "binlog_format is $binlog_format, ROW format is recommended"
    fi

    log_info "Source binlog configuration OK (format: $binlog_format)"
}

# ==========================================
# Step 2: Create Replication User
# ==========================================
create_replication_user() {
    log_info "Creating replication user on source..."

    mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" <<EOF
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
EOF

    log_info "Replication user created: ${REPL_USER}"
}

# (Step 3 moved to check_gtid_mode and dump_source_database)

# ==========================================
# Step 4: Check GTID Mode
# ==========================================
check_gtid_mode() {
    log_info "Checking GTID mode..."

    local gtid_mode=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SHOW VARIABLES LIKE 'gtid_mode'" | awk '{print $2}')

    if [ "$gtid_mode" == "ON" ]; then
        USE_GTID="true"
        log_info "GTID mode is ON - will use GTID-based replication (recommended)"
    else
        USE_GTID="false"
        log_warn "GTID mode is OFF - will use binlog position-based replication"
        log_warn "Consider enabling GTID for more robust replication"
    fi
}

# ==========================================
# Step 5: Dump Source Database
# ==========================================
dump_source_database() {
    log_info "Dumping source database..."

    # GTID 모드에 따라 다른 옵션 사용
    if [ "$USE_GTID" == "true" ]; then
        log_info "Using GTID-aware dump (--set-gtid-purged=ON)"
        mysqldump \
            -h "$SOURCE_HOST" \
            -P "$SOURCE_PORT" \
            -u "$SOURCE_USER" \
            -p"$SOURCE_PASSWORD" \
            --single-transaction \
            --routines \
            --triggers \
            --set-gtid-purged=ON \
            "$DB_NAME" > "$DUMP_FILE"
    else
        log_info "Using binlog position dump (--master-data=2)"
        # Lock tables for consistent snapshot
        mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -e "FLUSH TABLES WITH READ LOCK;"

        # Get current binlog position
        MASTER_STATUS=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SHOW MASTER STATUS")
        MASTER_LOG_FILE=$(echo "$MASTER_STATUS" | awk '{print $1}')
        MASTER_LOG_POS=$(echo "$MASTER_STATUS" | awk '{print $2}')

        log_info "Master Log File: $MASTER_LOG_FILE"
        log_info "Master Log Position: $MASTER_LOG_POS"

        # Save position to file for reference
        echo "MASTER_LOG_FILE=$MASTER_LOG_FILE" > /tmp/master_position.txt
        echo "MASTER_LOG_POS=$MASTER_LOG_POS" >> /tmp/master_position.txt

        mysqldump \
            -h "$SOURCE_HOST" \
            -P "$SOURCE_PORT" \
            -u "$SOURCE_USER" \
            -p"$SOURCE_PASSWORD" \
            --single-transaction \
            --routines \
            --triggers \
            --master-data=2 \
            "$DB_NAME" > "$DUMP_FILE"

        # Unlock tables
        mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -e "UNLOCK TABLES;"
    fi

    local dump_size=$(du -h "$DUMP_FILE" | cut -f1)
    log_info "Dump completed: $DUMP_FILE ($dump_size)"
}

# ==========================================
# Step 6: Import to Target (RDS)
# ==========================================
import_to_target() {
    log_info "Importing dump to target RDS..."
    log_info "This may take a while for large databases..."

    mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" "$DB_NAME" < "$DUMP_FILE"

    log_info "Import completed"
}

# ==========================================
# Step 7: Configure Replication on Target
# ==========================================
configure_replication() {
    log_info "Configuring replication on target RDS..."

    # 단일 EC2 환경: Source는 EC2의 Private IP 사용
    # localhost가 아닌 실제 Private IP를 사용해야 RDS에서 접근 가능
    local source_ip="${SOURCE_PRIVATE_IP:-$(hostname -I | awk '{print $1}')}"
    log_info "Source IP for replication: $source_ip"

    if [ "$USE_GTID" == "true" ]; then
        # GTID 기반 복제 설정 (권장)
        log_info "Configuring GTID-based replication..."
        mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" <<EOF
CALL mysql.rds_set_external_master_with_auto_position(
    '${source_ip}',
    ${SOURCE_PORT},
    '${REPL_USER}',
    '${REPL_PASSWORD}',
    0,
    0
);
EOF
    else
        # Binlog position 기반 복제 설정
        log_info "Configuring binlog position-based replication..."

        # 덤프 파일 헤더에서 binlog position 추출 (--master-data=2 사용 시)
        if [ -z "$MASTER_LOG_FILE" ] || [ -z "$MASTER_LOG_POS" ]; then
            log_info "Extracting binlog position from dump file..."
            MASTER_LOG_FILE=$(grep -m1 "CHANGE MASTER TO" "$DUMP_FILE" | sed -n "s/.*MASTER_LOG_FILE='\\([^']*\\)'.*/\\1/p")
            MASTER_LOG_POS=$(grep -m1 "CHANGE MASTER TO" "$DUMP_FILE" | sed -n "s/.*MASTER_LOG_POS=\\([0-9]*\\).*/\\1/p")
            log_info "Extracted - File: $MASTER_LOG_FILE, Position: $MASTER_LOG_POS"
        fi

        mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" <<EOF
CALL mysql.rds_set_external_master(
    '${source_ip}',
    ${SOURCE_PORT},
    '${REPL_USER}',
    '${REPL_PASSWORD}',
    '${MASTER_LOG_FILE}',
    ${MASTER_LOG_POS},
    0
);
EOF
    fi

    log_info "Replication configured"
}

# ==========================================
# Step 8: Start Replication
# ==========================================
start_replication() {
    log_info "Starting replication..."

    mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "CALL mysql.rds_start_replication;"

    sleep 2

    # Check replication status
    log_info "Checking replication status..."
    mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "SHOW SLAVE STATUS\G" | grep -E "(Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_Error)"
}

# ==========================================
# Main
# ==========================================
main() {
    echo "=========================================="
    echo "MySQL Replication Setup"
    echo "Source: $SOURCE_HOST:$SOURCE_PORT (Single EC2)"
    echo "Target: $TARGET_HOST:$TARGET_PORT (RDS)"
    echo "=========================================="

    preflight_check
    check_source_binlog
    create_replication_user
    check_gtid_mode
    dump_source_database
    import_to_target
    configure_replication
    start_replication

    log_info "=========================================="
    log_info "Replication setup completed!"
    log_info "GTID Mode: $USE_GTID"
    log_info "Monitor with: ./check-lag.sh"
    log_info "=========================================="
}

# ==========================================
# Usage
# ==========================================
usage() {
    echo "Usage: $0"
    echo ""
    echo "Environment variables:"
    echo "  SOURCE_HOST       Source MySQL host (default: localhost)"
    echo "  SOURCE_PORT       Source MySQL port (default: 3306)"
    echo "  SOURCE_USER       Source MySQL user (default: root)"
    echo "  SOURCE_PASSWORD   Source MySQL password"
    echo "  SOURCE_PRIVATE_IP EC2 Private IP for RDS connection (auto-detected if not set)"
    echo "  TARGET_HOST       Target RDS endpoint (required)"
    echo "  TARGET_PORT       Target RDS port (default: 3306)"
    echo "  TARGET_USER       Target RDS user (default: root)"
    echo "  TARGET_PASSWORD   Target RDS password"
    echo "  REPL_USER         Replication user (default: repl_user)"
    echo "  REPL_PASSWORD     Replication password (default: repl_password)"
    echo "  DB_NAME           Database name (default: billage)"
    echo ""
    echo "Example (Single EC2 environment):"
    echo "  SOURCE_PASSWORD=mypass TARGET_HOST=mydb.rds.amazonaws.com TARGET_PASSWORD=rdspass $0"
}

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    usage
    exit 0
fi

main "$@"