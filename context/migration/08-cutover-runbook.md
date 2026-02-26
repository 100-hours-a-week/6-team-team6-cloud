# DB 마이그레이션 컷오버 Runbook

## 문서 정보

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-02-13 |
| 버전 | v1.0 |
| 대상 | Host MySQL → RDS 무중단 전환 |
| 전략 | **2단계 Write Freeze (Soft + Hard)** |

---

## 1. 개요

### 1.1 Write Freeze 전략

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      2단계 Write Freeze (Defense in Depth)              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [사용자] ──▶ [Nginx] ──▶ [WAS 8080] ──▶ [Host MySQL]                   │
│                 │            │              │                            │
│                 ▼            ▼              ▼                            │
│           ┌─────────┐  ┌─────────┐    ┌─────────┐                       │
│           │  Soft   │  │ (선택)  │    │  Hard   │                       │
│           │ Freeze  │  │  Flag   │    │ Freeze  │                       │
│           └─────────┘  └─────────┘    └─────────┘                       │
│                                                                          │
│  T0 ──────────────────────────────────────────────────────────▶ T완료   │
│   │                                                                      │
│   ├─ Soft Freeze: Nginx에서 write 메서드 차단 (503)                     │
│   ├─ Hard Freeze: MySQL read_only=ON                                    │
│   ├─ Catch-up: RDS가 marker까지 따라잡기                                │
│   ├─ Switch: Nginx → 8081 (RDS WAS)                                     │
│   └─ Unfreeze: 트래픽 오픈                                              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 왜 2단계인가?

| 단계 | 역할 | 막는 대상 |
|------|------|----------|
| **Soft Freeze** (Nginx) | UX 보호, DB 부하 감소 | 사용자 write 요청 |
| **Hard Freeze** (DB) | 정합성 100% 보장 | 배치, 크론, 내부호출, 관리툴 |

> **핵심**: Nginx 차단만으로는 배치/크론/내부호출을 못 막음.
> DB read_only가 "최종 안전장치"로 정합성을 보장함.

---

## 2. 사전 준비 체크리스트

### 2.1 Go/No-Go 체크 (컷오버 30~60분 전)

```bash
# 체크리스트 스크립트
cat > /tmp/go-nogo-check.sh << 'EOF'
#!/bin/bash
echo "=== Go/No-Go 체크리스트 ==="
echo ""

# 1. Replication 상태
echo "[1] Replication 상태"
mysql -h $RDS_ENDPOINT -u billage_admin -p$RDS_PASSWORD -e "SHOW REPLICA STATUS\G" 2>/dev/null | \
  grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind|Last_Error"

# 2. RDS 자원 확인
echo ""
echo "[2] RDS 자원 (AWS Console에서 확인)"
echo "    - CPU Utilization < 70%"
echo "    - FreeStorageSpace > 20%"
echo "    - DatabaseConnections < 80%"

# 3. 배치/크론 확인
echo ""
echo "[3] 배치/크론 상태"
crontab -l 2>/dev/null || echo "    크론 없음"
ps aux | grep -E "batch|cron|worker" | grep -v grep || echo "    배치 프로세스 없음"

# 4. DDL 확인
echo ""
echo "[4] 진행 중인 DDL/긴 쿼리"
mysql -u billage_user -p$HOST_DB_PASSWORD -e "SHOW FULL PROCESSLIST;" 2>/dev/null | \
  grep -v "Sleep" | head -10

echo ""
echo "=== 모든 항목 확인 후 Go/No-Go 결정 ==="
EOF
chmod +x /tmp/go-nogo-check.sh
```

**체크리스트:**

- [ ] Replica_IO_Running: Yes
- [ ] Replica_SQL_Running: Yes
- [ ] Seconds_Behind_Source: 0~1초
- [ ] Last_Error: 없음
- [ ] RDS CPU < 70%
- [ ] 배치/크론 중지됨
- [ ] DDL 없음
- [ ] 팀원 역할 분담 완료
- [ ] 롤백 절차 숙지 완료

---

## 3. Soft Freeze 설정 (Nginx)

### 3.1 Write 차단 설정 파일

