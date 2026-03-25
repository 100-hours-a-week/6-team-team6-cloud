# Billage 카오스 엔지니어링 마스터 플랜

> **인프라**: kubeadm K8s (워커노드 3대) + RDS MySQL + NAT Instance
> **서비스**: Backend(Spring Boot), Frontend(Next.js), AI(FastAPI)
> **메시징**: Kafka(StatefulSet 3노드), RabbitMQ(Deployment)
> **데이터**: RDS MySQL 8.0 (외부), Qdrant VectorDB(StatefulSet 1노드)
> **외부 연동**: RunPod(AI 추론), 카카오 OAuth, ECR, SSM Parameter Store, S3
> **모니터링**: Prometheus + Grafana + Loki + Promtail (Management VPC)

---

## 실험 분류 체계

### Track A — 정석 카오스 엔지니어링 (AWS FIS / Chaos Mesh)

인프라/플랫폼 계층의 장애를 의도적으로 주입하고 시스템 내성을 검증한다.
도구가 지원하는 표준 장애 유형이며, 가설 → 실험 → 측정 → 개선의 정형화된 사이클을 따른다.

### Track B — 운영 인사이트 카오스 (실제 장애 경험 기반)

실제 운영에서 겪거나, 운영해봐야 알 수 있는 비직관적 장애를 재현한다.
"서버를 죽이는" 실험이 아니라 **"데이터 하나, 설정 하나, 시간의 경과"**가 시스템을 죽이는 시나리오.
정형화된 도구보다는 수동 주입 + 스크립트 기반이며, 발견의 스토리가 핵심이다.

---

## Track A — 정석 카오스 엔지니어링

---

### A-1. NAT Instance 완전 중단 (FIS)

> **도구**: AWS FIS `aws:ec2:stop-instances`
> **상세 설계서**: [chaos-nat-instance-fis-scenario.md](./chaos-nat-instance-fis-scenario.md)

| 항목 | 내용 |
|------|------|
| 장애 주입 | NAT Instance EC2 강제 중단 |
| 영향 범위 | 외부 통신 전면 차단 (RunPod, 카카오 OAuth, ECR pull, SSM) |
| 핵심 발견 | AI 추천 실패 → 물품 리스트 전체 조회 불가 (장애 전파) |
| 개선 사항 | ECR VPC Endpoint, NAT ASG 자동 복구, 격벽 패턴(Resilience4j), 순차 배포 |
| 포트폴리오 키워드 | 단일 장애 지점, 장애 전파, 격벽 패턴, 비용 트레이드오프 |

---

### A-2. NAT 대역폭 포화: 동시 배포 + 사용자 트래픽 (부하 재현)

> **도구**: 실제 운영 조건 재현 (FIS 아님, 직접 트리거)
> **상세 설계서**: [chaos-nat-instance-fis-scenario.md](./chaos-nat-instance-fis-scenario.md) 시나리오 B

| 항목 | 내용 |
|------|------|
| 장애 주입 | 3개 서비스 동시 롤링 업데이트 + AI 추천 API 부하 |
| 영향 범위 | NAT t3.nano 대역폭(32Mbps) 포화 → ECR pull 지연 + RunPod 타임아웃 |
| 핵심 발견 | AI 이미지 4GB pull 중 다른 서비스 이미지 pull/외부 API 경합 |
| 개선 사항 | ECR VPC Endpoint(NAT 분리), 순차 배포(동시 pull 방지), maxUnavailable=0 |
| 포트폴리오 키워드 | 네트워크 경합, burstable 인스턴스 한계, 배포 전략 |

---

### A-3. 워커노드 강제 종료 — Kafka 브로커 포함 (FIS)

> **도구**: AWS FIS `aws:ec2:stop-instances`
> **상세 설계서**: [chaos-worker-node-kafka-fis-scenario.md](./chaos-worker-node-kafka-fis-scenario.md)

| 항목 | 내용 |
|------|------|
| 장애 주입 | Kafka 브로커가 있는 워커노드 EC2 강제 종료 |
| 영향 범위 | Kafka 파티션 리더 재선출 + Backend/Frontend Pod 전멸 가능 + PVC AZ 바인딩 |
| 핵심 발견 | Anti-affinity 미설정 → Pod 동시 전멸, PVC AZ 불일치 → Kafka Pod Pending |
| 개선 사항 | Pod Anti-Affinity, PDB, WaitForFirstConsumer, tolerationSeconds 단축, Outbox 패턴 |
| 포트폴리오 키워드 | StatefulSet 운영, PVC AZ 바인딩, 분산 시스템 장애 복구 |

---

### A-4. 워커노드 강제 종료 — Qdrant 포함 (FIS)

> **도구**: AWS FIS `aws:ec2:stop-instances`
> **상세 설계서**: [chaos-worker-node-kafka-fis-scenario.md](./chaos-worker-node-kafka-fis-scenario.md) 시나리오 B

