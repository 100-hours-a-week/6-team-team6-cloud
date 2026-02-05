# envs/management/main.tf
# Management 환경 인프라 구성
#
# 모니터링 전용 VPC: Prometheus / Grafana / Loki + WireGuard VPN
# VPN 서버가 NAT instance를 겸용하여 Private Subnet의 인터넷 접근을 제공
# dev / prod와 VPC Peering으로 양방향 연결

#==============================================================================
# Remote State - Dev / Prod VPC 정보 참조
# [주의] dev와 prod가 먼저 apply되어야 이 리소스가 생성됨
#==============================================================================
data "terraform_remote_state" "dev" {
  backend = "s3"
  config = {
    bucket         = "billage-terraform-state-dev"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "billage-terraform-lock-dev"
  }
}

data "terraform_remote_state" "prod" {
  backend = "s3"
  config = {
    bucket         = "billage-terraform-state-prod"
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "billage-terraform-lock-prod"
  }
}

#==============================================================================
# VPC 모듈 - Public + Private Subnet
#==============================================================================
module "vpc" {
  source = "../../modules/vpc"

  project_name        = var.project_name
  env                 = var.env
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  availability_zone   = var.availability_zone
}

#==============================================================================
# Dev / Prod Route Table 조회 (VPC Peering 양방향 라우팅용)
# tag:Name 기준 조회 - vpc 모듈의 네이밍 규칙: {project}-{env}-public-rt
#==============================================================================
data "aws_route_tables" "dev" {
  vpc_id = data.terraform_remote_state.dev.outputs.vpc_id

  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-dev-public-rt"]
  }
}

data "aws_route_tables" "prod" {
  vpc_id = data.terraform_remote_state.prod.outputs.vpc_id

  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-prod-public-rt"]
  }
}

#==============================================================================
# Security Group - Monitoring Server (Private Subnet)
#==============================================================================
resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-${var.env}-monitoring-sg"
  description = "모니터링 서버 SG (Prometheus, Grafana, Loki)"
  vpc_id      = module.vpc.vpc_id

  # SSH - Management VPC 내부에서만 접근 (VPN 서버 경유)
  ingress {
    description = "SSH from Management VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Grafana - WireGuard 터널 및 VPC 내부 접근
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.monitoring_admin_cidr
  }

  # Prometheus - WireGuard 터널 및 VPC 내부 접근
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.monitoring_admin_cidr
  }

  # Loki HTTP - dev/prod Promtail에서 로그 수집 + VPC 내부 접근
  ingress {
    description = "Loki HTTP - Promtail log push (dev/prod/management)"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [
      data.terraform_remote_state.dev.outputs.vpc_cidr,
      data.terraform_remote_state.prod.outputs.vpc_cidr,
      var.vpc_cidr
    ]
  }

  # Loki gRPC - 미래용 (현재 docker-compose에서 expose 안 됨)
  ingress {
    description = "Loki gRPC (Future Use)"
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Outbound - 모든 트래픽 허용
  # Prometheus 스크레이핑 대상 포트 (dev/prod 타겟 서버로의 Outbound):
  #   Node Exporter: 9100, cAdvisor: 8082, MySQL Exporter: 9104
  #   Spring Actuator: 8080, Promtail: 9080 (미래용)
  # [참고] dev/prod 타겟 서버 SG에 management VPC CIDR 허용 추가 필요
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-monitoring-sg"
    Environment = var.env
    Project     = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

#==============================================================================
# Security Group - VPN Server (Public Subnet)
# WireGuard VPN + NAT instance 역할 겸용
#==============================================================================
resource "aws_security_group" "vpn" {
  name        = "${var.project_name}-${var.env}-vpn-sg"
  description = "VPN 서버 SG (WireGuard + NAT instance)"
  vpc_id      = module.vpc.vpc_id

  # SSH - 제한된 IP에서만 접근 (운영 시 특정 IP로 제한)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
  }

  # WireGuard VPN - 모든 IP에서 UDP 접근 허용
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound - 모든 트래픽 허용 (VPN 클라이언트 포워딩 + NAT)
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-vpn-sg"
    Environment = var.env
    Project     = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

#==============================================================================
# IAM Role - Prometheus EC2 Service Discovery
# dev/prod 타겟 서버를 자동 발견하기 위한 ec2:DescribeInstances 권한
#==============================================================================
resource "aws_iam_role" "prometheus_ec2_discovery" {
  name = "${var.project_name}-${var.env}-prometheus-ec2-discovery"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-${var.env}-prometheus-ec2-discovery"
    Environment = var.env
    Project     = var.project_name
  }
}

