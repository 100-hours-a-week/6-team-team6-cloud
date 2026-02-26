# Chat Server (WebSocket) 마이그레이션 계획

## 1. 개요: 상태보존 서비스 마이그레이션의 본질적 어려움

WebSocket 기반 채팅 서버의 멀티 인스턴스 마이그레이션은 분산 시스템에서 가장 복잡한 문제 중 하나다. 단순한 상태비저장(stateless) REST API와 달리, WebSocket은 클라이언트-서버 간 지속적인 양방향 연결을 유지하므로 다음과 같은 근본적 제약이 생긴다.

**상태보존 서비스의 세 가지 핵심 딜레마:**

첫째, 연결의 지역성(locality) 문제다. 특정 클라이언트의 WebSocket 연결은 어느 한 서버 인스턴스에만 존재한다. 사용자 A가 인스턴스 1에 연결되고 사용자 B가 인스턴스 2에 연결된 상황에서, A가 보낸 메시지를 B에게 전달하려면 반드시 인스턴스 간 통신(메시지 브로커)이 필요하다. 이는 회로 복잡도를 급격히 증가시킨다.

둘째, 연결의 생명주기(lifecycle) 문제다. 스케일 인(인스턴스 축소) 또는 배포(Instance Refresh) 상황에서 기존 연결은 어떻게 되는가? 클라이언트는 자동으로 재연결해야 하는데, 이 과정에서 메시지 손실, 중복, 순서 역전 같은 일관성 문제가 발생할 수 있다. 대규모 클라이언트의 동시 재연결은 thundering herd 현상을 유발해 시스템을 마비시킬 수 있다.

셋째, 메시지 전달 보증(delivery guarantee) 문제다. 과거 Redis Pub/Sub는 기본적으로 at-most-once 의미론(메시지 손실 가능)을 제공했으나, RabbitMQ는 at-least-once를 제공하여 이를 해결한다. 클라이언트 연결이 끊어진 시간에 발행된 메시지도 큐에서 유지되었다가 재연결 시 복구 가능하다. 추가로 모든 메시지를 데이터베이스에 영속화하여 이중 안전성을 확보한다.

이 마이그레이션의 성공 여부는 이 세 가지 문제를 얼마나 우아하게 해결하는지에 달려 있다.

---

## 2. 현재 상태 (AS-IS): 단일 인스턴스 아키텍처

### 2.1 배포 구성

현재 Billage의 채팅 서버는 Spring Boot 단일 인스턴스(포트 8080)에서 실행된다. 모든 WebSocket 연결이 이 인스턴스로 수렴하므로, 인스턴스 내에서의 메시지 전달은 단순한 in-memory 방식(자바의 CopyOnWriteArraySet이나 ConcurrentHashMap 같은 컬렉션 기반)으로 처리된다.

클라이언트는 온프레미스 환경의 Nginx 리버스 프록시(또는 EC2 Nginx)를 통해 Spring Boot 인스턴스에 접근한다. Nginx는 HTTP Upgrade 헤더를 그대로 통과시키고 proxy_pass를 통해 WebSocket 핸드셰이크를 중개한다.

### 2.2 Nginx WebSocket 프록시 설정

현재의 Nginx 설정 근본은 다음과 같다:

Nginx에서 proxy_http_version 1.1, Connection 헤더 "upgrade", proxy_set_header Upgrade $http_upgrade 등을 명시적으로 설정하여 WebSocket upgrade 요청을 Spring Boot로 전달한다. 이때 proxy_read_timeout, proxy_send_timeout은 충분히 길게 설정되어 있다(일반적으로 3600초 이상). 연결이 한번 upgrade되면, 이후 모든 통신은 TCP 원시 프레임으로 처리되므로 Nginx는 애플리케이션 로직에 개입하지 않는다.

### 2.3 메시지 저장소 및 연결 관리

모든 채팅 메시지는 MySQL(호스트 DB)의 chat_messages 테이블에 저장된다. 연결 상태(어떤 사용자가 어느 채팅방에 있는가)는 Spring WebSocket의 메모리 내 session map에 유지된다. Redis는 사용되지 않는다.

Spring은 SockJS 또는 raw WebSocket을 지원하는데, 현재는 raw WebSocket 또는 SockJS 래퍼를 사용 중이다. 클라이언트 연결 해제 시 Spring의 WebSocketHandler.afterConnectionClosed() 콜백이 호출되어 메모리를 정리한다.

### 2.4 단일 인스턴스 모델의 장점

이 아키텍처는 극도로 단순하다. 인스턴스 간 동기화가 필요 없고, 각 메시지 발행 시 메모리의 session map을 순회하며 구독자에게 직접 전달한다. 데이터 일관성 문제가 없으며, 메시지 순서는 자동으로 보장된다(FIFO, 단일 스레드풀 또는 순차 처리).

다만 이 모델의 치명적 약점은 수평 확장이 불가능하다는 점이다. 동시 연결 수가 증가하면 단일 인스턴스의 메모리와 CPU 용량이 한계에 다다른다.

---

## 3. 목표 상태 (TO-BE): 멀티 인스턴스 분산 아키텍처

### 3.1 배포 구성

Billage의 채팅 서버는 AWS Auto Scaling Group(ASG) 내 여러 인스턴스(최소 1개, 최대 6개)에서 실행된다. Application Load Balancer(ALB)가 모든 클라이언트 연결을 분산한다.

**핵심 설계 원칙: Sticky Session을 사용하지 않는다.**

이는 직관에 반하는 결정처럼 보이지만, 실제로는 더 견고한 아키텍처를 만든다. Sticky Session은 클라이언트의 모든 요청을 한 인스턴스로 고정하는데, 이는 단기적 편의를 제공하지만 장기적으로는 재앙이다. 만약 고정된 인스턴스가 장애 또는 배포로 제거되면, 클라이언트는 새 인스턴스로 강제 재연결되므로 Sticky Session의 이점이 사라진다. 결국 모든 클라이언트가 재연결 처리를 구현해야 하므로, Sticky Session은 "99%의 시간 동안 복잡성만 추가하는" 설계가 된다.

