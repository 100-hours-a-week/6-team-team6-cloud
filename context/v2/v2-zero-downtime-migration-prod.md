# v2 무중단 인프라 마이그레이션 가이드 (Prod)

> 작성일: 2026-03-01
> 대상: v1 (단일 EC2) → v2 (ALB + ASG + RDS)
> 목표: 사용자 체감 다운타임 0 (제로 다운타임)
> 도메인: `www.billages.com`

---

## 중단 vs 무중단 비교

| | 중단 마이그레이션 | 무중단 마이그레이션 |
|---|---|---|
| **사용자 체감** | 점검 페이지 (수 분) | 거의 없음 |
| **DB 이관** | Replica → Write Freeze → v1 정지 | Replica → Write Freeze → **v1도 RDS 전환** |
| **트래픽 전환** | v1 정지 → DNS 변경 | **v1/v2 동시 가동** 중 DNS 변경 |
| **WebSocket** | 재연결 필요 (중단) | 기존 연결 유지, 재연결 시 v2로 |
| **롤백** | v1 재시작 + DNS 원복 | DNS 원복만 (v1이 계속 가동 중) |
| **복잡도** | 낮음 | 높음 |
| **체크리스트** | [v2-migration-checklist-prod.md](./v2-migration-checklist-prod.md) | 이 문서 |

---

## 무중단의 핵심 원리

```
┌──────────────────────────────────────────────────────────────────────┐
│  핵심: v1과 v2가 동시에 같은 RDS + RabbitMQ를 바라보는 상태를 만든다  │
└──────────────────────────────────────────────────────────────────────┘

[Before]                              [After DB + Broker 통합]

 v1 EC2                                v1 EC2
 ├─ Nginx                             ├─ Nginx
 ├─ Backend → localhost MySQL          ├─ Backend ──┐
 ├─ STOMP  → SimpleBroker (인메모리)   ├─ STOMP ────┤
 ├─ Frontend                           ├─ Frontend  │
 └─ AI                                └─ AI        │
                                                     ▼
                                       ┌──────────────────────┐
 v2 ALB                    v2 ALB     │  RDS      RabbitMQ   │
 ├─ BE ASG → RDS           ├─ BE ASG──┘  MySQL    STOMP Relay │
 ├─ STOMP  → RabbitMQ      ├─ STOMP──────────────┘           │
 ├─ FE ASG                 ├─ FE ASG                          │
 └─ AI ASG                └─ AI ASG  └──────────────────────┘

→ 공유 DB: 어느 쪽에서 쓰든 데이터 정합성 유지
→ 공유 Broker: v1 유저와 v2 유저 간 실시간 채팅 메시지 전달 가능
→ DNS가 어디를 가리키든 서비스 + 채팅 모두 정상 동작
→ 롤백 = DNS만 원복 (v1이 살아있으므로 즉시)
```

---

## 전제 조건

- [x] v2 Terraform 인프라 배포 완료 (ALB, ASG, RDS, RabbitMQ, NAT)
- [x] v2.billages.com → ALB 정상 응답 확인
- [x] Dev 환경 v2 전환 완료 및 안정화 확인
- [ ] v1과 v2의 **JWT Secret 동일** 확인 (v1 토큰이 v2에서도 유효해야 함)
- [ ] v2 Backend CORS에 `www.billages.com` 포함 확인
- [ ] v1 Backend가 **외부 MySQL(RDS) 연결 가능**한지 사전 테스트
- [ ] v1 Backend의 **STOMP Broker 설정이 환경변수/설정으로 전환 가능**한지 확인 (BE팀 협의)
- [ ] v1 → RabbitMQ 네트워크 연결 가능한지 확인 (SG, port 61613)
- [ ] DNS TTL 60초로 사전 변경 완료 (D-2)
- [ ] 롤백 런북 팀 전원 숙지

---

## Phase 0: 사전 준비 (D-7 ~ D-2)

> [중단 마이그레이션 체크리스트](./v2-migration-checklist-prod.md)의 Phase 0과 동일.
> 0-1 ~ 0-6 항목을 그대로 수행한다.

### 0-7. 무중단 전용 추가 확인 — DB 연결