| 항목 | 내용 |
|------|------|
| 장애 주입 | Qdrant(StatefulSet, replicas=1)가 있는 워커노드 종료 |
| 영향 범위 | AI 벡터 검색 완전 중단, replicas=1이므로 복제본 없음 |
| 핵심 발견 | NAT 시나리오 격벽 패턴이 다른 장애에서도 동작하는지 교차 검증 |
| 개선 사항 | CircuitBreaker가 Qdrant 장애에서도 동작 확인, PVC 재마운트 시간 측정 |
| 포트폴리오 키워드 | 격벽 패턴 교차 검증, Graceful Degradation |

---

### A-5. Kafka 파티션 리더 집중 노드 종료 — Worst Case (FIS)

> **도구**: AWS FIS + kafka-reassign-partitions.sh
> **상세 설계서**: [chaos-worker-node-kafka-fis-scenario.md](./chaos-worker-node-kafka-fis-scenario.md) 시나리오 C

| 항목 | 내용 |
|------|------|
| 장애 주입 | 모든 파티션 리더를 broker-0에 집중 후 해당 노드 종료 |
| 영향 범위 | 전체 파티션 동시 리더 재선출 → 프로듀서 100% 일시 실패 |
| 핵심 발견 | 리더 분산 vs 리더 집중 시 장애 규모 차이 수치 비교 |
| 개선 사항 | auto.leader.rebalance.enable, acks=all, Outbox 폴백 |
| 포트폴리오 키워드 | Kafka 내부 동작 이해, Worst Case 시나리오 설계 |

---

### A-6. RDS MySQL 강제 페일오버 (FIS)

> **도구**: AWS FIS `aws:rds:reboot-db-instances` (force-failover)

| 항목 | 내용 |
|------|------|
| 장애 주입 | RDS Multi-AZ 강제 페일오버 트리거 |
| 영향 범위 | HikariCP 커넥션 풀 무효화 → 30~120초간 DB 요청 실패 |
| 핵심 발견 | 페일오버 중 진행 중이던 트랜잭션 롤백 여부, health check DOWN 전파 |
| 개선 사항 | HikariCP validation query, maxLifetime 단축, @Retryable |
| 포트폴리오 키워드 | 커넥션 풀 복구, 트랜잭션 정합성, Readiness Probe 연동 |
| 깊이 평가 | ★★☆ (Multi-AZ 켜기 자체는 간단하지만, HikariCP 튜닝과 트랜잭션 보호는 깊이 있음) |

---

### A-7. Backend → AI 서비스 간 네트워크 지연 주입 (Chaos Mesh)

> **도구**: Chaos Mesh `NetworkChaos`

| 항목 | 내용 |
|------|------|
| 장애 주입 | Backend ↔ AI Pod 간 200ms 지연 + 50ms 지터 |
| 영향 범위 | AI 추천 API 응답시간 급증 → Tomcat 스레드 점유 → 전체 API 마비 가능 |
| 핵심 발견 | timeout 미설정 시 cascade failure 패턴, 스레드 풀 고갈 속도 |
| 개선 사항 | Bulkhead(스레드풀 분리), TimeLimiter(3초), CircuitBreaker, 비동기 전환 |
| 포트폴리오 키워드 | Cascade Failure, Resilience4j, 스레드 풀 격리 |

---

### A-8. CoreDNS 장애 — 서비스 디스커버리 마비 (Chaos Mesh / 수동)

> **도구**: `kubectl scale deployment coredns -n kube-system --replicas=0`

| 항목 | 내용 |
|------|------|
| 장애 주입 | CoreDNS Pod 전체 제거 (60초간) |
| 영향 범위 | K8s 내부 DNS 해석 불가 → 서비스 간 통신 전면 마비 |
| 핵심 발견 | JVM은 DNS 캐싱(30초), Node.js/Python은 캐싱 없음 → 즉시 실패 |
| 개선 사항 | NodeLocal DNSCache DaemonSet, CoreDNS PDB, 언어별 DNS 캐시 설정 |
| 포트폴리오 키워드 | 서비스 디스커버리, DNS 캐싱 전략, kubeadm 컴포넌트 이해 |

---

### A-9. etcd 멤버 장애 — Control Plane 가용성 (수동)

> **도구**: `systemctl stop etcd` (kubeadm 직접 접근)

| 항목 | 내용 |
|------|------|
| 장애 주입 | etcd 멤버 1개 → 2개 순차 종료 |
| 영향 범위 | 1개: quorum 유지 → 정상, 2개: quorum 손실 → write 불가 |
| 핵심 발견 | 기존 Pod는 kubelet이 독립 실행 → 영향 없음 (이걸 아는 게 중요) |
| 개선 사항 | etcd 3노드 클러스터링, snapshot 자동 백업 (cronjob + S3), 복구 런북 |
| 포트폴리오 키워드 | **kubeadm 최대 차별화** — EKS/GKE에서 불가능한 실험 |