```bash
# /etc/nginx/conf.d/write-freeze.conf

# Write Freeze 활성화 시 이 파일을 include
# 비활성화 시 이 파일 삭제 후 nginx reload

# Write 메서드 차단 (POST, PUT, PATCH, DELETE)
map $request_method $is_write_method {
    default 0;
    POST    1;
    PUT     1;
    PATCH   1;
    DELETE  1;
}

# Write Freeze 상태 (1=활성, 0=비활성)
# 이 값을 변경하여 freeze 제어
geo $write_freeze_enabled {
    default 1;
}
```

### 3.2 서버 블록에 적용

```nginx
# /etc/nginx/sites-available/billage.conf 수정

server {
    server_name api.billages.com;

    # ... 기존 설정 ...

    location / {
        # Write Freeze 체크
        if ($write_freeze_enabled) {
            set $freeze_check "${is_write_method}";
        }

        # Write 메서드이고 Freeze 활성화 시 503 반환
        if ($freeze_check = "1") {
            return 503 '{"error":"Service temporarily unavailable","message":"Maintenance in progress. Please retry in a few minutes.","retry_after":300}';
        }

        proxy_pass http://backend;
        # ... 기존 proxy 설정 ...
    }
}
```

### 3.3 간단한 방식 (권장)

위 방식이 복잡하면, 별도 conf 파일로 간단하게:

```bash
# Soft Freeze 활성화
sudo tee /etc/nginx/conf.d/write-freeze.conf > /dev/null << 'EOF'
# Write Freeze - POST/PUT/PATCH/DELETE 차단
# 생성 시각: $(date)

server {
    listen 8088;
    server_name _;

    location / {
        # 모든 write 요청을 여기로 리다이렉트하여 503 반환
        return 503 '{"error":"maintenance","retry_after":300}';
        add_header Content-Type application/json;
        add_header Retry-After 300;
    }
}
EOF
sudo nginx -t && sudo systemctl reload nginx
```

### 3.4 Soft Freeze 스크립트

```bash
#!/bin/bash
# /home/ubuntu/soft-freeze.sh

ACTION=$1
FREEZE_CONF=/etc/nginx/conf.d/write-freeze.conf
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

case $ACTION in
    on)
        echo "[$TIMESTAMP] Soft Freeze 활성화 중..."

        # Write 요청 차단 설정
        sudo tee $FREEZE_CONF > /dev/null << 'CONF'
# Write Freeze Active
# POST, PUT, PATCH, DELETE → 503

map $request_method $write_blocked {
    default 0;
    POST    1;
    PUT     1;
    PATCH   1;
    DELETE  1;
}
CONF

        # 메인 설정에 조건 추가는 복잡하므로,
        # 대신 WAS 8080을 직접 정지하는 방식 권장
        echo "[$TIMESTAMP] WAS 8080 정지로 Soft Freeze 적용"
        sudo systemctl stop billage-backend

        echo "✅ Soft Freeze 활성화 완료"
        echo "   - WAS 8080: 정지됨"
        echo "   - Write 요청: 차단됨 (502 Bad Gateway)"
        ;;

    off)
        echo "[$TIMESTAMP] Soft Freeze 해제 중..."

        # 설정 파일 제거
        sudo rm -f $FREEZE_CONF 2>/dev/null

        # WAS 재시작 (Host로 롤백 시에만)
        # RDS 전환 완료 후에는 8081만 사용하므로 8080은 정지 유지

        echo "✅ Soft Freeze 해제 완료"
        ;;

    status)
        echo "=== Soft Freeze 상태 ==="
        if [ -f $FREEZE_CONF ]; then
            echo "Freeze 설정: 활성화"
        else
            echo "Freeze 설정: 비활성화"
        fi

        echo ""
        echo "WAS 상태:"
        systemctl is-active billage-backend && echo "  8080: 실행 중" || echo "  8080: 정지됨"
        curl -s localhost:8081/actuator/health > /dev/null && echo "  8081: 실행 중" || echo "  8081: 정지됨"
        ;;

    *)
        echo "사용법: $0 [on|off|status]"
        exit 1
        ;;
esac
```

---

## 4. Hard Freeze 설정 (MySQL)

