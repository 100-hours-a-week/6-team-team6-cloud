# Billage v2 Redis 도입 계획서

## 1. 개요

Billage v2에서 백엔드 인스턴스를 단일 서버에서 ASG 기반 다중 인스턴스(1~6개)로 확장하면서, 지금까지 단일 인스턴스 내에서만 유지되던 채팅 메시지와 상태 정보가 **네트워크를 통해 인스턴스 간에 공유되어야 하는 근본적인 변화**가 생긴다. Redis는 이러한 분산 시스템에서의 상태 공유 문제를 해결하는 핵심 인프라이며, 특히 채팅 기능의 안정적인 멀티캐스팅을 가능하게 한다.

Redis 도입의 가장 중요한 목표는 **Chat Pub/Sub을 통한 메시지 브로드캐스트**이다. 나머지 기능들(세션 저장, 응답 캐싱)은 선택적이며, 점진적으로 도입할 수 있다.

---

## 2. 현재 상태 (AS-IS): v1 아키텍처

### 2.1 기본 구성

- **백엔드 서버**: 단일 EC2 인스턴스로 운영
- **메시지 저장소**: WebSocket 연결이 모두 같은 프로세스 내에서 관리되므로, 메모리 또는 직접 DB 쓰기 방식 사용
- **세션 관리**: JWT 기반 stateless 인증 — 서버 측 세션 저장소 불필요
- **캐싱**: 캐싱 레이어 미존재

### 2.2 단일 인스턴스에서 Pub/Sub이 불필요한 이유

사용자 A가 연결한 WebSocket과 사용자 B가 연결한 WebSocket이 **같은 프로세스 내의 이벤트 루프에서 관리**되기 때문에, 메모리나 로컬 메시지 큐만으로도 메시지 전달이 가능하다. 외부 메시지 브로커가 필요 없다.

```
User A ──── WebSocket ──── [Backend Instance 1 (포트 8080)]
                               ↓
                          메모리 내 채팅방 관리
                               ↓
User B ──── WebSocket ──── [Backend Instance 1 (포트 8080)]
```

이 구조에서는 모든 메시지가 같은 메모리 공간을 공유한다.

---

## 3. 목표 상태 (TO-BE): v2 아키텍처

### 3.1 ElastiCache Redis 스펙 (300K MAU)

| 항목 | 값 | 근거 |
|------|-----|------|
| Redis 버전 | 7.0 | 최신 안정 버전, 성능 최적화 |
| 인스턴스 타입 | cache.t4g.small (Dev) / cache.t4g.medium (Prod 권장) | Dev: 1.37GB 메모리, Prod: 3.09GB (300K MAU 부하 대응) |
| 노드 수 | 1 | Dev 환경이므로 고가용성 필요 없음 |
| 자동 페일오버 | 비활성 | 단일 노드, 프로덕션 단계에서 Replication 도입 |
| 멀티 AZ | 비활성 | Dev 비용 최적화 |
| 엔진 포트 | 6379 | Redis 표준 포트 |
| **용량 정당화** | **cache.t4g.micro (512MB) → 부적절** | **300K MAU 부하에서 메모리 부족 위험**<br/>- Pub/Sub 구독자: ~5MB<br/>- 세션 저장소: ~1-5MB<br/>- 캐싱 (예상): ~50-100MB<br/>- 시스템 오버헤드: ~100MB<br/>- **필요: cache.t4g.small (1.37GB) 최소, Prod는 small 이상** |

### 3.2 네트워크 배치

- **배치**: 프라이빗 서브넷 (shared/elasticache/dev/ Terraform 참조)
- **서브넷**: 10.0.10.0/24, 10.0.11.0/24 (기존 DB 서브넷 그룹과 동일)
- **보안 그룹**: 6379 포트를 **VPC 내부 CIDR (10.0.0.0/16)에서만** 허용
  - 백엔드 보안 그룹 → Redis 보안 그룹 Ingress 규칙
- **public endpoint 없음**: VPC 외부에서 직접 접근 불가 (의도적)

### 3.3 유지보수 윈도우

- **시간**: 월요일 20:00~21:00 UTC (아침 05:00~06:00 KST)
- **자동 패치 적용**: 활성화

### 3.4 SSM Parameter Store 등록

```
/billage/dev/redis/host     → elasticache-instance-endpoint.abc123.ng.0001.apne2.cache.amazonaws.com
/billage/dev/redis/port     → 6379
/billage/dev/redis/password → (비어있음 — Auth Token 미사용)
```

Spring Boot 애플리케이션은 배포 시 SSM 파라미터를 읽어 Redis 연결 설정을 동적으로 구성한다.

---

## 4. Redis 용도 정의 및 우선순위

### 4.1 P0 (필수): Chat Pub/Sub — 멀티 인스턴스 메시지 브로드캐스트

**문제 상황**

```
User A ──── WebSocket ──── [Backend Instance 1]
                               ↓
                          Local In-Memory Queue
                               ↓
                          User A에게만 메시지 도착

User B ──── WebSocket ──── [Backend Instance 2]
                               ↓
                          Local In-Memory Queue
                               ↓
                          User B는 메시지를 받지 못함!
```

**Redis Pub/Sub 해결책**

```
User A ──── WebSocket ──── [Backend Instance 1]
                               ↓
                               └──→ Redis Channel: chat:room123
                                        ↓
User B ──── WebSocket ──── [Backend Instance 2]
                               ↓
                          (구독하고 있음)
                               ↓
                          메시지 수신 성공
```

**채널 설계**

- 채널명 패턴: `chat:{roomId}` (예: `chat:room-abc123-001`)
- 메시지 포맷 (JSON):

```
{
  "senderId": "user:001",
  "roomId": "room-abc123-001",
  "content": "안녕하세요!",
  "timestamp": 1707657600000,
  "type": "text",
  "metadata": {
    "ipAddress": "10.0.20.10"
  }
}
```

**TTL**: 없음 (Pub/Sub 메시지는 일시적)

**예상 사용량 (300K MAU 기준)**

- 300,000 MAU → ~10,000 DAU → ~1,000 concurrent users at peak
- 채팅방 수: 최대 300개 (피크)
- 채팅방당 평균 메시지율: 3-5 msg/sec
- 피크 시간대 동시 메시지: 50-200 msg/sec
- WebSocket concurrent connections: 300-500 at peak
- 각 메시지 크기: ~200 bytes
- **메모리 사용**: Pub/Sub은 메시지를 저장하지 않으므로 메모리 영향 미미 (구독자 메타데이터만 저장)
  - 구독자 정보: 300개 채팅방 × 3-5 구독자 = ~900 구독자 정보 (~5MB)

### 4.2 P1 (선택): Session Store — Refresh Token 블랙리스트 및 세션 상태

**용도**

- JWT Refresh Token 블랙리스트 (로그아웃 시)
- 활성 세션 메타데이터 (선택적)
- 다중 디바이스 로그인 추적

**키 설계**

- 패턴: `session:token:{jti}` (JTI: JWT ID)
- 값: `{"userId": "user:001", "deviceId": "device:abc", "loggedOutAt": null}`
- TTL: Refresh Token 유효 기간과 동일 (예: 7일)

**메모리 사용 (300K MAU)**

- 활성 세션 수: 최대 10,000명 (DAU 기반)
- 세션당 크기: ~150 bytes
- 총 예상: ~1.5 MB (무시할 수 있는 수치)

### 4.3 P2 (선택): API Response Caching — 자주 조회되는 데이터

**용도**

- 물품 목록 (카테고리별)
- 사용자 프로필 정보
- 통계 데이터

**키 설계**

- 패턴: `cache:item:list:{categoryId}` 또는 `cache:user:profile:{userId}`
- TTL: 콘텐츠에 따라 다름
  - 물품 목록: 5분
  - 사용자 프로필: 1시간
  - 통계: 1시간

**메모리 사용 (300K MAU 기준)**