---

### A-10. 복합 장애 GameDay — 워커노드 + 네트워크 지연 동시 (FIS + Chaos Mesh)

> **도구**: AWS FIS + Chaos Mesh 동시 실행
> **상세 설계서**: [chaos-worker-node-kafka-fis-scenario.md](./chaos-worker-node-kafka-fis-scenario.md) 시나리오 E

| 항목 | 내용 |
|------|------|
| 장애 주입 | 네트워크 지연 200ms (T+0) → 워커노드 종료 (T+2분) 단계적 투입 |
| 영향 범위 | 지연 상태에서 Kafka 리더 재선출 + Pod 재스케줄링 동시 발생 |
| 핵심 발견 | Track A 전체 개선사항이 복합 장애에서도 유효한지 최종 검증 |
| 개선 사항 | 모든 개선사항의 통합 검증 |
| 포트폴리오 키워드 | GameDay 운영 경험, SLO 달성 여부, MTTR 측정 |

---

## Track B — 운영 인사이트 카오스

---

### B-1. Kafka Poison Pill — 역직렬화 불가 메시지 주입

> **발생 근거**: 실제 경험 — "hello" 문자열 → CPU 100% + 디스크 풀 + 서버 다운
> **도구**: kafka-console-producer로 잘못된 포맷 메시지 수동 주입

| 항목 | 내용 |
|------|------|
| 장애 주입 | Kafka 토픽에 컨슈머가 역직렬화할 수 없는 메시지 주입 |
| 장애 메커니즘 | 역직렬화 실패 → 무한 재시도 → CPU 100% + 에러 로그 디스크 풀 → 서버 다운 |
| 핵심 발견 | **6바이트 문자열이 3단계 연쇄 장애를 일으킴** |
| 개선 사항 | ErrorHandlingDeserializer, Dead Letter Topic, 재시도 횟수 제한, 로그 로테이션 |
| 포트폴리오 키워드 | 실제 장애 경험, 데이터 레벨 카오스, Poison Pill 패턴 |

#### 실험 방법

```bash
# 정상 메시지 (JSON)가 흐르는 토픽에 잘못된 포맷 주입
kubectl exec -n kafka kafka-0 -- \
  bash -c 'echo "hello" | kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic billage-events'

# 관찰: 컨슈머 Pod의 CPU/Memory/로그 볼륨 변화
kubectl top pod -n billage -l app=backend --containers
kubectl exec -n billage deploy/backend -- du -sh /var/log/app/
```

#### 개선 코드

```java
// KafkaConsumerConfig.java
@Bean
public ConsumerFactory<String, RentalEvent> consumerFactory() {
    Map<String, Object> props = new HashMap<>();
    props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);

    // ★ 핵심: 역직렬화 실패 시 예외 대신 null 반환
    props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG,
              ErrorHandlingDeserializer.class);
    props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
              ErrorHandlingDeserializer.class);
    props.put(ErrorHandlingDeserializer.VALUE_DESERIALIZER_CLASS,
              JsonDeserializer.class);

    // 재시도 제한
    props.put(ConsumerConfig.MAX_POLL_INTERVAL_MS_CONFIG, 30000);

    return new DefaultKafkaConsumerFactory<>(props);
}

// Dead Letter Topic 설정
@Bean
public ConcurrentKafkaListenerContainerFactory<String, RentalEvent>
    kafkaListenerContainerFactory() {

    ConcurrentKafkaListenerContainerFactory<String, RentalEvent> factory =
        new ConcurrentKafkaListenerContainerFactory<>();
    factory.setConsumerFactory(consumerFactory());

    // 3번 재시도 후 DLT로 전송
    factory.setCommonErrorHandler(new DefaultErrorHandler(
        new DeadLetterPublishingRecoverer(kafkaTemplate),
        new FixedBackOff(1000L, 3L)    // 1초 간격, 최대 3회
    ));

    return factory;
}
```

#### Before / After

| 지표 | Before | After |
|------|--------|-------|
| Poison Pill 주입 시 컨슈머 상태 | 무한 재시도 → CPU 100% → 서버 다운 | 3회 재시도 → DLT 전송 → 다음 메시지 처리 |
| 정상 메시지 처리 영향 | 전면 중단 (컨슈머 스레드 점유) | 영향 없음 |
| 디스크 사용량 변화 | 에러 로그로 디스크 풀 | 로그 로테이션으로 제한 |
| 장애 복구 방법 | 서버 재시작 + 메시지 수동 삭제 | 자동 복구, DLT에서 사후 분석 |

---

### B-2. kubeadm 인증서 만료 — 시한폭탄

