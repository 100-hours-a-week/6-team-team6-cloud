# 2026-03-18 4차 시도 관측 기록

## 근본 목적

kubeadm init 후 control plane CrashLoopBackOff 현상의 4차 시도 관측 데이터와 원인 분석을 기록한다.

## 비목적

- 해결책 자체를 이 문서에서 제시하지 않는다.
- 이전 시도(1~3차) 기록을 중복 기술하지 않는다.

## 배경

3차 시도에서 cp-01의 etcd/apiserver가 kubeadm init 직후 CrashLoopBackOff에 진입하는 문제 발생.
근본 원인 후보: kubelet restart 시 static pod container hash 불일치 → etcd Killing → cascading failure.

### 이번 시도 변경사항

- `kubernetes_version`: `v1.28.0` → `v1.28.15` (kubelet/kubeadm과 일치시킴)
- 관측 강화: readyz 1회 OK가 아닌 **시간 경과 후에도 유지되는지** + container restart count 확인

---

## 관측 로그

### 02:54 UTC — 버전 확인

```
kubelet:              v1.28.15
kubeadm:              v1.28.15
kubernetesVersion:    v1.28.15   ← 3차에서는 v1.28.0이었음 (수정됨)
```

### 02:54:30 UTC — kubeadm init

SSM `control-plane-init.sh` 실행 → **Status: Success**

### 02:55:56~02:57:27 UTC — 30초 간격 4회 관측

| 관측 | 시각 | readyz | etcd state | etcd attempt | apiserver state | apiserver attempt | nodes |
|------|------|--------|------------|-------------|-----------------|-------------------|-------|
| #1 | 02:55:56 | `000` (연결 불가) | RUNNING | **1** | RUNNING | **1** | 0 |
| #2 | 02:56:26 | `000` | RUNNING | 1 | **not running** | - | - |
| #3 | 02:56:57 | `000` | RUNNING | 1 | RUNNING | **2** | 0 |
| #4 | 02:57:27 | `000` | RUNNING | 1 | **not running** | - | - |

#### 해석

1. **readyz가 한 번도 200을 반환하지 않았다** — `000`은 curl이 TCP 연결조차 못했다는 뜻
2. **etcd는 살아있다** (attempt=1, 1회 재시작 후 안정) — 3차와 다른 점!
3. **apiserver가 반복적으로 죽고 있다** — attempt 1→2로 증가, 30초마다 not running ↔ running 반복
4. **apiserver가 CrashLoop의 원인** — etcd는 안정인데 apiserver만 죽는 것은 3차와 다른 패턴

#### 3차 vs 4차 비교

| 항목 | 3차 (v1.28.0) | 4차 (v1.28.15) |
|------|-------------|---------------|
| 버전 불일치 | kubelet 1.28.15 / image 1.28.0 | 전부 1.28.15 |
| etcd | CrashLoop (kubelet이 Killing) | **안정 (attempt=1)** |
| apiserver | CrashLoop (etcd 죽어서) | **CrashLoop (원인 다름)** |
| readyz | 가끔 OK (CrashLoop 틈새) | **한 번도 OK 없음** |

**결론: 버전 일치시키니 etcd는 안정화되었지만, apiserver가 별도 원인으로 CrashLoop.** apiserver crash 원인을 확인해야 한다.

### 02:59~03:02 UTC — apiserver crash 원인 분석

apiserver 컨테이너 로그 확인 결과:
- **에러/panic 없음** — 정상적으로 Shutting down (graceful)
- `02:59:07` — 정상 시작 (`Resetting endpoints for master service "kubernetes" to [10.30.3.10]`)
- `03:01:55` — 정상 종료 (`Stopped listening on [::]:6443`) — 시작 후 약 2분 48초
- kubelet이 SIGTERM을 보내서 종료시킨 것

apiserver manifest의 probe 설정:
```yaml
startupProbe:
  failureThreshold: 24    # 24번 실패하면 컨테이너 재시작
  periodSeconds: 10        # 10초 간격
  initialDelaySeconds: 10  # 시작 후 10초 대기
  # → 최대 250초(4분 10초) 이내에 /livez 응답해야 함

livenessProbe:
  failureThreshold: 8
  periodSeconds: 10
  # → startup 통과 후 80초 내 /livez 실패 시 재시작
```

