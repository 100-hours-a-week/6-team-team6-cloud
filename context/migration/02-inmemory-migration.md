# Billage 메시지 브로커 마이그레이션 계획서 (로컬 Simple Broker → RabbitMQ)

## 1. 개요

Billage v2에서 백엔드 인스턴스를 단일 서버에서 ASG 기반 다중 인스턴스(1~6개)로 확장하면서, 지금까지 단일 인스턴스 내에서만 유지되던 WebSocket 채팅 메시지가 **네트워크를 통해 인스턴스 간에 공유되어야 하는 근본적인 변화**가 생긴다. RabbitMQ는 이러한 분산 시스템에서의 메시지 브로드캐스트 문제를 해결하는 핵심 인프라이며, 특히 채팅 기능의 안정적인 멀티캐스팅을 가능하게 한다.

RabbitMQ 도입의 가장 중요한 목표는 **STOMP 프로토콜을 통한 분산 메시지 브로드캐스트**이다. 이는 Spring의 내장 Simple Broker를 외부 메시지 브로커로 대체하는 것으로, 300K MAU 규모의 다중 인스턴스 환경에서 모든 사용자에게 메시지를 신뢰성 있게 전달한다.

---

## 2. 현재 상태 (AS-IS): v1 아키텍처

### 2.1 기본 구성

- **백엔드 서버**: 단일 EC2 인스턴스로 운영
- **WebSocket 메시지 브로커**: Spring STOMP SimpleBrokerMessageHandler (메모리 기반)
- **구독 정보 저장**: 메모리 내 (모든 연결이 같은 프로세스 내에서 관리)
- **세션 관리**: JWT 기반 stateless 인증 — 서버 측 세션 저장소 불필요
- **메시지 저장**: WebSocket 메시지는 DB에 저장, 실시간 전달은 메모리 큐 사용

### 2.2 단일 인스턴스에서 외부 브로커가 불필요한 이유

사용자 A가 연결한 WebSocket과 사용자 B가 연결한 WebSocket이 **같은 프로세스 내의 이벤트 루프에서 관리**되기 때문에, Spring의 SimpleBrokerMessageHandler만으로도 메시지 전달이 가능하다. 외부 메시지 브로커가 필요 없다.

```
User A ──── WebSocket ──── [Backend Instance 1 (포트 8080)]
                               ↓
                          SimpleBroker (메모리)
                               ↓
User B ──── WebSocket ──── [Backend Instance 1 (포트 8080)]
```

이 구조에서는 모든 메시지가 같은 메모리 공간을 공유하고, 구독 관계도 로컬에서만 유지된다.

### 2.3 현재 채팅 아키텍처 상세

**메시지 흐름**
1. 클라이언트 A가 WebSocket을 통해 `/app/chat/room/{roomId}` 엔드포인트로 메시지 전송
2. Spring STOMP 처리기가 메시지를 수신
3. `SimpleBrokerMessageHandler`가 메모리에서 `/sub/chat/room/{roomId}`를 구독 중인 모든 클라이언트 검색
4. 찾은 클라이언트들에게 메시지 전달 (같은 인스턴스에만)
5. 동시에 메시지를 DB에 저장

**300K MAU 기준 예상 부하**
- DAU: ~10,000명 (MAU 기준 약 5%)
- 동시 접속 피크: ~1,000명
- 활성 채팅방: 250-300개
- 채팅방당 평균 사용자: 3-5명
- 메시지 생성율 (피크): 50-200 msg/sec
- WebSocket 동시 연결: 300-500개

---

## 3. 목표 상태 (TO-BE): v2 아키텍처

### 3.1 RabbitMQ 개요

RabbitMQ는 AMQP 표준을 구현한 오픈소스 메시지 브로커로, STOMP 플러그인을 활성화하면 STOMP 프로토콜을 지원한다. 이를 통해 Spring의 STOMP 클라이언트가 외부 브로커와 직접 통신할 수 있다.

**아키텍처**
```
User A ──── WebSocket(STOMP) ──── [Backend Instance 1]
                                         ↓
                                  StompBrokerRelay
                                         ↓
                                  RabbitMQ (STOMP Plugin)
                                         ↓
User B ──── WebSocket(STOMP) ──── [Backend Instance 2]
                                         ↓
                                  StompBrokerRelay
```

모든 인스턴스가 RabbitMQ에 연결되어 있으므로, Instance 1의 메시지는 RabbitMQ를 거쳐 Instance 2의 클라이언트에게 전달된다.

### 3.2 배포 옵션 비교

| 옵션 | 방식 | 장점 | 단점 | 비용 (월) |
|------|------|------|------|---------|
| **Option A** | Amazon MQ for RabbitMQ (관리형) | 자동 패치, 모니터링, 고가용성 | 높은 비용, 과도한 리소스 | $150~300 |
| **Option B** | EC2에 직접 설치 (자가 관리) | 낮은 비용, 완전한 제어 | 운영 부담 증가, 보안 관리 필요 | $20~50 |
| **권장** | Option B (EC2 설치) | Billage 포트폴리오 규모에 충분 | - | - |

**선택 근거**
- 300K MAU 규모: RabbitMQ 단일 인스턴스로 충분
- 고가용성보다는 비용 효율성 우선 (Graceful Degradation로 커버)
- EC2 t3.medium 정도로 충분한 성능

### 3.3 RabbitMQ 사양 (300K MAU 기준)

| 항목 | 값 | 근거 |
|------|-----|------|
| 인스턴스 타입 | EC2 t3.medium 또는 t3.small | 메모리 4GB (small) 또는 8GB (medium) |
| 메모리 | 4~8GB | Pub/Sub은 메시지 저장 안 함, 구독자 메타만 필요 (~100-500MB) |
| 디스크 | 20GB EBS | 메시지 TTL 짧음, 로그만 저장 |
| vCPU | 2 코어 | 채팅 메시지 처리는 CPU 집약적 아님 |
| 네트워크 | Enhanced Networking | 높은 처리량 지원 |
| **Erlang/RabbitMQ 버전** | RabbitMQ 3.12+ (최신 LTS) | STOMP Plugin 최신 버전 지원 |
| **플러그인 활성화** | STOMP, Management | STOMP: 메시지 브로드캐스트용, Management: 모니터링용 |