> **발생 근거**: kubeadm 기본 인증서 유효기간 1년. 갱신 안 하면 클러스터 전체 마비.
> **도구**: `kubeadm certs check-expiration` + 인증서 만료 시뮬레이션

| 항목 | 내용 |
|------|------|
| 장애 시나리오 | 설치 1년 후 어느 날 갑자기 kubectl 응답 없음, 새 Pod 생성 불가 |
| 장애 메커니즘 | apiserver 인증서 만료 → kubelet ↔ apiserver TLS 핸드셰이크 실패 → 통신 불가 |
| 영향 범위 | 기존 Pod는 계속 실행(kubelet 독립) 하지만 **아무 제어 불가** |
| 핵심 공포 | 장애가 났는데 kubectl이 안 먹혀서 아무것도 할 수 없는 상황 |
| 포트폴리오 키워드 | **kubeadm 운영 경험의 결정적 증거** |

#### 실험 방법

```bash
# 1. 현재 인증서 만료일 확인
kubeadm certs check-expiration

# 출력 예시:
# CERTIFICATE                EXPIRES                  RESIDUAL TIME
# admin.conf                 Mar 24, 2027 00:00 UTC   364d
# apiserver                  Mar 24, 2027 00:00 UTC   364d
# apiserver-etcd-client      Mar 24, 2027 00:00 UTC   364d
# apiserver-kubelet-client   Mar 24, 2027 00:00 UTC   364d
# controller-manager.conf    Mar 24, 2027 00:00 UTC   364d
# etcd-healthcheck-client    Mar 24, 2027 00:00 UTC   364d
# etcd-peer                  Mar 24, 2027 00:00 UTC   364d
# etcd-server                Mar 24, 2027 00:00 UTC   364d
# front-proxy-client         Mar 24, 2027 00:00 UTC   364d
# scheduler.conf             Mar 24, 2027 00:00 UTC   364d
# super-admin.conf           Mar 24, 2027 00:00 UTC   364d

# 2. 인증서 만료 시뮬레이션 (dev 환경에서만!)
#    시스템 시간을 1년 뒤로 변경
sudo timedatectl set-ntp false
sudo timedatectl set-time "2027-03-25 00:00:00"

# 3. 장애 확인
kubectl get nodes
# error: You must be logged in to the server (Unauthorized)

# 4. 복구 절차 실행
sudo timedatectl set-time "2026-03-24 12:00:00"
sudo timedatectl set-ntp true

# 5. 실제 갱신 절차
sudo kubeadm certs renew all
sudo systemctl restart kubelet
# kubeconfig 파일도 재생성
sudo kubeadm kubeconfig user --client-name=admin --org=system:masters \
  > /etc/kubernetes/admin.conf
```

#### 개선: 자동 갱신 + 모니터링

```yaml
# CronJob: 매월 1일 인증서 잔여 기간 확인 + 60일 이내면 자동 갱신
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cert-renewal-check
  namespace: kube-system
spec:
  schedule: "0 9 1 * *"         # 매월 1일 09:00 KST
  jobTemplate:
    spec:
      template:
        spec:
          hostPID: true
          hostNetwork: true
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              effect: NoSchedule
          containers:
            - name: cert-check
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  # 인증서 만료일 확인
                  EXPIRY=$(kubeadm certs check-expiration 2>/dev/null | \
                    grep "apiserver " | awk '{print $NF}')

                  # 잔여 일수 계산
                  if [ "${EXPIRY%d}" -lt 60 ]; then
                    echo "⚠️ 인증서 만료 임박: ${EXPIRY} 남음. 자동 갱신 실행."
                    kubeadm certs renew all
                    # kubelet 재시작은 수동으로 (안전을 위해)
                    # 알림 전송
                    curl -X POST "$SLACK_WEBHOOK" \
                      -H 'Content-Type: application/json' \
                      -d "{\"text\":\"🔐 K8s 인증서 자동 갱신 완료. kubelet 재시작 필요.\"}"
                  else
                    echo "✅ 인증서 정상: ${EXPIRY} 남음."
                  fi
              volumeMounts:
                - name: k8s-certs
                  mountPath: /etc/kubernetes/pki
                  readOnly: true
          volumes:
            - name: k8s-certs
              hostPath:
                path: /etc/kubernetes/pki
          restartPolicy: OnFailure
```

```yaml
# Prometheus Alert: 인증서 만료 30일 전 경고
groups:
  - name: kubeadm_cert_alerts
    rules:
      - alert: KubeadmCertExpiringSoon
        expr: |
          (kube_certificate_expiration_timestamp_seconds - time()) / 86400 < 30
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "kubeadm 인증서 만료 {{ $value | printf \"%.0f\" }}일 전"
          description: "인증서 갱신 필요: kubeadm certs renew all"
```

---