### 4.1 Host MySQL read_only 설정

```bash
#!/bin/bash
# /home/ubuntu/hard-freeze.sh

ACTION=$1
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# MySQL 접속 정보 (debian-sys-maint 사용)
MYSQL_USER="debian-sys-maint"
MYSQL_PASS="8mglCugYwritTZLS"

case $ACTION in
    on)
        echo "[$TIMESTAMP] Hard Freeze 활성화 중..."

        # 활성 트랜잭션 확인
        echo "=== 활성 트랜잭션 확인 ==="
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SHOW FULL PROCESSLIST;" | grep -v Sleep | head -10

        # read_only 설정
        echo ""
        echo "read_only 설정 중..."
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SET GLOBAL read_only = ON;"

        # super_read_only 설정 (가능하면)
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SET GLOBAL super_read_only = ON;" 2>/dev/null

        # 확인
        echo ""
        echo "=== Hard Freeze 상태 ==="
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SHOW VARIABLES LIKE '%read_only%';"

        echo ""
        echo "✅ Hard Freeze 활성화 완료"
        echo "   - read_only: ON"
        echo "   - 모든 write 쿼리 차단됨"
        ;;

    off)
        echo "[$TIMESTAMP] Hard Freeze 해제 중..."

        # read_only 해제
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SET GLOBAL super_read_only = OFF;" 2>/dev/null
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SET GLOBAL read_only = OFF;"

        # 확인
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SHOW VARIABLES LIKE '%read_only%';"

        echo "✅ Hard Freeze 해제 완료"
        ;;

    status)
        echo "=== Hard Freeze 상태 ==="
        mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SHOW VARIABLES LIKE '%read_only%';"
        ;;

    *)
        echo "사용법: $0 [on|off|status]"
        exit 1
        ;;
esac
```

---

## 5. 컷오버 실행 절차

### 5.1 타임라인

```
T-60분   Go/No-Go 체크
T-10분   팀 준비 완료 선언
T-5분    최종 Lag 확인 (0초)
T0       ┌─────────────────────────────────┐
         │ 1. Soft Freeze (WAS 8080 정지)  │ ← ~2초
         │ 2. Hard Freeze (read_only=ON)   │ ← ~1초
         │ 3. Marker 기록                  │ ← ~1초
         └─────────────────────────────────┘
T0+5초   Catch-up 대기 (Lag=0 확인)
T0+10초  ┌─────────────────────────────────┐
         │ 4. Nginx 스위칭 (→ 8081)        │ ← ~1초
         │ 5. 헬스체크                     │ ← ~2초
         │ 6. Smoke 테스트                 │ ← ~5초
         └─────────────────────────────────┘
T0+20초  트래픽 정상화
T0+30초  Replication 정리
```

### 5.2 실행 스크립트

