# staging/qdrant-dev/outputs.tf

output "instance_id" {
  description = "Qdrant EC2 Instance ID"
  value       = aws_instance.qdrant.id
}

output "security_group_id" {
  description = "Qdrant Security Group ID"
  value       = aws_security_group.qdrant.id
}

output "private_ip" {
  description = "Qdrant Private IP"
  value       = aws_instance.qdrant.private_ip
}

output "public_ip" {
  description = "Qdrant Public IP (EIP 우선)"
  value       = local.qdrant_public_ip
}

output "elastic_ip" {
  description = "Qdrant Elastic IP"
  value       = var.create_eip ? aws_eip.qdrant[0].public_ip : null
}

output "qdrant_http_endpoint" {
  description = "Qdrant HTTP Endpoint (Private IP)"
  value       = "http://${local.qdrant_private_ip}:6333"
}

output "qdrant_grpc_endpoint" {
  description = "Qdrant gRPC Endpoint (Private IP)"
  value       = "${local.qdrant_private_ip}:6334"
}

output "healthcheck_command" {
  description = "Qdrant 헬스체크 명령 (Private IP)"
  value       = "curl -H 'api-key: <QDRANT_API_KEY>' http://${local.qdrant_private_ip}:6333/healthz"
}

output "ssh_command" {
  description = "Qdrant SSH 접속 명령 (VPN 경유 Private IP)"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${local.qdrant_private_ip}"
}
