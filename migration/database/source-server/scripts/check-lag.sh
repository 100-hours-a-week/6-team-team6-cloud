#!/bin/bash
# ==========================================
# Replication Lag 모니터링 스크립트
# ==========================================

set -e

TARGET_HOST="${TARGET_HOST:-}"
TARGET_PORT="${TARGET_PORT:-3306}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PASSWORD="${TARGET_PASSWORD:-}"

INTERVAL="${INTERVAL:-1}"
THRESHOLD="${THRESHOLD:-5}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$TARGET_HOST" ]; then
    echo "Usage: TARGET_HOST=<rds-endpoint> TARGET_PASSWORD=<password> $0"
    exit 1
fi

echo "=========================================="
echo "Replication Lag Monitor"
echo "Target: $TARGET_HOST:$TARGET_PORT"
echo "Interval: ${INTERVAL}s"
echo "Alert Threshold: ${THRESHOLD}s"
echo "Press Ctrl+C to stop"
echo "=========================================="

while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Get slave status
    STATUS=$(mysql -h "$TARGET_HOST" -P "$TARGET_PORT" -u "$TARGET_USER" -p"$TARGET_PASSWORD" -N -e "SHOW SLAVE STATUS\G" 2>/dev/null)

    IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
    LAG=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')
    LAST_ERROR=$(echo "$STATUS" | grep "Last_Error:" | cut -d: -f2-)

    # Determine status color
    if [ "$LAG" == "NULL" ] || [ -z "$LAG" ]; then
        LAG_COLOR="${RED}"
        LAG_DISPLAY="NULL (not replicating)"
    elif [ "$LAG" -eq 0 ]; then
        LAG_COLOR="${GREEN}"
        LAG_DISPLAY="0 (in sync)"
    elif [ "$LAG" -lt "$THRESHOLD" ]; then
        LAG_COLOR="${YELLOW}"
        LAG_DISPLAY="$LAG seconds"
    else
        LAG_COLOR="${RED}"
        LAG_DISPLAY="$LAG seconds (ALERT!)"
    fi

    # IO/SQL status
    if [ "$IO_RUNNING" == "Yes" ]; then
        IO_COLOR="${GREEN}"
    else
        IO_COLOR="${RED}"
    fi

    if [ "$SQL_RUNNING" == "Yes" ]; then
        SQL_COLOR="${GREEN}"
    else
        SQL_COLOR="${RED}"
    fi

    # Display
    echo -ne "\r[$TIMESTAMP] IO: ${IO_COLOR}${IO_RUNNING}${NC} | SQL: ${SQL_COLOR}${SQL_RUNNING}${NC} | Lag: ${LAG_COLOR}${LAG_DISPLAY}${NC}        "

    # Alert if lag exceeds threshold
    if [ "$LAG" != "NULL" ] && [ -n "$LAG" ] && [ "$LAG" -ge "$THRESHOLD" ]; then
        echo ""
        echo -e "${RED}[ALERT] Replication lag exceeded threshold: ${LAG}s >= ${THRESHOLD}s${NC}"
    fi

    # Show error if any
    if [ -n "$LAST_ERROR" ] && [ "$LAST_ERROR" != " " ]; then
        echo ""
        echo -e "${RED}[ERROR] $LAST_ERROR${NC}"
    fi

    sleep "$INTERVAL"
done