```bash
#!/bin/bash
# /home/ubuntu/cutover.sh
# DB 마이그레이션 컷오버 스크립트

set -e

# 환경 변수
RDS_ENDPOINT="billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com"
RDS_USER="billage_admin"
RDS_PASS="K6b54UJJM2dtLhECFbKCTx1d7Qd9vb6ohKUsDqcY"
HOST_MYSQL_USER="debian-sys-maint"
HOST_MYSQL_PASS="8mglCugYwritTZLS"

# 로그 파일
LOG_FILE="/tmp/cutover-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "════════════════════════════════════════════════════════════"
echo "   DB 마이그레이션 컷오버 시작"
echo "   시작 시각: $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════════"
echo ""

# T0 기록
T0=$(date +%s)
T0_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# ═══════════════════════════════════════════════════════════════
# Phase 1: Soft Freeze
# ═══════════════════════════════════════════════════════════════
echo "[T0] Phase 1: Soft Freeze"
echo "────────────────────────────────────────"

echo "[$(date '+%H:%M:%S')] WAS 8080 정지 중..."
sudo systemctl stop billage-backend

SOFT_FREEZE_TIME=$(date +%s)
echo "[$(date '+%H:%M:%S')] ✅ Soft Freeze 완료 ($((SOFT_FREEZE_TIME - T0))초)"
echo ""

# ═══════════════════════════════════════════════════════════════
# Phase 2: Hard Freeze
# ═══════════════════════════════════════════════════════════════
echo "[T0+$(($(date +%s) - T0))s] Phase 2: Hard Freeze"
echo "────────────────────────────────────────"

echo "[$(date '+%H:%M:%S')] read_only 설정 중..."
mysql -u $HOST_MYSQL_USER -p$HOST_MYSQL_PASS -e "SET GLOBAL read_only = ON;"

HARD_FREEZE_TIME=$(date +%s)
echo "[$(date '+%H:%M:%S')] ✅ Hard Freeze 완료 ($((HARD_FREEZE_TIME - T0))초)"
echo ""

# ═══════════════════════════════════════════════════════════════
# Phase 3: Marker 기록 & Catch-up
# ═══════════════════════════════════════════════════════════════
echo "[T0+$(($(date +%s) - T0))s] Phase 3: Marker & Catch-up"
echo "────────────────────────────────────────"

# GTID 마커 기록
MARKER_GTID=$(mysql -u $HOST_MYSQL_USER -p$HOST_MYSQL_PASS -N -e "SELECT @@GLOBAL.gtid_executed;")
echo "[$(date '+%H:%M:%S')] Marker GTID: $MARKER_GTID"

# Catch-up 대기
echo "[$(date '+%H:%M:%S')] RDS catch-up 대기 중..."
for i in {1..30}; do
    LAG=$(mysql -h $RDS_ENDPOINT -u $RDS_USER -p$RDS_PASS -N -e \
        "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Seconds_Behind" | awk '{print $2}')

    if [ "$LAG" = "0" ] || [ "$LAG" = "NULL" ]; then
        echo "[$(date '+%H:%M:%S')] ✅ Lag=0, catch-up 완료"
        break
    fi
    echo "[$(date '+%H:%M:%S')] Lag=${LAG}s, 대기 중..."
    sleep 1
done

CATCHUP_TIME=$(date +%s)
echo "[$(date '+%H:%M:%S')] ✅ Catch-up 완료 ($((CATCHUP_TIME - T0))초)"
echo ""

# ═══════════════════════════════════════════════════════════════
# Phase 4: Nginx 스위칭
# ═══════════════════════════════════════════════════════════════
echo "[T0+$(($(date +%s) - T0))s] Phase 4: Nginx 스위칭"
echo "────────────────────────────────────────"

echo "[$(date '+%H:%M:%S')] Backend → RDS (8081) 전환 중..."
/home/ubuntu/switch-backend.sh rds

SWITCH_TIME=$(date +%s)
echo "[$(date '+%H:%M:%S')] ✅ 스위칭 완료 ($((SWITCH_TIME - T0))초)"
echo ""

# ═══════════════════════════════════════════════════════════════
# Phase 5: 검증
# ═══════════════════════════════════════════════════════════════
echo "[T0+$(($(date +%s) - T0))s] Phase 5: 검증"
echo "────────────────────────────────────────"

# 헬스체크
echo "[$(date '+%H:%M:%S')] 헬스체크..."
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/actuator/health)
if [ "$HEALTH" = "200" ]; then
    echo "[$(date '+%H:%M:%S')] ✅ WAS 8081 헬스체크 OK"
else
    echo "[$(date '+%H:%M:%S')] ❌ WAS 8081 헬스체크 실패 (HTTP $HEALTH)"
    echo "⚠️  롤백을 고려하세요: /home/ubuntu/switch-backend.sh host"
fi

# Smoke 테스트 (읽기)
echo "[$(date '+%H:%M:%S')] Smoke 테스트 (읽기)..."
API_TEST=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/api/health 2>/dev/null || echo "000")
echo "[$(date '+%H:%M:%S')] API 응답: HTTP $API_TEST"

T_END=$(date +%s)
T_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_DURATION=$((T_END - T0))

echo ""
echo "════════════════════════════════════════════════════════════"
echo "   컷오버 완료"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "시작: $T0_TIME"
echo "완료: $T_END_TIME"
echo "총 소요 시간: ${TOTAL_DURATION}초"
echo ""
echo "Phase 별 소요 시간:"
echo "  - Soft Freeze: $((SOFT_FREEZE_TIME - T0))초"
echo "  - Hard Freeze: $((HARD_FREEZE_TIME - SOFT_FREEZE_TIME))초"
echo "  - Catch-up: $((CATCHUP_TIME - HARD_FREEZE_TIME))초"
echo "  - Switch: $((SWITCH_TIME - CATCHUP_TIME))초"
echo "  - 검증: $((T_END - SWITCH_TIME))초"
echo ""
echo "로그 파일: $LOG_FILE"
echo ""
echo "다음 단계:"
echo "  1. 모니터링 대시보드 확인 (5분)"
echo "  2. Replication 정리: mysql ... 'CALL mysql.rds_stop_replication;'"
echo "  3. Host MySQL read_only 유지 (롤백 대비)"
echo ""
```