**probe 실패가 원인은 아님** — 관측 시점(T+0~90s)에서 readyz가 000이었지만, 이후 apiserver가 살아나면 자연 통과.

### 03:04 UTC — 현재 상태 확인 (init 후 ~10분 경과)

```
apiserver: Running, attempt=5  ← 5번 재시작 끝에 안정화
etcd:      Running, attempt=1  ← 1번 재시작 후 안정 (3차와 다름!)
livez:     ok
readyz:    ok
```

kubelet PID: 2910 (kubeadm init의 kubelet restart 이후 고정)

**핵심 발견**: apiserver가 init 직후 여러 번 restart되는 것은 **kubeadm의 정상 동작**일 수 있다.
kubeadm init → kubelet 설정 변경 → kubelet restart → 기존 컨테이너 hash 불일치 → kill+recreate 반복 → 안정화.
3차 시도에서는 이 과정에서 etcd까지 kill되어 복구 불가능했지만, 버전 일치 후에는 etcd가 살아남아 apiserver가 결국 안정화됨.

### 03:07~03:09 UTC — 안정성 검증 (30초×3회)

```
check 1 (03:07:54): livez:200 readyz:200, apiserver attempt=5, etcd attempt=3
check 2 (03:08:24): livez:200 readyz:200, apiserver attempt=5, etcd attempt=3
check 3 (03:08:54): livez:200 readyz:200, apiserver attempt=5, etcd attempt=3
```

kubectl get nodes: cp-01 NotReady (CNI 미설치, 정상)

**livez/readyz는 안정. attempt 값 고정. 이 시점에서 apiserver/etcd는 더 이상 재시작하지 않는다.**

etcd attempt가 처음 관측(1) → 지금(3)으로 증가했지만, 최근 10분간은 고정. init 직후 혼란기에 재시작된 것.

### 03:07 UTC — SSM 외 직접 접속 확인 (사용자)

사용자가 `aws ssm start-session`으로 cp-01에 직접 접속하여 `kubectl get pods -n kube-system` 확인:

```
etcd:                      1/1 Running            1 restart    ← 안정
kube-apiserver:            1/1 Running            5 restarts   ← 안정
kube-controller-manager:   0/1 CrashLoopBackOff   6 restarts   ← 아직 CrashLoop
kube-scheduler:            0/1 CrashLoopBackOff   5 restarts   ← 아직 CrashLoop
kube-proxy:                0/1 CrashLoopBackOff   5 restarts   ← 아직 CrashLoop
```

**해석**: apiserver/etcd는 안정화됐지만, controller-manager/scheduler/kube-proxy는 이전 CrashLoop의 exponential back-off(최대 5분)가 남아있어 아직 재시작 대기 중. apiserver가 살아있으므로 back-off 만료 후 자연 복구될 것으로 예상.

### 03:17~03:18 UTC — controller-manager/scheduler/kube-proxy crash 원인

crictl logs로 직접 확인한 crash 원인:
```
controller-manager: dial tcp 10.30.3.10:6443: connect: connection refused (leader election 실패)
scheduler:          dial tcp 10.30.3.10:6443: connect: connection refused (list/watch 실패)
kube-proxy:         (로그 비어있음 — 같은 원인 추정)
```

**전부 apiserver 연결 거부.** apiserver가 Running이라고 했는데 왜?

### 03:20 UTC — 결정적 확인: apiserver가 다시 죽어있다

```
ss -tlnp | grep 6443    → (빈 출력) ← 6443 listen 없음!
crictl ps --name kube-apiserver  → (빈 출력) ← 컨테이너 없음!
kubectl get pods  → (응답 없음)
```

**/etc/hosts 확인**: `10.30.3.10 k8s-api.village.internal` — 정상 (문제 아님)

**결론**: 아까 내가 "apiserver attempt=5에서 안정화"라고 판단한 것은 **잘못**이었다.
apiserver는 여전히 간헐적으로 죽고 있으며, 내 3회 30초 관측이 "살아있는 순간"과 우연히 겹친 것이다.
3차 시도에서 readyz:OK가 가짜 양성이었던 것과 **동일한 패턴**.

### 현재 상태 요약 (init 후 ~25분 경과)

