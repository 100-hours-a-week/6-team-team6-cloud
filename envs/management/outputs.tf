# envs/management/outputs.tf
# Management 환경 출력 정보
# [참고] 다른 환경에서 terraform_remote_state로 참조할 수 있도록 구성

#==============================================================================
# VPC 정보
#==============================================================================
output "vpc_id" {
  description = "Management VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Management VPC CIDR"
  value       = module.vpc.vpc_cidr
}

output "public_subnet_id" {
  description = "Public Subnet ID (VPN 서버)"
  value       = module.vpc.public_subnet_id
}

output "private_subnet_id" {
  description = "Private Subnet ID (모니터링 서버)"
  value       = module.vpc.private_subnet_id
}

#==============================================================================
# EC2 정보
#==============================================================================
output "monitoring_server_instance_id" {
  description = "Monitoring 서버 EC2 인스턴스 ID"
  value       = module.ec2_monitoring.instance_id
}

output "monitoring_server_private_ip" {
  description = "Monitoring 서버 프라이빗 IP (WireGuard VPN을 통해 접근)"
  value       = module.ec2_monitoring.instance_private_ip
}

output "vpn_server_instance_id" {
  description = "VPN 서버 EC2 인스턴스 ID"
  value       = module.ec2_vpn.instance_id
}

output "vpn_server_public_ip" {
  description = "VPN 서버 Elastic IP (WireGuard 접속 주소)"
  value       = module.ec2_vpn.elastic_ip
}

#==============================================================================
# VPC Peering 정보
#==============================================================================
output "peering_dev_connection_id" {
  description = "Management ↔ Dev VPC Peering Connection ID"
  value       = module.vpc_peering_dev.peering_connection_id
}

output "peering_prod_connection_id" {
  description = "Management ↔ Prod VPC Peering Connection ID"
  value       = module.vpc_peering_prod.peering_connection_id
}

#==============================================================================
# 접속 정보
#==============================================================================
output "vpn_ssh_command" {
  description = "VPN 서버 SSH 접속 명령어"
  value       = "ssh -i <your-key.pem> ubuntu@${module.ec2_vpn.elastic_ip != null ? module.ec2_vpn.elastic_ip : module.ec2_vpn.instance_public_ip}"
}

output "grafana_url" {
  description = "Grafana URL (WireGuard VPN 연결 후 접근)"
  value       = "http://${module.ec2_monitoring.instance_private_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL (WireGuard VPN 연결 후 접근)"
  value       = "http://${module.ec2_monitoring.instance_private_ip}:9090"
}

output "loki_url" {
  description = "Loki URL (Promtail 클라이언트 설정용)"
  value       = "http://${module.ec2_monitoring.instance_private_ip}:3100"
}
