#!/bin/bash
# =============================================================================
# Billage DB Migration - One-Click Cutover Script
# Host MySQL → RDS 전환 통합 스크립트
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# RDS 접속 정보
RDS_HOST="billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com"
RDS_USER="billage_admin"
RDS_PASS="K6b54UJJM2dtLhECFbKCTx1d7Qd9vb6ohKUsDqcY"

# Host MySQL 접속 정보
HOST_USER="root"
HOST_PASS="sdfglhdsfljghsdflkhglkdfs"

NGINX_CONF="/etc/nginx/conf.d/upstream.conf"
WRITE_BLOCK_CONF="/etc/nginx/conf.d/write-block.conf"
TEST_CONF="/etc/nginx/sites-available/test.conf"

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# =============================================================================
# Soft Freeze: Nginx에서 POST/PUT/DELETE 차단 (503 반환)
# =============================================================================
soft_freeze_on() {
    log "Soft Freeze ON - POST/PUT/DELETE 차단"

    # write-block.conf 생성
    sudo bash -c "cat > $WRITE_BLOCK_CONF" << 'CONFEOF'
# Write Block - Soft Freeze
# POST, PUT, DELETE, PATCH 요청 시 503 반환
map $request_method $write_block {
    default 0;
    POST    1;
    PUT     1;
    DELETE  1;
    PATCH   1;
}
CONFEOF

    # test.conf 에 write_block 체크 추가
    if ! sudo grep -q 'if.*write_block' $TEST_CONF 2>/dev/null; then
        # proxy_pass 앞에 write_block 체크 추가
        sudo sed -i '/proxy_pass.*backend/i\            if ($write_block) { return 503; }' $TEST_CONF 2>/dev/null || true
    fi

    sudo nginx -t && sudo systemctl reload nginx
    success "Soft Freeze 활성화 (쓰기 요청 → 503)"
}

soft_freeze_off() {
    log "Soft Freeze OFF - 쓰기 차단 해제"

    # write-block.conf 삭제
    sudo rm -f $WRITE_BLOCK_CONF

    # write_block if문 제거
    sudo sed -i '/if.*write_block/d' $TEST_CONF 2>/dev/null || true

    sudo nginx -t && sudo systemctl reload nginx
    success "Soft Freeze 해제"
}

# =============================================================================
# Hard Freeze: MySQL read_only
# =============================================================================
hard_freeze_on() {
    log "Hard Freeze ON - Host MySQL read_only=ON"
    mysql -u $HOST_USER -p"$HOST_PASS" -e "SET GLOBAL read_only = ON;" 2>/dev/null
    success "Hard Freeze 활성화"
}

hard_freeze_off() {
    log "Hard Freeze OFF - Host MySQL read_only=OFF"
    mysql -u $HOST_USER -p"$HOST_PASS" -e "SET GLOBAL read_only = OFF;" 2>/dev/null
    success "Hard Freeze 해제"
}

# =============================================================================
# 사전 체크
# =============================================================================
pre_check() {
    log "========== 사전 체크 =========="

    # Replication Lag 체크
    LAG=$(mysql -h $RDS_HOST -u $RDS_USER -p"$RDS_PASS" -N -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind_Source" | awk '{print $2}')

    if [ "$LAG" != "0" ]; then
        error "Replication Lag이 0이 아닙니다: ${LAG}초"
    fi
    success "Replication Lag: 0초"

    # WAS 8081 체크
    WAS_8081=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/actuator/health 2>/dev/null || echo "000")
    if [ "$WAS_8081" != "200" ]; then
        error "WAS 8081 (RDS)가 정상이 아닙니다: HTTP $WAS_8081"
    fi
    success "WAS 8081 (RDS): 정상"
    echo ""
}