| 컴포넌트 | 상태 | restart count |
|---------|------|--------------|
| etcd | Running | 4 (증가 중) |
| apiserver | **Dead** (지금 이 순간) | 5+ |
| controller-manager | CrashLoopBackOff | 6+ |
| scheduler | CrashLoopBackOff | 6+ |
| kube-proxy | CrashLoopBackOff | 6+ |

### 핵심 미해결 질문

**apiserver가 왜 반복적으로 죽는가?**
- etcd는 살아있다 (attempt=4지만 현재 Running)
- apiserver는 error/panic 없이 graceful shutdown된다
- 즉 **kubelet이 apiserver를 kill**하고 있다
- kubelet이 apiserver를 kill하는 이유: **liveness probe 또는 startup probe 실패**
- 하지만 probe 실패 로그가 kubelet에서 안 보인다 → kubelet이 static pod hash 변경으로 recreate하는 것일 수 있다

**다음 조사**: kubelet 로그에서 apiserver pod와 관련된 모든 이벤트를 시간순으로 추적해야 한다.

---

## "이전엔 됐는데 지금 안 되는" 원인 분석

### 커밋 히스토리 비교

```
0d575eb (2026-03-12) — feat: add kubeadm prod stack and bootstrap assets  ← 최초 성공 시점
ff56172 (2026-03-1x) — feat(kubeadm): add runbook, learn docs, fix namespace/calico hotfix
```

### 코드 변경 비교 (init/join 관련)

| 파일 | 변경 여부 | 내용 |
|------|----------|------|
| `ssm-control-plane-init.sh.tftpl` | **변경 없음** | init 스크립트 동일 |
| `kubeadm-init-config.yaml.tftpl` | **변경 없음** | init config 동일 |
| `bootstrap-common.sh.tftpl` | **변경 없음** | containerd/kubelet 설치 동일 |
| `cloud-init-control-plane-init.yaml.tftpl` | **변경 없음** | cloud-init 동일 |
| `ssm-control-plane-join.sh.tftpl` | 변경됨 | /etc/hosts 순서 변경 (join 후 self-pin) |
| `ssm-platform-bootstrap.sh.tftpl` | 변경됨 | calico hotfix, BGP route 추가 |
| `main.tf` | 변경됨 | calico_kubernetes_service_host 추가, route table output |
| `modules/iam/main.tf` | 변경됨 | calico-bgp-routes IAM policy 추가 |
| `modules/network/main.tf` | 변경됨 | private_route_table_ids output 추가 |

**결론: init/join에 영향을 주는 코드는 변경되지 않았다.** 변경된 것은 모두 04-platform (bootstrap) 단계 관련.

### 진짜 차이: AMI

```
AMI 선택: most_recent = true (ubuntu-noble-24.04 최신)

최초 성공 (2026-03-12):  ami-04f851a80be515079 (20260218 빌드)
현재 (2026-03-18):       ami-084a56dceed3eb9bb (20260313 빌드) ← 새 AMI!
```

**AMI가 바뀌었다.** 3월 13일에 새 Ubuntu 24.04 AMI가 출시되었고, `most_recent = true`로 인해 3월 18일 terraform apply 시 이 새 AMI가 자동 선택된다.

Ubuntu 24.04 AMI 20260313에서 변경된 것이 kubelet/containerd/systemd의 동작에 영향을 줄 수 있다:
- kernel 버전 변경 → cgroup v2 동작 차이
- systemd 버전 변경 → kubelet restart 타이밍 차이
- containerd 기본 설정 변경

### terraform.tfvars 변경

이 세션에서 수행한 변경:
```
kubernetes_version: v1.28.0 → v1.28.15
```

하지만 원래 성공 시에도 `v1.28.0`이었다. 즉 **버전 불일치는 원래부터 있었는데 성공했다**.
→ 버전 불일치 자체는 근본 원인이 아닐 가능성.

### 종합 판단

| 후보 | 가능성 | 근거 |
|------|--------|------|
| 코드 변경 | **낮음** | init 관련 코드 변경 없음 |
| AMI 변경 | **높음** | 유일한 외부 요인 변화. 20260218→20260313 |
| kubernetes_version 불일치 | **중간** | 원래도 불일치였으나 새 AMI에서 더 민감하게 반응할 수 있음 |
| 타이밍/race condition | **높음** | 새 AMI의 systemd/kernel에서 kubelet restart 타이밍이 달라졌을 수 있음 |

### 추천 조치

