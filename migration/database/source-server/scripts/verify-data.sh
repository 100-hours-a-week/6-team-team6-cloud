#!/bin/bash
# ==========================================
# 데이터 정합성 검증 스크립트
# Source (EC2 MySQL) vs Target (RDS MySQL)
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

DB_NAME="${DB_NAME:-billage}"

# Tables to verify
TABLES=(
    "users"
    "billage_group"
    "membership"
    "post"
    "post_image"
    "chatroom"
    "chat_message"
    "refresh_token"
    "invitation"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REPORT_FILE="/tmp/data_verification_$(date +%Y%m%d_%H%M%S).txt"

log_info() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$REPORT_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$REPORT_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$REPORT_FILE"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1" | tee -a "$REPORT_FILE"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1" | tee -a "$REPORT_FILE"; }

# ==========================================
# Row Count Comparison
# ==========================================
compare_row_counts() {
    log_info "=========================================="
    log_info "1. Row Count Comparison"
    log_info "=========================================="

    local all_match=true

    printf "%-20s %15s %15s %10s\n" "Table" "Source" "Target" "Status" | tee -a "$REPORT_FILE"
    printf "%-20s %15s %15s %10s\n" "--------------------" "---------------" "---------------" "----------" | tee -a "$REPORT_FILE"

    for table in "${TABLES[@]}"; do
        local source_count=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SELECT COUNT(*) FROM ${DB_NAME}.${table}" 2>/dev/null || echo "ERROR")
        local target_count=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SELECT COUNT(*) FROM ${DB_NAME}.${table}" 2>/dev/null || echo "ERROR")

        if [ "$source_count" == "$target_count" ]; then
            printf "%-20s %15s %15s ${GREEN}%10s${NC}\n" "$table" "$source_count" "$target_count" "MATCH" | tee -a "$REPORT_FILE"
        else
            printf "%-20s %15s %15s ${RED}%10s${NC}\n" "$table" "$source_count" "$target_count" "MISMATCH" | tee -a "$REPORT_FILE"
            all_match=false
        fi
    done

    echo "" | tee -a "$REPORT_FILE"

    if $all_match; then
        log_pass "All row counts match"
    else
        log_fail "Row count mismatch detected"
    fi
}

# ==========================================
# Checksum Comparison
# ==========================================
compare_checksums() {
    log_info "=========================================="
    log_info "2. Checksum Comparison"
    log_info "=========================================="

    local tables_str=$(IFS=,; echo "${TABLES[*]}")

    log_info "Calculating checksums (this may take a while)..."

    local source_checksums=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "CHECKSUM TABLE ${tables_str}" 2>/dev/null)
    local target_checksums=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "CHECKSUM TABLE ${tables_str}" 2>/dev/null)

    echo "" | tee -a "$REPORT_FILE"
    printf "%-30s %15s %15s %10s\n" "Table" "Source" "Target" "Status" | tee -a "$REPORT_FILE"
    printf "%-30s %15s %15s %10s\n" "------------------------------" "---------------" "---------------" "----------" | tee -a "$REPORT_FILE"

    local all_match=true

    for table in "${TABLES[@]}"; do
        local source_cs=$(echo "$source_checksums" | grep "${DB_NAME}.${table}" | awk '{print $2}')
        local target_cs=$(echo "$target_checksums" | grep "${DB_NAME}.${table}" | awk '{print $2}')

        if [ "$source_cs" == "$target_cs" ]; then
            printf "%-30s %15s %15s ${GREEN}%10s${NC}\n" "${DB_NAME}.${table}" "$source_cs" "$target_cs" "MATCH" | tee -a "$REPORT_FILE"
        else
            printf "%-30s %15s %15s ${RED}%10s${NC}\n" "${DB_NAME}.${table}" "$source_cs" "$target_cs" "MISMATCH" | tee -a "$REPORT_FILE"
            all_match=false
        fi
    done

    echo "" | tee -a "$REPORT_FILE"

    if $all_match; then
        log_pass "All checksums match"
    else
        log_fail "Checksum mismatch detected"
    fi
}