대신 우리는 완전히 상태비저장(stateless) 기반으로 설계한다. RabbitMQ (STOMP Relay)가 인스턴스 간 메시지 전달의 중추 역할을 하고, 각 인스턴스는 자신에게 연결된 클라이언트만 책임진다.

### 3.2 ALB의 WebSocket 지원

ALB는 HTTP/1.1 Upgrade 메커니즘을 완전히 지원한다. 클라이언트가 WebSocket upgrade 요청을 보내면, ALB는 이를 대상 인스턴스(Target)로 통과시키고, 이후 모든 통신은 ALB의 투명한 TCP 프록시로 작동한다.

ALB의 연결 관리 파라미터:

- **Connection Idle Timeout**: 기본값 60초. 양방향 트래픽이 없는 연결은 60초 후 ALB가 종료한다. 이는 장시간 조용한 WebSocket 연결을 강제로 끊는다. 따라서 heartbeat/ping-pong 메커니즘이 필수다.
- **Deregistration Delay(Connection Draining)**: 기본값 300초. 인스턴스가 "draining" 상태에 진입하면(배포 또는 scale-in 시작), ALB는 기존 연결을 유지하지만 새 연결은 다른 인스턴스로 라우팅한다. 300초 후 ALB는 강제로 모든 draining 연스턴스의 연결을 종료한다.

### 3.3 RabbitMQ 역할

RabbitMQ는 인스턴스 간 메시지 브로드캐스트의 메인 메커니즘이다. 사용자 A(인스턴스 1)가 메시지를 보내면, 인스턴스 1은 이를 MySQL에 저장한 후 RabbitMQ의 topic exchange에 routing key `chat.room.{roomId}`로 발행한다. 그러면 인스턴스 2, 3, 4 등 이 exchange에 바인딩된 큐를 구독 중인 모든 인스턴스가 메시지를 수신하고, 자신의 메모리에서 구독 중인 클라이언트들에게 WebSocket을 통해 전달한다.

RabbitMQ는 **At Least Once 의미론**을 보장한다는 점이 핵심이다. 발행된 메시지는 최소 1회 이상 전달되며, 구독자가 부재 중이어도 큐에서 메시지를 유지한다. 이로 인해 메시지 손실이 거의 발생하지 않으며, 데이터베이스와의 이중 저장(dual write) 패턴으로 완전한 영속성을 확보한다.

### 3.4 메시지 영속성

모든 채팅 메시지는 다음 두 곳에 저장된다:

1. **RabbitMQ (STOMP Relay)**: 실시간 전달용. 현재 온라인 클라이언트들에게 즉시 도달시킨다. RabbitMQ는 at-least-once 의미론을 보장하므로 메시지 손실이 거의 없다.
2. **MySQL (RDS)**: 영속화 용. 모든 메시지의 완전한 히스토리를 보존한다.

이렇게 이원화하는 이유는, RabbitMQ의 큐 기반 전달만으로도 메시지 손실을 방지할 수 있지만, 클라이언트가 연결 끊김 상태에서 발행된 메시지를 나중에 조회할 수 있어야 하기 때문이다.

---

## 4. 아키텍처 변경점 상세

### 4.1 Connection Lifecycle: 클라이언트의 여정

클라이언트가 채팅에 입장하는 과정을 추적해보자.

**Step 1: WebSocket Upgrade 요청**
클라이언트(브라우저)가 wss://chat.billage.com/chat/room/123 으로 WebSocket 연결을 시도한다. 요청은 먼저 ALB의 리스너(443 HTTPS)에 도착한다.

**Step 2: ALB의 대상 선택 및 전달**
ALB의 대상 그룹은 ASG의 6개 인스턴스를 등록하고 있다. ALB는 로드 밸런싱 알고리즘(기본 least outstanding requests)에 따라 하나의 인스턴스를 선택한다. 예를 들어 인스턴스 3을 선택했다고 하자.

**Step 3: HTTP Upgrade 중개**
ALB는 WebSocket upgrade 요청의 Connection: Upgrade, Upgrade: websocket 헤더를 검사하고, 이 요청을 인스턴스 3의 Spring Boot로 통과시킨다. 핸드셰이크 성공 후, ALB는 투명한 TCP 프록시 역할을 한다. 이후 모든 프레임은 ALB의 개입 없이 클라이언트와 인스턴스 3 사이를 직통으로 오간다.

**Step 4: Spring의 연결 등록**
인스턴스 3의 Spring WebSocket 핸들러는 afterConnectionEstablished() 콜백에서 이 세션을 메모리에 등록한다. 사용자 ID, 채팅방 ID, 세션 토큰 등이 저장된다. 동시에 인스턴스 3은 RabbitMQ의 topic exchange에서 routing key `chat.room.123`으로 바인딩된 큐를 구독한다(이미 구독 중이 아니라면).

**Step 5: 메시지 수신 준비**
클라이언트는 이제 인스턴스 3을 통해 실시간으로 메시지를 수신할 수 있다.

**Step 6: 연결 유지**
ALB의 idle timeout이 60초이므로, 양방향 통신이 없으면 60초 후 연결이 끊긴다. 따라서 30초마다 ping-pong 프레임을 교환하는 heartbeat 메커니즘이 필수다(이는 4.3절에서 다룬다).

**Step 7: 연결 종료 또는 재연결**
클라이언트가 명시적으로 연결을 닫으면, 또는 네트워크 장애로 끊기면, Spring의 afterConnectionClosed() 콜백이 발동한다. 이 시점에 세션을 메모리에서 제거하고, 필요하면 구독 중인 RabbitMQ 큐를 해제한다. 클라이언트는 exponential backoff with jitter를 적용하여 자동으로 재연결을 시도한다.

### 4.2 메시지 흐름: 크로스 인스턴스 전달

구체적인 예시로 메시지 흐름을 살펴보자.

**시나리오: 사용자 A(인스턴스 1)가 활성 채팅방 중 하나에 "Hello"를 전송, 사용자 B(인스턴스 2)가 같은 방에 있음**

1. 클라이언트 A가 WebSocket을 통해 메시지 "Hello"를 인스턴스 1로 전송한다.

2. 인스턴스 1의 onMessage() 핸들러가 메시지를 수신한다. 이는 메시지 유효성 검증(userId 확인, 권한 확인)을 수행한다.