- 물품 목록(전체 카테고리): ~50-100 MB (더 많은 사용자, 더 많은 물품)
- 프로필 캐시(활성 사용자 10,000명): ~50-100 MB
- 통계 데이터: ~10-20 MB
- 총 P2 예상: ~110-220 MB (상황에 따라 변동)

**주의**: P2는 DB에서 읽기만 수행하고 Redis에서 캐시 miss 시 재쿼리하므로, 캐시 invalidation 전략이 중요하다. 물품 정보 수정 시 해당 캐시를 즉시 삭제해야 한다.

### 4.4 초기 도입 전략

1. **Phase 1 (1주)**: P0 (Chat Pub/Sub)만 구현 및 테스트
2. **Phase 2 (2주)**: P1 추가 (선택적, 비용-이점 재평가 후)
3. **Phase 3 (4주)**: P2 추가 (캐시 전략 정립 후)

---

## 5. 아키텍처 설계

### 5.1 Spring Boot의 Redis 연동

**의존성**

```
spring-boot-starter-data-redis
lettuce (내장, spring-boot-starter-data-redis에 포함)
```

**선택: Lettuce vs Jedis**

| 특성 | Lettuce | Jedis |
|------|---------|-------|
| 스레드 안전성 | O (Netty 기반 비동기) | X (연결풀링 필요) |
| 네이티브 비동기 | O (Mono/Flux 지원) | X |
| 리액티브 스트림 | O | X |
| 성능 | 높음 (non-blocking I/O) | 중간 |
| Spring Boot 기본값 | O | X |

**결론**: Lettuce 사용 (Spring Boot 기본값, 스레드 안전성 우수)

### 5.2 Redis 연결 풀 설정

```properties
spring.redis.host=elasticache-instance-endpoint.abc123.ng.0001.apne2.cache.amazonaws.com
spring.redis.port=6379
spring.redis.timeout=2000
spring.redis.lettuce.pool.max-active=8
spring.redis.lettuce.pool.max-idle=8
spring.redis.lettuce.pool.min-idle=0
spring.redis.lettuce.shutdown-timeout=100
```

**설정 설명 (300K MAU, 900 RPS 기준)**

- `max-active=30`: 동시에 획득 가능한 최대 연결 수
  - 백엔드 ASG 인스턴스: 2~6개 (평균 4개)
  - 인스턴스당 연결 필요: 5~8개
  - 총: 20~32개 (안전 여유: 30)
- `min-idle=2`: 최소 유휴 연결 유지 (빠른 응답)
- `shutdown-timeout=100ms`: 애플리케이션 종료 시 연결 정리 시간

### 5.3 Spring Boot Bean 구성

**RedisTemplate 빈**

```
RedisTemplate<String, Object> 타입으로 등록
- Serializer: Jackson2JsonRedisSerializer 사용
- Key Serializer: StringRedisSerializer
- Value Serializer: Jackson2JsonRedisSerializer
```

**MessageListener 빈 (Pub/Sub)**

```
RedisMessageListenerContainer 등록
- Listener: ChatMessageSubscriber 클래스 (MessageListener 구현)
- Topic Pattern: chat:* (모든 채팅 채널 구독)
- Thread Pool: corePoolSize=4, maxPoolSize=8
```

### 5.4 Chat Pub/Sub 구현 예시 (논리)

**Publisher 로직 (사용자 메시지 송신 시)**

1. WebSocket 메시지 수신: `{"roomId": "room-abc123-001", "content": "Hello"}`
2. 메시지 객체 생성 (timestamp, senderId 추가)
3. Redis PUBLISH 호출: 채널 `chat:room-abc123-001`에 JSON 메시지 발행
4. **동시에** DB에 저장 (메시지 영속화)
5. 응답 반환

**Subscriber 로직 (백엔드 인스턴스의 연결된 클라이언트에게 전달)**

1. Redis 채널 `chat:*` 구독 대기
2. 메시지 수신 시 ChatMessageSubscriber.onMessage() 호출
3. 메시지 역직렬화
4. WebSocket 세션 관리자에서 같은 채팅방에 연결된 모든 클라이언트 검색
5. 각 클라이언트의 WebSocket 세션에 메시지 전송 (sendMessage())

### 5.5 메시지 순서 보장 및 전달 보장

**Pub/Sub의 제약 (이해 필수)**

- **메시지 영속성 없음**: 구독자가 없을 때 발행된 메시지는 유실된다.
- **메시지 순서**: 단일 채널에서는 순서 보장되나, 여러 인스턴스의 구독자가 **정확히 같은 순서로** 받을 보장은 없다 (네트워크 지연).
- **전달 보장**: At-most-once (0회 또는 1회). 재시도 없음.

**해결책**

1. **채팅 메시지는 항상 DB에 저장**: Redis Pub/Sub은 실시간 전달용만. 메시지 영속화는 PostgreSQL/MySQL에서.
2. **메시지 ID (UUID) 사용**: 클라이언트는 메시지 ID로 중복 수신 감지 가능.
3. **Sequence Number**: 각 채팅방별 시퀀스 번호를 증분하여 순서 보장.

```
메시지 포맷 수정:
{
  "id": "msg-uuid-12345",
  "roomId": "room-abc123-001",
  "sequenceNumber": 42,
  "senderId": "user:001",
  "content": "Hello",
  "timestamp": 1707657600000
}
```

클라이언트는 `sequenceNumber`가 연속적인지 확인하여 메시지 손실 감지 가능.

### 5.6 연결 실패 및 우아한 성능 저하 (Graceful Degradation)

**Redis 연결 실패 시나리오**

1. ElastiCache 인스턴스 다운
2. 네트워크 단절
3. 보안 그룹 오구성

**Pub/Sub 구현 시 예외 처리**

```
try:
    redis.publish(channel, message)
except RedisConnectionException:
    logger.error("Redis Pub/Sub 불가 — 로컬 메모리 폴백")
    # 같은 인스턴스에만 메시지 전달 (partial functionality)
    localInstanceBroadcast(roomId, message)
```

**결과**

- 같은 인스턴스에 연결된 클라이언트만 메시지 수신 가능
- 다른 인스턴스의 클라이언트는 메시지를 못 받지만, 채팅방 목록 조회나 메시지 히스토리는 DB를 통해 정상 동작
- 채팅 기능만 부분 기능하며, 시스템은 완전히 중단되지 않음

---

## 6. 사전 준비 사항

### 6.1 Terraform을 통한 ElastiCache 프로비저닝

**경로**: `shared/elasticache/dev/`

**terraform apply 명령**

```
cd shared/elasticache/dev/
terraform plan   # 변경 사항 확인
terraform apply  # ElastiCache 생성
```

**소요 시간**: 약 10~15분

**Output**:
- Redis 엔드포인트 (예: `billage-redis-dev.abc123.ng.0001.apne2.cache.amazonaws.com`)
- 보안 그룹 ID
- 서브넷 그룹 ID

### 6.2 보안 그룹 확인

**인바운드 규칙** (6379 포트)

- Source: Backend Security Group ID
- Protocol: TCP
- Port Range: 6379

**확인 명령**

```
aws ec2 describe-security-groups \
  --group-ids sg-redis-dev \
  --query 'SecurityGroups[0].IpPermissions'
```

### 6.3 SSM Parameter Store 등록

**생성**

```
aws ssm put-parameter \
  --name /billage/dev/redis/host \
  --value "billage-redis-dev.abc123.ng.0001.apne2.cache.amazonaws.com" \
  --type "String" \
  --overwrite

aws ssm put-parameter \
  --name /billage/dev/redis/port \
  --value "6379" \
  --type "String" \
  --overwrite
```

**Spring Boot에서 읽기**

application.yml에 다음 추가:

```yaml
spring:
  redis:
    host: ${/billage/dev/redis/host}
    port: ${/billage/dev/redis/port}
```

Spring Cloud AWS Secrets 의존성이 필요:

```xml
<dependency>
  <groupId>org.springframework.cloud</groupId>
  <artifactId>spring-cloud-starter-aws-secrets-manager-config</artifactId>
</dependency>
```

### 6.4 Spring Boot 의존성 추가

**pom.xml**

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>

<dependency>
  <groupId>io.lettuce</groupId>
  <artifactId>lettuce-core</artifactId>
</dependency>

<dependency>
  <groupId>com.jackson</groupId>
  <artifactId>jackson-databind</artifactId>
</dependency>
```

**빌드 후 테스트**

```
mvn clean install
```

### 6.5 Docker 환경에서 Redis 연결 테스트

**로컬 docker-compose.yml 추가**

```yaml
services:
  redis:
    image: redis:7.0-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  backend:
    build: .
    environment:
      SPRING_REDIS_HOST: redis
      SPRING_REDIS_PORT: 6379
    depends_on:
      redis:
        condition: service_healthy
    ports:
      - "8080:8080"
```

**실행**

```
docker-compose up -d
```

**연결 테스트**

```bash
# 컨테이너 내부에서 Redis CLI 실행
docker exec -it redis redis-cli ping

# 결과: PONG
```

**스프링 부트 로그 확인**

```bash
docker logs backend | grep -i redis
```

예상 로그:
```
[INFO] org.springframework.data.redis.core.RedisTemplate : Successfully connected to Redis
[INFO] io.lettuce.core.EpollProvider : epoll not available, falling back to select
```

---

## 7. 실행 계획

### Phase 1: 인프라 준비 (소요: 1~2일)

**Step 1.1: ElastiCache 프로비저닝**

- Terraform 파일 검토 (공유 계정의 shared/elasticache/dev/)
- `terraform plan` 실행 및 변경 사항 확인
- `terraform apply` 실행 (약 10~15분)
- 엔드포인트 획득
- 보안 그룹 인바운드 규칙 확인

**담당**: DevOps/Infra 엔지니어
**체크리스트**:
- [ ] ElastiCache 인스턴스 생성 확인 (AWS 콘솔)
- [ ] Security Group 규칙 확인
- [ ] Redis 포트 (6379) 오픈 확인

**Step 1.2: SSM Parameter Store 등록**

```bash
aws ssm put-parameter \
  --name /billage/dev/redis/host \
  --value "<endpoint>" \
  --type "String" \
  --overwrite
```

**담당**: DevOps/Infra 엔지니어
**체크리스트**:
- [ ] /billage/dev/redis/host 등록
- [ ] /billage/dev/redis/port 등록
- [ ] SSM 파라미터 값 확인

### Phase 2: 백엔드 코드 구현 (소요: 3~5일)

**Step 2.1: Spring Boot 의존성 추가**

- pom.xml에 spring-boot-starter-data-redis 추가
- 로컬에서 `mvn clean install` 실행
- 컴파일 오류 확인

**담당**: Backend 엔지니어
**체크리스트**:
- [ ] spring-boot-starter-data-redis 추가
- [ ] lettuce-core 버전 확인 (auto-wired)
- [ ] 로컬 빌드 성공

**Step 2.2: Redis 설정 클래스 작성**

RedisConfig.java:

```
RedisTemplate<String, Object> 빈 정의
- StringRedisSerializer for keys
- Jackson2JsonRedisSerializer for values
RedisMessageListenerContainer 빈 정의
- Thread pool: 4~8 threads
- Listener: ChatMessageSubscriber 클래스
```

**담당**: Backend 엔지니어
**체크리스트**:
- [ ] RedisConfig 클래스 생성
- [ ] RedisTemplate Bean 빈 등록 테스트
- [ ] 로컬 docker-compose에서 정상 작동 확인

**Step 2.3: Chat Pub/Sub 구현**

ChatMessagePublisher.java:

```
메서드: publishMessage(ChatRoom room, ChatMessage message)
동작:
1. message에 timestamp, senderId 추가
2. Redis PUBLISH to channel "chat:{roomId}"
3. DB에 메시지 저장 (트랜잭션)
4. 응답 반환
에러 처리: Redis 연결 실패 시 graceful degradation
```

ChatMessageSubscriber.java:

```
MessageListener 구현
메서드: onMessage(Message message, byte[] pattern)
동작:
1. 메시지 역직렬화
2. roomId 추출
3. 같은 채팅방 클라이언트 검색
4. WebSocket 세션에 메시지 전송
에러 처리: WebSocket 세션 폐쇄 시 자동 제거
```

**담당**: Backend 엔지니어
**체크리스트**:
- [ ] ChatMessagePublisher 구현
- [ ] ChatMessageSubscriber 구현
- [ ] 단위 테스트 작성 (모의 Redis 사용)
- [ ] 통합 테스트 작성 (실제 Redis)

**Step 2.4: WebSocket 통합**

WebSocketHandler.java 수정:

```
기존: 로컬 메모리 큐 사용
변경: ChatMessagePublisher.publishMessage() 호출
```

**담당**: Backend 엔지니어
**체크리스트**:
- [ ] WebSocketHandler에서 ChatMessagePublisher 주입
- [ ] 메시지 송신 로직 수정
- [ ] 기존 동작 호환성 검증

### Phase 3: 로컬 통합 테스트 (소요: 2~3일)

**Step 3.1: docker-compose 환경 구성**

```yaml
services:
  redis
  backend (2개 인스턴스)
  postgres