- [ ] v1 Backend의 DB 접속 설정 변경 방법 확인
  ```bash
  # v1 EC2에서 Spring Boot 설정 파일 위치 확인
  cat /opt/billage/backend/application.yml | grep datasource
  # 또는 환경변수 방식이면
  cat /etc/systemd/system/billage-backend.service | grep DATASOURCE
  ```
- [ ] v1 Backend → RDS 연결 테스트 (설정은 변경하지 않고 접속만 확인)
  ```bash
  # v1 EC2에서 RDS endpoint로 직접 mysql 접속 테스트
  mysql -h <rds-endpoint> -u billage_admin -p -e "SELECT 1"
  ```
- [ ] v1↔RDS 간 Security Group 허용 확인
  - RDS SG Inbound: v1 EC2의 SG 또는 IP에서 3306 허용
- [ ] JWT Secret 일치 확인
  ```bash
  # v1 설정
  grep -i jwt /opt/billage/backend/application.yml
  # v2 SSM
  aws ssm get-parameter --name /billage/prod/be/jwt-secret --with-decryption
  # 두 값이 동일해야 함
  ```

### 0-8. 무중단 전용 추가 확인 — STOMP Broker (RabbitMQ) ★

> v1/v2 혼재 구간에서 채팅 실시간 전달을 보장하려면,
> v1도 v2와 같은 RabbitMQ를 STOMP Broker로 사용해야 한다.

#### BE팀 확인 사항

- [ ] v1 Backend의 STOMP Broker 설정 방식 확인
  ```bash
  # v1 EC2에서
  # 코드에서 broker 설정 확인
  grep -r "enableSimpleBroker\|enableStompBrokerRelay" /opt/billage/backend/
  # 환경변수 분기 여부 확인
  grep -r "STOMP\|BROKER\|RABBITMQ" /opt/billage/backend/
  ```
- [ ] STOMP Broker 전환 방식 판단

  | 결과 | 전환 방법 | 난이도 |
  |------|----------|--------|
  | 환경변수로 Simple/Relay 분기 가능 | 설정만 변경 | 쉬움 |
  | v2 코드에 Relay 지원 코드 있음, v1 미배포 | v1에 최신 코드 배포 후 설정 변경 | 보통 |
  | SimpleBroker 하드코딩, Relay 코드 없음 | 코드 변경 + 빌드 + 배포 필요 | 어려움 (Plan B 권장) |

#### 네트워크 확인

- [ ] v1 EC2 → RabbitMQ 네트워크 연결 테스트
  ```bash
  # v1 EC2에서 (RabbitMQ는 v2 Private Subnet에 위치)
  # STOMP 포트
  telnet <rabbitmq-private-ip> 61613
  # AMQP 포트 (Spring이 내부적으로 사용할 수 있음)
  telnet <rabbitmq-private-ip> 5672
  ```
- [ ] RabbitMQ Security Group에 v1 EC2 inbound 허용 추가
  ```hcl
  # v2/envs/prod/main.tf — RabbitMQ SG에 추가
  ingress {
    description = "STOMP from v1 EC2"
    from_port   = 61613
    to_port     = 61613
    protocol    = "tcp"
    cidr_blocks = ["<v1-ec2-private-ip>/32"]
  }
  ingress {
    description = "AMQP from v1 EC2"
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = ["<v1-ec2-private-ip>/32"]
  }
  ```

#### STOMP Destination 호환성 확인

- [ ] v1과 v2의 STOMP Destination 구조가 동일한지 확인
  ```
  Subscribe: /topic/chatrooms/{chatroomId}  ← 양쪽 동일?
  Subscribe: /user/queue/chat-inbox         ← 양쪽 동일?
  Publish:   /app/chat/join                 ← 양쪽 동일?
  Publish:   /app/chat/send                 ← 양쪽 동일?
  Publish:   /app/chat/read                 ← 양쪽 동일?
  ```
- [ ] RabbitMQ에서 사용하는 Exchange/Queue 이름이 v2와 호환되는지 확인

---

1## Phase 1: DB + Message Broker 통합 (v1 + v2 → 공유 RDS + RabbitMQ)

> 이 Phase가 무중단 마이그레이션의 핵심이다.
> 목표: v1과 v2 모두 같은 RDS + 같은 RabbitMQ를 바라보게 만든다.

### 1-1. Replication 설정 (사전 수행, 서비스 무영향)

