# modules/security-group/outputs.tf

output "main_sg_id" {
  description = "Main Security Group ID"
  value       = aws_security_group.main.id
}

output "main_sg_name" {
  description = "Main Security Group Name"
  value       = aws_security_group.main.name
}