3. 인스턴스 1은 메시지를 MySQL의 chat_messages 테이블에 저장한다(필드: messageId, roomId, senderId, content, timestamp, status 등). 이 쓰기가 동기식으로 완료되어야 한다. MySQL이 느리면 메시지 지연이 크다.

4. MySQL 저장 후, 인스턴스 1은 RabbitMQ의 topic exchange `chat-exchange`에 routing key `chat.room.456`으로 메시지를 발행한다. 발행 내용은 JSON: { "messageId": "msg-12345", "senderId": "user-A", "content": "Hello", "timestamp": 1707030000, "type": "message" }

5. RabbitMQ는 현재 이 routing key에 바인딩된 모든 큐(각 인스턴스별 큐: 인스턴스 1, 2, 3 등)에 메시지를 라우팅한다. 이는 동기식 처리다.

6. 인스턴스 1은 메시지를 자신의 메모리에 있는 채팅방 456의 구독자들(사용자 A 포함)에게 WebSocket으로 전달한다.

7. 인스턴스 2는 RabbitMQ에서 메시지를 수신하고, 자신의 메모리에서 채팅방 456의 구독자들(사용자 B)을 찾아 WebSocket으로 전달한다.

8. 인스턴스 3, 4 등은 채팅방 456을 구독하지 않으므로 무시한다(구독하지 않으면 RabbitMQ 큐 바인딩 자체가 해제됨).

**이 흐름의 지연 시간:**
MySQL 쓰기(평균 5ms) + RabbitMQ 발행/수신(평균 2ms) + 각 인스턴스 내 메모리 순회(1ms) = 총 8ms 정도. 단일 인스턴스 모델(3ms)보다는 느리지만 충분히 빠르다.

**메시지 순서 보장:**
단일 인스턴스 내에서는 순서가 보장된다(FIFO). 하지만 크로스 인스턴스 상황에서는 주의가 필요하다. 예를 들어 사용자 A, B, C가 각각 다른 인스턴스에 연결되어 있고, A->B->C 순서로 메시지를 보냈다면, 네트워크 지연으로 인해 B의 메시지가 먼저 도착할 수 있다. 이를 방지하려면:
- 각 메시지에 글로벌 타임스탐프(timestamp)를 매긴다.
- RabbitMQ에 발행할 때 sequence number를 부여한다.
- 클라이언트는 timestamp로 정렬하여 표시한다.

### 4.3 ALB의 WebSocket 지원 상세

ALB는 HTTP/1.1 프로토콜만 지원하므로, HTTP/2는 불가능하다. 따라서 모든 WebSocket 연결은 HTTP/1.1 upgrade를 통해 작동한다.

**Connection Idle Timeout: 60초 (기본값)**

이는 양방향 트래픽이 60초 이상 없으면 ALB가 연결을 종료한다는 뜻이다. 채팅방에는 긴 침묵의 순간이 많으므로, 반드시 heartbeat가 필요하다.

권장 heartbeat 전략:
- 클라이언트가 30초마다 ping 프레임을 보낸다.
- 서버가 pong 프레임으로 응답한다.
- 만약 pong을 받지 못하면(30초 타임아웃), 클라이언트는 연결이 죽었다고 판단하고 재연결을 시도한다.

ping-pong 프레임은 WebSocket 프로토콜의 control frame이므로, 페이로드가 없어 매우 가볍다. 300K MAU 환경에서 한 채팅방에 300-500명이 동시에 접속할 경우 ping 트래픽은 약 300-500 * 2 frames/min = 600-1000 frames/min 정도로 무시할 수 있다.

**Deregistration Delay: 300초 (기본값)**

이는 인스턴스 건강 상태가 unhealthy로 표시되거나 ASG에서 제거될 때 발동하는 메커니즘이다. 그 과정은 다음과 같다:

1. 배포(Instance Refresh)가 시작되면, ASG는 이전 인스턴스(예: instance-1)를 "draining" 상태로 표시한다.
2. ALB는 이 인스턴스로 **새로운** 연결을 더 이상 보내지 않는다. 기존 연결은 유지한다.
3. 300초의 deregistration delay 동안, 기존 클라이언트들은 계속 instance-1과 통신한다.
4. 300초 경과 후, ALB는 기존 연결을 강제 종료한다. TCP FIN이 보내진다.
5. 클라이언트는 TCP FIN을 감지하고 재연결을 시도한다. 새 연결은 새로운 인스턴스(instance-2)로 라우팅된다.

**이 과정의 의미:**
만약 deregistration delay가 없다면, 배포 시 순간적으로 수천 개의 연결이 끊어지고 모두 재연결을 시도한다(thundering herd). ALB와 신규 인스턴스에 폭발적인 부하가 쏟아진다. deregistration delay는 이를 완화하기 위한 장치다. 대신 배포 시간이 300초 이상 늘어날 수 있다.

**주의: Sticky Session을 사용하지 않으므로, 기존 연결도 항상 끊일 수 있다는 점을 고려해야 한다.**

---

## 5. RabbitMQ Topic Exchange 설계 (300K MAU 기준)

### 5.1 Topic Exchange 및 Routing Key 구조

300K MAU 환경에서 동시 활성 채팅방은 최대 250-300개로 예상된다. RabbitMQ의 topic exchange를 사용하여 routing key 기반으로 메시지를 라우팅한다.

**Topic Exchange명: chat-exchange**

**Routing Key 패턴: chat.room.{roomId}**

예: chat.room.001, chat.room.002, ..., chat.room.300

이 패턴의 장점은:
- 채팅방별 메시지를 명확히 구분한다.
- Topic exchange의 패턴 매칭으로 유연한 구독 가능 (예: chat.room.* for all rooms)
- 메시지 큐에 대기시키므로 구독자 부재 시에도 메시지 손실 없음
- RabbitMQ 클러스터 확장 시 용이

**큐 설정:**
각 인스턴스마다 큐(queue)를 생성하고, chat-exchange와 바인딩한다.
- 큐명: chat-queue-instance-{instance-id}
- Durable: true (서버 재시작 시 메시지 유지)
- Auto-delete: false (구독자 없어도 큐 유지)
- TTL: 24시간 (오래된 메시지 자동 삭제)