**메모리 분석 (300K MAU)**
```
RabbitMQ 기본 오버헤드: ~200-300MB
STOMP 연결 메타데이터: ~1MB
채팅방 구독자 정보: 300개 채팅방 × 3-5 구독자 × ~1KB = ~3-5MB
메시지 큐 (Pub/Sub은 저장 안 함): 최소 필요
총 필요: 400-500MB (안전 마진 포함 2-3GB 권장)

t3.small (4GB): 충분
t3.medium (8GB): 여유 있음, 향후 확장 대비
```

### 3.4 네트워크 배치

- **배치**: 프라이빟 서브넷 (shared/rabbitmq/ Terraform 참조)
- **서브넷**: 10.0.10.0/24, 10.0.11.0/24 (기존 DB 서브넷 그룹과 동일)
- **보안 그룹**:
  - 5672 포트 (AMQP): 백엔드 보안 그룹에서만 허용
  - 61613 포트 (STOMP): 백엔드 보안 그룹에서만 허용
  - 15672 포트 (Management UI): 운영 팀 IP에서만 허용 (또는 VPN)
- **public endpoint 없음**: VPC 외부에서 직접 접근 불가 (의도적)

### 3.5 유지보수 윈도우

- **시간**: 월요일 20:00~21:00 UTC (아침 05:00~06:00 KST)
- **작업**: RabbitMQ 버전 업데이트, OS 패치 (필요시)
- **자동화**: Terraform/IaC로 재배포 가능하게 구성

### 3.6 SSM Parameter Store 등록

```
/billage/dev/rabbitmq/host     → rabbitmq-instance.internal or IP
/billage/dev/rabbitmq/stomp_host   → 동일 (STOMP 연결용)
/billage/dev/rabbitmq/stomp_port   → 61613
/billage/dev/rabbitmq/username → guest (기본값 또는 사용자정의)
/billage/dev/rabbitmq/password → (필요시 설정, 초기: 불필요)
```

Spring Boot 애플리케이션은 배포 시 SSM 파라미터를 읽어 RabbitMQ 연결 설정을 동적으로 구성한다.

---

## 4. Spring STOMP 아키텍처 변경

### 4.1 SimpleBroker vs StompBrokerRelay

| 항목 | SimpleBroker | StompBrokerRelay |
|------|--------------|------------------|
| **위치** | 애플리케이션 메모리 내 | 외부 RabbitMQ |
| **메시지 흐름** | 직접 메모리 전달 | STOMP 프로토콜 통신 |
| **다중 인스턴스 지원** | ✗ (각 인스턴스 독립) | ✓ (모든 인스턴스 동기화) |
| **구독 정보 저장** | 애플리케이션 메모리 | RabbitMQ 메모리 |
| **메시지 순서 보장** | ✓ (같은 인스턴스) | ✓ (STOMP 채널 기준) |
| **장애 처리** | 인스턴스 다운 시 메모리 모두 유실 | RabbitMQ 장애 시만 영향 |

### 4.2 코드 변경 사항

**WebSocketMessageBrokerConfigurer 수정**

AS-IS (SimpleBroker):
```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    @Override
    public void configureMessageBroker(MessageBrokerRegistry config) {
        config.enableSimpleBroker("/sub");  // 로컬 메모리 브로커
        config.setApplicationDestinationPrefixes("/app");
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws/chat").setAllowedOrigins("*");
    }
}
```

TO-BE (StompBrokerRelay):
```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    @Value("${rabbitmq.stomp.host}")
    private String brokerHost;

    @Value("${rabbitmq.stomp.port}")
    private Integer brokerPort;

    @Value("${rabbitmq.username:guest}")
    private String username;

    @Value("${rabbitmq.password:guest}")
    private String password;

    @Override
    public void configureMessageBroker(MessageBrokerRegistry config) {
        config.enableStompBrokerRelay("/sub")
            .setRelayHost(brokerHost)
            .setRelayPort(brokerPort)
            .setClientLogin(username)
            .setClientPasscode(password)
            .setSystemLogin(username)
            .setSystemPasscode(password)
            .setConnectTimeout(10000)
            .setHeartbeat(10000, 10000);  // 10초 heartbeat

        config.setApplicationDestinationPrefixes("/app");
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws/chat").setAllowedOrigins("*");
    }
}
```

**application.yml 추가**

```yaml
rabbitmq:
  stomp:
    host: ${/billage/dev/rabbitmq/stomp_host}
    port: ${/billage/dev/rabbitmq/stomp_port}
  username: ${/billage/dev/rabbitmq/username}
  password: ${/billage/dev/rabbitmq/password}

logging:
  level:
    org.springframework.messaging: DEBUG
    org.springframework.web.socket: DEBUG
```

### 4.3 메시지 전송 로직은 변경 없음

메시지 송수신 코드는 STOMP 프로토콜 레벨에서 동일하므로 변경 불필요:

```java
@Controller
public class ChatController {

    @MessageMapping("/chat/room/{roomId}")  // /app/chat/room/{roomId}에 들어온 메시지
    @SendTo("/sub/chat/room/{roomId}")      // /sub/chat/room/{roomId}에 구독 중인 클라이언트에게 전송
    public ChatMessageResponse sendMessage(ChatMessage message) {
        // 변경 없음 — StompBrokerRelay가 자동으로 RabbitMQ에 전달
        return new ChatMessageResponse(message);
    }
}
```

### 4.4 구독 경로도 변경 없음

