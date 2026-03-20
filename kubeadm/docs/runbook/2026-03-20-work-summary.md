# 2026-03-20 작업 요약

## 목표

billage-k8s-manifests의 Stateless 서비스(Spring Boot, FastAPI, Next.js)를 kubeadm 클러스터에 배포

---

## 작업 흐름

### Phase 0: 매니페스트 불일치 수정

클러스터(Terraform)와 매니페스트(Helm Chart) 사이의 설정 불일치를 수정.

| 항목 | 변경 전 | 변경 후 | 파일 수 |
|------|--------|--------|---------|
| 네임스페이스 | `village-*` | `billage-*` | 7개 |
| 노드 라벨 | `node-role` | `workload-plane` | 6개 |
| Data 노드 Taint | `dedicated=data` | `workload-plane=data` | 3개 |
| ArgoCD 대상 NS | `billage-dev/prod` | `billage-app/data` | 2개 |

### Phase 1: 클러스터 트러블슈팅 & 재구축

기존 클러스터에서 CrashLoopBackOff 발견 → 원인 분석 → 해결.

**근본 원인:** containerd sandbox image (pause:3.8) vs kubeadm 기대값 (pause:3.9) 불일치

**해결 과정:**
1. `kubeadm reset -f && rm -rf /var/lib/etcd` — etcd 초기화
2. `control-plane-init.sh` — kubeadm init 재실행
3. Calico CNI 즉시 설치 — NetworkPluginNotReady 방지
4. containerd config에서 pause:3.9로 수정 — 10개 노드 전체 SSM으로 일괄 적용
5. cp-02, cp-03 control plane join
6. app-01~04, data-01~03 worker join

**결과:** 10/10 노드 Ready

- 상세 트러블슈팅: `2026-03-18-control-plane-crashloop-troubleshooting.md`

### Phase 2: Platform Bootstrap

```
✅ 노드 라벨/Taint — cloud-init에서 이미 적용됨
✅ 네임스페이스 4개 — billage-app, billage-data, billage-edge, billage-ops
✅ metrics-server — HPA용
✅ ingress-nginx — Ingress Controller
✅ cert-manager — TLS 인증서 관리
✅ zone 라벨 — 10개 노드에 AZ 라벨 수동 부여
```

### Phase 3: Secret 생성

SSM Parameter Store에서 값을 가져와 K8s Secret으로 등록.

| Secret | Namespace | Keys | 비고 |
|--------|-----------|------|------|
| spring-boot-secret | billage-app | 23개 | dev v2 인프라 주소 사용 |
| fastapi-secret | billage-app | 4개 | dev v2 Qdrant 주소 |
| nextjs-secret | billage-app | 5개 | NEXTAUTH_SECRET 포함 |
| ecr-secret | billage-app | 1개 | ECR 인증 (12시간 만료) |

**결정사항:**
- 모든 환경변수를 Secret으로 통일 (비민감 설정 포함)
- dev v2 인프라 사용 (VPC Peering) → `SPRING_PROFILES_ACTIVE=dev`
- `AI_BASE_URL`은 K8s 내부 주소: `http://fastapi.billage-app.svc.cluster.local:5000`

### Phase 4: VPC Peering & 보안그룹

kubeadm VPC(10.30.0.0/16) → dev v2 VPC(10.0.0.0/16) 통신을 위한 설정.

```
✅ VPC Peering 생성 (사전 완료)
✅ Route Table 양방향 설정 (사전 완료)
✅ dev v2 RDS 보안그룹 — 3306 허용
✅ dev v2 RabbitMQ 보안그룹 — 5672, 61613 허용
✅ dev v2 Kafka 보안그룹 — 9092 허용
✅ dev v2 Qdrant 보안그룹 — 6333-6334 허용
✅ NetworkPolicy — allow-egress-external 추가
```

### Phase 5: Helm 배포 & 트러블슈팅

배포 순서: FastAPI → Spring Boot → Next.js

| 문제 | 원인 | 해결 |
|------|------|------|
| Pod Pending | zone 라벨 없음 | 10개 노드에 AZ 라벨 부여 |
| ImagePullBackOff | ECR 인증 없음 | imagePullSecret 생성 |
| Spring Boot CrashLoop | 환경변수 이름 불일치 | application.yml과 매핑 일치 |
| RDS 연결 실패 | 보안그룹 미허용 | 10.30.0.0/16 인바운드 추가 |
| Pod→외부 통신 실패 | NetworkPolicy 차단 | allow-egress-external 추가 |
| FastAPI OOMKilled | 메모리 limit 부족 | 1Gi → 2Gi |
| Next.js NO_SECRET | NEXTAUTH_SECRET 누락 | Secret에 키 추가 |
| Next.js env 미주입 | 템플릿에 envFromSecret 누락 | deployment.yaml 수정 |
| Next.js probe 500 | `/` SSR 실패 | probe 경로 `/login`으로 변경 |

- 상세 트러블슈팅: `2026-03-20-stateless-deployment-troubleshooting.md`

---

## 최종 결과

```
NAME                          READY   STATUS    RESTARTS   AGE
fastapi-68f88587db-fh2zr      1/1     Running   0          30m
fastapi-68f88587db-qjbwh      1/1     Running   0          29m
nextjs-785644f795-95nz6       1/1     Running   0          40s
nextjs-785644f795-k7r6h       1/1     Running   0          51s
spring-boot-55d59f556-4p8nw   1/1     Running   0          40m
spring-boot-55d59f556-9z494   1/1     Running   0          40m
spring-boot-55d59f556-bl7c2   1/1     Running   0          40m
```

**7개 Pod 전부 1/1 Running, 재시작 0.**

---

## 변경된 파일 목록

### terraform/ (이 리포)
- `kubeadm/envs/prod/templates/bootstrap-common.sh.tftpl` — pause:3.9 수정 추가
- `kubeadm/docs/runbook/2026-03-18-control-plane-crashloop-troubleshooting.md` — 신규
- `kubeadm/docs/runbook/2026-03-20-stateless-deployment-troubleshooting.md` — 신규
- `kubeadm/docs/runbook/2026-03-20-work-summary.md` — 신규 (이 문서)
- `plan/kubernetes/task.md` — 진행 상태 업데이트

### billage-k8s-manifests/ (별도 리포, 6개 커밋)
- `base/*` — 네임스페이스, ingress, network-policies, secrets-example 이름 통일
- `charts/*/templates/deployment.yaml` — 노드 라벨, toleration 수정
- `charts/*/values-prod.yaml` — 환경변수 매핑 수정, Secret 통일
- `charts/nextjs/templates/deployment.yaml` — envFromSecret 블록 추가
- `charts/nextjs/values.yaml` — liveness probe 경로 /login
- `charts/fastapi/values-prod.yaml` — memory limit 2Gi
- `argocd/` — AppProject, ApplicationSet 네임스페이스 수정
- `docs/` — deployment-runbook, helm-charts-guide 이름 통일

---

## 다음 작업

1. **ArgoCD 설치 & CI/CD 파이프라인** — billage-ops 네임스페이스
2. **ECR 토큰 자동 갱신** — CronJob 설정
3. **Ingress 연결** — ALB + DNS + TLS 설정
4. **FCM JSON Secret** — placeholder를 실제 값으로 교체
5. **Stateful 서비스** — RabbitMQ, Qdrant K8s 마이그레이션 (또는 계속 dev v2 사용)
