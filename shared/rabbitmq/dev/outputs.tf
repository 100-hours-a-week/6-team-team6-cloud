# shared/rabbitmq/dev/outputs.tf

output "instance_id" {
  description = "RabbitMQ EC2 인스턴스 ID"
  value       = aws_instance.rabbitmq.id
}

output "private_ip" {
  description = "RabbitMQ Private IP"
  value       = aws_instance.rabbitmq.private_ip
}

output "amqp_endpoint" {
  description = "RabbitMQ AMQP Endpoint"
  value       = "${aws_instance.rabbitmq.private_ip}:5672"
}

output "stomp_endpoint" {
  description = "RabbitMQ STOMP Endpoint"
  value       = "${aws_instance.rabbitmq.private_ip}:61613"
}

output "management_url" {
  description = "RabbitMQ Management URL (VPN/Management CIDR에서만 접근)"
  value       = "http://${aws_instance.rabbitmq.private_ip}:15672"
}

output "security_group_id" {
  description = "RabbitMQ Security Group ID"
  value       = aws_security_group.rabbitmq.id
}

output "ssm_parameter_names" {
  description = "Backend 연동용 SSM 파라미터 목록"
  value = concat(
    [for p in aws_ssm_parameter.rabbitmq_be_config : p.name],
    [aws_ssm_parameter.rabbitmq_be_password.name]
  )
}
