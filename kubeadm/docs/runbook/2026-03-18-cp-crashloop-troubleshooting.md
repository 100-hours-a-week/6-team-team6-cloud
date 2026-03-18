# 2026-03-18 Control Plane CrashLoopBackOff 트러블슈팅 보고서

## 근본 목적

kubeadm init 후 control plane 전체가 CrashLoopBackOff에 빠지는 현상의 근본 원인을 분석하고, 타임라인과 영향 범위를 기록한다.

## 비목적

- 정상 kubeadm init/join 절차를 이 문서에서 다시 설명하지 않는다.
- 해결 후 검증 절차는 별도 관측 기록에 남긴다.

## 현상

`terraform destroy` → `terraform apply` → runbook 순서대로 실행 시, cp-01에서 `kubeadm init` 성공 후 **수 초~수십 초 만에** etcd, kube-apiserver, kube-scheduler, kube-controller-manager 전체가 CrashLoopBackOff에 진입한다. cp-02 join 시도와 무관하게 cp-01 단독으로도 발생한다.

---

## 타임라인 (로그 기반 재구성)

| 시각 (UTC) | 이벤트 | 증거 |
|-----------|--------|------|
| `02:04:04` | kubelet PID 2534 시작 (kubeadm init이 기동) | `kubelet[2534]: Creating Container Manager` |
| `02:04:04` | kubelet PID 2534가 apiserver 접속 실패 | `dial tcp 10.30.3.10:6443: connect: connection refused` |
| `02:04:05` | etcd, apiserver static pod admit | `Topology Admit Handler podName=etcd`, `podName=kube-apiserver` |
| `02:04:12` | **kubelet 재시작** — PID 2534 → PID 2961 | PID가 2534에서 2961로 변경, 새 `Creating Container Manager` |
| `02:04:12` | PID 2961이 etcd, apiserver를 다시 admit | 동일 pod UID 재처리 |
| `02:04:12` | kubelet이 **기존 etcd 컨테이너를 Killing** | `Reason:"Killing", Message:"Stopping container etcd"` (Count:2, 02:04:12~02:05:02) |
| `02:04:42` | apiserver가 GOAWAY 전송 후 connection 끊김 | `http2: server sent GOAWAY and closed the connection; LastStreamID=55` |
| `02:04:42` | apiserver 연결 거부 시작 | `dial tcp 10.30.3.10:6443: connect: connection refused` |
| `02:04:46` | mirror pod 생성 시도 → `already exists` | apiserver가 잠깐 살아있었음을 증명 |
| `02:04:52` | apiserver pod startup 관측 | `Observed pod startup duration podStartSLOduration=6.65s` |
| `02:05:01` | etcd pod startup 관측 | `Observed pod startup duration podStartSLOduration=15.29s` |
| `02:05:02` | apiserver 응답 비정상 | `rpc error: code = Unknown desc = malformed header: missing HTTP content-type` |
| `02:05:03` | **etcd CrashLoopBackOff 시작** (back-off 10s) | `failed to "StartContainer" for "etcd" with CrashLoopBackOff` |
| `02:05:03` | kube-scheduler CrashLoopBackOff 시작 | 동일 패턴 |
| `02:05:03` | kube-controller-manager CrashLoopBackOff 시작 | 동일 패턴 |
| `02:05:05` | kube-proxy CrashLoopBackOff 시작 | 동일 패턴 |
| `02:09:21` | Step 2.5 readiness check — **readyz: OK** | 이 시점에 잠깐 복구됨 (etcd 재시작 cycle 중 살아있는 순간) |
| `02:11:22` | etcd 다시 Killing (Count:3) | `Reason:"Killing", Message:"Stopping container etcd"` |
| `02:13:17` | cp-02 join 시도 — 실패 | etcd Killing Count:4, apiserver `malformed header` |
| `02:21:50` | etcd 재시작, leader elected | etcd 로그: `elected leader at term 8` |
| `02:22:02` | etcd **12초 만에 SIGTERM 수신** | `received signal; shutting down` (시작 후 12초) |
| `02:23:30` | apiserver etcd 연결 실패 | `dial tcp 127.0.0.1:2379: connect: connection refused` |
| `02:23:35` | apiserver Fatal | `Error creating leases: error creating storage factory: context deadline exceeded` |
| 이후 | 전체 back-off 5m0s 도달, 영구 CrashLoop | etcd attempt 7, 모든 컴포넌트 dead |

