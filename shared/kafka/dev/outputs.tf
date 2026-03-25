# shared/kafka/dev/outputs.tf

output "instance_id" {
  description = "Kafka EC2 인스턴스 ID"
  value       = aws_instance.kafka.id
}

output "private_ip" {
  description = "Kafka Private IP"
  value       = aws_instance.kafka.private_ip
}

output "bootstrap_servers" {
  description = "Kafka Bootstrap Servers"
  value       = "${aws_instance.kafka.private_ip}:9092"
}

output "security_group_id" {
  description = "Kafka Security Group ID"
  value       = aws_security_group.kafka.id
}

output "ssm_parameter_name" {
  description = "Kafka bootstrap-servers SSM 파라미터 이름"
  value       = aws_ssm_parameter.kafka_bootstrap_servers.name
}

output "kafka_ui_url" {
  description = "Kafka UI URL (Management VPC에서 접근)"
  value       = "http://${aws_instance.kafka.private_ip}:8989"
}