### B-3. 로그 폭탄 — 모니터링 시스템 자체 장애

> **발생 근거**: Poison Pill, DB 연결 실패 반복 등으로 에러 로그 폭주 → Loki 디스크 풀 → 모니터링 죽음
> **도구**: 의도적 에러 루프 발생 + Loki/Prometheus 디스크 모니터링

| 항목 | 내용 |
|------|------|
| 장애 시나리오 | 에러 로그 초당 수천 줄 발생 → Promtail → Loki 전송 → 모니터링 서버 디스크 풀 |
| 장애의 본질 | **장애 중에 모니터링이 죽는다** = 어디서 장애인지 볼 수 없다 |
| 영향 범위 | Prometheus 다운 → 알림 중단, Grafana 다운 → 대시보드 불가 |
| 핵심 공포 | 새벽 3시에 서비스 장애 + 모니터링 죽음 = 완전한 블라인드 |
| 포트폴리오 키워드 | 관측 가능성(Observability)의 가용성, 메타 모니터링 |

#### 실험 방법

```bash
# Step 1: 의도적으로 에러 로그 폭탄 발생
# Backend Pod에서 존재하지 않는 외부 API를 무한 호출 → 에러 로그 폭주
kubectl exec -n billage deploy/backend -- \
  bash -c 'while true; do curl -s http://nonexistent-service:9999/ 2>&1; done' &

# Step 2: Promtail → Loki 전송량 모니터링
# Management VPC의 모니터링 서버에서
ssh monitoring-server "df -h /var/lib/loki"
ssh monitoring-server "docker logs loki --tail 10"

# Step 3: 디스크 사용률 추이 관찰
watch -n 10 'ssh monitoring-server "df -h | grep loki"'

# Step 4: 정리
kubectl exec -n billage deploy/backend -- pkill curl
```

#### 개선

```yaml
# Promtail: 로그 전송량 제한 (rate limiting)
# promtail-config.yaml
scrape_configs:
  - job_name: kubernetes-pods
    pipeline_stages:
      # 동일 로그 라인 반복 시 드롭 (초당 100줄 초과 시)
      - limit:
          rate: 100
          burst: 200
          drop: true
      # 에러 로그만 별도 라벨링 (나중에 Loki에서 별도 retention)
      - match:
          selector: '{level="ERROR"}'
          stages:
            - labels:
                log_type: error

# Loki: 테넌트별 수집 제한
# loki-config.yaml
limits_config:
  ingestion_rate_mb: 10           # 초당 최대 10MB
  ingestion_burst_size_mb: 20
  max_streams_per_user: 10000
  reject_old_samples: true
  reject_old_samples_max_age: 168h   # 7일 이상 된 로그 거부

# 디스크 보호: retention 설정
# loki-config.yaml
compactor:
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150

storage_config:
  boltdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/boltdb-cache

schema_config:
  configs:
    - from: 2026-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
```

```yaml
# 메타 모니터링: 모니터링 서버 자체의 디스크 알림
# Prometheus alert (모니터링 서버의 node-exporter에서 수집)
groups:
  - name: monitoring_self_health
    rules:
      - alert: LokiDiskAlmostFull
        expr: |
          (1 - node_filesystem_avail_bytes{mountpoint="/var/lib/loki"} /
               node_filesystem_size_bytes{mountpoint="/var/lib/loki"}) > 0.8
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Loki 디스크 사용률 80% 초과"

      - alert: PrometheusDown
        expr: up{job="prometheus"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Prometheus 다운 — 모니터링 불가"
```

#### Before / After

| 지표 | Before | After |
|------|--------|-------|
| 에러 루프 시 Loki 디스크 증가 속도 | __GB/분 (무제한) | < 10MB/분 (rate limit) |
| 모니터링 서버 다운 여부 | 디스크 풀 → 다운 | 디스크 80% 알림 → 사전 대응 |
| 장애 중 대시보드 가용 여부 | 불가 | 가용 (디스크 보호) |
| 에러 로그 보존 | 무한 적재 | 7일 retention 자동 정리 |

---

### B-4. WebSocket 재연결 폭풍 (Thundering Herd)

> **발생 근거**: RabbitMQ 재시작 시 전체 WebSocket 클라이언트가 동시 재연결
> **도구**: RabbitMQ Pod 삭제 + 동시 접속 시뮬레이션

| 항목 | 내용 |
|------|------|
| 장애 시나리오 | RabbitMQ 재시작 → 모든 WebSocket 끊김 → 전원 동시 재연결 → 새 Pod 과부하 → 또 죽음 |
| 장애 메커니즘 | reconnectDelay가 고정값 → 모든 클라이언트가 같은 시점에 재연결 = Thundering Herd |
| 영향 범위 | 채팅 기능 무한 장애 루프 |
| 핵심 공포 | "RabbitMQ를 재시작하면 오히려 상황이 악화된다" |
| 포트폴리오 키워드 | Thundering Herd, Exponential Backoff with Jitter |

