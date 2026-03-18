# 01. AWS 인프라 구성

EC2 인스턴스가 올라갈 네트워크 기반과 10대의 EC2를 구성한다.
학습 목적이므로 SSH를 활성화하고, 각 리소스가 왜 필요한지 설명한다.

---

## 사전 준비

```bash
# 환경 변수 설정 (이후 모든 명령에서 사용)
export AWS_REGION="ap-northeast-2"
export CLUSTER_NAME="my-cluster"
export KEY_NAME="my-k8s-key"          # EC2 SSH 키 페어 이름
export MY_IP="$(curl -s ifconfig.me)"  # 내 PC IP (SSH 허용용)
```

---

## 1. VPC 생성

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.30.0.0/16 \
  --region $AWS_REGION \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${CLUSTER_NAME}-vpc},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
  --query "Vpc.VpcId" --output text)

# DNS hostname 활성화 (EC2가 private DNS name을 갖게 됨)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

echo "VPC_ID=$VPC_ID"
```

---

## 2. 서브넷 생성

서브넷을 3종류 × 3 AZ = 9개 만든다.
- **Public**: NLB가 올라갈 자리. EC2는 여기에 올리지 않는다.
- **CP(Control-Plane)**: cp 노드 전용. 고정 IP를 쓰기 위해 별도 분리.
- **Worker**: app/data 노드. 같은 서브넷을 공유해도 되지만, AZ별로 분리한다.

```bash
# AZ 목록
AZ_A="ap-northeast-2a"
AZ_B="ap-northeast-2b"
AZ_C="ap-northeast-2c"

# Public 서브넷 (NLB용, 각 AZ)
PUB_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.0.0/24 \
  --availability-zone $AZ_A \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-a},{Key=kubernetes.io/role/elb,Value=1}]" \
  --query "Subnet.SubnetId" --output text)

PUB_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.4.0/24 \
  --availability-zone $AZ_B \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-b},{Key=kubernetes.io/role/elb,Value=1}]" \
  --query "Subnet.SubnetId" --output text)

PUB_SUBNET_C=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.8.0/24 \
  --availability-zone $AZ_C \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-c},{Key=kubernetes.io/role/elb,Value=1}]" \
  --query "Subnet.SubnetId" --output text)

# Control-Plane 서브넷
CP_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.1.0/24 \
  --availability-zone $AZ_A \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp-a}]" \
  --query "Subnet.SubnetId" --output text)

CP_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.5.0/24 \
  --availability-zone $AZ_B \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp-b}]" \
  --query "Subnet.SubnetId" --output text)

CP_SUBNET_C=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.9.0/24 \
  --availability-zone $AZ_C \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp-c}]" \
  --query "Subnet.SubnetId" --output text)

# Worker 서브넷
WRK_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.2.0/24 \
  --availability-zone $AZ_A \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-worker-a}]" \
  --query "Subnet.SubnetId" --output text)

WRK_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.6.0/24 \
  --availability-zone $AZ_B \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-worker-b}]" \
  --query "Subnet.SubnetId" --output text)

WRK_SUBNET_C=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.30.10.0/24 \
  --availability-zone $AZ_C \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-worker-c}]" \
  --query "Subnet.SubnetId" --output text)

echo "Public: $PUB_SUBNET_A $PUB_SUBNET_B $PUB_SUBNET_C"
echo "CP:     $CP_SUBNET_A $CP_SUBNET_B $CP_SUBNET_C"
echo "Worker: $WRK_SUBNET_A $WRK_SUBNET_B $WRK_SUBNET_C"
```

> **`kubernetes.io/role/elb=1` 태그**: AWS Load Balancer Controller가 internet-facing ALB를 만들 때 이 태그가 붙은 퍼블릭 서브넷을 자동 검색한다. 없으면 ALB 생성이 실패한다.

---

## 3. Internet Gateway + 라우팅

EC2가 인터넷으로 나가려면 IGW와 라우팅 테이블이 필요하다.
여기서는 NAT Gateway 없이 EC2에 Public IP를 직접 붙이는 방식을 사용한다.

```bash
# IGW 생성 및 VPC 연결
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-igw}]" \
  --query "InternetGateway.InternetGatewayId" --output text)

aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# 라우팅 테이블 생성 (전체 서브넷이 동일 테이블 공유 — 학습 환경)
RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-rt}]" \
  --query "RouteTable.RouteTableId" --output text)

# 기본 경로: 모든 트래픽을 IGW로
aws ec2 create-route --route-table-id $RT_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID

# 모든 서브넷에 라우팅 테이블 연결
for SUBNET in $PUB_SUBNET_A $PUB_SUBNET_B $PUB_SUBNET_C \
              $CP_SUBNET_A $CP_SUBNET_B $CP_SUBNET_C \
              $WRK_SUBNET_A $WRK_SUBNET_B $WRK_SUBNET_C; do
  aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET
done

echo "IGW_ID=$IGW_ID  RT_ID=$RT_ID"
```

---

## 4. Security Group 생성

보안 그룹을 역할별로 분리한다.

### 4-1. Cluster Mesh SG (전체 노드 공통)

클러스터 노드끼리는 모든 포트 통신이 허용되어야 한다.
Calico BGP(179), overlay 트래픽, kubelet(10250), NodePort(30000-32767) 등이 포함된다.

```bash
MESH_SG=$(aws ec2 create-security-group \
  --group-name "${CLUSTER_NAME}-cluster-mesh-sg" \
  --description "All traffic between cluster nodes" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cluster-mesh-sg}]" \
  --query "GroupId" --output text)

# Self-referencing rule: 같은 SG끼리 전체 허용
aws ec2 authorize-security-group-ingress \
  --group-id $MESH_SG \
  --ip-permissions "IpProtocol=-1,FromPort=-1,ToPort=-1,UserIdGroupPairs=[{GroupId=${MESH_SG},Description=cluster-internal}]"

# 전체 outbound 허용
aws ec2 authorize-security-group-egress \
  --group-id $MESH_SG \
  --ip-permissions "IpProtocol=-1,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=0.0.0.0/0}]" 2>/dev/null || true

echo "MESH_SG=$MESH_SG"
```

### 4-2. Control-Plane SG

```bash
CP_SG=$(aws ec2 create-security-group \
  --group-name "${CLUSTER_NAME}-control-plane-sg" \
  --description "Access rules for control-plane nodes" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${CLUSTER_NAME}-control-plane-sg}]" \
  --query "GroupId" --output text)

# VPC 내부에서 kube-apiserver 접근 (worker → cp)
aws ec2 authorize-security-group-ingress --group-id $CP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=6443,ToPort=6443,IpRanges=[{CidrIp=10.30.0.0/16,Description=kube-apiserver-from-vpc}]"

# etcd peer 통신 (cp끼리)
aws ec2 authorize-security-group-ingress --group-id $CP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=2379,ToPort=2380,UserIdGroupPairs=[{GroupId=${CP_SG},Description=etcd-peer}]"

# SSH (학습용 — 내 PC에서만)
aws ec2 authorize-security-group-ingress --group-id $CP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=ssh-my-pc}]"

echo "CP_SG=$CP_SG"
```

### 4-3. App Worker SG

```bash
APP_SG=$(aws ec2 create-security-group \
  --group-name "${CLUSTER_NAME}-app-sg" \
  --description "App worker nodes" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${CLUSTER_NAME}-app-sg}]" \
  --query "GroupId" --output text)

# ALB → NodePort (ingress-nginx용)
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=30000,ToPort=32767,IpRanges=[{CidrIp=10.30.0.0/16,Description=nodeport-from-vpc}]"

# SSH (학습용)
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=ssh-my-pc}]"

echo "APP_SG=$APP_SG"
```

### 4-4. Data Worker SG

```bash
DATA_SG=$(aws ec2 create-security-group \
  --group-name "${CLUSTER_NAME}-data-sg" \
  --description "Data worker nodes" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${CLUSTER_NAME}-data-sg}]" \
  --query "GroupId" --output text)

# SSH (학습용)
aws ec2 authorize-security-group-ingress --group-id $DATA_SG \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=ssh-my-pc}]"

echo "DATA_SG=$DATA_SG"
```

---

## 5. IAM Role 생성

노드가 SSM, ECR, CloudWatch, ALB Controller API를 사용하기 위한 역할이다.

```bash
# EC2가 assume할 수 있는 trust policy
cat > /tmp/ec2-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name "${CLUSTER_NAME}-nodes-role" \
  --assume-role-policy-document file:///tmp/ec2-trust.json

# AWS 관리형 정책 연결
aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-nodes-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-nodes-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-nodes-role" \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
```

### AWS Load Balancer Controller 정책 (인라인)

aws-load-balancer-controller가 ALB를 생성/관리하려면 EC2/ELB API 권한이 필요하다.
여기서는 IRSA(IAM Roles for Service Accounts) 대신 노드 instance profile에 직접 붙인다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > /tmp/alb-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["iam:CreateServiceLinkedRole"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {"iam:AWSServiceName": "elasticloadbalancing.amazonaws.com"}
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses",
        "ec2:DescribeAvailabilityZones", "ec2:DescribeInternetGateways",
        "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeTags", "ec2:DescribeRouteTables",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateSecurityGroup", "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:DeleteSecurityGroup",
        "elasticloadbalancing:*"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["acm:ListCertificates", "acm:DescribeCertificate"],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name "${CLUSTER_NAME}-aws-lbc-policy" \
  --policy-document file:///tmp/alb-policy.json

aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-nodes-role" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-aws-lbc-policy"

# Instance Profile 생성
aws iam create-instance-profile \
  --instance-profile-name "${CLUSTER_NAME}-nodes-profile"

aws iam add-role-to-instance-profile \
  --instance-profile-name "${CLUSTER_NAME}-nodes-profile" \
  --role-name "${CLUSTER_NAME}-nodes-role"

echo "Instance Profile: ${CLUSTER_NAME}-nodes-profile"
```