1. **AMI 고정** — `most_recent = true` 대신 이전 성공 AMI `ami-04f851a80be515079` 를 명시적으로 지정하여 테스트
2. 만약 이전 AMI에서 성공하면 → 새 AMI의 변경사항이 원인임이 확정
3. AMI 고정 후에도 실패하면 → 다른 원인 (AWS 인프라 타이밍 등)

---

## 심층 분석: etcd가 반복 종료되는 원인 (06:46~07:08 UTC)

### 초기 trigger: kubelet PID 교체

```
02:54:43  systemd: Started kubelet.service
02:54:44  kubelet[2488]: Started kubelet
02:54:44  kubelet[2488]: Adding static pod path /etc/kubernetes/manifests
02:54:44  kubelet[2488]: podName="etcd-billage-kubeadm-prod-cp-01"
...
02:54:50  systemd: Stopping kubelet.service   ← kubeadm이 kubelet config 쓴 뒤 restart
02:54:50  systemd: Stopped kubelet.service
02:54:50  systemd: Started kubelet.service
02:54:50  kubelet[2910]: Started kubelet       ← 새 PID, 이후 이 프로세스가 계속 유지
```

새 kubelet(2910)이 이전 kubelet(2488)이 만든 컨테이너를 즉시 Killing:

```
02:54:50  kubelet[2910]: Reason:"Killing", Message:"Stopping container kube-apiserver"
02:54:50  kubelet[2910]: Reason:"Killing", Message:"Stopping container etcd"
```

**kubelet PID 2910은 이후 변경되지 않음**을 확인. 그럼 그 이후 etcd를 계속 죽이는 건 뭔가?

### etcd 컨테이너 종료 패턴: SIGTERM (exit code 0)

etcd attempt 46 (06:55:08~06:55:22) 분석:

```
시작:   06:55:08.859  StartContainer returns successfully
리더:   06:55:09.881  became leader at term 46
서빙:   06:55:09.886  ready to serve client requests
종료:   06:55:22.243  received signal; shutting down, signal: "terminated"
```

| 항목 | 값 |
|------|-----|
| exitCode | **0** (정상 종료) |
| reason | Completed |
| 수명 | **14초** |
| 종료 원인 | SIGTERM 수신 |

**etcd가 crash하는 게 아니다.** 정상 동작 중에 SIGTERM을 받고 graceful shutdown하고 있다.

### containerd 로그로 본 kill 체인

```
06:55:22.237  StopContainer for etcd (deed3f5da94f3)       ← kubelet이 CRI 호출
06:55:22.239  Stop container with signal terminated         ← containerd가 SIGTERM 전달
06:55:22.251  etcd exit (pid 46602, exit code 0)
06:55:22.289  StopPodSandbox for 84017767c                  ← sandbox도 정리
06:55:22.296  sandbox exit (exit_status:137, SIGKILL)
06:55:22.327  TearDown network for sandbox
06:55:22.654  RunPodSandbox for Attempt:47                  ← 즉시 새 sandbox 생성
06:55:22.719  new sandbox id: 9fb455a3c60a1
```

**kubelet이 CRI `StopContainer` API를 호출하여 etcd를 종료시킨 것이다.** 외부 프로세스가 직접 SIGTERM을 보낸 게 아니라, kubelet → containerd → SIGTERM 경로.

### probe 실패 로그가 없는 이유

kubelet 로그에서 etcd의 `Unhealthy` 이벤트가 전혀 없다:

```bash
journalctl -u kubelet | grep "unhealthy.*etcd\|etcd.*unhealthy\|probe.*etcd"
# → 결과 없음
```

하지만 **apiserver가 죽어있어서 kubelet이 이벤트를 API 서버에 쓸 수 없다**:

```
Unable to write event ... 'Patch "https://k8s-api.village.internal:6443/..."':
  dial tcp 10.30.3.10:6443: connect: connection refused
```

apiserver의 `Unhealthy` 이벤트는 **이전에 apiserver가 살아있을 때 기록된 것**이 남아있다:

```
Reason:"Unhealthy", Message:"Liveness probe failed: HTTP probe failed with statuscode: 500"
Count: 36 (03:07:02 ~ 06:30:02)
```

**etcd의 probe 실패 이벤트도 발생하고 있지만, apiserver가 죽어있어 기록이 남지 않는 것으로 추정.**