---

## 근본 원인 분석

### 1차 원인: kubeadm init 중 kubelet 재시작 (PID 2534 → 2961)

`kubeadm init`이 kubelet을 PID 2534로 시작한 후, 8초 만에 PID 2961로 재시작했다.

```
02:04:04  kubelet[2534]: Creating Container Manager
02:04:12  kubelet[2961]: Creating Container Manager   ← 8초 후 새 PID
```

kubeadm init 과정에서 kubelet 설정 파일(`/var/lib/kubelet/config.yaml`)을 쓰고 kubelet을 restart하는 것은 정상 동작이다. 그러나 **새 kubelet(2961)이 기존 kubelet(2534)이 만든 etcd 컨테이너를 자기 것이 아닌 것으로 판단하고 Killing**한 것이 문제의 시작이다.

증거:
```
02:04:12  Reason:"Killing", Message:"Stopping container etcd"  (FirstTimestamp: 02:04:12)
```

kubelet 재시작 시점과 etcd Killing 시점이 **동일 초(02:04:12)**이다.

### 2차 원인: etcd Killing → apiserver 연쇄 죽음

etcd가 killed되면:
1. apiserver가 etcd backend 연결을 잃음
2. apiserver가 `GOAWAY` HTTP/2 프레임을 보내고 connection 종료 (`02:04:42`)
3. apiserver 자체도 etcd 없이 동작 불가 → crash
4. kubelet이 apiserver에 mirror pod 상태를 보고할 수 없음
5. 모든 컴포넌트가 cascading failure

### 3차 원인: CrashLoopBackOff 탈출 불가

etcd가 재시작해도 **kubelet이 다시 Killing**한다. Killing 이벤트가 반복됨:
```
Count:2  02:04:12 ~ 02:05:02
Count:3  02:04:12 ~ 02:11:22
Count:4  02:04:12 ~ 02:13:17
```

kubelet이 왜 etcd를 반복 killing하는지:
- static pod manifest의 hash가 변경되었거나
- kubelet 재시작 후 기존 컨테이너의 annotation/hash가 불일치하면 kubelet은 "old pod"로 판단하고 terminate 후 새로 생성

이 과정에서 etcd가 정상 기동 → 12초 후 kill → 재시작 → 12초 후 kill의 cycle에 빠진다.

### 왜 Step 2.5에서 readyz OK였나?

CrashLoopBackOff의 back-off 시간은 `10s → 20s → 40s → 80s → 160s → 300s`로 증가한다. 각 cycle에서 etcd/apiserver가 잠깐 살아있는 구간이 있다. Step 2.5가 실행된 `02:09:21`은 back-off cycle 중 apiserver가 잠깐 살아있는 순간과 겹친 것이다.

즉 **readyz OK는 "안정적으로 동작 중"이 아니라 "CrashLoop cycle 중 잠깐 살아있는 순간"**이었다.

---

## 왜 이전 구축(1차 시도)에서는 init이 성공하고 readyz도 통과했는가?

1차 시도의 타임라인:
```
kubeadm init 완료 → readyz OK (attempt 5, ~50초 대기) → 정상
```

3차 시도 (이번):
```
kubeadm init 완료 → readyz OK (attempt 1, 즉시) → 이미 CrashLoop 진입 상태
```

**차이**: 1차에서는 kubelet 재시작 후 etcd 컨테이너가 정상적으로 "인계"되었지만, 3차에서는 인계 실패로 Killing이 시작되었다. 이것은 **타이밍에 의존하는 race condition**이다.