#### 실험 방법

```bash
# Step 1: WebSocket 동시 접속 클라이언트 시뮬레이션 (500개)
# wscat 또는 artillery를 사용
npm install -g artillery
cat <<'EOF' > ws-load-test.yml
config:
  target: "ws://backend-svc.billage:8080/ws"
  phases:
    - duration: 300
      arrivalRate: 50        # 초당 50개 WebSocket 연결 생성
  ws:
    subprotocols:
      - v12.stomp

scenarios:
  - engine: ws
    flow:
      - send: "CONNECT\naccept-version:1.2\n\n\0"
      - think: 300            # 5분간 연결 유지
EOF

artillery run ws-load-test.yml &

# Step 2: 500개 연결이 맺어진 상태에서 RabbitMQ Pod 삭제
sleep 60
kubectl delete pod -n billage -l app=rabbitmq --force

# Step 3: 관찰
# - RabbitMQ 새 Pod의 CPU/Memory 급증
# - 동시 재연결 요청 수
# - 새 Pod 생존 여부
# - 재연결 패턴 (전부 동시 vs 분산)
```

#### 개선: Exponential Backoff with Jitter

```javascript
// Frontend: WebSocket 재연결 로직 (SockJS + STOMP)

class WebSocketManager {
  constructor() {
    this.baseDelay = 1000;       // 초기 1초
    this.maxDelay = 30000;       // 최대 30초
    this.attempt = 0;
  }

  connect() {
    const socket = new SockJS('/ws');
    this.stompClient = Stomp.over(socket);

    this.stompClient.connect({}, () => {
      console.log('WebSocket connected');
      this.attempt = 0;          // 연결 성공 시 카운터 리셋
    });

    socket.onclose = () => {
      this.reconnectWithJitter();
    };
  }

  reconnectWithJitter() {
    this.attempt++;

    // Exponential Backoff: 1s → 2s → 4s → 8s → ... → 30s (cap)
    const exponentialDelay = Math.min(
      this.baseDelay * Math.pow(2, this.attempt - 1),
      this.maxDelay
    );

    // ★ Jitter: 동시 재연결 방지 (0~100% 범위의 랜덤 지연)
    const jitter = exponentialDelay * Math.random();
    const finalDelay = exponentialDelay + jitter;

    console.log(`Reconnecting in ${Math.round(finalDelay)}ms (attempt ${this.attempt})`);

    setTimeout(() => this.connect(), finalDelay);
  }
}

// 사용자 500명의 재연결 분포 예시:
// Before (고정 5초): 500명 전부 T+5초에 재연결 → 스파이크
// After  (jitter):   T+1~60초에 분산 재연결 → 부하 분산
```

#### Before / After

| 지표 | Before (고정 delay) | After (jitter) |
|------|--------------------|----------------|
| 재연결 피크 동시 접속 수 | 500 (전원 동시) | ~30 (분산) |
| RabbitMQ 새 Pod CPU 피크 | __% (과부하) | < 50% |
| RabbitMQ 재시작 후 생존 | 죽을 수 있음 | 안정적 생존 |
| 전체 재연결 완료 시간 | 5초 (but 실패 가능) | ~60초 (안정적 성공) |

---

### B-5. ECR 이미지 롤백 불가 — 시간이 만든 장애

> **발생 근거**: ECR lifecycle policy "최근 10개 태그만 유지" → 11번째 이전 버전 롤백 불가
> **도구**: 롤백 훈련 (실제 이전 버전으로 배포 시도)

| 항목 | 내용 |
|------|------|
| 장애 시나리오 | 심각한 버그 발견 → 10번 이상 전 버전으로 롤백 필요 → 이미지 삭제됨 |
| 장애의 본질 | **시간이 지나면 롤백 능력을 잃는다** |
| 영향 범위 | 롤백 불가 → 핫픽스를 빌드해서 배포해야 함 → 복구 시간 30분+ |
| 핵심 공포 | 새벽 3시에 버그 발견했는데 코드 수정 없이는 복구 불가 |
| 포트폴리오 키워드 | 재해 복구, ECR lifecycle, 롤백 전략 |

#### 실험 방법

```bash
# Step 1: 현재 ECR에 남아있는 이미지 태그 확인
aws ecr describe-images \
  --repository-name billage-backend \
  --query 'imageDetails[*].{tag:imageTags[0],pushed:imagePushedAt}' \
  --output table

# Step 2: 가장 오래된 태그로 롤백 시도
OLDEST_TAG=$(aws ecr describe-images \
  --repository-name billage-backend \
  --query 'sort_by(imageDetails, &imagePushedAt)[0].imageTags[0]' \
  --output text)

kubectl set image deployment/backend \
  backend=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-backend:$OLDEST_TAG \
  -n billage

# Step 3: lifecycle policy에 의해 삭제된 태그로 롤백 시도 (실패 확인)
kubectl set image deployment/backend \
  backend=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/billage-backend:v1.0.1 \
  -n billage

# 관찰: ImagePullBackOff 발생
kubectl get events -n billage --field-selector reason=Failed
```