- [ ] v1 Host MySQL에서 `mysqldump --single-transaction` + GTID 기준점 확보
  ```bash
  mysqldump -u billage_user -p \
    --single-transaction \
    --routines --triggers --events \
    --set-gtid-purged=ON \
    billage | gzip > /tmp/billage-prod-$(date +%Y%m%d).sql.gz
  ```
- [ ] RDS에 덤프 import
- [ ] RDS를 Host MySQL의 external replica로 설정
  ```sql
  CALL mysql.rds_set_external_source_gtid_purged('<gtid_set>');
  CALL mysql.rds_set_external_master_with_auto_position(
    '<host-mysql-ip>', 3306, 'repl_user', '<password>', 0
  );
  CALL mysql.rds_start_replication;
  ```
- [ ] Replication 정상 확인 (`Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`)

### 1-2. Lag 모니터링 & Catch-up

- [ ] `Seconds_Behind_Source` = 0 안정적 유지 확인 (최소 1분)
  ```bash
  watch -n 5 "mysql -h <rds-endpoint> -u billage_admin -p<pwd> \
    -e 'SHOW REPLICA STATUS\G' 2>/dev/null | grep -E 'Seconds_Behind|Running|Error'"
  ```

### 1-3. Write Freeze & Replication 정리 (중단 ~수 초)

> 이 구간만 쓰기가 막힌다. 읽기는 계속 가능.

- [ ] **팀 공지**: "DB 전환 진행 중 (쓰기 일시 중단, 수 초 소요)"
- [ ] Host MySQL read_only 설정
  ```sql
  SET GLOBAL read_only = ON;
  SET GLOBAL super_read_only = ON;
  ```
- [ ] `Seconds_Behind_Source` = 0 최종 확인
- [ ] Replication 정리
  ```sql
  CALL mysql.rds_stop_replication;
  CALL mysql.rds_reset_external_master;
  ```
- [ ] 데이터 건수 검증 (v1 스냅샷과 비교)

### 1-4. v1 Backend → RDS + RabbitMQ 동시 전환 ★

> **이 단계가 유일한 순단 구간이다** (v1 Backend 재시작 ~10-30초)
> v1 Frontend는 계속 서빙되고, API 호출만 잠깐 502가 발생한다.
> DB와 STOMP Broker 설정을 한 번에 변경하여 **재시작을 1회로** 묶는다.

- [ ] v1 Backend 설정 변경 (**DB + STOMP Broker 동시**)
  ```bash
  # 방법은 v1 설정 방식에 따라 다름

  # ── DB URL 변경 ──
  # A) application.yml 직접 수정
  sudo sed -i 's|jdbc:mysql://localhost:3306|jdbc:mysql://<rds-endpoint>:3306|' \
    /opt/billage/backend/application.yml

  # B) systemd 환경변수 방식
  sudo sed -i 's|SPRING_DATASOURCE_URL=.*|SPRING_DATASOURCE_URL=jdbc:mysql://<rds-endpoint>:3306/billage|' \
    /etc/systemd/system/billage-backend.service

  # ── STOMP Broker 변경 (SimpleBroker → RabbitMQ) ──
  # 환경변수 분기 방식인 경우 (예시)
  # STOMP_BROKER_TYPE=relay
  # RABBITMQ_HOST=<rabbitmq-private-ip>
  # RABBITMQ_STOMP_PORT=61613
  # RABBITMQ_USER=billage
  # RABBITMQ_PASS=<password>

  # systemd 환경변수 추가/변경
  sudo sed -i '/\[Service\]/a Environment="STOMP_BROKER_TYPE=relay"\nEnvironment="RABBITMQ_HOST=<rabbitmq-private-ip>"\nEnvironment="RABBITMQ_STOMP_PORT=61613"\nEnvironment="RABBITMQ_USER=billage"\nEnvironment="RABBITMQ_PASS=<password>"' \
    /etc/systemd/system/billage-backend.service

  sudo systemctl daemon-reload
  ```

  > **참고**: 위 환경변수명은 예시. 실제 변수명은 BE팀 코드에 따라 다름.
  > Phase 0-8에서 확인한 설정 방식에 맞게 변경할 것.

- [ ] v1 Backend 재시작 (**1회만**)
  ```bash
  sudo systemctl restart billage-backend
  ```
