#!/bin/bash
# Backend DB 전환 스크립트
# 사용법: ./switch-backend.sh [host|rds]

set -e

TARGET=$1
UPSTREAM_CONF=/etc/nginx/conf.d/upstream.conf
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ "$TARGET" == "host" ]; then
    PORT=8080
    echo "[$TIMESTAMP] 전환: Backend → Host MySQL (8080)"
elif [ "$TARGET" == "rds" ]; then
    PORT=8081
    echo "[$TIMESTAMP] 전환: Backend → RDS (8081)"
else
    echo "사용법: ./switch-backend.sh [host|rds]"
    echo "  host: Host MySQL (8080)"
    echo "  rds:  RDS (8081)"
    exit 1
fi

# 현재 상태 확인
CURRENT=$(grep -A1 'upstream backend {' $UPSTREAM_CONF | grep 'server localhost' | grep -oP ':\K[0-9]+')
echo "현재 Backend 포트: $CURRENT"

if [ "$CURRENT" == "$PORT" ]; then
    echo "이미 $TARGET ($PORT) 상태입니다."
    exit 0
fi

# 백업
sudo cp $UPSTREAM_CONF ${UPSTREAM_CONF}.backup.$(date +%Y%m%d-%H%M%S)

# upstream backend만 변경 (backend_host, backend_rds는 유지)
sudo sed -i "/upstream backend {/,/^}/ s/server localhost:[0-9]*/server localhost:$PORT/" $UPSTREAM_CONF

# Nginx 설정 테스트 및 reload
if sudo nginx -t; then
    sudo systemctl reload nginx
    echo ""
    echo "✅ 전환 완료: Backend → $TARGET (localhost:$PORT)"
    echo ""
    
    # 헬스체크
    sleep 1
    HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/actuator/health)
    if [ "$HEALTH" == "200" ]; then
        echo "✅ WAS :$PORT 헬스체크 OK"
    else
        echo "⚠️  WAS :$PORT 헬스체크 실패 (HTTP $HEALTH)"
    fi
else
    echo "❌ Nginx 설정 오류! 롤백 중..."
    sudo cp ${UPSTREAM_CONF}.backup.* $UPSTREAM_CONF 2>/dev/null
    exit 1
fi