클라이언트 측 WebSocket 구독 코드도 동일:
```javascript
// 변경 전/후 동일
stompClient.subscribe('/sub/chat/room/' + roomId, function(message) {
    console.log('Received:', JSON.parse(message.body));
});
```

---

## 5. 마이그레이션 실행 계획

### 5.1 Step 1: RabbitMQ 인스턴스 프로비저닝

**Option B 선택 (EC2 설치)**

**1-1. EC2 인스턴스 생성**

- **타입**: t3.small (vCPU 2, 메모리 2GB) 또는 t3.medium (vCPU 2, 메모리 4GB)
- **OS**: Amazon Linux 2 또는 Ubuntu 22.04 LTS
- **EBS**: 20GB gp3
- **서브넷**: 프라이빗 (10.0.10.0/24)
- **보안 그룹**: rabbitmq-sg (별도 생성)
- **IAM 역할**: CloudWatch Logs, Systems Manager Session Manager 접근

**Terraform 코드 예시**

```hcl
# shared/rabbitmq/main.tf
resource "aws_instance" "rabbitmq" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = "t3.small"  # 또는 t3.medium
  subnet_id     = var.private_subnet_id

  vpc_security_group_ids = [aws_security_group.rabbitmq.id]
  iam_instance_profile   = aws_iam_instance_profile.rabbitmq.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/install-rabbitmq.sh", {
    rabbitmq_version = "3.12.1"
  }))

  tags = {
    Name = "billage-rabbitmq-dev"
  }
}

resource "aws_security_group" "rabbitmq" {
  name   = "billage-rabbitmq-dev-sg"
  vpc_id = var.vpc_id

  # STOMP
  ingress {
    from_port       = 61613
    to_port         = 61613
    protocol        = "tcp"
    security_groups = [var.backend_sg_id]
  }

  # AMQP (내부용)
  ingress {
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [var.backend_sg_id]
  }

  # Management UI (운영팀용)
  ingress {
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr_block]  # VPN IP 또는 운영팀 IP
  }

  # 아웃바운드
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

**1-2. RabbitMQ 설치 스크립트**

```bash
#!/bin/bash
# install-rabbitmq.sh

set -e

# 패키지 업데이트
sudo yum update -y
sudo yum install -y erlang-25.x

# RabbitMQ 설치
sudo yum install -y rabbitmq-server

# STOMP 플러그인 활성화
sudo rabbitmq-plugins enable rabbitmq_stomp
sudo rabbitmq-plugins enable rabbitmq_management
sudo rabbitmq-plugins enable rabbitmq_management_agent

# RabbitMQ 시작
sudo systemctl start rabbitmq-server
sudo systemctl enable rabbitmq-server

# 기본 사용자 설정 (선택)
# sudo rabbitmqctl add_user billage ${RABBITMQ_PASSWORD}
# sudo rabbitmqctl set_permissions -p / billage ".*" ".*" ".*"

# 로그 출력
echo "RabbitMQ installation complete"
sudo rabbitmqctl status
```

**1-3. 프로비저닝 검증**

```bash
# EC2 인스턴스에 SSH 접속 (Systems Manager Session Manager)
aws ssm start-session --target i-xxxxxxxxx

# RabbitMQ 상태 확인
sudo rabbitmqctl status

# STOMP 플러그인 확인
sudo rabbitmqctl list_plugins | grep stomp
# 출력 예: [E* ] rabbitmq_stomp

# 포트 확인
sudo ss -tlnp | grep -E '5672|61613|15672'
# 출력: 0.0.0.0:61613, 0.0.0.0:5672, 127.0.0.1:15672
```

**담당**: DevOps/Infra 엔지니어

**체크리스트**:
- [ ] EC2 인스턴스 생성
- [ ] RabbitMQ 설치 완료
- [ ] STOMP, Management 플러그인 활성화
- [ ] 보안 그룹 인바운드 규칙 확인 (5672, 61613, 15672)
- [ ] EC2에서 포트 리스닝 확인

### 5.2 Step 2: 백엔드 코드 수정

**2-1. application.yml 프로필 분리**

```yaml
# application-local.yml (로컬 개발)
spring:
  profiles:
    active: local

# 단순히 로컬에서는 SimpleBroker 계속 사용 가능
# (RabbitMQ 설정 없음)
```

```yaml
# application-dev.yml (Dev 환경)
rabbitmq:
  stomp:
    host: ${/billage/dev/rabbitmq/stomp_host}
    port: 61613
  username: guest
  password: guest
```

**2-2. WebSocketConfig 클래스 수정**

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    @Value("${rabbitmq.stomp.host:localhost}")
    private String brokerHost;

    @Value("${rabbitmq.stomp.port:61613}")
    private Integer brokerPort;

    @Value("${rabbitmq.username:guest}")
    private String username;

    @Value("${rabbitmq.password:guest}")
    private String password;

    @Override
    public void configureMessageBroker(MessageBrokerRegistry config) {
        if (isRabbitMQEnabled()) {
            // RabbitMQ 모드 (Dev/Prod)
            config.enableStompBrokerRelay("/sub")
                .setRelayHost(brokerHost)
                .setRelayPort(brokerPort)
                .setClientLogin(username)
                .setClientPasscode(password)
                .setSystemLogin(username)
                .setSystemPasscode(password)
                .setConnectTimeout(10000)
                .setHeartbeat(10000, 10000);
        } else {
            // SimpleBroker 모드 (Local 개발)
            config.enableSimpleBroker("/sub");
        }

        config.setApplicationDestinationPrefixes("/app");
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws/chat")
            .setAllowedOrigins("*")
            .withSockJS();  // fallback for older browsers
    }

    private boolean isRabbitMQEnabled() {
        return !brokerHost.equals("localhost") || brokerPort != 61613;
    }
}
```

**2-3. 로깅 강화**