---

## 6. EC2 키 페어 생성 (학습용 SSH)

```bash
aws ec2 create-key-pair \
  --key-name $KEY_NAME \
  --query "KeyMaterial" --output text > ~/.ssh/${KEY_NAME}.pem

chmod 400 ~/.ssh/${KEY_NAME}.pem
echo "키 파일: ~/.ssh/${KEY_NAME}.pem"
```

---

## 7. AMI 확인

Ubuntu 24.04 LTS (Noble) 최신 AMI를 사용한다.

```bash
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
    "Name=virtualization-type,Values=hvm" \
    "Name=architecture,Values=x86_64" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)

echo "AMI_ID=$AMI_ID"
```

---

## 8. EC2 인스턴스 10대 생성

### Control-Plane 노드 3대

```bash
# cp-01 (고정 IP 10.30.1.10, AZ-a)
CP01=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --subnet-id $CP_SUBNET_A \
  --private-ip-address 10.30.1.10 \
  --security-group-ids $MESH_SG $CP_SG \
  --iam-instance-profile Name="${CLUSTER_NAME}-nodes-profile" \
  --key-name $KEY_NAME \
  --associate-public-ip-address \
  --no-source-dest-check \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --metadata-options '{"HttpEndpoint":"enabled","HttpTokens":"required","HttpPutResponseHopLimit":2}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp-01},{Key=NodeRole,Value=control-plane}]" \
  --query "Instances[0].InstanceId" --output text)

# cp-02 (고정 IP 10.30.5.10, AZ-b)
CP02=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --subnet-id $CP_SUBNET_B \
  --private-ip-address 10.30.5.10 \
  --security-group-ids $MESH_SG $CP_SG \
  --iam-instance-profile Name="${CLUSTER_NAME}-nodes-profile" \
  --key-name $KEY_NAME \
  --associate-public-ip-address \
  --no-source-dest-check \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --metadata-options '{"HttpEndpoint":"enabled","HttpTokens":"required","HttpPutResponseHopLimit":2}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp-02},{Key=NodeRole,Value=control-plane}]" \
  --query "Instances[0].InstanceId" --output text)

# cp-03 (고정 IP 10.30.9.10, AZ-c)
CP03=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --subnet-id $CP_SUBNET_C \
  --private-ip-address 10.30.9.10 \
  --security-group-ids $MESH_SG $CP_SG \
  --iam-instance-profile Name="${CLUSTER_NAME}-nodes-profile" \
  --key-name $KEY_NAME \
  --associate-public-ip-address \
  --no-source-dest-check \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --metadata-options '{"HttpEndpoint":"enabled","HttpTokens":"required","HttpPutResponseHopLimit":2}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp-03},{Key=NodeRole,Value=control-plane}]" \
  --query "Instances[0].InstanceId" --output text)

echo "CP01=$CP01  CP02=$CP02  CP03=$CP03"
```

> **`--no-source-dest-check`**: Calico가 BGP로 파드 트래픽을 라우팅할 때, EC2는 자신의 IP가 아닌 패킷은 기본으로 드롭한다. 이 플래그를 꺼야 파드 간 트래픽이 흐른다.

### App Worker 노드 4대

```bash
APP_SUBNETS=($WRK_SUBNET_A $WRK_SUBNET_B $WRK_SUBNET_C $WRK_SUBNET_A)

for i in 01 02 03 04; do
  IDX=$((10#$i - 1))
  SUBNET=${APP_SUBNETS[$IDX]}

  aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.medium \
    --subnet-id $SUBNET \
    --security-group-ids $MESH_SG $APP_SG \
    --iam-instance-profile Name="${CLUSTER_NAME}-nodes-profile" \
    --key-name $KEY_NAME \
    --associate-public-ip-address \
    --no-source-dest-check \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --metadata-options '{"HttpEndpoint":"enabled","HttpTokens":"required","HttpPutResponseHopLimit":2}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-app-${i}},{Key=NodeRole,Value=app}]" \
    --query "Instances[0].InstanceId" --output text
done
```

### Data Worker 노드 3대

