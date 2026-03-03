# rehearsal/infra/outputs.tf

output "vpc_id" {
  description = "Target VPC ID"
  value       = data.aws_vpc.base.id
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.rehearsal.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.rehearsal.arn
}

output "alb_http8081_endpoint" {
  description = "8081 listener endpoint"
  value       = "http://${aws_lb.rehearsal.dns_name}:8081"
}

output "target_group_arn" {
  description = "Backend target group ARN"
  value       = aws_lb_target_group.backend.arn
}

output "backend_asg_name" {
  description = "Backend ASG name"
  value       = aws_autoscaling_group.backend.name
}

output "backend_launch_template_name" {
  description = "Backend launch template name"
  value       = aws_launch_template.backend.name
}

output "rds_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "rds_address" {
  description = "RDS address"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "rds_identifier" {
  description = "RDS identifier"
  value       = aws_db_instance.main.identifier
}

output "rehearsal_subnet_ids" {
  description = "Rehearsal ALB/ASG attached subnet ids"
  value       = [data.aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "public_dns_alias" {
  description = "Route53 alias record (create_dns_record=true 일 때만 값 있음)"
  value       = var.create_dns_record ? aws_route53_record.rehearsal[0].name : ""
}
