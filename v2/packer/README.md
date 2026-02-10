# Billage Golden AMI

Spring Boot(BE), FastAPI(AI), Next.js(FE) 세 가지 애플리케이션을 위한 공통 베이스 이미지.

## 목적

- **일관성**: 모든 서버가 동일한 베이스 환경에서 시작
- **배포 속도**: Docker 이미지 사전 pull, 도구 사전 설치로 Cold Start 최소화
- **운영 편의성**: 모니터링 스택이 부팅 시 자동 시작되어 별도 설정 불필요

## 디렉토리 구조

```
packer/
├── build.pkr.hcl           # Packer 빌드 정의
├── variables.pkr.hcl       # 변수 선언
├── scripts/
│   ├── setup.sh            # 설치 스크립트
│   └── cleanup.sh          # 정리 스크립트
└── files/
    ├── monitoring/         # 모니터링 설정 파일
    └── systemd/            # Systemd 서비스 파일
```

## 설치 항목

### 기본 도구
| 도구 | 용도 |
|------|------|
| Docker Engine + Compose Plugin | 컨테이너 런타임 |
| AWS CLI v2 | AWS 리소스 관리 |
| Amazon SSM Agent | Session Manager 접속 |
| ECR Credential Helper | ECR 인증 자동화 |

### 모니터링 스택
| 컨테이너 | 포트 | 역할 |
|----------|------|------|
| Node Exporter | 9100 | 호스트 메트릭 (CPU, 메모리, 디스크) |
| cAdvisor | 8080 | 컨테이너 메트릭 |
| Promtail | 9080 | 로그 수집 → Loki 전송 |

## 주요 설계 결정

### ECR Credential Helper 사용
`~/.docker/config.json`에 `credsStore: ecr-login` 설정으로 ECR 인증을 자동화했다. `docker login` 없이 바로 ECR 이미지를 pull/push할 수 있다.

### Promtail 동적 라벨링
`-config.expand-env=true` 플래그로 환경변수 확장을 활성화했다. `${APP_NAME}` 환경변수를 통해 job 라벨이 동적으로 설정되므로, 동일한 AMI로 backend/frontend/ai-server를 구분할 수 있다.

### Systemd 서비스
`monitoring.service`는 `docker.service`와 `network-online.target`에 의존한다. 부팅 순서를 보장하고, Docker 재시작 시에도 모니터링 스택이 자동 복구된다.

### 볼륨 마운트 최적화
- Node Exporter: `/`를 `/host`로 마운트하여 호스트 전체 파일시스템 메트릭 수집
- cAdvisor: Docker 소켓, cgroup, /sys를 마운트하여 컨테이너 리소스 사용량 수집
- Promtail: `/var/log/app`를 read-only로 마운트하여 애플리케이션 로그 수집

## AMI 정리 작업

`cleanup.sh`에서 수행하는 작업:

- apt 캐시 및 패키지 목록 삭제
- 로그 파일 truncate (권한 유지를 위해 삭제하지 않음)
- SSH 호스트 키 삭제 (첫 부팅 시 재생성) -> 이거 안하면 ami 씀ㄴ 무조건 그 키가 들어가버림. 마스터키가 되어버림.
- shell history 삭제
- cloud-init 상태 초기화
- machine-id 초기화

이를 통해 AMI 크기를 줄이고, 보안상 민감한 정보를 제거한다.

## 사전 Pull된 이미지

빌드 시점에 다음 이미지를 미리 pull해둔다:
- `prom/node-exporter:latest`
- `gcr.io/cadvisor/cadvisor:latest`
- `grafana/promtail:latest`

첫 부팅 시 이미지 다운로드 시간이 없어 모니터링 스택이 즉시 시작된다.

## 인스턴스 사용 시

배포된 인스턴스에서 `/etc/default/monitoring` 파일에 `APP_NAME`을 설정하면 Promtail이 해당 값을 job 라벨로 사용한다. Loki에서 `{job="backend"}` 형태로 쿼리할 수 있다.

애플리케이션 로그는 `/var/log/app/` 디렉토리에 작성하면 Promtail이 자동 수집한다.