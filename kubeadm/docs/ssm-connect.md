# SSM 인스턴스 접속

SSH 없이 AWS SSM Session Manager로 접속한다.

## 사전 준비

```bash
# AWS CLI Session Manager plugin 설치 (최초 1회)
# macOS
brew install --cask session-manager-plugin

# 접속 전 인스턴스 ID 확인
cd kubeadm/envs/prod
CLUSTER_NAME=$(terraform output -raw platform_bootstrap_ssm_document_name | sed 's/-platform-bootstrap//')

CP01=$(terraform output -json control_plane_instance_ids | jq -r '."cp-01"')
CP02=$(terraform output -json control_plane_instance_ids | jq -r '."cp-02"')
CP03=$(terraform output -json control_plane_instance_ids | jq -r '."cp-03"')

APP01=$(terraform output -json app_instance_ids | jq -r '."app-01"')
APP02=$(terraform output -json app_instance_ids | jq -r '."app-02"')
APP03=$(terraform output -json app_instance_ids | jq -r '."app-03"')
APP04=$(terraform output -json app_instance_ids | jq -r '."app-04"')

DATA01=$(terraform output -json data_instance_ids | jq -r '."data-01"')
DATA02=$(terraform output -json data_instance_ids | jq -r '."data-02"')
DATA03=$(terraform output -json data_instance_ids | jq -r '."data-03"')
```

## 접속 명령

```bash
# control-plane
aws ssm start-session --target $CP01 --region ap-northeast-2
aws ssm start-session --target $CP02 --region ap-northeast-2
aws ssm start-session --target $CP03 --region ap-northeast-2

# app nodes
aws ssm start-session --target $APP01 --region ap-northeast-2
aws ssm start-session --target $APP02 --region ap-northeast-2
aws ssm start-session --target $APP03 --region ap-northeast-2
aws ssm start-session --target $APP04 --region ap-northeast-2

# data nodes
aws ssm start-session --target $DATA01 --region ap-northeast-2
aws ssm start-session --target $DATA02 --region ap-northeast-2
aws ssm start-session --target $DATA03 --region ap-northeast-2
```

## 접속 후 root 전환

```bash
sudo -i
kubectl get nodes
```

## 인스턴스 ID를 모를 때 (이름으로 검색)

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=billage-kubeadm-prod-cp-01" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text \
  --region ap-northeast-2
```