```java
@Configuration
public class WebSocketLoggingConfig {

    @Bean
    public TcpOperationsHandler tcpOperationsHandler() {
        return new TcpOperationsHandler() {
            @Override
            public void onTcpConnected(String sessionId) {
                log.info("STOMP Relay connected: {}", sessionId);
            }

            @Override
            public void onTcpDisconnected(String sessionId) {
                log.warn("STOMP Relay disconnected: {}", sessionId);
            }
        };
    }
}
```

**담당**: Backend 엔지니어

**체크리스트**:
- [ ] WebSocketConfig 수정 완료
- [ ] RabbitMQ 연결 설정 추가
- [ ] SimpleBroker fallback 구현
- [ ] application-dev.yml 작성
- [ ] application-local.yml 확인
- [ ] 로컬 빌드 성공 (mvn clean install)

### 5.3 Step 3: 로컬 통합 테스트

**3-1. docker-compose 환경 구성**

```yaml
# docker-compose.yml
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.12-management-alpine
    container_name: billage-rabbitmq
    ports:
      - "5672:5672"    # AMQP
      - "61613:61613"  # STOMP
      - "15672:15672"  # Management UI
    environment:
      RABBITMQ_DEFAULT_USER: guest
      RABBITMQ_DEFAULT_PASS: guest
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    networks:
      - billage-net

  postgres:
    image: postgres:15-alpine
    container_name: billage-postgres
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: billage
      POSTGRES_PASSWORD: password
      POSTGRES_DB: billage_dev
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U billage"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - billage-net

  backend:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: billage-backend
    ports:
      - "8080:8080"
    environment:
      SPRING_PROFILES_ACTIVE: dev
      RABBITMQ_STOMP_HOST: rabbitmq
      RABBITMQ_STOMP_PORT: 61613
      RABBITMQ_USERNAME: guest
      RABBITMQ_PASSWORD: guest
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/billage_dev
      SPRING_DATASOURCE_USERNAME: billage
      SPRING_DATASOURCE_PASSWORD: password
    depends_on:
      rabbitmq:
        condition: service_healthy
      postgres:
        condition: service_healthy
    networks:
      - billage-net

networks:
  billage-net:
    driver: bridge

volumes:
  rabbitmq_data:
  postgres_data:
```

**실행**

```bash
docker-compose up -d
docker-compose logs -f backend
```

**담당**: Backend 엔지니어

