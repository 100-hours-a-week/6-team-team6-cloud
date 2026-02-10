# envs/management/terraform.tfvars

project_name = "billage"
env          = "management"
aws_region   = "ap-northeast-2"

# 키페어 설정 (Prod/Dev와 동일한 키 사용)
create_key_pair   = false
existing_key_name = "billage-keypair"

# CIDR 설정 (기본값 명시)
vpc_cidr            = "10.2.0.0/16"
public_subnet_cidr  = "10.2.1.0/24"
private_subnet_cidr = "10.2.2.0/24"
