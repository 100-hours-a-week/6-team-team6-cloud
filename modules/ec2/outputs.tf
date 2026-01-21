# modules/ec2/outputs.tf

output "instance_id" {
  description = "EC2 인스턴스 ID"
  value       = aws_instance.main.id
}

output "instance_public_ip" {
  description = "EC2 퍼블릭 IP"
  value       = aws_instance.main.public_ip
}

output "instance_private_ip" {
  description = "EC2 프라이빗 IP"
  value       = aws_instance.main.private_ip
}

output "elastic_ip" {
  description = "Elastic IP (생성된 경우)"
  value       = var.create_eip ? aws_eip.main[0].public_ip : null
}

output "instance_public_dns" {
  description = "EC2 퍼블릭 DNS"
  value       = aws_instance.main.public_dns
}

output "ami_id" {
  description = "사용된 AMI ID"
  value       = data.aws_ami.ubuntu.id
}

output "key_pair_name" {
  description = "키페어 이름"
  value       = var.create_key_pair ? aws_key_pair.main[0].key_name : var.existing_key_name
}