```

**담당**: Backend 엔지니어
**체크리스트**:
- [ ] docker-compose.yml 작성
- [ ] 모든 서비스 헬스체크 정의
- [ ] `docker-compose up` 성공

**Step 3.2: 단일 인스턴스 채팅 테스트**

```
1. 웹소켓 클라이언트 A 연결 (ws://localhost:8080/chat/room-123)
2. 메시지 송신: "Hello"
3. 메시지 수신 확인
4. DB 저장 확인
5. Redis에 메시지가 저장되지 않음을 확인 (Pub/Sub 특성)
```

**담당**: QA 엔지니어
**체크리스트**:
- [ ] 메시지 송수신 성공
- [ ] DB 저장 확인
- [ ] 로그에 오류 없음

**Step 3.3: 다중 인스턴스 채팅 테스트**

```
1. 웹소켓 클라이언트 A 연결 → Backend Instance 1
2. 웹소켓 클라이언트 B 연결 → Backend Instance 2 (다른 인스턴스)
3. A에서 메시지 송신
4. A와 B 모두 메시지 수신 확인 ← 이것이 핵심 테스트!
5. 메시지 순서 확인 (sequenceNumber)
```

**담당**: QA 엔지니어
**체크리스트**:
- [ ] Instance 1과 2 모두 메시지 송수신 확인
- [ ] Redis Pub/Sub 채널에 메시지 발행 확인 (redis-cli로 SUBSCRIBE 후 관찰)
- [ ] 메시지 손실 없음
- [ ] 정상 종료 시 연결 풀 정리 확인

**Step 3.4: 부하 테스트 (300K MAU, 900 RPS)**

```
시나리오 1: 정상 운영
- 동시 채팅방: 50개 × 초당 3-5 메시지
- 총 메시지율: 150-250 msg/sec
- WebSocket 연결: 300-400
- 지속 시간: 5분

시나리오 2: 중간 부하
- 동시 채팅방: 100-150개 × 초당 3-5 메시지
- 총 메시지율: 300-750 msg/sec
- WebSocket 연결: 500-800
- 지속 시간: 5분

시나리오 3: 피크 부하 (목표)
- 동시 채팅방: 250-300개 × 초당 2-3 메시지
- 총 메시지율: 500-900 msg/sec
- WebSocket 연결: 900-1,200
- 백엔드 RPS: ~900
- 지속 시간: 3분

측정 항목:
- Redis 메모리 사용량 (목표: < 1GB)
- 연결 수 (CONNECTED CLIENTS, 목표: < 500)
- 메시지 지연 시간 (p95 < 100ms, p99 < 200ms)
- CPU 사용률 (목표: < 70%)
```

**담당**: Performance 엔지니어
**체크리스트**:
- [ ] 부하 테스트 스크립트 작성 (Apache JMeter 또는 locust)
- [ ] 메트릭 수집 및 분석
- [ ] 병목 지점 확인 및 최적화 (connection pool size 등)

### Phase 4: Dev 환경 배포 (소요: 1~2일)

**Step 4.1: Docker 이미지 빌드 및 ECR 푸시**

```bash
docker build -t billage-backend:v2.0.0-redis .
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin <ecr-repo>
docker tag billage-backend:v2.0.0-redis <ecr-repo>/billage-backend:v2.0.0-redis
docker push <ecr-repo>/billage-backend:v2.0.0-redis
```

**담당**: DevOps 엔지니어
**체크리스트**:
- [ ] Docker 이미지 빌드 성공
- [ ] ECR 푸시 성공
- [ ] 이미지 스캔 (취약성) 수행

**Step 4.2: ECS 작업 정의 업데이트**

```
환경 변수 추가:
SPRING_REDIS_HOST: /billage/dev/redis/host (SSM 파라미터 참조)
SPRING_REDIS_PORT: /billage/dev/redis/port
```

**담당**: DevOps 엔지니어
**체크리스트**:
- [ ] 작업 정의 생성/업데이트
- [ ] SSM 파라미터 마운트 확인
- [ ] IAM 역할에 SSM 읽기 권한 확인

**Step 4.3: ECS 서비스 배포**

```bash
aws ecs update-service \
  --cluster dev \
  --service billage-backend \
  --task-definition billage-backend:v2.0.0-redis \
  --force-new-deployment
```

**소요 시간**: 약 5~10분 (task 재시작)

**담당**: DevOps 엔지니어
**체크리스트**:
- [ ] 기존 인스턴스 정상 운영 중
- [ ] 새 이미지 배포 (롤링 업데이트)
- [ ] 모든 인스턴스 정상 상태 (RUNNING)
- [ ] CloudWatch 로그에 Redis 연결 메시지 확인

**Step 4.4: 통합 테스트 (Dev 환경)**

```
1. 2~3개 백엔드 인스턴스 구동 (ASG 확인)
2. 채팅 애플리케이션 접속
3. 여러 클라이언트에서 메시지 송수신 테스트
4. ElastiCache 메트릭 모니터링 (CurrConnections, FreeableMemory)
```

**담당**: QA + Backend 엔지니어
**체크리스트**:
- [ ] 다중 인스턴스 채팅 동작 확인
- [ ] 인스턴스 스케일 업/다운 중 메시지 손실 없음
- [ ] CloudWatch 메트릭 정상 범위 (메모리 < 50%, CPU < 30%)
- [ ] 로그 오류 없음

---

## 8. 검증 방법 및 체크리스트

### 8.1 기본 연결 확인

**Redis PING/PONG**

```bash
# EC2에서 Redis에 직접 연결 (VPC 내부)
redis-cli -h billage-redis-dev.abc123.ng.0001.apne2.cache.amazonaws.com -p 6379
> PING
< PONG
```

**예상 결과**: PONG 반환

**Spring Boot 로그 확인**

```bash
aws logs tail /ecs/billage-backend-dev --follow | grep -i redis
```

**예상 로그**:
```
[INFO] org.springframework.data.redis.core.RedisTemplate : Successfully connected to Redis
[INFO] io.lettuce.core.EpollProvider : epoll not available, falling back to select (정상)
```

**체크리스트**:
- [ ] Redis PING 응답
- [ ] Spring Boot 로그에 연결 성공 메시지
- [ ] 보안 그룹 규칙 확인 (6379 ← Backend SG)

### 8.2 Pub/Sub 메시지 전달 테스트

**테스트 코드 (단위 테스트)**

```
@Test
void testChatMessagePublishSubscribe() throws InterruptedException {
    // Given: 채팅방 생성
    ChatRoom room = new ChatRoom("room-test-001");
    ChatMessage message = new ChatMessage(room.getId(), "user:001", "Hello", ChatMessageType.TEXT);

    // When: 메시지 발행
    publisher.publishMessage(room, message);
    Thread.sleep(500); // Redis 처리 시간

    // Then: 메시지가 구독자에게 도착했는지 확인
    verify(subscriber).onMessage(contains("Hello"), any());
}
```

**통합 테스트 (2개 인스턴스)**

```
조건:
- Backend Instance 1 (포트 8080): 클라이언트 A 연결
- Backend Instance 2 (포트 8081): 클라이언트 B 연결

단계:
1. 클라이언트 A: WebSocket 연결 → /chat/room-test-001
2. 클라이언트 B: WebSocket 연결 → /chat/room-test-001
3. 클라이언트 A: 메시지 송신 → "Hello from Instance 1"
4. 확인: 클라이언트 A와 B 모두 "Hello from Instance 1" 수신
5. 클라이언트 B: 메시지 송신 → "Hello from Instance 2"
6. 확인: 클라이언트 A와 B 모두 "Hello from Instance 2" 수신

성공 지표:
- 메시지 송수신 지연 < 100ms
- 메시지 손실: 0개
- 중복 메시지: 0개
```

**redis-cli를 이용한 채널 모니터링**

```bash
# 터미널 1: 채널 구독 모니터링
redis-cli -h <redis-host> SUBSCRIBE "chat:room-test-001"

# 터미널 2: 웹 애플리케이션에서 메시지 송신
# (포트 8080에서 메시지 송신)

# 터미널 1 결과:
# 1) "subscribe"
# 2) "chat:room-test-001"
# 3) (integer) 1
# 1) "message"
# 2) "chat:room-test-001"
# 3) "{\"id\":\"msg-uuid-123\",\"content\":\"Hello\",\"senderId\":\"user:001\",\"timestamp\":1707657600000}"
```

**체크리스트**:
- [ ] 메시지 발행 성공 (redis-cli 모니터링)
- [ ] 메시지 형식 정상 (JSON 파싱 가능)
- [ ] 여러 채팅방 채널 격리 확인 (chat:room-001 ≠ chat:room-002)

### 8.3 부하 테스트

**테스트 구성**

```
시나리오 1: 정상 운영
- 동시 채팅방: 10개
- 채팅방당 메시지율: 5 msg/sec
- 총 메시지율: 50 msg/sec
- 지속 시간: 5분

시나리오 2: 중간 부하
- 동시 채팅방: 50개
- 채팅방당 메시지율: 5 msg/sec
- 총 메시지율: 250 msg/sec
- 지속 시간: 5분

시나리오 3: 최대 부하 (예상 피크)
- 동시 채팅방: 100개
- 채팅방당 메시지율: 5 msg/sec
- 총 메시지율: 500 msg/sec
- 지속 시간: 3분
```

**부하 테스트 도구**: Apache JMeter 또는 Python locust

**JMeter 설정**

```
Thread Group:
- Number of Threads: 100 (클라이언트)
- Ramp-up Period: 60초 (1분에 걸쳐 100명 접속)
- Loop Count: 5 (각 클라이언트가 5번 반복)

WebSocket Sampler:
- Connection timeout: 10000ms
- 메시지 송신 간격: 200ms
```

**측정 항목 (300K MAU 목표 기준)**

| 지표 | 정상 범위 | 경고 범위 | 심각 범위 |
|------|---------|---------|---------|
| Redis 메모리 사용량 | < 300MB | 400~700MB | > 900MB |
| CurrConnections | < 200 | 300~400 | > 500 |
| 메시지 지연 (P95) | < 50ms | 75~150ms | > 300ms |
| 메시지 지연 (P99) | < 100ms | 150~250ms | > 500ms |
| CPU 사용률 | < 30% | 40~60% | > 75% |
| 메시지 손실률 | 0% | 0.01~0.1% | > 0.1% |

**결과 분석**

```
예상 결과:
- 시나리오 1: 모든 지표 정상
- 시나리오 2: 메모리 ~ 200MB, CPU ~ 40%, 지연 < 100ms (정상)
- 시나리오 3: 메모리 ~ 300MB, CPU ~ 60%, 지연 ~ 150ms
  (제한: cache.t4g.micro = 0.5GB 메모리, 이 이상은 불안정)
```

**체크리스트**:
- [ ] 부하 테스트 스크립트 작성
- [ ] 메트릭 수집 (CloudWatch 대시보드)
- [ ] 결과 분석 및 병목 지점 식별
- [ ] Connection pool size 최적화 (필요시)

### 8.4 메모리 모니터링

**CloudWatch 메트릭**

```
메트릭: AWS/ElastiCache
- FreeableMemory: 여유 메모리 (bytes)
- DatabaseMemoryUsagePercentage: 메모리 사용률 (%)
- CurrConnections: 현재 연결 수
- NetworkBytesIn/Out: 네트워크 트래픽
```

**Grafana 대시보드 설정**

```
1. CloudWatch 데이터소스 추가
2. 대시보드 생성:
   - FreeableMemory (시계열)
   - DatabaseMemoryUsagePercentage (게이지)
   - CurrConnections (시계열)
   - 메시지 처리율 (app 메트릭에서)
```

**Alarm 설정 (AWS SNS)**

```
조건 1: Memory > 80% (경고)
조건 2: Memory > 95% (심각)
조건 3: CurrConnections > 100 (경고)
```

**체크리스트**:
- [ ] CloudWatch 메트릭 수집 확인
- [ ] Grafana 대시보드 생성
- [ ] SNS 알림 구독 (이메일)
- [ ] 알림 테스트

### 8.5 연결 풀 모니터링

**Lettuce 연결 풀 상태**

```
로그 모니터링:
[INFO] io.lettuce.core.EpollProvider : Using Epoll
[INFO] io.lettuce.core.ClientResources : Netty event loop group initialized

Spring metrics (Micrometer):
redis.connection.pool.size: 8
redis.connection.active: 2~4 (평상시)
```

**최적화**

```
current 설정:
max-active: 8 (ASG 6 instances × 1 conn 정도)
min-idle: 0 (유휴 연결 제거)

조정 기준:
- ASG 인스턴스 = N일 때
- max-active = N × 2~3 (여유)
- min-idle = N × 1 (기본 유지)
```

**체크리스트**:
- [ ] 연결 풀 크기 적정성 평가
- [ ] 유휴 연결 정리 확인
- [ ] 연결 누수 없음 (연결 수 증가 추이 모니터링)

### 8.6 장애 시나리오 테스트

**시나리오 1: Redis 인스턴스 다운**

```
사전 조건: 2개 클라이언트가 채팅방에 연결

단계:
1. redis-cli를 통해 SHUTDOWN 실행 (또는 AWS 콘솔에서 재부팅)
2. 메시지 송신 시도
3. 동작 관찰

예상 동작:
- 로그: "[ERROR] io.lettuce.core.RedisConnectionException"
- 클라이언트: 로컬 인스턴스 내 메시지만 송수신 (partial)
- 타 인스턴스 클라이언트: 메시지 미수신
- 채팅방 목록 조회: 정상 (DB 접근)
- 메시지 히스토리: 정상 (DB에서 읽음)

복구:
- ElastiCache 자동 재시작 또는 수동 복구 기다림
- 복구 후: Pub/Sub 자동 재연결
```

**체크리스트**:
- [ ] Redis 장애 감지 로그 확인
- [ ] Graceful degradation 동작
- [ ] 채팅 외 기능 정상 운영
- [ ] Redis 복구 후 자동 재연결

**시나리오 2: 네트워크 지연**

```
도구: Docker tc (traffic control)로 지연 모의

단계:
1. Backend ↔ Redis 간 300ms 지연 추가
   tc qdisc add dev eth0 root netem delay 300ms
2. 메시지 송수신 테스트
3. 지연 감지 (타임아웃 설정 재확인)

예상:
- 메시지 지연 증가 (300~400ms)
- 타임아웃 미발생 (timeout=2000ms)
- 정상 동작

정리:
tc qdisc del dev eth0 root
```

**체크리스트**:
- [ ] 네트워크 지연 시뮬레이션 설정
- [ ] 메시지 전달 지연 확인
- [ ] 타임아웃 마진 충분 (2000ms는 충분)

### 8.7 성능 기준선 설정

**Baseline 메트릭** (300K MAU, 부하 테스트 기반)

```
시나리오 1 (정상 운영: 50개 채팅방, 150-250 msg/sec, 300-400 WS conn):
- Redis 메모리: 50~80MB
- CurrConnections: 80~120
- 메시지 지연 (P50): 10~20ms
- 메시지 지연 (P95): 30~50ms
- 메시지 지연 (P99): 50~100ms
- Backend RPS: ~300
- CPU: 15~25%

시나리오 2 (중간 부하: 100-150개 채팅방, 300-750 msg/sec, 500-800 WS conn):
- Redis 메모리: 100~200MB
- CurrConnections: 150~300
- 메시지 지연 (P50): 20~40ms
- 메시지 지연 (P95): 60~100ms
- 메시지 지연 (P99): 100~200ms
- Backend RPS: ~600
- CPU: 35~50%

시나리오 3 (피크 부하: 250-300개 채팅방, 500-900 msg/sec, 900-1,200 WS conn):
- Redis 메모리: 250~400MB
- CurrConnections: 300~450
- 메시지 지연 (P50): 40~80ms
- 메시지 지연 (P95): 100~200ms
- 메시지 지연 (P99): 200~400ms
- Backend RPS: ~900
- CPU: 55~75%
```

**향후 참고 기준**

- 메모리 사용량 증가 추이 모니터링
- 메시지 지연이 갑자기 증가 → Connection pool 조정 필요
- CPU > 70% 지속 → Redis 인스턴스 업그레이드 (cache.t4g.small)

---

## 9. Fallback 및 롤백 계획

### 9.1 Fallback: Redis 연결 실패 시

**문제**: ElastiCache 인스턴스 다운 또는 네트워크 단절

**즉시 대응 (자동)**

```java
// ChatMessagePublisher.publishMessage()에서:
try {
    redisTemplate.convertAndSend("chat:" + roomId, message);
} catch (RedisConnectionException e) {
    logger.warn("Redis Pub/Sub unavailable, using local fallback", e);
    // 로컬 In-Memory Broadcast (같은 인스턴스에만)
    localChatService.broadcastToLocalClients(roomId, message);
}

// DB 저장은 항상 진행 (독립적 트랜잭션)
chatMessageRepository.save(message);
```

**결과**

| 기능 | 정상 | Redis 장애 |
|------|------|---------|
| 같은 인스턴스 채팅 | ✓ | ✓ (작동) |
| 다중 인스턴스 채팅 | ✓ | ✗ (불가) |
| 채팅방 목록 | ✓ | ✓ (작동) |
| 메시지 히스토리 | ✓ | ✓ (작동) |
| 새 메시지 영속화 | ✓ | ✓ (작동) |

**사용자 영향**

- 사용자는 같은 서버에 연결된 다른 사용자하고만 실시간 채팅 가능
- 다른 서버의 사용자 메시지는 새로고침 후에만 확인 (DB 폴링)
- 채팅 기능이 부분적으로만 작동하지만, 서비스 전체 중단은 아님

### 9.2 Fallback 지속 시간

**자동 재시도 정책**

```
첫 시도: 즉시 (0ms)
재시도 1: 1초 후
재시도 2: 5초 후
재시도 3: 10초 후
이후: 30초 주기로 계속 재시도
```

**Redis 복구 감지**

```
백그라운드 태스크:
- 30초마다 Redis PING 시도
- 응답 성공 → 로그: "Redis 복구됨, Pub/Sub 재개"
- 자동 재연결 (Lettuce 내장)
```

**모니터링**

```
CloudWatch Alarm:
- Redis CurrConnections = 0 지속 시간 > 5분
- → SNS 알림: "Redis 연결 끊김 감지"
```

### 9.3 롤백: Redis 삭제 또는 다운그레이드

**상황**: Redis가 더 이상 필요 없다고 판단 (매우 드문 경우)

**단계**

1. **백엔드 코드 롤백** (먼저 수행)
   - ChatMessagePublisher 제거 또는 비활성화
   - 로컬 In-Memory 큐로 복귀
   - 배포: 새 ECS 작업 정의 사용

2. **서비스 재배포 후 검증** (1~2시간)
   - 이전 동작 확인 (단일 인스턴스 채팅)
   - 로그에 Redis 연결 시도 없음

3. **Terraform으로 ElastiCache 삭제**
   ```bash
   cd shared/elasticache/dev/
   terraform destroy
   ```
   - 소요: 약 10분
   - 자동 백업: 비활성화 상태 (데이터 손실 무관)

4. **SSM 파라미터 정리** (선택)
   ```bash
   aws ssm delete-parameter --name /billage/dev/redis/host
   aws ssm delete-parameter --name /billage/dev/redis/port
   ```

**주의**: 현재 운영 중인 채팅 메시지는 DB에 저장되어 있으므로, 실시간 Pub/Sub만 손실된다. 메시지 히스토리는 보존.

### 9.4 점진적 롤백 (카나리 배포)

**상황**: Redis 도입 후 예상치 못한 문제 발생

**단계**

1. **트래픽 분할**
   - 50%의 사용자: 이전 버전 (Redis 없음)
   - 50%의 사용자: 새 버전 (Redis 사용)
   - 도구: ALB Target Group weights

2. **모니터링** (30분)
   - 에러율, 지연 시간, 메모리 사용량 비교
   - 새 버전에 문제 발견 → 3번으로 진행

3. **문제 해결 또는 전체 롤백**
   - 문제 없음: 100% 새 버전으로 전환
   - 문제 있음: 100% 이전 버전으로 되돌림 (1번의 역방향)

**ALB 설정 예시**

```
Target Group: backend-v2.0.0-with-redis
  - Weight: 50%
  - Desired Count: 3

Target Group: backend-v1.9.9-without-redis
  - Weight: 50%
  - Desired Count: 3
```

---

## 10. 리스크 및 주의사항

### 10.1 Pub/Sub의 근본적 특성

**제약 1: 메시지 영속성 없음**

```
구독자가 없을 때 발행된 메시지는 즉시 유실된다.

예시:
1. 17:00:00 - 채팅방 room-001에 구독자 없음
2. 17:00:05 - 메시지 발행 (구독자가 없는 상태에서)
3. 17:00:10 - 사용자 A가 구독 시작
4. 결과: 17:00:05의 메시지를 A는 받지 못함

해결책:
- 채팅방 방문 시 DB에서 최근 메시지 히스토리 먼저 로드
- Redis Pub/Sub은 "새 메시지 실시간 전달"용만 사용
```

**제약 2: 메시지 순서 보장 제한**

```
단일 채널(chat:room-001)에서는 순서 보장되지만,
여러 인스턴스의 구독자가 "정확히 같은 순서로" 받을 보장은 없다.

이유:
- 네트워크 지연 (Instance A의 listener가 Instance B보다 느릴 수 있음)
- 스레드 스케줄링 (메시지 처리가 비동기)

영향:
- 메시지 순서가 약간 뒤바뀔 수 있음 (매우 드문 경우)
- 대부분의 경우 순서 유지 (같은 채널의 FIFO 특성)

해결책:
- 각 메시지에 순서번호(sequenceNumber) 부여
- 클라이언트에서 받은 메시지를 sequenceNumber로 정렬
- 순간적 뒤바뀜을 감지하면 정렬

메시지 포맷:
{
  "id": "msg-uuid-12345",
  "sequenceNumber": 42,
  "roomId": "room-abc123-001",
  "content": "Hello"
}

클라이언트 로직:
expected_seq = 42
while (received_message.seq != expected_seq):
    wait_for_next_message()
render_message(received_message)
expected_seq += 1
```

**제약 3: 전달 보장 - At-Most-Once**

```
메시지는 0회 또는 1회만 전달된다 (재시도 없음).

상황 1: 메시지 유실 (Pub/Sub 특성)
- 구독자가 없을 때 발행된 메시지 → 유실
- 확률: 낮음 (보통 최소 1명 이상 구독)

상황 2: 메시지 중복 (network retry)
- 아주 드문 경우, 네트워크 재시도로 중복 수신 가능
- 확률: 극히 낮음

해결책:
- 메시지 ID(idempotency key)로 중복 감지
- 클라이언트: Set<messageId>로 이미 수신한 메시지 추적
- 또는 DB에서 메시지 ID로 unique constraint 설정

DB 스키마:
CREATE TABLE chat_messages (
  id UUID PRIMARY KEY,
  sequence_number BIGINT,
  room_id VARCHAR(100) NOT NULL,
  sender_id VARCHAR(100) NOT NULL,
  content TEXT,
  created_at TIMESTAMP,
  UNIQUE(room_id, sequence_number)
);
```

**체크리스트**:
- [ ] 채팅 히스토리는 항상 DB에서 로드
- [ ] 메시지 sequenceNumber 구현
- [ ] 메시지 ID (UUID) 설정
- [ ] 클라이언트에서 중복 감지 로직

### 10.2 메모리 용량 제한

**300K MAU 기준 권장 사양**: cache.t4g.small (1.37 GB) 이상

**메모리 분배 (300K MAU 추정)**

```
Redis 자체 오버헤드: ~100MB
  - 메타데이터, 인덱싱, 버퍼 등

Pub/Sub 구독자 정보: 채팅방 수 × 평균 구독자
  - 300개 채팅방 × 3-5 구독자 = ~900 구독자 메타데이터 (~5MB)

세션 저장소 (P1): 10,000개 활성 세션 × 150bytes = 1.5MB

API 응답 캐싱 (P2): 물품 목록 80-100MB + 프로필 50-100MB = 130-200MB

총 사용 가능 (cache.t4g.small): 1.37GB - 100MB = 1.27GB

실제 사용 예측: ~200-250MB (정상 운영)
피크 사용 예측: ~400-500MB (대규모 캐싱 + 피크 트래픽)
실제 사용 권장: < 900MB (66% - 안전 여유)
```

**인스턴스 권장 업그레이드 경로**:
```
Dev (초기): cache.t4g.small (1.37GB)
Prod (300K MAU): cache.t4g.medium (3.09GB) 또는 cache.r7g.large (16GB, 매우 대규모)
```

**메모리 부족 시나리오 (300K MAU, cache.t4g.small 1.37GB)**

```
정상 운영:
- Pub/Sub 구독자: ~5MB
- 세션: ~1.5MB
- 기본 캐싱: ~50-100MB
- 시스템 오버헤드: ~100MB
- 총: ~150-200MB (11-15%)

→ 대규모 물품 목록 캐시 추가 (100MB)
→ 프로필 캐시 추가 (100MB)
→ 메모리 사용률 = 350-400MB / 1370MB = 25-29% (안전)

→ 추가 데이터 캐싱 (통계, 추천 모델 등 250-300MB)
→ 메모리 사용률 = 600-700MB / 1370MB = 43-51% (정상)

→ 피크 트래픽 + 모든 캐싱 활성
→ 메모리 사용률 = 900-1000MB / 1370MB = 65-73% (경고)

→ 메모리 정책 발동 (LRU eviction)
→ 캐시 히트율 감소 → 성능 저하

해결: cache.t4g.medium (3.09GB) 또는 높은 TTL로 캐시 전략 재검토
```

**maxmemory-policy 설정**

```
ElastiCache 파라미터 그룹에서 설정:
maxmemory-policy: allkeys-lru

동작:
- 메모리 초과 시 LRU(최근 사용하지 않은) 키 자동 삭제
- allkeys: 모든 키 대상 (세션, 캐시 모두)
- 순서: P2 캐시 → P1 세션 → P0 Pub/Sub (거의 안 지워짐)
```

**모니터링 및 알림**

```
CloudWatch Alarm:
- DatabaseMemoryUsagePercentage > 80% (경고)
  → 불필요한 캐시 정리 또는 캐시 TTL 단축

- DatabaseMemoryUsagePercentage > 95% (심각)
  → 즉시 캐시 전략 재평가 또는 인스턴스 업그레이드

업그레이드 경로:
cache.t4g.micro (0.5GB) → cache.t4g.small (2GB) → cache.t4g.medium (6.38GB)
```

**체크리스트**:
- [ ] maxmemory-policy = allkeys-lru 설정
- [ ] CloudWatch Alarm 설정 (80%, 95%)
- [ ] 메모리 증가 추이 월 1회 검토
- [ ] P2 캐싱은 신중하게 도입 (메모리 영향 커짐)

### 10.3 네트워크 지연 및 가용성

**문제**: VPC 내부 Private Subnet 배치로 인한 지연

```
현재 구조:
Backend (Public Subnet) → NAT/Private → Redis (Private Subnet)

지연:
- 일반적: 1~5ms
- 고부하: 10~50ms
- 네트워크 혼잡: 50~200ms

영향:
- 메시지 수신 지연: 일반적 10~30ms, 피크 50~100ms
- 사용자 체감: 거의 즉시 (인지 가능한 지연 < 100ms)
```

**Private Subnet의 장점 및 단점**

| 항목 | 장점 | 단점 |
|------|------|------|
| 보안 | Redis에 VPC 외부 접근 불가 | ✗ |
| 비용 | NAT 게이트웨이 비용 절감 | 비용 절감 |
| 성능 | 낮은 지연 (같은 VPC) | 높은 부하 시 지연 증가 가능 |

**로컬 개발 시 주의**

```
개발 환경에서 AWS ElastiCache에 직접 연결 불가
(VPC 외부 접근 차단)

해결책:
- 로컬 docker-compose에서 Redis 컨테이너 실행
- spring.profiles.active=local에서 Redis 주소 = localhost:6379
- dev 환경에서만 실제 ElastiCache 사용
```

**체크리스트**:
- [ ] 프로덕션에서 ElastiCache Private 배치 확인
- [ ] 로컬 개발 시 docker-compose Redis 사용
- [ ] 네트워크 지연 모니터링 (CloudWatch NetworkLatency 메트릭)
- [ ] 지연 > 200ms 지속 시 알림

### 10.4 ElastiCache 재시작 및 복구

**자동 재시작 (유지보수 윈도우)**

```
시간: 월요일 20:00~21:00 UTC (05:00~06:00 KST)
- 자동 패치 적용
- 인스턴스 재부팅

영향:
- 약 5~10분 Redis 불가
- 이 시간대 채팅이 부분 마비 가능 (로컬 fallback으로 작동)

권장:
- 05:00~06:00에 중요한 이벤트/프로모션 금지
- 사용자에게 공지 (유지보수 안내)
```

**수동 재부팅 (장애 대응)**

```
상황: Redis가 응답하지 않음

AWS 콘솔에서:
1. ElastiCache 대시보드 → Clusters
2. "billage-redis-dev" 선택
3. "Reboot Cluster" 클릭
4. 재부팅 시작

소요 시간: 5~10분
```

**자동 복구 메커니즘**

```
Lettuce 라이브러리:
- Redis 연결 끊김 감지 (자동)
- 지수 백오프로 재연결 시도
- 최대 대기: 30초 이상

로그 예시:
[WARN] io.lettuce.core.RedisConnectionException: Unable to connect
[WARN] io.lettuce.core.RedisConnectionStateListener: Connection lost
[INFO] io.lettuce.core.ConnectionWatchdog: Reconnecting...
[INFO] io.lettuce.core.ConnectionWatchdog: Successfully reconnected
```

**체크리스트**:
- [ ] 유지보수 윈도우 확인 (05:00~06:00 KST)
- [ ] 자동 재연결 로그 확인
- [ ] 재부팅 후 메시지 전달 정상화 검증

---

## 11. 모니터링 항목 및 대시보드

### 11.1 핵심 메트릭 (CloudWatch)

**ElastiCache 메트릭**

| 메트릭 | 수집 주기 | 경보 임계값 | 용도 |
|--------|---------|----------|------|
| FreeableMemory (bytes) | 1분 | < 102MB (20% 미만) | 메모리 부족 감지 |
| DatabaseMemoryUsagePercentage (%) | 1분 | > 80% | 용량 계획 |
| CurrConnections | 1분 | > 100 | 연결 풀 모니터링 |
| NetworkBytesIn/Out (bytes) | 1분 | 급증 > 100배 | 비정상 트래픽 감지 |
| EngineCPUUtilization (%) | 1분 | > 70% | Redis 서버 부하 |
| ReplicationLag (milliseconds) | - | N/A (단일 노드) | 향후 replication 도입 시 |

**애플리케이션 메트릭** (Spring Boot Micrometer)

```
redis.connection.pool.active: 활성 연결 수
redis.connection.pool.idle: 유휴 연결 수
redis.command.latency: 명령 지연 시간 (ms)
redis.command.count: 명령 실행 횟수
redis.errors: Redis 오류 횟수
```

**채팅 애플리케이션 메트릭** (Custom)

```
chat.message.published: 발행된 메시지 수
chat.message.received: 수신된 메시지 수
chat.message.latency: 메시지 지연 (ms, Pub → Sub)
chat.message.loss: 손실된 메시지 수 (0 목표)
chat.active.rooms: 활성 채팅방 수
chat.active.connections: 활성 WebSocket 연결 수
```

### 11.2 Grafana 대시보드

**대시보드 1: Redis 상태**

```
- 상단: FreeableMemory (시계열)
- 상단: DatabaseMemoryUsagePercentage (게이지)
- 중단: CurrConnections (시계열)
- 중단: EngineCPUUtilization (시계열)
- 하단: NetworkBytesIn/Out (스택형)
- 하단: 로그 패널 (CloudWatch Logs)
```

**대시보드 2: 채팅 성능**

```
- 상단: Messages Per Second (처리량)
- 상단: Message Latency P50/P95/P99 (백분위수)
- 중단: Active Chat Rooms (추이)
- 중단: WebSocket Connections (추이)
- 하단: Message Loss Rate (목표: 0%)
- 하단: Error Rate (redis, websocket)
```

**대시보드 3: 인프라 통합**

```
- ECS 작업: 실행 중인 백엔드 인스턴스 수
- ASG: 현재 용량 vs 원하는 용량
- ALB: 요청 수, 오류율, 응답 시간
- Redis: 위의 메트릭들 종합
```

**구성 방법**

```
1. Grafana → Data Sources → Add CloudWatch
2. Grafana → New Dashboard
3. 패널 추가: Metrics 쿼리 작성
   예) Namespace=AWS/ElastiCache, MetricName=FreeableMemory
