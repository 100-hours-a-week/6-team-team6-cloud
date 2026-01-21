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

  project_name     = var.project_name
  env              = var.env
  vpc_id           = module.vpc.vpc_id
  ssh_allowed_cidr = var.ssh_allowed_cidr
  db_allowed_cidr  = var.db_allowed_cidr
}

#==============================================================================
# EC2 모듈 - Main Server (DB 포함)
#==============================================================================
module "ec2_main" {
  source = "../../modules/ec2"

  project_name       = var.project_name
  env                = var.env
  instance_type      = var.instance_type
  subnet_id          = module.vpc.public_subnet_id
  security_group_ids = [module.security_group.main_sg_id]
  root_volume_size   = var.root_volume_size
  
  # 키페어 설정 (둘 중 하나 선택)
  create_key_pair   = var.create_key_pair
  public_key        = var.public_key
  existing_key_name = var.existing_key_name
  
  # Elastic IP 생성 (고정 IP 필요 시)
  create_eip = var.create_eip
}