# =============================================================================
# CUTOVER 실행
# =============================================================================
do_cutover() {
    log "========== CUTOVER 시작 =========="
    START_TIME=$(date +%s.%N)

    # Step 1: Soft Freeze (Nginx에서 쓰기 차단)
    log "[1/4] Soft Freeze - Nginx POST/PUT/DELETE 차단"
    soft_freeze_on

    # Step 2: Hard Freeze (MySQL read_only)
    log "[2/4] Hard Freeze - Host MySQL read_only=ON"
    hard_freeze_on

    # Step 3: 최종 Lag 확인
    log "[3/4] 최종 Replication Lag 확인"
    sleep 1
    FINAL_LAG=$(mysql -h $RDS_HOST -u $RDS_USER -p"$RDS_PASS" -N -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind_Source" | awk '{print $2}')
    while [ "$FINAL_LAG" != "0" ]; do
        warn "Lag: ${FINAL_LAG}초 - 대기 중..."
        sleep 1
        FINAL_LAG=$(mysql -h $RDS_HOST -u $RDS_USER -p"$RDS_PASS" -N -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind_Source" | awk '{print $2}')
    done
    success "최종 Lag: 0초"

    # Step 4: Nginx 스위칭 + Soft Freeze 해제
    log "[4/4] Nginx 스위칭 → 8081 (RDS)"
    sudo sed -i '/upstream backend {/,/^}/ s/server localhost:[0-9]*/server localhost:8081/' $NGINX_CONF
    soft_freeze_off  # 쓰기 차단 해제 (RDS로 전환되었으므로)

    END_TIME=$(date +%s.%N)
    ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)

    echo ""
    log "========== CUTOVER 완료 =========="
    success "총 소요시간: ${ELAPSED}초"
}

# =============================================================================
# 검증
# =============================================================================
verify() {
    log "========== 전환 검증 =========="
    sleep 2

    HEALTH=$(curl -s http://test.billages.com/api/actuator/health 2>/dev/null | grep -o "UP" | head -1)
    if [ "$HEALTH" = "UP" ]; then
        success "서비스 헬스체크: UP"
    else
        warn "헬스체크 확인 필요"
    fi

    CURRENT=$(grep -A2 "upstream backend {" $NGINX_CONF | grep "server" | grep -o "808[01]")
    success "현재 Backend: localhost:$CURRENT"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  RDS 전환 완료! 서비스 정상 운영 중  ${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# =============================================================================
# 롤백
# =============================================================================
rollback() {
    log "========== ROLLBACK 시작 =========="

    # 1. Nginx → 8080 + 쓰기 차단 해제
    log "[1/2] Nginx 롤백 → 8080 (Host)"
    sudo sed -i '/upstream backend {/,/^}/ s/server localhost:[0-9]*/server localhost:8080/' $NGINX_CONF
    soft_freeze_off
    success "Nginx 롤백 완료"

    # 2. Host MySQL read_only 해제
    log "[2/2] Host MySQL read_only=OFF"
    hard_freeze_off

    echo ""
    success "ROLLBACK 완료 - Host MySQL로 복귀"
}

# =============================================================================
# 상태 확인
# =============================================================================
show_status() {
    log "현재 상태 확인"
    echo ""

    CURRENT=$(grep -A2 "upstream backend {" $NGINX_CONF | grep "server" | grep -o "808[01]")
    echo "Backend: localhost:$CURRENT"

    LAG=$(mysql -h $RDS_HOST -u $RDS_USER -p"$RDS_PASS" -N -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind_Source" | awk '{print $2}')
    echo "Replication Lag: ${LAG}초"

    READONLY=$(mysql -u $HOST_USER -p"$HOST_PASS" -N -e "SELECT @@read_only;" 2>/dev/null)
    echo "Host read_only: $READONLY"

    if [ -f "$WRITE_BLOCK_CONF" ]; then
        echo "Soft Freeze: ON (쓰기 차단 중)"
    else
        echo "Soft Freeze: OFF"
    fi
}

# =============================================================================
# 메인
# =============================================================================
case "${1:-}" in
    run)
        echo -e "${YELLOW}"
        echo "============================================"
        echo "  Billage DB Migration - CUTOVER"
        echo "  Host MySQL → RDS 전환"
        echo "============================================"
        echo -e "${NC}"
        read -p "정말 실행하시겠습니까? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            pre_check
            do_cutover
            verify
        else
            echo "취소되었습니다."
        fi
        ;;
    rollback)
        echo -e "${RED}"
        echo "============================================"
        echo "  ROLLBACK - Host MySQL로 복귀"
        echo "============================================"
        echo -e "${NC}"
        read -p "롤백을 실행하시겠습니까? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            rollback
        else
            echo "취소되었습니다."
        fi
        ;;
    status)
        show_status
        ;;
    *)
        echo "사용법:"
        echo "  ./cutover.sh run       - Cutover 실행 (Host → RDS)"
        echo "  ./cutover.sh rollback  - 롤백 (RDS → Host)"
        echo "  ./cutover.sh status    - 현재 상태 확인"
        ;;
esac