4. 저장 및 공유 (팀 → View 권한)
```

### 11.3 알림 설정 (CloudWatch + SNS)

**Alarm 1: 메모리 부족**

```
조건: FreeableMemory < 102 MB (20%)
지속 시간: 2분 (false positive 방지)
작업: SNS → 이메일 알림
심각도: 경고 (주황색)

이유: 메모리 부족 시 성능 저하, 메모리 정책(LRU) 발동
대응: 불필요한 캐시 정리 또는 인스턴스 업그레이드 검토
```

**Alarm 2: 메모리 사용률 높음**

```
조건: DatabaseMemoryUsagePercentage > 80%
지속 시간: 5분
작업: SNS → Slack 채널 (심각도: 낮음)
심각도: 정보 (파란색)

이유: 용량 계획 신호
대응: 캐싱 전략 재평가, 향후 증설 고려
```

**Alarm 3: 연결 수 증가**

```
조건: CurrConnections > 100
지속 시간: 1분
작업: SNS → 로그만 (자동 조치 없음)
심각도: 정보 (파란색)

이유: 비정상 증가는 아니나, 부하 증가 신호
대응: 성능 메트릭 함께 확인
```

**Alarm 4: Redis 연결 불가**

```
조건: EngineHealthy = 0 (불건강)
지속 시간: 즉시
작업: SNS → 이메일 + SMS
심각도: 긴급 (빨간색)

