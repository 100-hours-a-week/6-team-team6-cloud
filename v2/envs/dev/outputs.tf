# v2/envs/dev/outputs.tf
# Billage v2 Dev 환경 출력값

#==============================================================================
# 네트워크
#==============================================================================
output "vpc_id" {
  description = "VPC ID"
  value       = data.aws_vpc.existing.id
}

# Private Subnet IDs는 shared/rds/dev에서 관리

output "public_subnet_ids" {
  description = "Public Subnet IDs"
  value       = [data.aws_subnet.public.id, aws_subnet.public_c.id]
}

#==============================================================================
# ALB
#==============================================================================
output "alb_dns_name" {
  description = "ALB DNS Name"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "ALB Zone ID"
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

#==============================================================================
# RDS (shared/rds/dev에서 참조)
#==============================================================================
output "rds_endpoint" {
  description = "RDS Endpoint"
  value       = data.aws_db_instance.main.endpoint
}

#==============================================================================
# ElastiCache Redis (shared/elasticache/dev에서 참조)
#==============================================================================
output "redis_endpoint" {
  description = "Redis Endpoint"
  value       = data.aws_elasticache_cluster.main.cache_nodes[0].address
}

#==============================================================================
# ASG (서비스별)
#==============================================================================
output "asg_names" {
  description = "Auto Scaling Group Names"
  value = {
    backend  = aws_autoscaling_group.backend.name
    frontend = aws_autoscaling_group.frontend.name
    ai       = aws_autoscaling_group.ai.name
  }
}

output "launch_template_ids" {
  description = "Launch Template IDs"
  value = {
    backend  = aws_launch_template.backend.id
    frontend = aws_launch_template.frontend.id
    ai       = aws_launch_template.ai.id
  }
}

#==============================================================================
# Route 53
#==============================================================================
output "app_url" {
  description = "Application URL"
  value       = "https://v2.${var.env}.${var.domain_name}"
}

#==============================================================================
# Security Groups
#==============================================================================
output "security_group_ids" {
  description = "Security Group IDs"
  value = {
    alb      = aws_security_group.alb.id
    backend  = aws_security_group.backend.id
    frontend = aws_security_group.frontend.id
    ai       = aws_security_group.ai.id
  }
}

#==============================================================================
# IAM
#==============================================================================
output "app_role_arn" {
  description = "Application IAM Role ARN"
  value       = aws_iam_role.app.arn
}

output "app_instance_profile" {
  description = "Application Instance Profile Name"
  value       = aws_iam_instance_profile.app.name
}