resource "aws_iam_role_policy" "prometheus_ec2_discovery" {
  name = "${var.project_name}-${var.env}-prometheus-ec2-discovery-policy"
  role = aws_iam_role.prometheus_ec2_discovery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "prometheus_ec2_discovery" {
  name = "${var.project_name}-${var.env}-prometheus-ec2-discovery"
  role = aws_iam_role.prometheus_ec2_discovery.name

  tags = {
    Name        = "${var.project_name}-${var.env}-prometheus-ec2-discovery"
    Environment = var.env
    Project     = var.project_name
  }
}

#==============================================================================
# EC2 - Monitoring Server (Private Subnet)
# [참고] swap 설정은 user_data 스크립트로 별도 구현 필요
#==============================================================================
module "ec2_monitoring" {
  source = "../../modules/ec2"

  project_name       = var.project_name
  env                = var.env
  instance_name      = "monitoring-server"
  instance_role      = "monitoring-server"
  instance_type      = var.monitoring_instance_type
  subnet_id          = module.vpc.private_subnet_id
  security_group_ids = [aws_security_group.monitoring.id]
  root_volume_size   = var.monitoring_root_volume_size

  # Private Subnet - Public IP 및 EIP 불필요
  associate_public_ip = false
  create_eip          = false

  # IAM - Prometheus EC2 Service Discovery
  iam_instance_profile = aws_iam_instance_profile.prometheus_ec2_discovery.name

  # 키페어
  create_key_pair   = var.create_key_pair
  public_key        = var.public_key
  existing_key_name = var.existing_key_name

  # User Data - Docker & Swap Setup
  user_data = file("${path.module}/user_data/monitoring_setup.sh")
}

#==============================================================================
# EC2 - VPN Server (Public Subnet)
# WireGuard VPN + NAT instance 역할 겸용
# [참고] WireGuard 구성, iptables NAT 규칙, net.ipv4.ip_forward=1은
#         user_data 스크립트로 구현됨
#==============================================================================
module "ec2_vpn" {
  source = "../../modules/ec2"

  project_name       = var.project_name
  env                = var.env
  instance_name      = "vpn-server"
  instance_role      = "vpn-server"
  instance_type      = var.vpn_instance_type
  subnet_id          = module.vpc.public_subnet_id
  security_group_ids = [aws_security_group.vpn.id]
  root_volume_size   = var.vpn_root_volume_size

  # Public Subnet - EIP 할당
  associate_public_ip = true
  create_eip          = true

  # NAT instance - Source/Destination Check 비활성화
  source_destination_check = false

  # 키페어
  create_key_pair   = var.create_key_pair
  public_key        = var.public_key
  existing_key_name = var.existing_key_name

  # User Data - WireGuard & NAT Setup
  user_data = file("${path.module}/user_data/vpn_setup.sh")
}

#==============================================================================
# Private Subnet Default Route - VPN Server (NAT instance)
# Private Subnet → Internet 트래픽을 VPN 서버를 경유하여 라우팅
#==============================================================================
resource "aws_route" "private_default" {
  route_table_id         = module.vpc.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.ec2_vpn.primary_network_interface_id
}

#==============================================================================
# VPC Peering - Management ↔ Dev
#==============================================================================
module "vpc_peering_dev" {
  source = "../../modules/vpc-peering"

  project_name = var.project_name
  env          = var.env
  peer_name    = "dev"

  requester_vpc_id   = module.vpc.vpc_id
  requester_vpc_cidr = var.vpc_cidr
  accepter_vpc_id    = data.terraform_remote_state.dev.outputs.vpc_id
  accepter_vpc_cidr  = data.terraform_remote_state.dev.outputs.vpc_cidr

  requester_route_table_ids = [module.vpc.public_route_table_id, module.vpc.private_route_table_id]
  accepter_route_table_ids  = data.aws_route_tables.dev.ids
}

#==============================================================================
# VPC Peering - Management ↔ Prod
#==============================================================================
module "vpc_peering_prod" {
  source = "../../modules/vpc-peering"

  project_name = var.project_name
  env          = var.env
  peer_name    = "prod"

  requester_vpc_id   = module.vpc.vpc_id
  requester_vpc_cidr = var.vpc_cidr
  accepter_vpc_id    = data.terraform_remote_state.prod.outputs.vpc_id
  accepter_vpc_cidr  = data.terraform_remote_state.prod.outputs.vpc_cidr

  requester_route_table_ids = [module.vpc.public_route_table_id, module.vpc.private_route_table_id]
  accepter_route_table_ids  = data.aws_route_tables.prod.ids
}