- [ ] v1 Backend 헬스체크 확인 (재시작 완료 대기)
  ```bash
  # 최대 30초 대기
  for i in $(seq 1 30); do
    if curl -sf https://www.billages.com/api/actuator/health > /dev/null 2>&1; then
      echo "✅ v1 Backend UP (${i}초)"
      break
    fi
    echo "⏳ 대기 중... (${i}초)"
    sleep 1
  done
  ```
- [ ] Host MySQL read_only 해제 (롤백 대비, 데이터는 더 이상 쓰이지 않음)
  ```sql
  SET GLOBAL super_read_only = OFF;
  SET GLOBAL read_only = OFF;
  ```

### 1-5. 공유 DB + 공유 Broker 검증

> v1과 v2 모두 같은 RDS + 같은 RabbitMQ를 바라보는지 확인한다.

#### DB 검증

- [ ] v1에서 테스트 데이터 생성 (게시글 작성 등)
- [ ] v2에서 해당 데이터 조회 확인
  ```bash
  curl https://v2.billages.com/api/posts | jq '.[-1]'
  ```
- [ ] v2에서 테스트 데이터 생성
- [ ] v1에서 해당 데이터 조회 확인

#### STOMP Broker 검증 (채팅 Cross-Delivery) ★

> 이 검증이 통과해야 진짜 무중단 채팅이 보장된다.

- [ ] **v1 → v2 실시간 채팅 테스트**
  1. 브라우저 A: `www.billages.com` 접속 (v1 경유) → 채팅방 입장
  2. 브라우저 B: `v2.billages.com` 접속 (v2 경유) → 같은 채팅방 입장
  3. 브라우저 A에서 메시지 전송
  4. **브라우저 B에서 새로고침 없이 실시간 수신 확인** ← 핵심
- [ ] **v2 → v1 실시간 채팅 테스트** (반대 방향)
  1. 브라우저 B에서 메시지 전송
  2. **브라우저 A에서 새로고침 없이 실시간 수신 확인**
- [ ] 채팅 인박스 (`/user/queue/chat-inbox`) 양쪽에서 업데이트 확인
- [ ] **팀 공지**: "DB + 메시지 브로커 전환 완료, 정상 서비스 중"

#### 검증 실패 시 → Plan B로 전환