#### 개선

```hcl
# ECR lifecycle policy 조정
# terraform/shared/ecr/main.tf

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "prod 태그는 최근 30개 유지 (롤백 여유)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["prod-", "release-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "dev 태그는 최근 10개 유지"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["dev-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "미태그 이미지 7일 후 삭제"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

---

### B-6. Spring Boot GC Pause → livenessProbe 연쇄 Kill

> **발생 근거**: JVM Full GC(Stop-the-World) → health check 타임아웃 → K8s가 정상 Pod를 kill
> **도구**: stress-ng로 메모리 압력 주입

| 항목 | 내용 |
|------|------|
| 장애 시나리오 | 트래픽 급증 → JVM 힙 메모리 압력 → Full GC 발생(수 초간 STW) → liveness 실패 → Pod kill |
| 장애 메커니즘 | Kill 된 트래픽이 나머지 Pod로 → 거기도 GC 압력 → 연쇄 kill |
| 영향 범위 | Backend Pod 전멸 가능 |
| 핵심 공포 | "트래픽이 늘었을 뿐인데 왜 Pod가 계속 죽지?" |
| 포트폴리오 키워드 | JVM 운영, GC 튜닝, Probe 설계 |

#### 실험 방법

```bash
# Backend Pod에 메모리 압력 주입
kubectl exec -n billage deploy/backend -- \
  stress-ng --vm 2 --vm-bytes 512M --vm-hang 0 --timeout 120s &

# 관찰
kubectl get pods -n billage -w    # Pod Restart 카운터 증가 관찰
kubectl logs -n billage deploy/backend --previous | grep "GC"
```

#### 개선

```yaml
# livenessProbe를 GC-safe하게 설정
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    spec:
      containers:
        - name: backend
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8080
            initialDelaySeconds: 60      # JVM 워밍업 대기
            periodSeconds: 10
            timeoutSeconds: 5            # 기본 1초 → 5초 (GC pause 여유)
            failureThreshold: 5          # 기본 3회 → 5회 (연속 50초 실패 시에만 kill)
            # = GC pause 5초 × 5회 = 25초까지 허용

          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3          # readiness는 더 민감하게 (트래픽 차단)

          # JVM 옵션
          env:
            - name: JAVA_OPTS
              value: >-
                -XX:+UseG1GC
                -XX:MaxGCPauseMillis=200
                -XX:+HeapDumpOnOutOfMemoryError
                -XX:HeapDumpPath=/var/log/app/heapdump.hprof
                -Xms512m
                -Xmx512m
```

---

### B-7. SSM Parameter Store 장애 시 Pod 시작 불가

> **발생 근거**: Pod 시작 시 SSM에서 환경변수(DB 비밀번호, JWT 시크릿) 조회 → SSM 장애 시 신규 Pod 부팅 실패
> **도구**: SSM 접근 차단 (Security Group 또는 IAM 권한 제거)

| 항목 | 내용 |
|------|------|
| 장애 시나리오 | 롤링 업데이트 중 NAT 장애(또는 SSM 장애) → 새 Pod가 시크릿 조회 실패 → 시작 불가 |
| 장애 메커니즘 | Old Pod 종료 → New Pod SSM 조회 실패 → CrashLoopBackOff → 서비스 다운 |
| 영향 범위 | 배포 중이 아니면 영향 없음, **배포 타이밍에 SSM 장애가 겹치면 치명적** |
| 핵심 공포 | "배포하다가 서비스가 죽었는데 롤백도 안 돼" (새 Pod도 SSM 못 읽으니까) |
| 포트폴리오 키워드 | 시크릿 관리, External Secrets Operator, 장애 시점 의존성 |

#### 실험 방법

```bash
# Step 1: 현재 Backend Pod의 환경변수가 SSM에서 오는지 확인
kubectl exec -n billage deploy/backend -- env | grep -E "DB_|JWT_|KAKAO_"

# Step 2: SSM 접근 차단 (IAM 정책에서 ssm:GetParameter 제거)
# 또는 NAT를 죽여서 SSM 접근 불가 상태 만들기 (NAT 시나리오와 연계)

# Step 3: 롤링 업데이트 트리거
kubectl rollout restart deployment/backend -n billage

# Step 4: 관찰 — 새 Pod가 CrashLoopBackOff에 빠지는지
kubectl get pods -n billage -w
kubectl logs -n billage <new-pod-name>
# 예상: "Failed to fetch parameter /billage/dev/db-password"
```

#### 개선

```yaml
# External Secrets Operator: SSM 값을 K8s Secret으로 동기화
# SSM 장애 시에도 마지막 동기화 값으로 Pod 시작 가능

apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: billage-backend-secrets
  namespace: billage
spec:
  refreshInterval: 1h            # 1시간마다 SSM과 동기화
  secretStoreRef:
    name: aws-ssm
    kind: ClusterSecretStore
  target:
    name: backend-secrets          # 생성될 K8s Secret 이름
    creationPolicy: Owner
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: /billage/dev/db-password
    - secretKey: JWT_SECRET
      remoteRef:
        key: /billage/dev/jwt-secret
    - secretKey: KAKAO_CLIENT_SECRET
      remoteRef:
        key: /billage/dev/kakao-client-secret

---
# Backend Deployment: SSM 직접 조회 대신 K8s Secret 사용
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    spec:
      containers:
        - name: backend
          envFrom:
            - secretRef:
                name: backend-secrets    # ← External Secret이 동기화한 Secret
```

---

## 전체 실험 우선순위 & 로드맵

### Phase 1 (Week 1-2): 핵심 인프라 + 실제 경험 기반

| 순서 | 실험 | Track | 이유 |
|------|------|-------|------|
| 1 | A-1. NAT 완전 중단 | A | 가장 풍부한 파생, 격벽 패턴 도출 |
| 2 | B-1. Kafka Poison Pill | B | 실제 경험, 즉시 실험 가능, 강력한 스토리 |
| 3 | A-2. NAT 대역폭 포화 | A | A-1과 연계, ECR VPC Endpoint 도출 |

### Phase 2 (Week 3-4): K8s + Kafka 깊이

| 순서 | 실험 | Track | 이유 |
|------|------|-------|------|
| 4 | A-3. 워커노드 + Kafka | A | kubeadm 핵심, StatefulSet 운영 |
| 5 | A-5. Kafka 리더 집중 | A | A-3 심화, Worst Case 시나리오 |
| 6 | B-4. Thundering Herd | B | RabbitMQ WebSocket, 비직관적 장애 |

### Phase 3 (Week 5-6): 운영 성숙도

| 순서 | 실험 | Track | 이유 |
|------|------|-------|------|
| 7 | B-2. kubeadm 인증서 만료 | B | kubeadm 운영의 결정적 증거 |
| 8 | B-3. 로그 폭탄 | B | Observability 가용성 |
| 9 | B-6. GC Pause 연쇄 Kill | B | JVM 운영 깊이 |
| 10 | B-7. SSM Pod 시작 불가 | B | 시크릿 관리 아키텍처 |

### Phase 4 (Week 7-8): 통합 검증 + 보완

| 순서 | 실험 | Track | 이유 |
|------|------|-------|------|
| 11 | A-7. 네트워크 지연 | A | Cascade Failure 검증 |
| 12 | A-4. 워커노드 + Qdrant | A | 격벽 패턴 교차 검증 |
| 13 | A-8. CoreDNS 장애 | A | 서비스 디스커버리 |
| 14 | A-9. etcd 장애 | A | kubeadm 차별화 |
| 15 | A-6. RDS 페일오버 | A | 데이터 계층 보완 |
| 16 | B-5. ECR 롤백 불가 | B | 재해 복구 훈련 |
| 17 | A-10. GameDay 복합 장애 | A | **최종 통합 검증** |

---

## 포트폴리오 최종 구성 — 면접 설명 흐름

```
"카오스 엔지니어링을 두 가지 축으로 진행했습니다.

첫 번째는 AWS FIS와 Chaos Mesh를 활용한 정석적 장애 주입입니다.
NAT Instance SPOF 실험에서 AI 장애가 전체 서비스로 전파되는 것을 발견하고
격벽 패턴으로 해결했고,
워커노드 장애 실험에서 Kafka PVC AZ 바인딩 문제와 Pod 배치 문제를 발견하고
Anti-Affinity + WaitForFirstConsumer + Outbox 패턴으로 해결했습니다.

두 번째는 실제 운영에서 발견한 비직관적 장애를 재현하고 방어한 것입니다.
Kafka 토픽에 잘못된 포맷의 메시지가 들어가서 서버가 죽은 Poison Pill 경험,
kubeadm 인증서 만료라는 시한폭탄,
에러 로그 폭주로 모니터링 시스템 자체가 죽는 상황,
WebSocket 재연결 폭풍으로 복구가 오히려 장애를 악화시키는 패턴 등을
카오스 실험으로 정형화하고 방어를 검증했습니다.

모든 실험은 Before/After 수치로 검증했고,
최종적으로 GameDay에서 복합 장애 시나리오를 수행하여
SLO(가용률 99.5%, p99 < 2s)를 달성하는 것을 확인했습니다."
```