**체크리스트**:
- [ ] docker-compose.yml 작성
- [ ] RabbitMQ 서비스 시작 및 헬스체크 성공
- [ ] PostgreSQL 시작 및 헬스체크 성공
- [ ] Backend 서비스 시작 및 로그 확인
- [ ] RabbitMQ Management UI 접속 가능 (http://localhost:15672)

### 5.4 Step 4: 채팅 테스트

**4-1. 단일 인스턴스 채팅 테스트**

```
시나리오:
1. 웹소켓 클라이언트 A 연결 (ws://localhost:8080/ws/chat)
2. 채팅방 room-001에 구독 (/sub/chat/room/room-001)
3. 메시지 송신: "Hello from local"
4. 동일 인스턴스의 클라이언트 B가 메시지 수신 확인
5. DB에 메시지 저장 확인
```

**테스트 코드**

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
public class ChatWebSocketTest {

    @LocalServerPort
    private int port;

    @Test
    public void testSingleInstanceChat() throws Exception {
        // WebSocket 연결
        StompSession session = stompClient.connect(
            "ws://localhost:" + port + "/ws/chat",
            new StompSessionHandlerAdapter() {})
            .get();

        // /sub/chat/room-001 구독
        session.subscribe("/sub/chat/room-001",
            new DefaultStompFrameHandler<>(ChatMessage.class) {
                @Override
                public void handleFrame(StompHeaders headers, ChatMessage payload) {
                    assertEquals("Hello from local", payload.getContent());
                }
            });

        // 메시지 송신
        ChatMessage message = new ChatMessage("room-001", "user-001", "Hello from local");
        session.send("/app/chat/room-001", message);

        // DB에서 메시지 확인
        await()
            .timeout(Duration.ofSeconds(5))
            .untilAsserted(() -> {
                Optional<ChatMessage> saved = chatMessageRepository
                    .findByContentAndRoomId("Hello from local", "room-001");
                assertTrue(saved.isPresent());
            });
    }
}
```

**담당**: QA/Backend 엔지니어

**체크리스트**:
- [ ] WebSocket 연결 성공
- [ ] 메시지 송수신 성공
- [ ] DB 저장 확인
- [ ] RabbitMQ 큐 상태 확인 (Management UI)
- [ ] 로그에 오류 없음

**4-2. 다중 인스턴스 채팅 테스트 (선택사항)**

```bash
# docker-compose에서 backend를 2개로 확장
docker-compose up -d --scale backend=2

# 클라이언트 A → Backend Instance 1 연결
# 클라이언트 B → Backend Instance 2 연결
# A에서 메시지 송신 → A와 B 모두 수신 확인
```

**담당**: QA 엔지니어

**체크리스트**:
- [ ] 2개 인스턴스 모두 구동 확인
- [ ] 다른 인스턴스로 라우팅된 클라이언트 확인
- [ ] 메시지 크로스 인스턴스 전달 확인

### 5.5 Step 5: 부하 테스트

**5-1. 테스트 시나리오**

```
시나리오 1: 정상 운영 (기저 부하)
- 동시 채팅방: 10개
- 채팅방당 메시지율: 3-5 msg/sec
- 총 메시지율: 30-50 msg/sec
- WebSocket 연결: 50-100개
- 지속 시간: 5분

시나리오 2: 중간 부하
- 동시 채팅방: 50개
- 채팅방당 메시지율: 3-5 msg/sec
- 총 메시지율: 150-250 msg/sec
- WebSocket 연결: 200-300개
- 지속 시간: 5분

시나리오 3: 피크 부하 (목표)
- 동시 채팅방: 250-300개
- 채팅방당 메시지율: 2-3 msg/sec
- 총 메시지율: 500-900 msg/sec
- WebSocket 연결: 800-1200개
- 지속 시간: 3분
```

**부하 테스트 도구**

Apache JMeter 또는 locust:

```python
# locust를 사용한 예시
from locust import HttpUser, WebSocketClient, task, between
import json

class ChatUser(HttpUser):
    wait_time = between(1, 3)

    def on_start(self):
        self.ws = WebSocketClient(
            base_url=self.host,
            on_message=self.on_message
        )
        self.ws.connect()

    @task
    def send_message(self):
        message = {
            "roomId": "room-001",
            "content": "Test message",
            "senderId": "user-test"
        }
        self.ws.send(json.dumps(message))

    def on_message(self, message):
        # 메시지 수신 처리
        pass
```

**측정 항목**

| 지표 | 정상 범위 | 경고 범위 | 심각 범위 |
|------|---------|---------|---------|
| RabbitMQ 메모리 사용률 | < 30% | 50-70% | > 80% |
| RabbitMQ CPU | < 40% | 60-80% | > 90% |
| 메시지 지연 (P95) | < 100ms | 100-300ms | > 300ms |
| 메시지 지연 (P99) | < 200ms | 200-500ms | > 500ms |
| 메시지 손실률 | 0% | > 0.01% | > 0.1% |
| 연결 풀 활성 연결 | < 50 | 50-100 | > 100 |

**담당**: Performance 엔지니어

**체크리스트**:
- [ ] 부하 테스트 스크립트 작성
- [ ] 시나리오 1, 2, 3 실행
- [ ] 메트릭 수집 및 분석
- [ ] 병목 지점 확인
- [ ] 결과 보고서 작성

---

## 6. Dev 환경 배포

### 6.1 Step 1: Docker 이미지 빌드 및 ECR 푸시

```bash
# 이미지 빌드
docker build -t billage-backend:v2.0.0-rabbitmq .

# ECR 로그인
aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin <ecr-repo>

# 이미지 태그 및 푸시
docker tag billage-backend:v2.0.0-rabbitmq \
  <ecr-repo>/billage-backend:v2.0.0-rabbitmq
docker push <ecr-repo>/billage-backend:v2.0.0-rabbitmq
```

**담당**: DevOps 엔지니어

**체크리스트**:
- [ ] Docker 빌드 성공
- [ ] ECR 푸시 성공
- [ ] 이미지 취약성 스캔

### 6.2 Step 2: ECS 작업 정의 업데이트

```json
{
  "family": "billage-backend-dev",
  "taskRoleArn": "arn:aws:iam::ACCOUNT:role/billage-backend-dev",
  "executionRoleArn": "arn:aws:iam::ACCOUNT:role/ecsTaskExecutionRole",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "billage-backend",
      "image": "<ecr-repo>/billage-backend:v2.0.0-rabbitmq",
      "portMappings": [{"containerPort": 8080}],
      "environment": [
        {"name": "SPRING_PROFILES_ACTIVE", "value": "dev"},
        {"name": "RABBITMQ_STOMP_HOST", "value": "<rabbitmq-instance-ip>"}
      ],
      "secrets": [
        {
          "name": "RABBITMQ_STOMP_PORT",
          "valueFrom": "/billage/dev/rabbitmq/stomp_port"
        },
        {
          "name": "RABBITMQ_USERNAME",
          "valueFrom": "/billage/dev/rabbitmq/username"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/billage-backend-dev",
          "awslogs-region": "ap-northeast-2",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ],
  "cpu": "1024",
  "memory": "2048",
  "requiresCompatibilities": ["EC2", "FARGATE"]
}
```

**담당**: DevOps 엔지니어

**체크리스트**:
- [ ] 작업 정의 생성/업데이트
- [ ] SSM 파라미터 참조 확인
- [ ] IAM 역할 권한 확인

### 6.3 Step 3: ECS 서비스 배포

```bash
# 서비스 업데이트 (Blue/Green 배포)
aws ecs update-service \
  --cluster dev \
  --service billage-backend \
  --task-definition billage-backend-dev:2 \
  --force-new-deployment

# 배포 상태 확인
aws ecs describe-services \
  --cluster dev \
  --services billage-backend \
  --query 'services[0].deployments'
```

**소요 시간**: 약 5~10분

**담당**: DevOps 엔지니어

**체크리스트**:
- [ ] 기존 인스턴스 정상 운영
- [ ] 새 이미지 배포 (롤링 업데이트)
- [ ] 모든 인스턴스 RUNNING 상태
- [ ] CloudWatch 로그에 RabbitMQ 연결 메시지 확인

### 6.4 Step 4: Dev 환경 통합 테스트

```
1. 2~3개 백엔드 인스턴스 구동 (ASG 확인)
2. 채팅 애플리케이션 접속
3. 여러 클라이언트에서 메시지 송수신
4. RabbitMQ 메트릭 모니터링 (CPU, Memory, Connection Count)
5. 인스턴스 스케일 업/다운 중 메시지 손실 없음 확인
```

**담당**: QA + Backend 엔지니어

**체크리스트**:
- [ ] 다중 인스턴스 채팅 동작 확인
- [ ] 메시지 손실 없음
- [ ] CloudWatch 메트릭 정상 범위
- [ ] 로그 오류 없음

---

## 7. 검증 방법 및 체크리스트

### 7.1 기본 연결 확인

**RabbitMQ STOMP 연결 테스트**

```bash
# EC2에서 RabbitMQ 상태 확인
aws ssm start-session --target i-xxxxxxxxx
sudo rabbitmqctl status

# STOMP 포트 리스닝 확인
sudo ss -tlnp | grep 61613

# 백엔드에서 STOMP 연결 테스트 (telnet 또는 nc)
nc -zv <rabbitmq-ip> 61613
```

**Spring Boot 로그 확인**

```bash
# CloudWatch Logs에서 RabbitMQ 연결 로그 검색
aws logs tail /ecs/billage-backend-dev --follow | grep -i stomp

# 예상 로그:
# [INFO] org.springframework.messaging.simp.stomp.StompBrokerRelayMessageHandler
#        : Initializing STOMP broker relay
# [INFO] io.lettuce.core... (또는 spring websocket logs)
```

**체크리스트**:
- [ ] RabbitMQ 포트 61613 리스닝 확인
- [ ] Spring Boot 로그에 STOMP 브로커 초기화 메시지
- [ ] 보안 그룹 규칙 확인 (61613 ← Backend SG)

### 7.2 메시지 전달 테스트

**End-to-End 테스트**

```
조건:
- Backend Instance 1 (포트 8080): 클라이언트 A 연결
- Backend Instance 2 (포트 8081): 클라이언트 B 연결

단계:
1. 클라이언트 A: WebSocket 연결 → /ws/chat
2. 클라이언트 B: WebSocket 연결 → /ws/chat
3. 둘 다 /sub/chat/room-001 구독
4. 클라이언트 A: 메시지 송신 → "Hello from Instance 1"
5. 확인: A와 B 모두 "Hello from Instance 1" 수신
6. 클라이언트 B: 메시지 송신 → "Hello from Instance 2"
7. 확인: A와 B 모두 "Hello from Instance 2" 수신

성공 지표:
- 메시지 송수신 지연 < 100ms
- 메시지 손실: 0개
- 중복 메시지: 0개
```

**RabbitMQ Management UI로 확인**

```
1. http://<rabbitmq-ip>:15672 접속 (username: guest, password: guest)
2. "Queues" 탭에서 STOMP 관련 큐 확인
3. "Connections" 탭에서 활성 STOMP 연결 확인
4. "Channels" 탭에서 메시지 흐름 확인
```

**체크리스트**:
- [ ] 메시지 발행 성공
- [ ] 메시지 형식 정상 (JSON)
- [ ] 채팅방별 채널 격리 확인
- [ ] RabbitMQ Management UI에서 연결/큐 상태 확인

### 7.3 장애 시나리오 테스트

**시나리오 1: RabbitMQ 연결 끊김**

```
사전 조건: 클라이언트 A, B가 채팅방에 연결

단계:
1. RabbitMQ 서비스 중지 (또는 네트워크 단절)
   sudo systemctl stop rabbitmq-server
2. 메시지 송신 시도
3. 동작 관찰

예상 동작:
- 로그: "[ERROR] ... STOMP connection lost"
- 클라이언트: 메시지 대기 또는 오류 표시
- 다른 인스턴스 클라이언트: 메시지 수신 불가
- 채팅방 목록 조회: 정상 (DB 접근)
- 메시지 히스토리: 정상 (DB에서 읽음)

복구:
- RabbitMQ 서비스 재시작
  sudo systemctl start rabbitmq-server
- 자동 재연결 확인 (로그)
```

**체크리스트**:
- [ ] RabbitMQ 중지 후 오류 로그 확인
- [ ] Graceful degradation 동작
- [ ] RabbitMQ 복구 후 자동 재연결
- [ ] 채팅 외 기능 정상 운영

**시나리오 2: 네트워크 지연**

```
도구: tc (traffic control)

단계:
1. Backend ↔ RabbitMQ 간 300ms 지연 추가
   sudo tc qdisc add dev eth0 root netem delay 300ms
2. 메시지 송수신
3. 지연 시간 측정

정리:
sudo tc qdisc del dev eth0 root
```

**체크리스트**:
- [ ] 네트워크 지연 시뮬레이션 설정
- [ ] 메시지 전달 지연 확인
- [ ] 타임아웃 마진 충분 (기본 10초)

---

## 8. 모니터링

### 8.1 핵심 메트릭 (CloudWatch)

**RabbitMQ 메트릭 (EC2 CloudWatch 에이전트)**

| 메트릭 | 수집 주기 | 경보 임계값 | 용도 |
|--------|---------|----------|------|
| CPU Utilization (%) | 1분 | > 70% | 브로커 부하 모니터링 |
| Memory (%) | 1분 | > 80% | 메모리 부족 감지 |
| Disk Usage (%) | 5분 | > 80% | 디스크 부족 감지 |
| Network In/Out | 1분 | 급증 감지 | 비정상 트래픽 |

**RabbitMQ 네이티브 메트릭 (Management API)**

```bash
# RabbitMQ Management API에서 메트릭 수집
curl http://<rabbitmq-ip>:15672/api/overview \
  -u guest:guest | jq '.object_totals'

# 출력 예:
# {
#   "connections": 42,
#   "channels": 84,
#   "queues": 120,
#   "consumers": 100,
#   "exchanges": 20,
#   "messages": 500,
#   "messages_ready": 100,
#   "messages_unacknowledged": 50
# }
```

**애플리케이션 메트릭 (Spring Boot)**

```
spring.websocket.session.count: 활성 WebSocket 세션 수
spring.websocket.message.rate: 메시지 처리율 (msg/sec)
spring.websocket.message.latency: 메시지 지연 (ms)
```

### 8.2 CloudWatch 알람 설정

**Alarm 1: RabbitMQ CPU 높음**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name billage-rabbitmq-cpu-high \
  --alarm-description "RabbitMQ CPU > 70%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 70 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --alarm-actions arn:aws:sns:ap-northeast-2:ACCOUNT:billage-alerts
```

**Alarm 2: RabbitMQ 메모리 높음**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name billage-rabbitmq-memory-high \
  --alarm-description "RabbitMQ Memory > 80%" \
  --metric-name MemoryUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 3
```

**담당**: DevOps 엔지니어

**체크리스트**:
- [ ] CloudWatch 에이전트 설치 (EC2)
- [ ] 메트릭 수집 확인
- [ ] 알람 규칙 설정
- [ ] SNS 주제 구독 (이메일/Slack)

### 8.3 로그 모니터링

```bash
# CloudWatch Logs 그룹 생성
aws logs create-log-group --log-group-name /rabbitmq/billage-dev

# RabbitMQ 로그를 CloudWatch로 전송 (EC2 CloudWatch 에이전트 설정)
# /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json에 다음 추가:
[
  {
    "log_group_name": "/rabbitmq/billage-dev",
    "log_stream_name": "{instance_id}",
    "file_path": "/var/log/rabbitmq/rabbit@*.log"
  }
]

# 오류 검색
aws logs filter-log-events \
  --log-group-name /rabbitmq/billage-dev \
  --filter-pattern "ERROR"
```

**체크리스트**:
- [ ] CloudWatch Logs 그룹 생성
- [ ] 로그 전송 확인
- [ ] 오류 필터 설정
- [ ] 로그 보존 기간 설정 (30일)

---

## 9. 롤백 계획

### 9.1 Fallback: RabbitMQ 연결 실패 시

**자동 처리**

Spring의 StompBrokerRelay가 연결 실패 시:
1. 재시도 로직 활성화 (Exponential backoff)
2. 최대 시간 동안 재연결 시도
3. 재연결 실패 시 로그에 경고

**수동 대응**

```java
@Component
public class RabbitMQHealthCheck {

    @Scheduled(fixedDelay = 30000)  // 30초마다
    public void checkRabbitMQ() {
        try {
            // RabbitMQ 연결 상태 확인
            stompBrokerRelay.isConnected();
        } catch (Exception e) {
            log.error("RabbitMQ 연결 실패: {}", e.getMessage());
            // 알람 발송, 메트릭 증가 등
            metricsService.incrementRabbitMQFailure();
        }
    }
}
```

**최종 폴백: SimpleBroker 복귀**

RabbitMQ가 회복 불가능한 경우:
```bash
# 1. 애플리케이션 프로필 변경
SPRING_PROFILES_ACTIVE=local  # SimpleBroker 모드로 전환

# 2. 서비스 재배포
aws ecs update-service \
  --cluster dev \
  --service billage-backend \
  --force-new-deployment
```

**결과**
- 같은 인스턴스 내 채팅: 가능 (SimpleBroker 사용)
- 다른 인스턴스 간 채팅: 불가
- 부분 서비스 중단 (완전 중단 아님)

**체크리스트**:
- [ ] RabbitMQ 연결 실패 감지 로깅
- [ ] 수동 폴백 절차 테스트
- [ ] SimpleBroker 복귀 시간 < 5분

### 9.2 롤백: RabbitMQ 완전 제거

**상황**: RabbitMQ 도입 후 예상치 못한 문제 발생

**단계**

1. **코드 롤백**
   - WebSocketConfig에서 StompBrokerRelay 제거
   - SimpleBroker로 복귀
   - 새 이미지 빌드 및 배포

2. **인프라 롤백**
   ```bash
   # EC2 인스턴스 종료
   aws ec2 terminate-instances --instance-ids i-xxxxxxxxx

   # Terraform 정리 (선택)
   cd shared/rabbitmq/
   terraform destroy
   ```

3. **모니터링 확인**
   - 채팅 기능 정상화 (단일 인스턴스)
   - 로그 오류 없음
   - 메트릭 정상화

**주의**: 배포된 메시지는 DB에 저장되어 있으므로 메시지 히스토리는 보존된다.

**체크리스트**:
- [ ] 코드 롤백 및 테스트
- [ ] 이미지 재빌드 및 배포
- [ ] SimpleBroker 정상 작동 확인
- [ ] RabbitMQ 인스턴스 종료

---

## 10. Go/No-Go 체크리스트

배포 전 이 체크리스트를 모두 완료해야 함:

### Infrastructure
- [ ] RabbitMQ EC2 인스턴스 프로비저닝 완료
- [ ] STOMP, Management 플러그인 활성화
- [ ] 보안 그룹 인바운드 규칙 설정 (5672, 61613, 15672)
- [ ] EC2에서 포트 리스닝 확인
- [ ] SSM Parameter Store에 연결 정보 등록

### Application Code
- [ ] WebSocketConfig StompBrokerRelay 구현
- [ ] application-dev.yml 작성
- [ ] SimpleBroker fallback 구현
- [ ] 로컬 빌드 성공 (mvn clean install)
- [ ] 유닛 테스트 통과

### Local Testing
- [ ] docker-compose 환경 구성
- [ ] RabbitMQ 서비스 시작 및 헬스체크 성공
- [ ] Backend 서비스 시작 및 RabbitMQ 연결 확인
- [ ] 단일 인스턴스 채팅 테스트 통과
- [ ] RabbitMQ Management UI 접속 가능

### Load Testing
- [ ] 부하 테스트 스크립트 작성
- [ ] 시나리오 1, 2, 3 실행
- [ ] 메트릭 목표값 달성 (P95 < 100ms, CPU < 70%)
- [ ] 메시지 손실 0개 확인
- [ ] 병목 지점 분석 완료

### Deployment
- [ ] Docker 이미지 빌드 및 ECR 푸시
- [ ] ECS 작업 정의 업데이트
- [ ] 보안 그룹 규칙 확인
- [ ] CloudWatch 로그 그룹 생성

### Dev Environment
- [ ] Dev 배포 완료 (2~3개 인스턴스)
- [ ] 다중 인스턴스 채팅 테스트 통과
- [ ] CloudWatch 메트릭 정상 범위
- [ ] RabbitMQ 메모리 < 30%, CPU < 40%
- [ ] 로그 오류 없음

### Monitoring
- [ ] CloudWatch 메트릭 수집 확인
- [ ] 알람 규칙 설정 및 테스트
- [ ] SNS 주제 구독 (이메일/Slack)
- [ ] 대시보드 구성 완료

### Fallback & Rollback
- [ ] RabbitMQ 장애 시 Graceful Degradation 테스트
- [ ] SimpleBroker 복귀 절차 테스트 완료
- [ ] 롤백 시간 < 5분 확인

---

## 11. 리스크 및 주의사항

### 11.1 메시지 전달 보장

**STOMP Pub/Sub의 특성**

RabbitMQ의 STOMP 플러그인은 메시지 브로드캐스트에 최적화되어 있으나, 다음 제약이 있다:

```
1. 메시지 영속성 없음 (기본)
   - 구독자가 없을 때 발행된 메시지는 메모리에만 유지
   - 브로커 재시작 시 손실

2. 메시지 순서 (채널 내)
   - 단일 채널(/sub/chat/room-001)에서는 FIFO 보장
   - 여러 인스턴스의 구독자 간 순서는 최선의 노력 (Best-effort)

3. 전달 보장
   - At-most-once (0회 또는 1회)
   - 재시도 없음
```

**해결책**

```
1. 메시지는 항상 DB에 저장 (영속성 보장)
2. 각 메시지에 sequenceNumber 부여 (순서 감지)
3. 메시지 ID (UUID)로 중복 감지
4. 채팅 히스토리는 DB에서 로드
```

**메시지 포맷**
```json
{
  "id": "msg-uuid-abc123",
  "roomId": "room-001",
  "sequenceNumber": 42,
  "senderId": "user-001",
  "content": "Hello",
  "timestamp": 1707657600000
}
```

### 11.2 메모리 관리

**RabbitMQ 메모리 사용 예측**

```
EC2 t3.small (2GB) 기준:

기본 오버헤드: 300-500MB
Erlang VM: 200-300MB
STOMP 연결 (100개): 100-200MB
큐/Exchange 메타: 50-100MB
여유: 500-600MB

총: ~1.5-1.8GB (안전)
```

**모니터링**

```bash
# EC2에서 메모리 사용 확인
free -h

# RabbitMQ 내부 메모리 상태
sudo rabbitmqctl status | grep memory
```

**경고 임계값**
- > 80%: 경고 (캐시 정책 검토)
- > 95%: 심각 (즉시 개입 필요)

### 11.3 연결 관리

**StompBrokerRelay 연결 풀**

```yaml
# Spring Boot 자동 설정
spring:
  websocket:
    client:
      max-connections: 100 (기본값)
      heartbeat: 10000  # 10초
      tcp-connect-timeout: 10000
      tcp-receive-timeout: 10000
```

**모니터링**

```bash
# 활성 STOMP 연결 확인
curl http://localhost:15672/api/connections -u guest:guest | jq '.' | grep name
```

### 11.4 네트워크 지연

**VPC 내부 지연**

```
일반 상황: 1-5ms
고부하: 10-50ms
네트워크 혼잡: 50-200ms
```

메시지 타임아웃은 기본 10초로 설정되어 있으므로 충분하다.

### 11.5 보안

**현재 (Dev) 보안 수준**

```
- VPC 내부 전용 (외부 접근 불가)
- 인증 없음 (VPC CIDR 신뢰)
- 암호화 없음 (내부 통신)
```

**향후 (Prod) 개선사항**

```
1. STOMP 사용자 인증 추가
   sudo rabbitmqctl add_user billage <password>

2. SSL/TLS 암호화 활성화
   STOMP 포트 61613 → 61614 (TLS)

3. 접근 제어 강화
   VPC Endpoint 사용 (프라이빗 링크)
```

---

## 12. 향후 고려사항 (프로덕션 전환 시)

### 12.1 고가용성 (HA)

**현재 (Dev)**: 단일 RabbitMQ 인스턴스

**권장 (Prod)**:
```
Master RabbitMQ (Primary)
Replica RabbitMQ (Secondary) with Standby
(또는 AWS ELB with Auto Failover)
```

**이점**
- Master 장애 시 자동 전환
- 읽기 부하 분산
- 백업 생성 (Replica에서)

**비용**: 약 2배

### 12.2 메시지 지속성 (선택사항)

**현재**: 메시지 캐시 없음 (Pub/Sub만)

**향후**: 메시지 큐 추가
```
채팅 메시지 → RabbitMQ 큐 → 지속 저장 → 히스토리
(DB와의 이중 저장으로 신뢰성 극대화)
```

### 12.3 클러스터링

**데이터 규모 > 512GB일 때만 필요**

현재 범위에서는 고려하지 않음.

---

## 13. 결론

RabbitMQ 도입은 Billage v2의 **다중 인스턴스 아키텍처에서 필수적인 메시지 브로커 변화**이다. Spring의 SimpleBrokerMessageHandler로는 불가능한 "인스턴스 간 메시지 브로드캐스트"를 STOMP 프로토콜을 통해 안정적으로 구현할 수 있다.

### 핵심 성공 요소

1. **명확한 역할 분담**: 실시간 전달(RabbitMQ) vs 데이터 영속화(DB)
2. **Graceful Degradation**: RabbitMQ 장애 시에도 부분 기능 유지
3. **적절한 모니터링**: CloudWatch + RabbitMQ Management UI
4. **Phase별 진행**: 로컬 → Dev → (향후 Prod)

### 초기 투자

- **인프라**: EC2 t3.small (~$15/월)
- **개발**: 1~2주 (코드 수정 + 테스트)
- **운영**: 주 1회 모니터링 리뷰 (~30분)

### 기대 효과

- 채팅 메시지 신뢰성 향상 (다중 인스턴스 동기화)
- 시스템 확장성 확보 (1~6개 인스턴스 자유로운 스케일링)
- 향후 메시지 큐 및 고급 기능 확장 기반 마련

이 문서는 초기 도입 가이드이며, Dev 환경 검증 후 프로덕션 단계로의 전환 시 고가용성 및 보안 요구사항을 반영하여 업데이트할 것이다.
