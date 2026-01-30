# modules/security-group/outputs.tf

output "main_sg_id" {
  description = "Main Security Group ID"
  value       = aws_security_group.main.id
}

output "main_sg_name" {
  description = "Main Security Group Name"
  value       = aws_security_group.main.name
}

output "monitoring_sg_id" {
  description = "Monitoring Server Security Group ID"
  value       = aws_security_group.monitoring.id
}

output "monitoring_target_sg_id" {
  description = "Monitoring Target Security Group ID"
  value       = aws_security_group.monitoring_target.id
}