### 5.2 메시지 포맷 (JSON)

RabbitMQ topic exchange에 발행되는 메시지의 포맷은 JSON이어야 한다. 이는 다양한 클라이언트(웹, 모바일, 데스크톱)에서 파싱하기 쉽기 때문이다.

**메시지 스키마:**

RabbitMQ (STOMP Relay) 을 통해 발행되는 메시지의 포맷은 JSON이어야 한다.

```
{
  "messageId": "msg-1707030000-abc123",
  "senderId": "user-A",
  "roomId": 456,
  "content": "Hello world",
  "timestamp": 1707030000000,
  "type": "message",
  "metadata": {
    "senderName": "Alice",
    "senderAvatar": "https://...",
    "editedAt": null
  }
}
```

각 필드의 역할:
- **messageId**: 글로벌 유니크 ID. 재연결 시 중복 방지를 위해 사용된다. 형식은 타임스탐프 + UUID 조합이 권장된다.
- **senderId**: 메시지 발신자의 사용자 ID.
- **roomId**: 메시지가 발행된 채팅방 ID. 리시버가 검증할 때 사용한다.
- **content**: 메시지 본문. 최대 5000자로 제한.
- **timestamp**: 메시지 생성 타임스탐프 (밀리초). 이를 기준으로 메시지 순서를 정렬한다.
- **type**: 메시지 타입. "message" (일반 메시지), "system" (시스템 알림), "notification" (사용자 입장/퇴장) 등.
- **metadata**: 선택적 필드. 발신자 정보, 수정 시간 등을 포함한다.

### 5.3 RabbitMQ Consumer Lifecycle

**Consumer 등록:**
애플리케이션이 시작되면, 각 인스턴스는 RabbitMQ 브로커에 consumer를 등록한다. Consumer는 chat-queue-instance-{instance-id} 큐에서 메시지를 지속적으로 폴링한다.

**메시지 수신:**
Consumer가 메시지를 수신하면, 애플리케이션은 메시지를 처리하고 클라이언트에게 WebSocket으로 전달한다. RabbitMQ는 메시지가 처리될 때까지 큐에서 유지한다.

**메시지 확인 (Acknowledgment):**
- Auto-ACK: 메시지 수신 즉시 확인 (손실 위험, 권장하지 않음)
- Manual-ACK: 메시지 처리 완료 후 명시적 확인 (권장, 메시지 손실 방지)

**Consumer 제거:**
인스턴스가 종료되면, consumer 등록을 해제한다. RabbitMQ는 자동으로 미처리 메시지를 다른 consumer에게 재전달한다 (재분배).

**메모리 관리:**
RabbitMQ가 메시지 큐를 관리하므로, 각 인스턴스의 메모리 누수 문제가 없다. 대신 RabbitMQ 브로커 자신의 메모리와 디스크를 모니터링해야 한다.

---

## 6. Connection 관리 전략

### 6.1 Heartbeat/Ping-Pong 메커니즘

**목표**: ALB의 60초 idle timeout을 회피하고, 네트워크 단절을 조기에 감지한다.

**구현:**
- 클라이언트는 30초마다 WebSocket ping 프레임을 보낸다.
- 서버는 pong 프레임으로 응답한다.
- 클라이언트가 30초 내에 pong을 받지 못하면, 연결이 죽었다고 판단하고 재연결한다.
- 서버 측에서도 마찬가지로 일정 시간 ping을 받지 못하면 연결을 강제 닫을 수 있다.

**세부 구현:**
클라이언트는 Timer나 setInterval을 사용하여 30초마다 ping을 보낸다. 서버는 Spring WebSocket의 sendMessage()를 통해 pong을 보낸다. 이 프로세스는 WebSocket 표준에 따르므로 매우 간단하다.

ping-pong이 이루어지지 않는 상황:
- 네트워크 단절: 클라이언트 네트워크가 끊어지면 ping을 보낼 수 없다. 하지만 OS의 TCP keep-alive(기본 2시간)보다 빨리 감지할 수 있다.
- ALB 장애: 드물지만, ALB 자체가 응답하지 않으면 pong도 오지 않는다.
- 서버 과부하: 서버가 매우 바쁘면 pong 응답이 지연될 수 있다. 이 경우 client-side timeout을 길게 설정(예: 60초)해야 한다.

### 6.2 연결 끊김 감지 및 자동 재연결

**클라이언트 측 재연결 로직:**

사용자가 명시적으로 연결을 끊지 않은 경우, 다음과 같은 상황에서 재연결이 필요하다:

1. pong 응답을 받지 못함 (30초 타임아웃)
2. WebSocket close frame 수신 (ALB deregistration, 서버 shutdown)
3. WebSocket error 이벤트 (네트워크 에러)
4. 사용자가 재연결 버튼 클릭

**재연결 전략:**
초기 재연결은 즉시 시도한다. 만약 실패하면, exponential backoff with jitter를 적용한다.

retry 패턴:
- 1차: 즉시
- 2차: 1초 + random(0~500ms) = 1~1.5초
- 3차: 2초 + random(0~1000ms) = 2~3초
- 4차: 4초 + random(0~2000ms) = 4~6초
- 5차: 8초 + random(0~4000ms) = 8~12초
- 최대: 60초 (이후는 60초 간격)

**jitter 추가의 중요성:**
만약 1000개의 클라이언트가 동시에 연결이 끊어지면, 모두 같은 시간에 재연결을 시도하면 thundering herd가 발생한다. jitter는 각 클라이언트의 재연결 시간을 약간씩 어긋나게 하여, ALB와 서버에 들어오는 부하를 분산한다.

### 6.3 미수신 메시지 복구

**문제 상황:**
클라이언트가 인스턴스 A에 연결되어 있다. 이 상태에서 인스턴스 A가 배포(draining)되어 deregistration delay 동안 기존 메시지는 여전히 도착하지만, RabbitMQ에 발행되지 않을 수 있다 (인스턴스 A가 drain 상태라는 것은 ALB에만 그렇다는 뜻이고, RabbitMQ는 여전히 큐를 구독 중이다). 실제로는 RabbitMQ는 계속 메시지를 발행한다.

