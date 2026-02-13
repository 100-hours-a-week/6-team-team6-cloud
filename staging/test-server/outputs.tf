# staging/test-server/outputs.tf

output "instance_id" {
  description = "리허설 EC2 Instance ID"
  value       = aws_instance.rehearsal.id
}

output "public_ip" {
  description = "리허설 EC2 Elastic IP"
  value       = aws_eip.rehearsal.public_ip
}

output "private_ip" {
  description = "리허설 EC2 Private IP"
  value       = aws_instance.rehearsal.private_ip
}

output "security_group_id" {
  description = "리허설 Security Group ID"
  value       = aws_security_group.rehearsal.id
}

output "rds_endpoint" {
  description = "리허설용 RDS Endpoint (참고용)"
  value       = "billage-dev-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com"
}

output "ssh_command" {
  description = "SSH 접속 명령어"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_eip.rehearsal.public_ip}"
}
