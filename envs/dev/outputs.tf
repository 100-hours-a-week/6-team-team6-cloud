# envs/dev/outputs.tf
# 인프라 정보 출력

#==============================================================================
# VPC 정보
#==============================================================================
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = module.vpc.vpc_cidr
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = module.vpc.public_subnet_id
}

#==============================================================================
# Security Group 정보
#==============================================================================
output "main_security_group_id" {
  description = "Main Security Group ID"
  value       = module.security_group.main_sg_id
}

#==============================================================================
# EC2 정보
#==============================================================================
output "instance_id" {
  description = "EC2 인스턴스 ID"
  value       = module.ec2_main.instance_id
}

output "instance_public_ip" {
  description = "EC2 퍼블릭 IP"
  value       = module.ec2_main.instance_public_ip
}

output "elastic_ip" {
  description = "Elastic IP (고정 IP)"
  value       = module.ec2_main.elastic_ip
}

output "instance_private_ip" {
  description = "EC2 프라이빗 IP"
  value       = module.ec2_main.instance_private_ip
}

output "ami_id" {
  description = "사용된 AMI ID"
  value       = module.ec2_main.ami_id
}

#==============================================================================
# SSH 접속 명령어
#==============================================================================
output "ssh_command" {
  description = "SSH 접속 명령어"
  value       = "ssh -i <your-key.pem> ubuntu@${module.ec2_main.elastic_ip != null ? module.ec2_main.elastic_ip : module.ec2_main.instance_public_ip}"
}

#==============================================================================
# 도메인 정보
#==============================================================================
output "domain_url" {
  description = "서비스 도메인 URL"
  value       = var.domain_name != "" ? "https://${var.env}.${var.domain_name}" : null
}

output "ssl_setup_command" {
  description = "SSL 설정 명령어 (서버에서 실행)"
  value       = var.domain_name != "" ? "sudo /opt/billage/scripts/setup-ssl.sh ${var.env}.${var.domain_name}" : null
}
