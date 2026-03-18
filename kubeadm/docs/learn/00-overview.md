# 00. 아키텍처 개요

이 런북은 AWS 위에 kubeadm 기반 프로덕션급 쿠버네티스 클러스터를 처음부터 직접 구축하는 학습 가이드다.
모든 명령어는 실제 실행 순서대로 작성되어 있으며, 각 단계에서 **왜 이 작업이 필요한지**를 함께 설명한다.

---

## 클러스터 구성

```
                         인터넷
                           │
                  [ALB - internet-facing]
                  ACM TLS 종료 (443→nginx)
                           │
            ┌──────────────┼──────────────┐
            │         app-01~04           │
            │  [ingress-nginx NodePort]   │
            │    (billage-edge 트래픽)    │
            └──────────────┼──────────────┘
                           │ 클러스터 내부
         ┌─────────────────┼─────────────────┐
         │    k8s-api.village.internal        │
         │    [internal NLB :6443]            │
         │         │                          │
         │  ┌──────┴──────┐                  │
         │  cp-01  cp-02  cp-03               │
         │  (etcd, kube-apiserver 등)         │
         │                                    │
         │  app-01  app-02  app-03  app-04    │
         │  (billage-app, billage-edge,        │
         │   billage-ops workload)             │
         │                                    │
         │  data-01  data-02  data-03         │
         │  (billage-data, DB/MQ 등)          │
         │  taint: workload-plane=data:       │
         │         NoSchedule                 │
         └────────────────────────────────────┘
                   Calico BGP mesh
```

---

## 노드 구성

| 이름 | 역할 | 대수 | 예시 IP | AZ |
|------|------|------|---------|----|
| my-cluster-cp-01 | control-plane (init) | 1 | 10.30.1.10 | ap-northeast-2a |
| my-cluster-cp-02 | control-plane (join) | 1 | 10.30.5.10 | ap-northeast-2b |
| my-cluster-cp-03 | control-plane (join) | 1 | 10.30.9.10 | ap-northeast-2c |
| my-cluster-app-01 | app worker | 1 | 동적 | ap-northeast-2a |
| my-cluster-app-02 | app worker | 1 | 동적 | ap-northeast-2b |
| my-cluster-app-03 | app worker | 1 | 동적 | ap-northeast-2c |
| my-cluster-app-04 | app worker | 1 | 동적 | ap-northeast-2a |
| my-cluster-data-01 | data worker | 1 | 동적 | ap-northeast-2a |
| my-cluster-data-02 | data worker | 1 | 동적 | ap-northeast-2b |
| my-cluster-data-03 | data worker | 1 | 동적 | ap-northeast-2c |

---

## 네트워크 설계

| 구분 | CIDR | 비고 |
|------|------|------|
| VPC | 10.30.0.0/16 | 전용 |
| Public 서브넷 (3 AZ) | 10.30.0.0/24, 10.30.4.0/24, 10.30.8.0/24 | NLB용 |
| CP 서브넷 (3 AZ) | 10.30.1.0/24, 10.30.5.0/24, 10.30.9.0/24 | cp 노드 |
| Worker 서브넷 (3 AZ) | 10.30.2.0/24, 10.30.6.0/24, 10.30.10.0/24 | app/data 노드 |
| Pod CIDR | 192.168.0.0/16 | Calico IP Pool |
| Service CIDR | 10.96.0.0/12 | ClusterIP 범위 |
| DNS ClusterIP | 10.96.0.10 | CoreDNS |

> **CIDR 비겹침 원칙**: VPC(10.30), Pod(192.168), Service(10.96)은 서로 겹치지 않아야 한다.

---

## API 서버 접근 방식

```
worker/cp 노드 → k8s-api.village.internal:6443 → internal NLB → cp-01~03
```

단, **control-plane 노드 자신은** `/etc/hosts`에 `k8s-api.village.internal → 자신의 private IP`를 등록한다.
이유: cp 노드가 NLB를 통해 자기 자신에 접속하는 순환 의존성(self-loop)을 방지하기 위함이다.
kubelet과 admin kubeconfig가 apiserver에 접근할 때 NLB를 거치면, NLB 헬스체크 실패 상황에서 self-loop가 발생할 수 있다.

---

## 전체 구축 흐름

```
01. AWS 인프라  →  02. 노드 공통 설정  →  03. kubeadm init (cp-01)
      ↓                  (전체 10대)
04. 노드 join (cp-02/03, app×4, data×3)
      ↓
05. Calico CNI 설치
      ↓
06. 노드 라벨 / taint
      ↓
07. 네임스페이스 + RBAC
      ↓
08. NetworkPolicy
      ↓
09. ingress-nginx + AWS Load Balancer Controller
      ↓
10. cert-manager + TLS
```

---

## 이 런북에서 사용하는 변수

각 문서에서 아래 값을 그대로 사용한다. 실제 환경에 맞게 바꾸어 적용한다.

```bash
CLUSTER_NAME="my-cluster"
AWS_REGION="ap-northeast-2"
CONTROL_PLANE_ENDPOINT="k8s-api.village.internal"

# cp 노드 고정 IP
CP01_IP="10.30.1.10"
CP02_IP="10.30.5.10"
CP03_IP="10.30.9.10"

# Kubernetes 버전
K8S_VERSION="v1.28.0"
K8S_MINOR="v1.28"

# 네트워크
POD_CIDR="192.168.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
DNS_IP="10.96.0.10"
```

---

다음: [01-aws-infra.md](./01-aws-infra.md)