이유: 서비스 부분 마비 (채팅 로컬만 가능)
대응: 즉시 DevOps 호출, ElastiCache 상태 확인
```

**Alarm 5: 메시지 손실 감지**

```
조건: chat.message.loss > 0
지속 시간: 즉시
작업: SNS → 개발 팀 알림
심각도: 경고 (주황색)

이유: Pub/Sub 정상 작동 확인용
대응: 메시지 시퀀스 로그 검토, 재시도 정책 확인
```

### 11.4 로그 집계 및 분석

**CloudWatch Logs**

```
로그 그룹: /ecs/billage-backend-dev
로그 스트림: task/billage-backend/xxxxx

검색 필터:
- "[ERROR]" → Redis 오류
- "RedisConnectionException" → 연결 문제
- "message.published" → 메시지 발행 로그
- "timeout" → 지연/타임아웃
```

**Insights 쿼리**

```
# 초당 메시지 처리율
fields @timestamp, @message | filter @message like /published/ | stats count() as message_count by bin(5m)

# 평균 메시지 지연 (ms)
fields @message | filter @message like /latency/ | stats avg(latency) as avg_latency

# Redis 오류 빈도
fields @timestamp | filter @message like /RedisConnectionException/ | stats count() as error_count by bin(1m)
```

**체크리스트**:
- [ ] CloudWatch Logs 그룹 생성
- [ ] Log Insights 쿼리 저장 (재사용용)
- [ ] 로그 보존 기간 설정 (30일 권장)

### 11.5 주기적 리뷰

**일간 (매일 아침)**

```
체크리스트:
- [ ] Grafana 대시보드 확인 (전날 문제 있었는지)
- [ ] SNS 알람 이메일 확인
- [ ] Redis 메모리 사용률 추이 (정상 범위?)
- [ ] 메시지 처리율 (평소 수준?)
```

**주간 (매주 금요일)**

```
체크리스트:
- [ ] 일간 리뷰 요약
- [ ] 성능 메트릭 비교 (주 vs 주)
- [ ] 메모리 사용 추이 (증가 기울기?)
- [ ] 에러율 및 타임아웃 분석
- [ ] 용량 계획 검토 (언제쯤 업그레이드?)
```

**월간 (매월 말)**

```
체크리스트:
- [ ] 전월 메트릭 종합 리포트
- [ ] 성능 기준선 vs 실제 (baseline 업데이트?)
- [ ] 용량 증가 추이 (선형 vs 지수?)
- [ ] 향후 3개월 용량 예측
- [ ] 인스턴스 업그레이드 필요성 평가
```

---

## 12. 향후 고려사항 (프로덕션 전환 시)

### 12.1 Redis Replication (Master-Replica)

**Dev 환경**: 단일 노드 (현재)

**Prod 환경 (권장)**

```
Master Node (primary): 읽기/쓰기
Replica Node (secondary): 읽기만 가능, 자동 백업용