> Cross-Delivery 테스트 실패 시, STOMP Broker 통합을 포기하고 Plan B를 적용한다.
> [Plan B: STOMP Broker 통합 불가 시](#plan-b-stomp-broker-통합-불가-시) 참고.

---

## Phase 2: DNS 전환 (트래픽 스위칭)

> v1과 v2 모두 정상 동작 + 같은 DB를 바라보는 상태에서 DNS를 전환한다.
> v1 서비스를 정지하지 않으므로, DNS 전파 중에도 양쪽 모두 정상 서빙.

### 2-1. 전환 전 최종 확인

- [ ] v1 정상: `curl https://www.billages.com/api/actuator/health` → 200
- [ ] v2 정상: `curl https://v2.billages.com/api/actuator/health` → 200
- [ ] 양쪽 모두 같은 DB 데이터 반환 확인
- [ ] ALB Target Group 모두 healthy

### 2-2. DNS 즉시 전환

> WebSocket/STOMP 특성상 점진적 가중치 전환보다 **즉시 전환**을 권장한다.
> (이유는 [Phase 3: WebSocket/STOMP 고려사항](#phase-3-webstomp-고려사항-) 참고)

- [ ] `www.billages.com` A 레코드 → ALB Alias로 변경
  ```bash
  aws route53 change-resource-record-sets --hosted-zone-id <zone-id> \
    --change-batch '{
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "www.billages.com",
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": "<alb-hosted-zone-id>",
            "DNSName": "<alb-dns-name>",
            "EvaluateTargetHealth": true
          }
        }
      }]
    }'
  ```
- [ ] DNS 전파 확인
  ```bash
  # 60~120초 내 ALB DNS가 반환되어야 함
  watch -n 10 "dig www.billages.com +short"
  ```

### DNS 전파 중 상태 (60~120초)

```
이 구간에서 일어나는 일:

[DNS 캐시 만료 전 클라이언트]  →  v1 EIP  →  v1 (정상 동작!)
[DNS 캐시 만료 후 클라이언트]  →  ALB     →  v2 (정상 동작!)

→ 양쪽 모두 같은 RDS를 바라보므로 데이터 정합성 문제 없음
→ 사용자는 아무것도 모른 채 v2로 자연스럽게 이동
```

### 2-3. 전환 직후 확인

- [ ] `https://www.billages.com` 접속 → v2에서 서빙 확인
- [ ] `https://www.billages.com/api/actuator/health` → 200 OK
- [ ] `https://www.billages.com/ai/health` → 200 OK
- [ ] WebSocket 연결 테스트 (채팅 기능)

---

## Phase 3: WebSocket/STOMP 고려사항 ★

> 이 섹션이 무중단 마이그레이션에서 가장 중요한 부분이다.

### RabbitMQ 공유로 해결되는 것

Phase 1-4에서 v1도 RabbitMQ를 사용하도록 전환했으므로:

```
[RabbitMQ 공유 상태]

 v1 유저 A ─── STOMP ──→ v1 Backend ──→ RabbitMQ ──→ v2 Backend ──→ v2 유저 B ✅
 v2 유저 B ─── STOMP ──→ v2 Backend ──→ RabbitMQ ──→ v1 Backend ──→ v1 유저 A ✅
```

| 상황 | 실시간 전달 | DB 저장 | 비고 |
|------|-----------|--------|------|
| v1 유저 → v1 유저 | O | O | RabbitMQ 경유 |
| v2 유저 → v2 유저 | O | O | RabbitMQ 경유 |
| v1 유저 → v2 유저 | **O** | O | **RabbitMQ가 중계** |
| v2 유저 → v1 유저 | **O** | O | **RabbitMQ가 중계** |

→ DNS 전파 중 v1/v2 혼재 구간에서도 **채팅이 완벽하게 동작한다.**

### STOMP 클라이언트 재연결 흐름

```
1. DNS 변경 (www.billages.com → ALB)

2. 기존 WebSocket 연결은 v1 EIP와 직접 맺어져 있음
   → DNS 변경은 기존 TCP 연결에 영향 없음
   → 사용자가 페이지에 머물면 v1 연결 유지
   → v1도 RabbitMQ를 쓰므로 채팅은 정상 동작

3. 다음 상황에서 v2로 전환됨:
   a) 페이지 새로고침 → 새 WebSocket 연결 → DNS 조회 → v2 ALB
   b) 네트워크 끊김 → STOMP reconnect (5초 후) → DNS 조회 → v2 ALB
   c) 채팅방 나갔다 다시 입장 → 새 연결 → v2 ALB

4. STOMP reconnect 시 자동 처리:
   - STOMP CONNECT (Authorization 헤더)
   - /topic/chatrooms/{id} 재구독
   - /app/chat/join 재발행 → membershipId 획득
   - pending 큐 flush

5. v1에 남은 연결은 시간이 지나면 자연스럽게 v2로 이동
   → 강제로 끊을 필요 없음
```

### WebSocket ALB 라우팅 확인

> 현재 ALB 설정에서 `/ws/*` 패턴을 사용하고 있으나,
> 프론트엔드는 `/ws`로 연결하므로 패턴 수정이 필요할 수 있다.

- [ ] ALB Listener Rule 확인: `/ws` 경로가 매칭되는지
  ```bash
  aws elbv2 describe-rules --listener-arn <https-listener-arn> \
    --query 'Rules[?Priority==`90`].Conditions'
  ```
- [ ] 필요 시 path pattern을 `/ws`와 `/ws/*` 모두 포함하도록 수정
  ```hcl
  # v2/envs/prod/main.tf
  condition {
    path_pattern {
      values = ["/ws", "/ws/*"]
    }
  }
  ```
- [ ] 단, 현재는 API 서브도메인 host header 룰(Priority 100)이 커버하므로 기능상 문제 없음

---

## Phase 4: 전환 후 검증

### 4-1. 기능 테스트 (E2E)

- [ ] 회원가입 / 로그인 (JWT 발급 — v2에서 새로 발급)
- [ ] **v1에서 발급한 JWT로 v2 API 호출** (토큰 호환성 확인)
- [ ] 게시글 CRUD
- [ ] 이미지 업로드 (S3 Presigned URL)
- [ ] **채팅 WebSocket 연결** (`wss://www.billages.com/ws`)
  - [ ] 메시지 송수신
  - [ ] 페이지 새로고침 후 재연결
  - [ ] 읽음 처리 (`/app/chat/read`)
- [ ] AI 기능 호출 (`/ai/*` 경로)
- [ ] 채팅 인박스 실시간 업데이트 (`/user/queue/chat-inbox`)

### 4-2. 성능 검증

- [ ] 응답 시간 비교 (v1 기준선 vs v2 실측)
  ```bash
  curl -w "DNS: %{time_namelookup}s, Connect: %{time_connect}s, TTFB: %{time_starttransfer}s, Total: %{time_total}s\n" \
    -o /dev/null -s https://www.billages.com/api/actuator/health
  ```
- [ ] ALB CloudWatch 지표 확인
  - TargetResponseTime (p50, p95, p99)
  - HTTPCode_Target_5XX_Count
  - HealthyHostCount
  - ActiveConnectionCount (WebSocket 연결 수)

### 4-3. 인프라 모니터링

- [ ] Prometheus → v2 인스턴스 메트릭 수집 정상
- [ ] Grafana 대시보드에 Prod v2 데이터 표시
- [ ] RDS CloudWatch (CPUUtilization, FreeStorageSpace, DatabaseConnections)

---

## Phase 5: v1 정리 & 안정화 (D+0 ~ D+14)

### 5-1. v1 서비스 정지 (DNS 전파 완료 확인 후)

> v1은 DNS 전환 후에도 계속 가동 중이다. 충분히 안정화된 후 정지한다.

- [ ] DNS 전파 완료 확인 (모든 resolve가 ALB를 가리킴)
  ```bash
  # 여러 DNS 서버에서 확인
  dig @8.8.8.8 www.billages.com +short
  dig @1.1.1.1 www.billages.com +short
  ```
- [ ] v2 트래픽만 들어오는지 확인 (v1 nginx access log에 새 요청 없음)
  ```bash
  # v1 EC2에서
  tail -f /var/log/nginx/access.log
  # 1~2분간 새 요청이 없으면 안전
  ```
- [ ] v1 서비스 순차 정지
  ```bash
  sudo systemctl stop billage-backend
  sudo systemctl stop billage-frontend
  sudo systemctl stop billage-ai
  sudo systemctl stop nginx
  ```

### 5-2. 안정화 (중단 마이그레이션과 동일)

> [v2-migration-checklist-prod.md](./v2-migration-checklist-prod.md)의 Phase 5 참고.

- [ ] RDS `deletion_protection` 활성화
- [ ] CloudWatch 알람 설정
- [ ] v1 EC2 인스턴스 **중지 (Stop)** — 삭제하지 않음 (2주 유지)
- [ ] v1 EIP 유지 (롤백 대비)

---

## 롤백 전략

> 무중단 마이그레이션의 가장 큰 장점: **각 Phase별로 롤백이 쉽다.**

### Phase별 롤백

| Phase | 상태 | 롤백 방법 | 소요 시간 |
|-------|------|----------|----------|
| Phase 1-1~1-2 | Replication 중 | Replication 정리, 아무 변경 없음 | 즉시 |
| Phase 1-3 | Write Freeze 중 | `read_only OFF` 해제 | 즉시 |
| Phase 1-4 | v1 Backend → RDS + RabbitMQ | v1 Backend 설정 원복 (DB: localhost, STOMP: simple) + 재시작 | ~30초 |
| Phase 2 | DNS 전환 완료 | Route53 → v1 EIP로 원복 | ~60초 |
| Phase 5 | v1 정지 후 | v1 서비스 재시작 + DNS 원복 | ~2분 |

### Phase 1-4 롤백 (v1 Backend → localhost MySQL + SimpleBroker 원복)

```bash
# v1 EC2 SSH

# 1. DB 설정 localhost로 원복
sudo sed -i 's|jdbc:mysql://<rds-endpoint>:3306|jdbc:mysql://localhost:3306|' \
  /opt/billage/backend/application.yml

# 2. STOMP Broker 설정 원복 (환경변수 방식인 경우)
# systemd에서 추가했던 STOMP/RABBITMQ 환경변수 제거
sudo sed -i '/STOMP_BROKER_TYPE\|RABBITMQ_HOST\|RABBITMQ_STOMP_PORT\|RABBITMQ_USER\|RABBITMQ_PASS/d' \
  /etc/systemd/system/billage-backend.service
sudo systemctl daemon-reload

# 3. Backend 재시작
sudo systemctl restart billage-backend

# 4. 헬스체크 확인
curl https://www.billages.com/api/actuator/health
```

> **주의**: Phase 1-4 이후 v2에서 쓰여진 데이터는 RDS에만 있고 localhost MySQL에는 없음.
> 롤백 시 RDS → Host MySQL 역동기화가 필요할 수 있음.

### Phase 2 롤백 (DNS 원복)

```bash
# Route53 → v1 EIP로 원복 (v1이 계속 가동 중이므로 즉시 복구)
aws route53 change-resource-record-sets --hosted-zone-id <zone-id> \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "www.billages.com",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [{"Value": "<v1-EIP>"}]
      }
    }]
  }'
```

> **핵심 장점**: v1이 살아있으므로 DNS만 돌리면 즉시 복구.
> 중단 마이그레이션처럼 v1 서비스를 재시작할 필요가 없다.

### 즉시 롤백 트리거

| 조건 | 임계값 | 조치 |
|------|--------|------|
| 5xx 에러율 | > 5% 3분 지속 | DNS 원복 |
| RDS 연결 불가 | 1분 지속 | DNS 원복 |
| ALB healthy Target 0 | 2분 지속 | DNS 원복 |
| WebSocket 연결 실패 | 다수 보고 | DNS 원복 |

---

## 리스크 & 대응

| 리스크 | 영향 | 대응 |
|--------|------|------|
| v1 Backend 재시작 실패 (Phase 1-4) | v1 API ~30초 502 | RDS + RabbitMQ 연결 사전 테스트로 예방, 실패 시 원복 |
| v1 → RabbitMQ 연결 실패 | v1 채팅 불가 | Phase 0-8에서 네트워크/SG 사전 테스트, 실패 시 Plan B |
| STOMP Broker 전환이 코드 변경 필요 | v1 코드 배포 필요 | BE팀과 사전 협의, 불가 시 Plan B 적용 |
| DNS 전파 지연 (2분 초과) | 일부 유저 v1 접속 지속 | v1도 정상 동작 + RabbitMQ 공유 → 문제 없음 |
| v1/v2 혼재 중 채팅 | RabbitMQ 공유 시 문제 없음 | Phase 1-5 Cross-Delivery 테스트로 사전 검증 |
| JWT Secret 불일치 | v1 토큰으로 v2 인증 실패 | Phase 0에서 반드시 검증 |
| RDS SG에 v1 IP 미허용 | v1 Backend → RDS 연결 실패 | Phase 0에서 사전 테스트 |
| v1 Backend 설정 방식 다름 | sed 명령이 안 맞음 | Phase 0에서 설정 파일 구조 확인, 수동 변경 방법 준비 |

---

## 예상 소요 시간

| 단계 | 예상 시간 | 서비스 영향 |
|------|----------|-----------|
| Phase 0: 사전 준비 | 2~3시간 (D-7~D-2) | 없음 |
| Phase 1-1~1-2: Replication | 1~2시간 (사전) | 없음 |
| Phase 1-3: Write Freeze | **~10초** | 쓰기만 불가 (읽기 정상) |
| Phase 1-4: v1 Backend 재시작 (DB+Broker) | **~10-30초** | v1 API만 502 (Frontend 정상) |
| Phase 1-5: 공유 DB + Broker 검증 | 10분 | 없음 (채팅 Cross-Delivery 테스트 포함) |
| Phase 2: DNS 전환 | 60~120초 | 없음 (양쪽 정상) |
| Phase 4: 검증 | 30~60분 | 없음 |
| **총 사용자 체감 영향** | **~30초** | v1 Backend 재시작 구간만 |

---

## 역할 분담 (예시)

| 역할 | 담당 | 책임 |
|------|------|------|
| **총괄** | DevOps Lead | Go/No-Go 판단, 롤백 결정 |
| **DB+Broker 통합** | DevOps | Replication, Write Freeze, v1→RDS+RabbitMQ 전환 |
| **DNS 전환** | DevOps | Route53 변경, 전파 확인 |
| **기능 테스트** | Backend/Frontend/AI | E2E, 채팅 WebSocket, JWT 호환 |
| **채팅 테스트** | Frontend | WebSocket 재연결, STOMP 동작 확인 |
| **모니터링** | DevOps | Grafana/CloudWatch 실시간 감시 |

---

## 참고: 점진적 가중치 전환 (옵션)

> WebSocket/STOMP 때문에 즉시 전환을 권장하지만,
> 채팅 기능이 중요하지 않거나 일시적 gap을 수용할 수 있다면 점진적 전환도 가능하다.

```
Route53 Weighted Routing:

┌─────────┬────────────┬────────────┬───────────┬──────────────────┐
│  단계   │ v1 가중치  │ v2 가중치  │ 관찰 시간 │    롤백 기준     │
├─────────┼────────────┼────────────┼───────────┼──────────────────┤
│ 1단계   │     90     │     10     │   30분    │ 5xx > 5%         │
│ 2단계   │     50     │     50     │   1시간   │ 5xx > 3%         │
│ 3단계   │     10     │     90     │   1시간   │ 5xx > 1%         │
│ 4단계   │      0     │    100     │     -     │ 완료             │
└─────────┴────────────┴────────────┴───────────┴──────────────────┘

참고:
- v1도 RabbitMQ를 공유하는 경우, 점진적 전환에서도 채팅이 정상 동작함
- RabbitMQ 공유가 안 되는 경우(Plan B), 각 단계에서 채팅 gap 발생 가능
- 총 전환 시간: ~2.5시간
```

---

## Plan B: STOMP Broker 통합 불가 시

> v1 Backend 코드가 SimpleBroker로 하드코딩되어 있거나,
> RabbitMQ Relay 전환에 코드 변경 + 배포가 필요하여 리스크가 큰 경우.
> 마이그레이션 직전에 v1 코드를 변경하는 건 새로운 변수를 만드는 것이므로,
> 안전하게 Plan B를 선택할 수 있다.

### Plan B 전략: 채팅만 잠시 점검

```
DB는 무중단 전환 (공유 RDS) + 채팅만 짧은 점검 구간을 둔다.

1. Phase 1-1~1-3: DB Replication + Write Freeze (기존과 동일)
2. Phase 1-4: v1 Backend → RDS만 전환 (STOMP은 SimpleBroker 유지)
3. 팀 공지: "채팅 기능 잠시 점검 중 (약 3분)"
4. Phase 2: DNS 즉시 전환
5. DNS 전파 대기 (~120초)
   → 이 구간에서 v1/v2 간 채팅 cross-delivery 안 됨 (DB에는 저장)
6. v1 트래픽 소멸 확인 후 공지: "채팅 기능 복구 완료"
```

### Plan B의 사용자 체감

```
┌───────────────┬─────────────────────────────────────────┐
│    구간       │             사용자 체감                  │
├───────────────┼─────────────────────────────────────────┤
│ DB 전환       │ v1 API 502 (~10-30초)                   │
│ DNS 전파 중   │ API/페이지: 정상 (양쪽 공유 DB)          │
│               │ 채팅: 실시간 전달 일부 누락 (~2분)       │
│               │       → DB에는 저장, 새로고침 시 보임    │
│ DNS 전파 완료 │ 모든 기능 정상                           │
└───────────────┴─────────────────────────────────────────┘

총 영향: API ~30초 502 + 채팅 ~2분 실시간 gap
         (사이트 자체는 중단되지 않음)
```

### Plan B vs 완전 무중단 비교

| | 완전 무중단 (RabbitMQ 공유) | Plan B (SimpleBroker 유지) |
|---|---|---|
| v1 코드 변경 | 필요할 수 있음 | 불필요 |
| 채팅 영향 | 없음 | ~2분 실시간 gap |
| API 영향 | ~30초 (재시작) | ~30초 (재시작) |
| 사전 준비 | SG 변경 + BE팀 협의 | DB 전환만 |
| 리스크 | v1 STOMP 설정 변경 리스크 | 낮음 |
| 추천 상황 | 환경변수 분기 가능한 경우 | 코드 변경이 필요한 경우 |
