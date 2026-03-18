# Kubernetes 클러스터 구축 Runbook (prod)

`kubeadm/envs/prod` 스택 기반 프로덕션 클러스터 구축 Step-by-Step 가이드.

처음 보는 사람도 명령어를 순서대로 실행하면 전체 클러스터가 구축되도록 작성되었다.

---

## 근본 목적

- `kubeadm/envs/prod` 클러스터 구축 절차를 선형 단계로 고정해, 작업자에 따라 순서가 흔들리거나 누락되는 일을 줄인다.
- 특히 Terraform, kubeadm bootstrap, 플랫폼 애드온, 외부 DNS 검증까지의 연결 관계를 빠르게 파악할 수 있게 한다.

## 비목적

- 장애 조사 보고서나 일회성 운영 메모를 실행 단계 문서와 섞어 두지 않는다.
- 각 단계의 구현 배경을 과도하게 늘어놓아 실제 실행 순서를 흐리지 않는다.

## 실행 문서

| 파일 | 내용 | 소요 시간 |
|------|------|-----------|
| [00-prereqs.md](./00-prereqs.md) | 아키텍처 요약, IAM 권한, backend 리소스, ACM 인증서, 도구 버전 확인 | ~10분 |
| [01-terraform.md](./01-terraform.md) | terraform.tfvars 작성, terraform apply, 변수 export | ~10-15분 |
| [02-cp-init.md](./02-cp-init.md) | cloud-init 완료 대기, cp-01 kubeadm init, join env 추출/인코딩 | ~8-10분 |
| [03-node-join.md](./03-node-join.md) | cp-02/03 join, app/data worker join, 10대 확인 | ~5-8분 |
| [04-platform.md](./04-platform.md) | SSM Document 실행 (Calico, cert-manager, ingress-nginx, aws-lbc) + 수동 추가 설치 (ingress-nginx HA, metrics-server, EBS CSI) | ~25-35분 |
| [05-dns-verify.md](./05-dns-verify.md) | ALB hostname 확인, DNS CNAME 등록, 최종 검증 | ~5-10분 |
| [99-troubleshooting.md](./99-troubleshooting.md) | 단계별 실패 케이스 및 해결 방법 | - |

**전체 소요 시간: 약 65-90분** (DNS 전파 시간 제외)

---

## 참고 기록

| 파일 | 용도 |
|------|------|
| [2026-03-13-kubeadm-prod-troubleshooting-report.md](./2026-03-13-kubeadm-prod-troubleshooting-report.md) | 2026-03-13 기준 장애 수습 기록. 선형 실행 단계가 아니라 참고용 보고서다. |

---

## 주요 설계 결정 사항

- **NAT Gateway 없음**: 노드 public IP + SG 제한으로 부트스트랩 egress 확보
- **kube-apiserver 접근**: internal NLB + private Route53 (`k8s-api.billage.internal`)만 사용
- **control-plane self-dependency 방지**: 각 control-plane 노드는 `/etc/hosts`에 `k8s-api.billage.internal → 자신의 private IP` 등록
- **TLS 종료**: ALB에서 ACM 인증서로 종료, cert-manager는 nginx ingress용 내부 인증서 관리
- **IAM**: IRSA 대신 노드 instance profile 사용

---

## 빠른 참조 — 자주 쓰는 명령

```bash
# 변수 재설정 (새 터미널 열 때마다)
cd kubeadm/envs/prod
CLUSTER_NAME=$(terraform output -raw platform_bootstrap_ssm_document_name | sed 's/-platform-bootstrap//')
CP01=$(terraform output -json control_plane_instance_ids | jq -r --arg n "${CLUSTER_NAME}-cp-01" '.[$n]')
SSM_DOC=$(terraform output -raw platform_bootstrap_ssm_document_name)

# 노드 상태 확인
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["kubectl get nodes -L node-group,workload-plane"]' \
  --region ap-northeast-2

# Pod 전체 확인
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CP01" \
  --parameters 'commands=["kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded"]' \
  --region ap-northeast-2
```
