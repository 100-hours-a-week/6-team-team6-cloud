# kubeadm prod 트러블슈팅 보고서 (2026-03-13, 최신화)

## 근본 목적
- `kubeadm/envs/prod` 클러스터의 장애 경로를 사실 기반으로 고정하고, 다음 작업자가 같은 실패를 반복하지 않도록 재현 가능한 조치 순서를 남긴다.
- 특히 `control-plane endpoint` 경로, `Calico/CNI` 경로, `platform bootstrap` 재실행 리스크를 분리해 운영한다.

## 비목적
- 성공/실패 로그를 무작위로 나열하지 않는다.
- 원인과 근거가 없는 추정은 기록하지 않는다.

## 최신 상황도 (2026-03-13 18:31 KST 관측)
| 레이어 | 상태 | 근거 |
|---|---|---|
| EC2 / NLB / private DNS | 정상 | `billage-kubeadm-prod-api-tg` target health `3/3 healthy` |
| Node | 정상 | `kubectl get nodes` 기준 `10/10 Ready` |
| Calico control plane | 부분 불안정 | `calico-kube-controllers 1/1`, `calico-typha 3/3`, `calico-node`는 시점별 `8~10/10` 변동 |
| Calico CSI | 대부분 수렴 | `csi-node-driver`는 endpoint 고정 후 `10/10` 또는 `9~10/10` 변동 |
| Foundation/Addons | 미적용 | `billage-*` namespace, `ingress-nginx`, `cert-manager` 미생성 |

## 오늘 추가로 확인한 핵심 원인
1. `Calico CSI`는 기본적으로 `KUBERNETES_SERVICE_HOST=10.96.0.1`(Service IP) 경로를 사용했다.
- `crictl inspect`에서 `calico-csi` 컨테이너 env 확인.
- control-plane 불안정 시 Service 경로로 토큰 조회가 실패하면서 `exitCode=2` CrashLoop 반복.

2. `platform-bootstrap`/수동 롤링을 반복하면 Calico가 자기 자신을 다시 흔들 수 있다.
- `kubectl rollout restart`가 누적되면 `pod sandbox changed`, `bird.ctl connection refused`가 재발.
- 즉, 장애 수습 구간에서 bootstrap 문서를 여러 번 재실행하면 수렴 시간을 늘린다.

3. `terraform -target` 사용 시 기대 외 리소스 변경이 같이 발생할 수 있다.
- 이전 실행에서 `aws_ssm_document`만 노렸지만 control-plane instance `user_data` 변경이 같이 적용되어 안정성 저하를 유발했다.

## 오늘 실제 조치
1. 라이브 hotfix
- `daemonset/csi-node-driver`에 `KUBERNETES_SERVICE_HOST=10.30.3.10`, `KUBERNETES_SERVICE_PORT=6443` 주입.
- 롤링 후 `csi-node-driver`가 CrashLoop 구간을 벗어나는 것 확인.

2. 재발 방지 코드 반영
- [ssm-platform-bootstrap.sh.tftpl](/Users/cho/IdeaProjects/6-team-team6-cloud/kubeadm/envs/prod/templates/ssm-platform-bootstrap.sh.tftpl)
  - 기존 `calico-node`, `calico-kube-controllers`, `calico-typha` env 고정에 더해 `csi-node-driver` env 고정 추가.
  - `csi-node-driver` rollout/status 대기 절차 추가.

3. 운영 중 명령 정리
- 오래 대기하던 수동 안정화 명령(`fc55d56c-65c6-436a-85ce-97002c4004d5`)은 취소 처리.

## 수집 증거 (이번 세션 주요 command id)
- 상태 체크: `2139f17e-e066-4509-87d3-3ab4d6a722db`
- Calico/CSI 상세 수집: `aaa82d05-5646-4baa-9930-1b4b0e638632`
- `data-01` 컨테이너 런타임 inspect: `4a7196e0-a9dc-44a0-a90c-5729daaba25f`
- CSI endpoint hotfix/rollout: `9fa3ca60-e1d6-49ef-9868-e336db2f737f`
- 최신 스냅샷: `5596833a-d8f7-4824-a9e9-30e58386eac2`

## 미완료/리스크
- 현재도 `calico-node` 일부가 `Ready`와 `NotReady`를 왕복하는 시점이 존재한다.
- 로그상 주된 증상은 readiness probe의 `BIRD socket` 초기화 지연과 `pod sandbox changed` 반복이다.
- Foundation 리소스(`billage-*`, RBAC, NetworkPolicy), ingress-nginx, cert-manager/TLS는 아직 미적용 상태다.

## 다음 작업 권장 순서
1. Calico 안정화 게이트 먼저 통과
- 최소 10분 연속 기준: `calico-node 10/10`, `csi-node-driver 10/10`, `calico-kube-controllers 1/1`, `calico-typha 3/3`.

2. 이후 단계 분리 적용
- `foundation(namespace/RBAC/NetworkPolicy)` → `ingress-nginx + AWS LBC` → `cert-manager/TLS`.
- 단계별 완료 확인 전 다음 단계로 넘어가지 않는다.

3. 운영 규칙
- 장애 구간에서는 `platform-bootstrap` 전체 재실행 대신, 필요한 리소스만 부분 적용한다.
- `terraform -target`은 인스턴스 스펙(user_data) 변화를 동반할 수 있으므로 사전 plan diff를 엄격히 확인한다.