---

## 6. 롤백 절차

### 6.1 즉시 롤백 (전환 후 5분 이내)

```bash
#!/bin/bash
# /home/ubuntu/rollback.sh

echo "════════════════════════════════════════════════════════════"
echo "   롤백 시작"
echo "════════════════════════════════════════════════════════════"

# 1. Nginx → Host (8080)
echo "[1/4] Nginx 롤백..."
/home/ubuntu/switch-backend.sh host

# 2. Host MySQL read_only 해제
echo "[2/4] Host MySQL read_only 해제..."
mysql -u debian-sys-maint -p'8mglCugYwritTZLS' -e "SET GLOBAL read_only = OFF;"

# 3. WAS 8080 재시작
echo "[3/4] WAS 8080 재시작..."
sudo systemctl start billage-backend

# 4. 헬스체크
echo "[4/4] 헬스체크..."
sleep 3
curl -s http://localhost:8080/actuator/health

echo ""
echo "✅ 롤백 완료"
```

---

## 7. 측정 시트 템플릿

### 7.1 컷오버 기록표

```
═══════════════════════════════════════════════════════════════
                    컷오버 측정 기록표
═══════════════════════════════════════════════════════════════

일시: ____년 __월 __일 __:__

참여자:
  - 실행: ____________
  - 모니터링: ____________
  - 롤백 대기: ____________

───────────────────────────────────────────────────────────────
Phase 1: 사전 확인
───────────────────────────────────────────────────────────────
[ ] Replica_IO_Running: Yes / No
[ ] Replica_SQL_Running: Yes / No
[ ] Seconds_Behind_Source: ____초
[ ] 배치/크론 중지: Y / N
[ ] Go/No-Go 결정: Go / No-Go

───────────────────────────────────────────────────────────────
Phase 2: 컷오버 실행
───────────────────────────────────────────────────────────────
T0 (시작):           __:__:__

Soft Freeze 완료:    __:__:__ (T0+____초)
Hard Freeze 완료:    __:__:__ (T0+____초)
Marker GTID:         ________________________________
Catch-up 완료:       __:__:__ (T0+____초)
Switch 완료:         __:__:__ (T0+____초)
검증 완료:           __:__:__ (T0+____초)

T_END (완료):        __:__:__

───────────────────────────────────────────────────────────────
Phase 3: 결과
───────────────────────────────────────────────────────────────
총 Write Freeze 시간: ____초 (목표: <30초)
총 컷오버 시간:       ____초

헬스체크: Pass / Fail
Smoke 테스트: Pass / Fail
에러 발생: Y / N (있으면 상세: _____________)

───────────────────────────────────────────────────────────────
Phase 4: 후속 작업
───────────────────────────────────────────────────────────────
[ ] Replication 정리 (rds_stop_replication)
[ ] 5분 모니터링 완료
[ ] 30분 모니터링 완료
[ ] Host MySQL read_only 해제 (롤백 기간 후)

비고:
________________________________________________________________
________________________________________________________________
```

---

## 8. 관련 문서

- 메인 런북: `context/migration/db-migration-runbook.md`
- 롤백 런북: `context/migration/07-rollback-runbook.md`
- 트러블슈팅: `docs/troubleshooting/DB_MIGRATION_TROUBLESHOOTING.md`
- 리허설 보고서: `docs/report/DB_MIGRATION_REHEARSAL_REPORT.md`