이점:
- 고가용성: Master 장애 시 Replica 승격 (자동 failover)
- 성능: 읽기 요청을 Replica로 분산 (read scaling)
- 백업: Replica에서 스냅샷 생성 (Master 영향 없음)

비용: 약 2배 (인스턴스 2개)
```

**도입 시기**

```
Prod 단계에서, 가용성 요구사항이 높을 때
Dev에서는 단일 노드로 비용 절감
```

### 12.2 Redis Cluster (수평 확장)

**현재 (단일 인스턴스)**

```
메모리 한계: 최대 인스턴스 크기 (cache.r7g.16xlarge = 768GB)
확장성: 메모리를 늘릴 수만 있음 (수직 확장)
```

**향후 필요 시 (Cluster)**

```
데이터가 512GB를 초과할 때:

예시:
- Master 1: 512GB (Partition 0~5000)
- Master 2: 512GB (Partition 5001~10000)
- Master 3: 512GB (Partition 10001~16383)

이점:
- 무제한 확장성 (노드 추가)
- 높은 처리량 (병렬 처리)

단점:
- 복잡도 증가 (키 분배, 파티션)
- Pub/Sub 성능 저하 (클러스터 전반 브로드캐스트)

채팅에는 권장하지 않음 (Pub/Sub 특성상).
대신 메시지 히스토리 캐싱용으로 고려.
```

### 12.3 Redis 백업 및 복구

**Dev (현재): 백업 불필요**

```
이유:
- 메시지는 DB에 저장 (Redis는 임시 저장소)
- Redis 손실 = 채팅 Pub/Sub만 불가 (메시지 히스토리는 안전)
```

**Prod: 자동 백업 활성화**

```
ElastiCache 파라미터:
snapshot-interval: 60 (분)  → 1시간마다
snapshot-window: 03:00-04:00 (UTC) → 아침 시간대
snapshot-retention: 7 (days)  → 7일 보관