kubeadm init 중 kubelet이 restart될 때:
- 성공 경로: 새 kubelet이 기존 etcd 컨테이너의 hash를 인식 → 그대로 유지
- 실패 경로: 새 kubelet이 기존 etcd 컨테이너의 hash 불일치 판단 → Killing → CrashLoop

---

## 영향 범위

| 컴포넌트 | 상태 | 원인 |
|---------|------|------|
| etcd | CrashLoopBackOff (attempt 7+) | kubelet에 의한 반복 Killing |
| kube-apiserver | CrashLoopBackOff | etcd 연결 불가 |
| kube-scheduler | CrashLoopBackOff | apiserver 연결 불가 |
| kube-controller-manager | CrashLoopBackOff | apiserver 연결 불가 |
| kube-proxy | CrashLoopBackOff | apiserver 연결 불가 |
| NLB target health | 3/3 unhealthy | apiserver 6443 TCP 응답 없음 |
| cp-02 join | Failed (download-certs timeout) | NLB unhealthy → apiserver 접근 불가 |

---

## 시스템 환경 (사고 당시)

| 항목 | 값 |
|------|-----|
| 인스턴스 타입 | (IMDS 조회 실패 — 인스턴스 metadata 접근 차단 가능) |
| vCPU | 2 |
| 메모리 | 7.6GiB (사용 639MiB, 여유 7.0GiB) |
| 디스크 | 48GB (사용 3.5GB, 여유 44GB) |
| OOM | 없음 (dmesg에 OOM/killed 기록 없음) |
| Swap | 비활성화 |
| Kubernetes 버전 | v1.28.15 (kubelet), v1.28.0 (kubeadm init config) |
| etcd 버전 | 3.5.15 |

**리소스 부족이 아님.** 메모리 7GB 여유, 디스크 44GB 여유, OOM 없음.

---

## 해결 방향

### 단기 (현재 상태 복구)

현재 상태는 복구 불가. `terraform destroy` → `terraform apply` 후 재시도.

### 중기 (재발 방지)

1. **kubelet restart race condition 회피**: kubeadm init 완료 후 etcd/apiserver가 안정적으로 동작하는지 확인하는 로직을 강화
   - readyz 1회 OK가 아니라 **30초 간격으로 3회 연속 OK** 확인
   - `crictl ps --name etcd` + `crictl ps --name kube-apiserver`로 컨테이너가 Running이고 restart count가 증가하지 않는지 확인

2. **kubeadm init config에서 kubelet 버전과 image 버전 일치**:
   - `kubernetes_version = "v1.28.0"` (kubeadm init config)이지만 실제 kubelet은 `v1.28.15`
   - 이 불일치가 static pod manifest hash 차이를 유발할 가능성 있음

3. **cp-02 join 전 cp-01 안정성 검증 강화**:
   ```bash
   # etcd container restart count가 0인지 확인
   crictl ps --name etcd -o json | jq '.containers[0].metadata.attempt'
   # 0이어야 한다. 0보다 크면 이미 CrashLoop 진입
   ```

### 장기 (아키텍처)

- kubelet, kubeadm, kubectl, container image 버전을 완전히 일치시키는 것을 검토
- kubeadm init config의 `kubernetesVersion`을 설치된 kubelet 버전과 동기화

---

## 핵심 교훈

1. **`readyz: OK` ≠ stable**: CrashLoopBackOff cycle 중에도 readyz가 OK인 순간이 있다. 안정성은 **시간 경과 후에도 유지되는지**로 판단해야 한다.
2. **kubelet restart는 transparent하지 않다**: kubeadm init 과정에서 kubelet이 restart될 때, 기존 static pod 컨테이너가 kill될 수 있다. 이것은 kubeadm의 정상 동작이지만, race condition으로 실패하면 cascading failure를 일으킨다.
3. **etcd 단일 member의 취약성**: 1-member etcd는 etcd 프로세스가 죽으면 즉시 전체 control plane이 죽는다. CrashLoopBackOff에 빠지면 자력 복구가 불가능하다.