```bash
DATA_SUBNETS=($WRK_SUBNET_A $WRK_SUBNET_B $WRK_SUBNET_C)

for i in 01 02 03; do
  IDX=$((10#$i - 1))
  SUBNET=${DATA_SUBNETS[$IDX]}

  aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.medium \
    --subnet-id $SUBNET \
    --security-group-ids $MESH_SG $DATA_SG \
    --iam-instance-profile Name="${CLUSTER_NAME}-nodes-profile" \
    --key-name $KEY_NAME \
    --associate-public-ip-address \
    --no-source-dest-check \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --metadata-options '{"HttpEndpoint":"enabled","HttpTokens":"required","HttpPutResponseHopLimit":2}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-data-${i}},{Key=NodeRole,Value=data}]" \
    --query "Instances[0].InstanceId" --output text
done
```

### 인스턴스 시작 대기

```bash
echo "모든 인스턴스 running 대기..."
aws ec2 wait instance-running \
  --filters "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
  --region $AWS_REGION

echo "완료. 인스턴스 목록:"
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-*" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}" \
  --output table
```

---

## 9. Internal NLB 생성 (kube-apiserver 엔드포인트)

kube-apiserver를 HA로 운영하기 위해 cp 3대 앞에 internal NLB를 둔다.
클러스터 외부(다른 VPC)에서 접근할 때도 이 NLB를 경유한다.

```bash
# NLB 생성 (internal, 퍼블릭 서브넷에 위치 — 단 internal이므로 인터넷 노출 없음)
NLB_ARN=$(aws elbv2 create-load-balancer \
  --name "${CLUSTER_NAME}-api-nlb" \
  --type network \
  --scheme internal \
  --subnets $PUB_SUBNET_A $PUB_SUBNET_B $PUB_SUBNET_C \
  --tags "Key=Name,Value=${CLUSTER_NAME}-api-nlb" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $NLB_ARN \
  --query "LoadBalancers[0].DNSName" --output text)

echo "NLB_ARN=$NLB_ARN"
echo "NLB_DNS=$NLB_DNS"

# Target Group (TCP 6443)
TG_ARN=$(aws elbv2 create-target-group \
  --name "${CLUSTER_NAME}-api-tg" \
  --protocol TCP \
  --port 6443 \
  --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-protocol TCP \
  --health-check-port 6443 \
  --query "TargetGroups[0].TargetGroupArn" --output text)

# cp 노드 3대를 Target Group에 등록
aws elbv2 register-targets \
  --target-group-arn $TG_ARN \
  --targets Id=$CP01 Id=$CP02 Id=$CP03

# Listener (TCP 6443 → Target Group)
aws elbv2 create-listener \
  --load-balancer-arn $NLB_ARN \
  --protocol TCP \
  --port 6443 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

echo "TG_ARN=$TG_ARN"
```

---

## 10. Route53 Private Hosted Zone

`k8s-api.village.internal` DNS를 VPC 내부에서만 해석되도록 설정한다.

```bash
# Private Hosted Zone 생성
HOSTED_ZONE=$(aws route53 create-hosted-zone \
  --name "village.internal" \
  --vpc VPCRegion=${AWS_REGION},VPCId=${VPC_ID} \
  --caller-reference "$(date +%s)" \
  --hosted-zone-config Comment="k8s internal DNS",PrivateZone=true \
  --query "HostedZone.Id" --output text | cut -d'/' -f3)

echo "HOSTED_ZONE=$HOSTED_ZONE"

# NLB DNS를 k8s-api.village.internal로 ALIAS 등록
cat > /tmp/dns-change.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "k8s-api.village.internal",
      "Type": "CNAME",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${NLB_DNS}"}]
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE \
  --change-batch file:///tmp/dns-change.json
```

---

## 변수 정리 (이후 단계에서 사용)

```bash
# 이후 단계에서 필요한 변수를 파일로 저장해 두면 편하다
cat > ~/k8s-env.sh <<EOF
export CLUSTER_NAME="${CLUSTER_NAME}"
export AWS_REGION="${AWS_REGION}"
export KEY_NAME="${KEY_NAME}"
export CP01="${CP01}"
export CP02="${CP02}"
export CP03="${CP03}"
export VPC_ID="${VPC_ID}"
export NLB_DNS="${NLB_DNS}"
export CONTROL_PLANE_ENDPOINT="k8s-api.village.internal"
EOF

echo "source ~/k8s-env.sh 으로 변수를 복원할 수 있다."
```

### Public IP 확인

```bash
source ~/k8s-env.sh

# SSH 접속용 Public IP 확인
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-cp-01" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text
```

---

다음: [02-node-setup.md](./02-node-setup.md) — **전체 10대 노드**에서 실행