용도:
- Pub/Sub 설정 및 메타데이터 백업
- 재해 복구 시 빠른 복구
```

### 12.4 보안 강화 (Prod)

**현재 (Dev): 최소 보안**

```
- VPC 내부 전용 (외부 접근 불가)
- 인증 없음 (VPC CIDR 신뢰)
- 암호화 없음 (같은 네트워크)
```

**Prod (권장)**

```
1. AUTH Token 활성화
   - Redis 명령에 암호 요청
   - ElastiCache: Enable AUTH Token
   - Spring Boot: spring.redis.password

2. 인 트랜싯 암호화 (TLS)
   - ElastiCache: Enable In-Transit Encryption
   - 모든 네트워크 트래픽 암호화
   - 성능 오버헤드: 5~10%

3. 인 레스트 암호화 (KMS)
   - ElastiCache: Enable At-Rest Encryption
   - 디스크 저장 시 암호화 (백업 포함)
   - 성능 오버헤드: < 2%

4. 보안 그룹: 최소 권한
   - Backend SG만 6379 포트 허용
   - 다른 보안 그룹 차단
```

---

## 13. 결론

Redis 도입은 Billage v2의 **다중 인스턴스 아키텍처에서 필수적인 인프라 변화**이다. 단일 인스턴스의 로컬 메모리만으로는 불가능한 "인스턴스 간 메시지 브로드캐스트"를 Redis Pub/Sub으로 안정적으로 구현할 수 있다.

**핵심 성공 요소**

1. **명확한 우선순위**: P0 (Chat Pub/Sub) → P1 (선택) → P2 (선택)
2. **Graceful Degradation**: Redis 장애 시에도 시스템이 부분 기능 유지
3. **적절한 모니터링**: CloudWatch + Grafana로 실시간 상태 파악
4. **Phase별 진행**: 단계적 구현 및 검증으로 리스크 최소화

**초기 투자**

- 인프라: ElastiCache 비용 (~$15/월 Dev, 확대 시 증가)
- 개발: 2~3주 (코드 작성 + 테스트)
- 운영: 월 1~2시간 (모니터링 리뷰)

**기대 효과**

- 채팅 메시지 신뢰성 향상 (인스턴스 간 동기화)
- 시스템 확장성 확보 (1~6개 인스턴스 자유로운 스케일링)
- 향후 캐싱 및 세션 관리 기반 마련

이 문서는 초기 도입 가이드이며, Prod 단계로의 전환 시 추가 보안 및 고가용성 요구사항을 반영하여 업데이트할 것이다.
