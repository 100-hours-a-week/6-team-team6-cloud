# RDS Fault Injection Execution Report

## 근본 목적

이 문서는 `Spring -> RDS` 의존성 지연 실험 결과를 사실 기반으로 남겨, 이후 원인 추적과 복구 설계 개선에 바로 사용할 수 있는 실행 근거를 보존한다.

## 비목적

이 문서는 실험 과정의 모든 시행착오를 장황하게 나열하거나 설정 변경 자체를 성과처럼 포장하는 데 목적이 없다.

## 개요

- 실험 일시: `2026-03-25`
- 대상 경로: `Spring -> Toxiproxy -> RDS`
- 목적: `RDS` 지연이 Spring 응답 시간과 클러스터 동작에 어떻게 전파되는지 확인
- 실행 브랜치: `feature/rds-fault-injection-135`
- 기준 커밋: `cf2d222`

## 수행 내용

1. 로컬에서 백엔드 이미지를 `linux/amd64`로 빌드해 `ECR`의 `billage-be:kube_latest`로 푸시했다.
2. kubeadm 클러스터에 `toxiproxy-rds`를 배포하고, Spring deployment가 `DEV_DB_URL`을 `toxiproxy-rds`로 보도록 전환했다.
3. 프록시 경유 시 `useSSL=true`로는 Spring이 `Flyway` 단계에서 `Communications link failure`로 기동하지 못하는 것을 확인했다.
4. 실험용 datasource URL을 `jdbc:mysql://toxiproxy-rds.billage-app.svc.cluster.local:3306/billage?useSSL=false`로 조정한 뒤 Spring pod가 정상 기동했다.
5. `toxiproxy-rds`에 `300ms` latency toxic을 주입하고, 동일 Spring pod의 `/actuator/health` 응답 시간을 전후 비교했다.
6. 실험 종료 후 toxic을 제거해 `toxics: []` 상태까지 확인했다.

## 핵심 결과

### Baseline

- 측정 대상 pod: `spring-boot-55b4d4d878-rxw4k`
- 측정 경로: `kubectl port-forward pod/... 18080:8080` 후 `GET /actuator/health`
- 결과:
  - `0.018092s`
  - `0.012583s`
  - `0.010602s`

### 300ms Latency 주입 후

- toxic:
  - name: `latency_downstream`
  - type: `latency`
  - stream: `downstream`
  - latency: `300ms`
  - jitter: `50ms`
- 결과:
  - `0.671434s`
  - `0.594950s`
  - `0.655901s`

### 관찰 포인트

- baseline 대비 `health` 응답 시간이 약 `0.01s -> 0.60s` 수준으로 증가했다.
- `toxiproxy-rds` 로그에는 Spring pod에서 들어온 다수의 client connection이 기록됐다.
- 실험 중 Spring pod 재기동과 HPA scale-up이 발생했고, HPA는 한때 `9` replica까지 증가했다.
- 종료 시점에는 toxic은 제거됐지만, `scaleDown.stabilizationWindowSeconds=300` 영향으로 HPA desired replica가 즉시 원복되지는 않았다.

## 장애 및 수정 사항

### 1. Toxiproxy 이미지 경로 오류

- 문제: `shopify/toxiproxy:2.12.0` 이미지를 pull 하지 못했다.
- 수정: 실제 동작 확인 후 `ghcr.io/shopify/toxiproxy:2.12.0`로 교체

### 2. Spring 기동 실패

- 문제: `Flyway` 초기화 시 `Communications link failure`
- 원인: 프록시 호스트를 경유하는 동안 `useSSL=true` 설정과 실제 upstream hostname/TLS 검증 경로가 맞지 않아 DB 연결이 실패한 것으로 판단
- 수정: 실험 경로의 datasource URL을 `useSSL=false`로 조정

### 3. 아키텍처 주의점

- 로컬 Mac에서 일반 `docker build`로 푸시하면 `arm64` manifest만 올라가 `ImagePullBackOff`가 발생할 수 있다.
- 실제 적용 이미지는 `docker buildx build --platform linux/amd64 ... --push`로 다시 푸시했다.

## 증거 파일

- raw evidence 디렉터리: [`2026-03-25-rds-latency`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-25-rds-latency)
- 캡처 가이드: [`CAPTURE_GUIDE.md`](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/fault-injection/evidence/2026-03-25-rds-latency/CAPTURE_GUIDE.md)

## PR에 넣을 핵심 메시지

- `Spring -> RDS` 경로를 `toxiproxy-rds`로 전환해 실서비스와 유사한 의존성 지연 실험 경로를 구성했다.
- baseline에서는 `/actuator/health`가 `10ms` 수준으로 응답했지만, `300ms` latency toxic 주입 후 동일 pod의 응답 시간이 `~600ms`까지 증가했다.
- 실험 과정에서 `toxiproxy` 이미지 경로와 `useSSL` 설정 문제가 드러났고, 이를 정리해 이후 재현 가능성을 높였다.
- 실험 종료 후 toxic은 제거했으며, 남은 replica 수 증가는 HPA cooldown으로 인해 자연 감쇠되는 상태다.
