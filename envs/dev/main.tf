# envs/dev/main.tf
# Dev 환경 인프라 구성
# 
# 1단계: Big Bang 배포 - 단일 인스턴스 (FE + BE + DB + AI)
# 대상: 카카오 재직자 500명 MAU, 50명 동시접속

#==============================================================================
# VPC 모듈
#==============================================================================
module "vpc" {
  source = "../../modules/vpc"

  project_name       = var.project_name
  env                = var.env
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  availability_zone  = var.availability_zone
}

#==============================================================================
# Security Group 모듈
#==============================================================================
module "security_group" {
  source = "../../modules/security-group"

  project_name            = var.project_name
  env                     = var.env
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = var.vpc_cidr
  ssh_allowed_cidr        = var.ssh_allowed_cidr
  db_allowed_cidr         = var.db_allowed_cidr
  monitoring_allowed_cidr = var.monitoring_allowed_cidr
}

#==============================================================================
# EC2 모듈 - Main Server (DB 포함)
#==============================================================================
module "ec2_main" {
  source = "../../modules/ec2"

  project_name       = var.project_name
  env                = var.env
  instance_name      = "main-server"
  instance_role      = "monitoring-target"
  instance_type      = var.instance_type
  subnet_id          = module.vpc.public_subnet_id
  security_group_ids = [
    module.security_group.main_sg_id,
    module.security_group.monitoring_target_sg_id
  ]
  root_volume_size   = var.root_volume_size

  # 키페어 설정 (둘 중 하나 선택)
  create_key_pair   = var.create_key_pair
  public_key        = var.public_key
  existing_key_name = var.existing_key_name

  # Elastic IP 생성 (고정 IP 필요 시)
  create_eip = var.create_eip

  # 환경 설정 스크립트 (첫 부팅 시 자동 실행)
  user_data = var.run_setup_script ? file("${path.module}/../../scripts/setup.sh") : ""
}

#==============================================================================
# IAM Role - Prometheus EC2 Service Discovery
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
# EC2 모듈 - Monitoring Server (Prometheus, Grafana, Loki)
#==============================================================================
module "ec2_monitoring" {
  source = "../../modules/ec2"

  project_name       = var.project_name
  env                = var.env
  instance_name      = "monitoring-server"
  instance_role      = "monitoring-server"
  instance_type      = var.monitoring_instance_type
  subnet_id          = module.vpc.public_subnet_id
  security_group_ids = [module.security_group.monitoring_sg_id]
  root_volume_size   = var.monitoring_root_volume_size

  # 키페어 설정 (main 서버와 동일)
  create_key_pair   = var.create_key_pair
  public_key        = var.public_key
  existing_key_name = var.existing_key_name

  # Elastic IP 생성
  create_eip = var.create_monitoring_eip

  # IAM Instance Profile (EC2 Service Discovery용)
  iam_instance_profile = aws_iam_instance_profile.prometheus_ec2_discovery.name
}

#==============================================================================
# Route 53 - DNS 레코드
#==============================================================================
# 기존 Hosted Zone 조회 (billages.com)
data "aws_route53_zone" "main" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name
}

# dev.billages.com -> Main Server Elastic IP
resource "aws_route53_record" "dev" {
  count   = var.domain_name != "" && var.create_eip ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "${var.env}.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.ec2_main.elastic_ip]
}

# monitoring.dev.billages.com -> Monitoring Server Elastic IP
resource "aws_route53_record" "monitoring" {
  count   = var.domain_name != "" && var.create_monitoring_eip ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "monitoring.${var.env}.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [module.ec2_monitoring.elastic_ip]
}