### etcd 수명 패턴

| attempt | sandbox | 수명 | 종료 방법 |
|---------|---------|------|----------|
| 46 | 84017767c | **14초** | kubelet StopContainer |
| 47 | 9fb455a3c | **~5분 35초** | kubelet StopPodSandbox |
| 48 | 440eb37af | **~7분 42초** | 확인 시점에 이미 Exited |

14초 → 5분 → 7분으로 수명이 길어지고 있다. 이는 **etcd startup probe 통과 후 liveness probe 실패**까지의 시간과 일치한다.

### etcd static pod manifest의 probe 설정

```yaml
startupProbe:
  path: /health?serializable=false    # linearizable read 필요
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 24                # 최대 250초 허용
  timeoutSeconds: 15

livenessProbe:
  path: /health?exclude=NOSPACE&serializable=true  # local check
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 8                 # 80초 연속 실패 시 kill
  timeoutSeconds: 15
```

타이밍 계산:
- startup probe 통과: T+10~T+20 (첫 번째 혹은 두 번째 체크에서 통과)
- liveness probe 시작: startup 통과 후 T+10
- liveness probe kill: 8회 연속 실패 = 80초 후

**예상 수명: ~90~100초.** 하지만 실제 수명은 5~7분. → liveness probe가 처음엔 통과하다가 중간에 실패하기 시작하는 것.

### 건강 검사 직접 확인 (07:07 UTC)

etcd attempt 48이 353초간 실행 중일 때:

```bash
curl -s http://127.0.0.1:2381/health?serializable=false
# → HTTP 200, {"health":"true","reason":""}
```

이 시점에서는 건강했지만, 1분 21초 후(07:08:42)에 이미 Exited. **간헐적으로 health check가 실패하는 구간이 있다.**

### 매니페스트 파일 검증

```
etcd.yaml       Modify: 02:54:43 (init 시점 이후 변경 없음)
apiserver.yaml   Modify: 02:54:43 (동일)
```

**매니페스트 변경으로 인한 pod 재생성은 아님.**

### 연쇄 실패 메커니즘 (self-reinforcing loop)

```
etcd 죽음 (liveness probe 실패 추정)
  → apiserver가 etcd 연결 실패 → /livez HTTP 500 → liveness 실패 → kill
    → controller-manager, scheduler: apiserver 연결 불가 → crash
      → 모든 컴포넌트 CrashLoopBackOff (최대 5분 backoff)
        → etcd 재시작 → apiserver는 여전히 backoff 대기 중
          → etcd는 client 없이 혼자 동작 → 시간 경과 후 liveness 실패
            → 다시 죽음 → 무한 루프
```

### apiserver가 죽는 구체적 원인

apiserver의 liveness probe는 `/livez`를 체크하며, 이 endpoint에는 etcd 연결 상태가 포함된다. etcd가 죽으면:

```
Liveness probe failed: HTTP probe failed with statuscode: 500
```

그리고 apiserver sandbox가 반복적으로 `task not found` 에러를 보임:

```
CreateContainerError: failed to get sandbox container task:
  no running task found: task d1e9dac8... not found: not found
```

### 결론: 왜 etcd가 계속 죽는가

1. **최초 원인**: kubelet PID 교체(2488→2910) 시 etcd 컨테이너 kill (02:54:50)
2. **연쇄 반응**: etcd 죽음 → apiserver 죽음 → 모든 컴포넌트 CrashLoopBackOff
3. **지속 원인**: etcd가 재시작되어도 apiserver가 backoff 중 → etcd의 liveness probe가 간헐적으로 실패 → kubelet이 다시 kill → 무한 루프
4. **probe 실패가 보이지 않는 이유**: apiserver가 죽어있어서 kubelet의 Unhealthy 이벤트가 API 서버에 기록되지 않음

### 미해결 질문

- etcd의 liveness probe(`/health?serializable=true`)가 왜 간헐적으로 실패하는가?
  - 가능성 1: WAL 재생(1857 entries) 중 일시적 무응답
  - 가능성 2: 새 AMI의 EBS I/O 특성 변화
  - 가능성 3: containerd/shim 레벨의 간헐적 문제
- 이전 AMI(20260218)에서는 같은 코드로 성공 → AMI 변경이 근본 요인일 가능성 여전히 높음

