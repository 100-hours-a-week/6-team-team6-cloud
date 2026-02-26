# shared/rds/rehearsal/outputs.tf

output "endpoint" {
  description = "RDS Endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "private_subnet_ids" {
  description = "Private Subnet IDs"
  value       = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

output "address" {
  description = "RDS Address (host only)"
  value       = aws_db_instance.main.address
}

output "port" {
  description = "RDS Port"
  value       = aws_db_instance.main.port
}

output "database_name" {
  description = "Database Name"
  value       = aws_db_instance.main.db_name
}

output "security_group_id" {
  description = "RDS Security Group ID"
  value       = aws_security_group.rds.id
}

output "identifier" {
  description = "RDS Identifier"
  value       = aws_db_instance.main.identifier
}