더 명확한 문제: 클라이언트가 연결을 끊어져 있던 동안, RabbitMQ에 발행된 메시지는 큐에 남아 있지만, 클라이언트는 구독하지 않으므로 받지 못한다. 클라이언트가 나중에 재연결하면, 끊어진 동안의 메시지는 별도로 조회해야 한다.

**해결 방법: lastMessageId 기반 복구**

1. 클라이언트는 마지막으로 수신한 메시지의 ID를 기억한다.
2. 재연결 성공 후, 클라이언트는 서버에 "마지막으로 받은 메시지는 msg-12345, 그 이후의 모든 메시지를 보내달라"는 요청을 한다.
3. 서버는 MySQL에서 messageId > msg-12345이고 roomId = {현재 방}인 모든 메시지를 조회한다.
4. 서버는 이 메시지들을 클라이언트에게 한 번에 전송한다 (bulk recover).
5. 클라이언트는 기존 UI에 중복 없이 추가한다 (messageId 기반 중복 필터링).

**성능 고려:**
만약 클라이언트가 1시간 동안 끊어져 있었고, 그 사이에 1000개 메시지가 발행되었다면, 1000개를 한 번에 조회하면 네트워크와 DB에 부하가 크다. 해결책:
- 마지막 24시간 또는 최대 10000개 메시지만 유지한다.
- 그 이상 오래된 메시지를 조회할 때는 "히스토리 조회" API를 사용하도록 유도한다.

### 6.4 Connection Count 모니터링

**중요 메트릭:**
- 전체 WebSocket 연결 수: sum(각 인스턴스의 연결 수)
- 인스턴스별 연결 수: 불균형 감지
- RabbitMQ 큐 크기: 각 인스턴스별 처리 대기 메시지 수
- 평균 메시지 레이턴시: 发행 ~ 수신 시간

**모니터링 구현:**
각 인스턴스는 메모리 내에 현재 연결 수를 추적한다. afterConnectionEstablished()에서 카운트를 증가, afterConnectionClosed()에서 감소시킨다. 이 값을 Prometheus 메트릭으로 노출하고, CloudWatch로 수집한다.

---

## 7. Scale-out 시나리오

### 7.1 새 인스턴스 추가 프로세스

ASG의 desired capacity가 3에서 4로 증가하면, AWS는 새 인스턴스(예: instance-4)를 시작한다.

1. EC2가 부팅되고 Spring Boot 애플리케이션이 시작된다.
2. Spring이 RabbitMQ 연결 풀을 초기화한다. 이는 메시지 발행/수신 연결을 포함한다.
3. 애플리케이션이 ready 상태가 되면, Health Check Endpoint가 정상 응답을 시작한다.
4. ALB는 Health Check가 성공하면, 이 인스턴스를 Target Group에 등록한다.
5. 이 시점부터 ALB는 새 WebSocket 연결을 instance-4로 라우팅하기 시작한다.

**기존 연결에 미치는 영향: 없음**

기존 클라이언트(instance-1, 2, 3에 연결된)는 전혀 영향을 받지 않는다. ALB는 기존 연결을 그대로 유지한다.

### 7.2 RabbitMQ 연결 준비 과정의 레이스 컨디션

**주의할 점:**
만약 Spring의 RabbitMQ 연결 초기화가 느리면, 일부 클라이언트는 이미 instance-4로 연결될 수 있다. 이 경우 WebSocket 메시지는 도착하지만, RabbitMQ 구독이 아직 준비되지 않았을 수 있다.

**해결책:**
Spring의 readiness probe에서 RabbitMQ 연결을 명시적으로 확인한다. RabbitMQ 연결이 실패하면 readiness check를 fail로 반환한다. 그러면 ALB는 이 인스턴스를 unhealthy로 표시하고 트래픽을 보내지 않는다.

```
readiness check:
1. HTTP request to /actuator/health/readiness
2. Application responds 200 OK only if:
   - Spring is fully started
   - MySQL connection successful
   - RabbitMQ connection pool ready
   - Consumer subscriptions ready
3. If any fails, respond 503 Service Unavailable
```

---

## 8. Scale-in / 배포 시나리오 (가장 중요)

이 시나리오가 마이그레이션의 성공을 결정한다. 인스턴스가 제거될 때 기존 클라이언트 연결이 어떻게 처리되는가가 핵심이다.

### 8.1 Instance Refresh 배포 프로세스

Terraform으로 ASG 인스턴스 타입을 변경하거나 AMI를 업데이트하면, AWS는 Instance Refresh를 시작한다.

**Phase 1: 선택 및 Draining (0초)**
ASG는 교체할 인스턴스를 선택한다. 예: instance-1을 교체하기로 결정.

**Phase 2: ALB Draining (0초 ~ 300초)**
ASG는 ALB의 Target Group에 "deregister" 명령을 내린다. 정확히는 "connection draining"을 시작한다. ALB는:
- instance-1로 새로운 연결을 보내지 않는다.
- 기존 연결(예: 1000개)은 계속 유지한다.
- 300초(deregistration_delay) 타이머를 시작한다.

**Phase 3: 기존 연결 유지 (300초)**
이 300초 동안, instance-1에 연결된 1000개 클라이언트는 계속 메시지를 주고받을 수 있다. instance-1은 정상적으로 작동한다.

- RabbitMQ에 발행된 메시지는 계속 수신한다.
- 새로운 메시지는 계속 MySQL과 RabbitMQ에 저장/발행한다.
- Ping-pong도 정상 작동한다.

**Phase 4: 강제 연결 종료 (300초 후)**
300초 경과 후, ALB는 instance-1의 모든 연결을 강제 종료한다. TCP FIN 프레임이 보내진다.

```
Timeline:
0s: ASG detach instance-1, ALB start draining
0s ~ 300s: 1000 clients still connected, receive messages normally
300s: ALB force closes all 1000 connections
300s+: 1000 clients receive TCP FIN / close event
```

**Phase 5: 클라이언트 재연결**
1000개 클라이언트는 동시에 TCP FIN을 받는다. WebSocket close 이벤트가 발동한다. 각 클라이언트는 exponential backoff를 시작한다. 그 결과:

- 일부는 즉시 재연결
- 일부는 1~1.5초 후 재연결
- 일부는 2~3초 후 재연결
- ...

이렇게 분산되면 ALB와 신규 인스턴스로의 부하가 분산된다.

### 8.2 메시지 유실 가능 구간 식별

**Case 1: instance-1 draining 동안 발행된 메시지**

instance-1이 draining 상태에서도 RabbitMQ에 메시지를 발행할 수 있다. 이 메시지는:
- MySQL에 저장된다. (영속화 OK)
- RabbitMQ에 발행된다. (큐에서 모든 구독자들이 수신)
- instance-1 자신의 클라이언트들은 직접 수신한다.

**유실 없음.**

**Case 2: 재연결하기 전, 미수신 메시지**

클라이언트가 300초에 연결을 끊고, 재연결하는 데 5초가 소요되면, 그 5초 동안 발행된 메시지는:
- MySQL에는 저장된다.
- RabbitMQ의 큐에는 저장되지만, 클라이언트가 구독 중이 아니므로 받지 못한다.

**유실 가능성 있음.**

이를 복구하려면 재연결 후 lastMessageId 기반 복구를 사용한다.

**Case 3: 데이터베이스 저장 중 장애**

만약 MySQL 쓰기가 실패했는데 RabbitMQ에는 발행되었다면?

이는 매우 드문 경우지만, 해결책:
- MySQL 쓰기를 재시도한다.
- 또는 RabbitMQ에서 메시지를 수신하면, 비동기로 MySQL에 저장한다.
- 결과적으로 최종적 일관성(eventual consistency)을 보장한다.

### 8.3 Thundering Herd 시뮬레이션

instance-1에 5000개 연결이 있다고 가정하자. 300초에 모두 끊기면:

```
0~100ms: 500개 클라이언트 재연결 시도 (즉시)
100~200ms: 또 다른 부분들
...
1~3초: exponential backoff 적용된 클라이언트들 도착
```

이 과정에서:
- ALB의 connection 새로 생성 부하
- 신규 인스턴스의 Spring WebSocket handler 로드
- RabbitMQ 큐 구독 재설정
- MySQL 미수신 메시지 조회 (bulk select)

**성능 영향:** 약 5~10초 동안 클라이언트 응답 속도가 느려질 수 있다. jitter 없이 모두 동시에 재연결하면 이 기간이 훨씬 길어진다.

---

## 9. 메시지 영속성 전략

### 9.1 Dual-Write 패턴

모든 메시지는 두 곳에 저장된다:

**1. MySQL (RDS)**
구조:
```
CREATE TABLE chat_messages (
  messageId VARCHAR(50) PRIMARY KEY,
  roomId INT NOT NULL,
  senderId VARCHAR(100) NOT NULL,
  content TEXT NOT NULL,
  timestamp BIGINT NOT NULL,
  status VARCHAR(20),
  createdAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX (roomId, timestamp),
  INDEX (messageId, timestamp)
);
```

모든 메시지는 동기식으로 MySQL에 저장된다. 저장이 실패하면 에러를 클라이언트에게 반환한다.

**2. RabbitMQ (STOMP Relay)**
메시지는 JSON으로 직렬화되어 topic exchange `chat-exchange`의 routing key `chat.room.{roomId}`로 발행된다. RabbitMQ는 at-least-once 의미론을 제공하여 메시지 손실을 방지한다.

### 9.2 메시지 저장 순서 보장

MySQL과 RabbitMQ에 동시에 저장할 때, 순서 불일치 가능성:

**정확한 흐름:**
```
1. MySQL INSERT (동기, 블로킹)
2. MySQL INSERT 성공 후, 트랜잭션 커밋
3. RabbitMQ PUBLISH (동기, 매우 빠름)
4. RabbitMQ PUBLISH 완료 후, 클라이언트에 ACK 반환
```

이 순서를 보장함으로써, "MySQL에는 없지만 RabbitMQ에는 있는" 경우를 방지한다.

### 9.3 메시지 중복 방지

**문제:**
클라이언트가 재연결 후 미수신 메시지를 MySQL에서 조회한다. 동시에 RabbitMQ에서도 같은 메시지가 도착할 수 있다. 클라이언트는 같은 메시지를 중복으로 표시할 수 있다.

**해결책: messageId 기반 Idempotency**

클라이언트는 수신한 모든 메시지의 messageId를 메모리에 유지한다. 새 메시지를 받을 때마다, messageId가 이미 표시되었는지 확인한다. 중복이면 무시한다.

```
receivedMessageIds = new Set()

onMessage(msg):
  if receivedMessageIds.has(msg.messageId):
    return  // 이미 표시됨
  receivedMessageIds.add(msg.messageId)
  displayMessage(msg)
```

---

## 10. 실행 계획

### Phase 1: RabbitMQ STOMP Relay 코드 구현 (Backend) [1주]

**작업:**
- Spring WebSocket 핸들러에 RabbitMQ 발행 로직 추가
- Chat message service에 RabbitMQ publish 메서드 구현
- RabbitMQ consumer 라이프사이클 관리 (큐 바인딩/언바인딩)
- 메시지 포맷(JSON) 정의 및 직렬화 로직
- Error handling: RabbitMQ 장애 시 graceful degradation

**테스트:**
- 단일 인스턴스에서 RabbitMQ 발행/수신 테스트
- 메시지 포맷 검증

### Phase 2: 클라이언트 재연결 로직 (Frontend) [1주]

**작업:**
- WebSocket 재연결 메커니즘 구현
- Exponential backoff with jitter 알고리즘
- Heartbeat (ping-pong) 구현
- lastMessageId 기반 미수신 메시지 조회 API 호출
- 메시지 중복 필터링 (messageId 기반 Set)
- UI: 연결 상태 표시 (연결 중, 재연결 중, 오류)

**테스트:**
- 네트워크 단절 시뮬레이션
- 개발자 도구에서 WebSocket 차단 후 재연결 확인

### Phase 3: Dev 환경 2-인스턴스 테스트 [3일]

