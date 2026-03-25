## 추가 Fault Injection 시나리오 제안

기존 4가지 방향에 더해, 실제 v2 운영 경험에서 도출한 시나리오 3가지를 추가합니다.
정석적 인프라 장애 주입(Track A)과 운영해봐야 아는 비직관적 장애(Track B) 두 축으로 구성했습니다.

---

### 5. NAT Instance SPOF — 외부 통신 전면 차단 + 장애 전파 검증 (Track A, AWS FIS)

v2에서 비용 최적화를 위해 NAT Gateway 대신 NAT Instance(t3.nano)를 사용 중인데, 이것이 **단일 장애 지점(SPOF)** 입니다.

**FIS로 NAT Instance를 강제 중단**하면 Private Subnet의 모든 아웃바운드가 끊기면서:
- AI 서비스 → RunPod 호출 실패
- 카카오 OAuth 실패
- ECR 이미지 pull 실패 (CI/CD 전면 중단)
- SSM Parameter Store 접근 불가

여기서 핵심 발견은, **v2 운영 중 실제로 AI 추천 API 실패가 전체 물품대여 리스트 조회를 죽이는 장애 전파를 경험**했다는 점입니다. 부가 기능(AI 추천) 장애가 핵심 기능(리스트 조회)까지 죽이는 구조적 문제가 있었습니다.

**실험 후 개선 방향:**
- 인프라: ECR VPC Endpoint 도입 (이미지 pull을 NAT에서 분리), NAT Instance ASG 자동 복구
- 애플리케이션: Resilience4j 격벽 패턴 (CircuitBreaker + Bulkhead + TimeLimiter) 으로 AI 장애 격리
- 배포: 3개 서비스 순차 배포로 NAT 대역폭 경합 방지
- Before/After 수치 비교 + 비용 트레이드오프 분석 ($3.80 → $18.20, NAT Gateway $32 대비 43% 절감)

---

### 6. Kafka Poison Pill — 데이터 레벨 카오스 (Track B, 운영 경험 기반)

**실제 경험**: 단일 서버 환경에서 Kafka 토픽에 `"hello"`라는 문자열이 들어갔을 때, 컨슈머가 JSON 역직렬화에 실패하면서 **무한 재시도 → CPU 100% → 에러 로그로 디스크 풀 → 서버 다운**이 발생했습니다.

6바이트 메시지 하나가 3단계 연쇄 장애(CPU 고갈 + 디스크 고갈 + 서비스 전면 중단)를 일으킨 사례입니다. 이것은 인프라가 아닌 **데이터가 시스템을 죽이는** 패턴(Poison Pill)으로, 정석적 카오스 엔지니어링에서는 다루지 않는 영역입니다.

**실험 방법**: `kafka-console-producer`로 역직렬화 불가능한 메시지를 의도적으로 주입
**실험 후 개선 방향:**
- `ErrorHandlingDeserializer` 적용 (역직렬화 실패 시 예외 삼킴)
- Dead Letter Topic으로 처리 불가 메시지 격리
- `FixedBackOff(1000L, 3L)` — 3회 재시도 후 DLT 전송, 무한 재시도 차단
- 로그 로테이션 설정으로 디스크 보호

---

### 7. kubeadm 인증서 만료 — 시한폭탄 (Track B, kubeadm 운영 필수 지식)

kubeadm으로 클러스터를 구축하면 **인증서 유효기간이 1년**입니다. 갱신하지 않으면 1년 후 어느 날 갑자기:
- `kubectl` 명령 불가 (Unauthorized)
- apiserver ↔ kubelet TLS 핸드셰이크 실패
- 새 Pod 생성/스케줄링 불가
- **기존 Pod는 kubelet이 독립 실행하므로 계속 동작하지만, 아무것도 제어할 수 없는 상태**

EKS/GKE에서는 자동 갱신되므로 아무도 모르는 문제지만, kubeadm은 직접 관리해야 합니다.

**실험 방법**: dev 환경에서 시스템 시간을 1년 뒤로 변경하여 인증서 만료 상태 재현
**실험 후 개선 방향:**
- `kubeadm certs check-expiration` 정기 확인 CronJob
- Prometheus Alert — 인증서 만료 30일 전 경고
- `kubeadm certs renew all` 자동화
- 이 실험은 **kubeadm을 직접 구축하고 운영했다는 결정적 증거**가 됩니다
