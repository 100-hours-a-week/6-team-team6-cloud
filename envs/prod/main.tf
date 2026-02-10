# envs/prod/main.tf
# Prod 환경 인프라 구성
#
# 1단계: Big Bang 배포 - 단일 인스턴스 (FE + BE + DB + AI)
# 운영 환경 단일 인스턴스 구성

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

  project_name           = var.project_name
  env                    = var.env
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr               = var.vpc_cidr
  ssh_allowed_cidr       = var.ssh_allowed_cidr
  db_allowed_cidr        = var.db_allowed_cidr
  management_scrape_cidr = var.management_scrape_cidr

  # VPN 역할별 접근 제어 (Pure Routing용)
  enable_vpn_role_based_access = var.enable_vpn_role_based_access
  vpn_devops_cidr              = var.vpn_devops_cidr
  vpn_backend_cidr             = var.vpn_backend_cidr
  vpn_frontend_cidr            = var.vpn_frontend_cidr
  vpn_ai_ml_cidr               = var.vpn_ai_ml_cidr
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

  # 키페어 설정 (dev와 동일한 keypair 사용)
  create_key_pair   = var.create_key_pair
  public_key        = var.public_key
  existing_key_name = var.existing_key_name

  # Elastic IP 생성 (고정 IP 필요 시)
  create_eip = var.create_eip
}

#==============================================================================
# CloudWatch 모니터링 모듈
#==============================================================================
module "cloudwatch" {
  source = "../../modules/cloudwatch"

  project_name  = var.project_name
  environment   = var.env
  instance_id   = module.ec2_main.instance_id
  instance_name = "${var.project_name}-${var.env}-main-server"

  # 알림 설정
  alarm_email         = var.alarm_email
  enable_discord      = var.enable_discord
  discord_webhook_url = var.discord_webhook_url

  # 알람 임계값 (선택적 커스터마이징)
  cpu_threshold = var.cpu_threshold
}