# ==========================================
# K6 Load Test Data Verification
# ==========================================
verify_k6_data() {
    log_info "=========================================="
    log_info "3. K6 Load Test Data Verification"
    log_info "=========================================="

    local source_k6=$(mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -N -e "SELECT COUNT(*) FROM ${DB_NAME}.post WHERE title LIKE 'load-test-%'" 2>/dev/null || echo "0")
    local target_k6=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SELECT COUNT(*) FROM ${DB_NAME}.post WHERE title LIKE 'load-test-%'" 2>/dev/null || echo "0")

    log_info "K6 test posts on source: $source_k6"
    log_info "K6 test posts on target: $target_k6"

    if [ "$source_k6" == "$target_k6" ]; then
        log_pass "K6 test data count matches"
    else
        local diff=$((source_k6 - target_k6))
        if [ "$diff" -gt 0 ]; then
            log_warn "Target is missing $diff K6 test posts (possible cutover gap)"
        else
            log_warn "Target has $((diff * -1)) more K6 test posts than source"
        fi
    fi
}

# ==========================================
# Recent Data Sampling
# ==========================================
sample_recent_data() {
    log_info "=========================================="
    log_info "4. Recent Data Sampling"
    log_info "=========================================="

    log_info "Most recent 5 posts on target:"
    mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "SELECT id, title, created_at FROM ${DB_NAME}.post ORDER BY created_at DESC LIMIT 5" 2>/dev/null | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"

    log_info "Most recent 5 posts on source:"
    mysql -h "$SOURCE_HOST" -P "$SOURCE_PORT" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" -e "SELECT id, title, created_at FROM ${DB_NAME}.post ORDER BY created_at DESC LIMIT 5" 2>/dev/null | tee -a "$REPORT_FILE"
}

# ==========================================
# FK Integrity Check
# ==========================================
check_fk_integrity() {
    log_info "=========================================="
    log_info "5. Foreign Key Integrity Check"
    log_info "=========================================="

    # Check orphan post_images
    local orphan_images=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "
        SELECT COUNT(*) FROM ${DB_NAME}.post_image pi
        LEFT JOIN ${DB_NAME}.post p ON pi.post_id = p.id
        WHERE p.id IS NULL AND pi.deleted_at IS NULL
    " 2>/dev/null || echo "ERROR")

    if [ "$orphan_images" == "0" ]; then
        log_pass "No orphan post_images found"
    else
        log_fail "Found $orphan_images orphan post_images"
    fi

    # Check orphan chat_messages
    local orphan_messages=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "
        SELECT COUNT(*) FROM ${DB_NAME}.chat_message cm
        LEFT JOIN ${DB_NAME}.chatroom c ON cm.chatroom_id = c.id
        WHERE c.id IS NULL AND cm.deleted_at IS NULL
    " 2>/dev/null || echo "ERROR")

    if [ "$orphan_messages" == "0" ]; then
        log_pass "No orphan chat_messages found"
    else
        log_fail "Found $orphan_messages orphan chat_messages"
    fi
}

# ==========================================
# Summary
# ==========================================
print_summary() {
    echo "" | tee -a "$REPORT_FILE"
    echo "==========================================" | tee -a "$REPORT_FILE"
    echo "VERIFICATION SUMMARY" | tee -a "$REPORT_FILE"
    echo "==========================================" | tee -a "$REPORT_FILE"
    echo "Report saved to: $REPORT_FILE"
    echo ""
    echo "Review any MISMATCH or FAIL items above."
    echo "==========================================" | tee -a "$REPORT_FILE"
}

# ==========================================
# Main
# ==========================================
main() {
    echo "==========================================" | tee "$REPORT_FILE"
    echo "DATA VERIFICATION REPORT" | tee -a "$REPORT_FILE"
    echo "Generated: $(date)" | tee -a "$REPORT_FILE"
    echo "Source: $SOURCE_HOST:$SOURCE_PORT" | tee -a "$REPORT_FILE"
    echo "Target: $TARGET_HOST:$TARGET_PORT" | tee -a "$REPORT_FILE"
    echo "==========================================" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"

    compare_row_counts
    compare_checksums
    verify_k6_data
    sample_recent_data
    check_fk_integrity
    print_summary
}

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "Usage: $0"
    echo ""
    echo "Environment variables:"
    echo "  SOURCE_HOST, SOURCE_PORT, SOURCE_USER, SOURCE_PASSWORD"
    echo "  TARGET_HOST, TARGET_PORT, TARGET_USER, TARGET_PASSWORD"
    echo "  DB_NAME (default: billage)"
    exit 0
fi

if [ -z "$TARGET_HOST" ]; then
    echo "Error: TARGET_HOST is required"
    echo "Usage: TARGET_HOST=<rds-endpoint> TARGET_PASSWORD=<password> $0"
    exit 1
fi

main "$@"