**설정:**
- ECS 또는 EC2에 2개 Spring Boot 인스턴스 배포
- ALB 구성 (sticky session OFF)
- RabbitMQ 인스턴스 프로비저닝 (EC2 또는 Amazon MQ)

**테스트 시나리오:**
- 클라이언트 A를 인스턴스 1에 연결
- 클라이언트 B를 인스턴스 2에 연결
- A가 메시지 발송 → B가 수신하는지 확인
- B가 메시지 발송 → A가 수신하는지 확인
- 메시지 순서 확인

### Phase 4: Scale-in 시뮬레이션 [3일]

**절차:**
- 2개 인스턴스에서 각 50개 클라이언트 연결 (총 100개)
- 1개 인스턴스를 수동으로 terminate
- 50개 클라이언트의 재연결 관찰
- 메시지 손실 여부 확인
- 미수신 메시지 복구 확인

### Phase 5: 부하 테스트 [1주]

**시나리오:**
- 100개 채팅방 동시 활성화
- 각 방마다 평균 10명 클라이언트
- 초당 500 메시지 발송
- 지속 시간: 30분

**검증:**
- 메시지 레이턴시 (p50, p95, p99)
- MySQL 쓰기 성능
- RabbitMQ 메시지 처리 처리량
- ALB 연결 수
- 메모리 사용량 (메모리 누수 검사)

---

## 11. 검증 방법

### 11.1 2개 인스턴스 간 메시지 전달

**테스트 케이스:**

Test-1: 같은 채팅방의 크로스 인스턴스 메시지 전달
- 클라이언트 A를 인스턴스 1로 라우팅
- 클라이언트 B를 인스턴스 2로 라우팅
- 같은 채팅방 456에 입장
- A가 10개 메시지 발송
- B가 모두 수신하는가?
- 예상: 100% 수신률, 순서 정확

Test-2: 메시지 시퀀싱
- A와 B가 동시에 메시지 발송 (race condition)
- 타임스탐프 기준으로 메시지 정렬되는가?
- 예상: 타임스탐프 기준 정렬, 순서 일치

### 11.2 인스턴스 Terminate 후 재연결

**테스트 케이스:**

Test-3: 인스턴스 terminate 후 클라이언트 재연결
- 인스턴스 1에 50개 클라이언트 연결
- 인스턴스 1을 AWS 콘솔에서 terminate
- ALB가 deregistration 시작 (300초 draining)
- 300초 후 강제 종료
- 50개 클라이언트가 재연결하는가?
- 예상: 모두 다른 인스턴스로 재연결, 3초 내 완료

Test-4: 재연결 중 메시지 수신
- 인스턴스 1에 클라이언트 A 연결
- 인스턴스 1을 terminate 시작
- Draining 동안(300초 내) 다른 클라이언트 B가 메시지 발송
- A가 재연결 후 그 메시지를 수신하는가?
- 예상: 미수신 메시지 복구, 메시지 손실 없음

### 11.3 Instance Refresh 연속성

**테스트 케이스:**

Test-5: Instance Refresh 중 서비스 연속성
- 3개 인스턴스에 각 100개 클라이언트 (총 300개)
- Instance Refresh 시작
- 첫 인스턴스부터 순차적으로 교체
- 채팅 서비스가 중단되는가?
- 예상: 100% uptime, 메시지 지연은 최대 5초, 손실 없음

### 11.4 메시지 순서 정합성

**테스트 케이스:**

Test-6: 글로벌 메시지 순서
- 3개 인스턴스에 각 10개 클라이언트 (총 30개)
- 클라이언트들이 무작위로 메시지 발송
- 특정 감시자 클라이언트가 모든 메시지를 수신
- 수신 순서가 타임스탐프 순서와 일치하는가?
- 예상: 일치율 100% (또는 허용 범위 내 <0.1% 역전)

---

## 12. Fallback 및 롤백 전략

### 12.1 RabbitMQ 장애 시나리오

만약 RabbitMQ에 장애가 발생했다면(RabbitMQ 브로커 다운, 네트워크 단절)?

**Graceful Degradation 모드:**
- 같은 인스턴스 내 클라이언트들(예: 같은 채팅방에 있는)은 계속 메시지를 주고받을 수 있다. 애플리케이션의 메모리 내 메시지 큐가 작동한다.
- 다른 인스턴스 간 메시지는 전달되지 않는다 (메시지는 애플리케이션 메모리에 일시 저장, 손실 가능).
- 사용자에게 명확히 알려야 한다: "일부 채팅이 실시간으로 전달되지 않을 수 있습니다. 새로고침하면 다시 시작됩니다."

**복구:**
RabbitMQ가 복구되면, 미처리 메시지는 큐에서 자동으로 consumer에게 재전달되고, 다시 정상 작동한다.

### 12.2 전체 채팅 장애 시나리오

만약 WebSocket 자체가 작동하지 않는다면(Spring 배포 오류, ALB 설정 오류)?

**Fallback: REST Polling API**
- 클라이언트는 WebSocket 연결 실패를 감지한다.
- 사용자에게 "실시간 채팅 사용 불가, 메시지 새로고침으로 조회 가능" 메시지를 표시한다.
- 클라이언트는 3초마다 /api/chat/room/{roomId}/messages?since={lastMessageId} API를 호출한다.
- 서버는 MySQL에서 새 메시지를 조회하여 반환한다.
- 이는 실시간성이 떨어지지만(최대 3초 지연), 서비스는 계속된다.

### 12.3 전체 롤백: v1으로 복귀

만약 마이그레이션 자체를 취소해야 한다면?

**절차:**
1. ALB 설정에서 대상 그룹을 단일 인스턴스(또는 Nginx)로 변경
2. 모든 새 연결이 단일 인스턴스로 라우팅됨
3. 기존 클라이언트(멀티 인스턴스에 연결된)는 재연결 시 단일 인스턴스로 이동
4. 점진적으로 모든 클라이언트가 단일 인스턴스로 옮겨짐
5. ASG 스케일 다운: 6개 → 1개

**시간:**
완전 롤백에는 5~10분이 소요된다(모든 클라이언트의 재연결 대기).

---

## 13. 리스크 및 완화 전략

### 13.1 Thundering Herd: 대규모 동시 재연결

**리스크:**
만약 5000개 클라이언트가 동시에 재연결을 시도하면, ALB와 신규 인스턴스의 부하가 폭발한다. Connection 생성, TLS 핸드셰이크, Spring session 초기화 등의 CPU 사용률이 500%를 초과할 수 있다.

**영향:**
- 전체 채팅 지연 (10초 이상)
- 신규 연결 실패 (Connection refused)
- 재시도 폭발 (exponential backoff이 없으면)

**완화 전략:**
1. **클라이언트 측 jitter**: exponential backoff에 random jitter를 추가하여 재연결 시간을 분산한다.
2. **서버 측 rate limiting**: 인스턴스당 초당 최대 100개 새 WebSocket 연결만 수용한다. 초과분은 일시적으로 거절하고 클라이언트에게 재시도 지시.
3. **ALB 연결 큐**: ALB의 deregistration delay를 300초에서 600초로 증가시켜, 재연결이 더 분산되도록 한다.
4. **사전 스케일 아웃**: 배포 전에 ASG의 desired capacity를 미리 증가시킨다 (1 → 2 → 3 → 2 → 1 방식의 canary).

### 13.2 RabbitMQ 메모리 및 디스크 관리 (300K MAU 기준)

**리스크:**
300K MAU 환경에서 동시 활성 채팅방은 최대 250-300개이다. 각 인스턴스마다 하나의 큐를 생성하므로, 최대 6개 백엔드 인스턴스 × 300개 채팅방 = 1,800개 큐 바인딩이 생긴다. RabbitMQ의 at-least-once 보증으로 인해 각 메시지는 큐에서 메모리/디스크에 저장되므로, 메모리 관리가 중요하다.

예상 메모리/디스크 사용:
- 메시지당 약 1-2 KB (JSON 메타데이터 + 콘텐츠)
- 초당 50-200 메시지 발생 (피크 시간대)
- 24시간 보관 기준: 50 msg/sec × 86,400초 = 4.3M 메시지 / 일 ≈ 4-8 GB

**완화 전략:**
1. **메시지 TTL 설정**: 메시지를 24시간 후 자동으로 제거 (RabbitMQ 정책).
2. **큐 메모리 제한**: 큐당 최대 메모리 설정 (예: 100MB), 초과 시 오래된 메시지부터 삭제.
3. **메모리 모니터링**: CloudWatch/RabbitMQ management console에서 메모리/디스크 사용량 추적, 80% 초과 시 알림.
4. **디스크 용량 계획**: RabbitMQ 브로커는 최소 50GB 이상의 여유 디스크 필요.

### 13.3 메시지 순서 역전

**리스크:**
네트워크 지연, RabbitMQ 처리 지연, 클라이언트 간 시간 동기화 오류 등으로 인해 메시지 순서가 뒤바뀔 수 있다.

**예:**
사용자 A가 "Hello"를 보냈고, 즉시 "World"를 보냈다. 하지만 클라이언트 B가 받은 순서는 "World" → "Hello"일 수 있다.

**발생 확률:**
매우 낮다 (0.1% 미만). 하지만 완전히 불가능하지는 않다.

**완화 전략:**
1. **타임스탐프 기반 정렬**: 클라이언트는 수신 시간(local time)이 아니라 메시지의 timestamp 필드로 정렬한다.
2. **서버 시간 동기화**: 모든 인스턴스의 시간을 NTP로 동기화한다 (AWS는 기본으로 NTP 제공).
3. **Sequence Number**: 각 채팅방마다 글로벌 sequence number를 부여한다 (1, 2, 3, ...). 클라이언트는 sequence number로 순서를 보장한다.

3번 방법이 가장 견고하다. 구현:
- MySQL에 seq INT AUTO_INCREMENT 칼럼 추가
- 메시지 발행 시 seq도 함께 발행
- 클라이언트는 seq 기준으로 정렬 (timestamp는 보조)

### 13.4 WebSocket과 HTTP 혼합 부하에서 ALB 동작 특성

**리스크:**
ALB는 HTTP와 WebSocket을 동시에 처리한다. 만약 채팅 API(REST) 부하가 높으면, WebSocket upgrade 요청이 지연될 수 있다.

**예:**
- 일반 HTTP API 요청: 10000 req/sec
- WebSocket upgrade: 100 req/sec
- ALB의 기본 동시 연결 제한: 1000개 (설정에 따라 다름)

만약 HTTP 요청이 연결을 점유하면, WebSocket upgrade가 큐에서 대기할 수 있다.

**완화 전략:**
1. **별도 ALB**: WebSocket용 ALB를 분리한다. HTTP는 다른 ALB.
2. **리스너 우선순위**: 같은 ALB 내에서 WebSocket 리스너에 더 높은 우선순위를 부여한다 (AWS ALB는 이를 지원하지 않으므로, 별도 ALB가 필요).
3. **연결 제한 조정**: ALB의 최대 동시 연결 수를 HTTP와 WebSocket 각각으로 세분화한다.

초기 단계에서는 1번 구현이 권장된다.

---

## 결론

Chat Server의 멀티 인스턴스 마이그레이션은 단순한 "load balancer 추가"를 넘어, 분산 시스템의 본질적인 어려움을 모두 마주하는 과정이다.

**핵심 설계 원칙:**

1. **상태를 외부화(externalize)한다**: RabbitMQ (STOMP Relay)와 RDS MySQL이 상태의 소유권을 갖는다. 각 인스턴스는 임시 상태(현재 연결)만 보유한다.

2. **재연결을 기본으로 설계한다**: 모든 클라이언트가 언제든 재연결될 수 있음을 가정한다. Sticky Session은 착각일 뿐이다.

3. **메시지 영속성을 이중화한다**: RabbitMQ의 큐 기반 전달과 MySQL의 견고한 저장을 조합한다.

4. **장애를 예상하고 우아하게 처리한다**: RabbitMQ 다운 시 partial service, WebSocket 불가 시 HTTP polling fallback.

이 마이그레이션이 성공하면, Billage 채팅은 초당 수천 메시지, 수만 동시 사용자를 지탱할 수 있는 확장성 있는 서비스가 된다.

