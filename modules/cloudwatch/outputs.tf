# =============================================================================
# CloudWatch Monitoring Module - Outputs
# =============================================================================

output "sns_topic_arn" {
  description = "ARN of the SNS topic for alarms"
  value       = aws_sns_topic.alarms.arn
}

output "sns_topic_name" {
  description = "Name of the SNS topic for alarms"
  value       = aws_sns_topic.alarms.name
}

output "cpu_alarm_arn" {
  description = "ARN of the CPU utilization alarm"
  value       = aws_cloudwatch_metric_alarm.cpu_high.arn
}

output "instance_status_alarm_arn" {
  description = "ARN of the instance status check alarm"
  value       = aws_cloudwatch_metric_alarm.status_check_failed_instance.arn
}

output "system_status_alarm_arn" {
  description = "ARN of the system status check alarm"
  value       = aws_cloudwatch_metric_alarm.status_check_failed_system.arn
}

output "discord_lambda_arn" {
  description = "ARN of the Discord notification Lambda function"
  value       = var.enable_discord ? aws_lambda_function.discord_notifier[0].arn : null
}

output "alarm_names" {
  description = "List of all alarm names created"
  value = [
    aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.status_check_failed_instance.alarm_name,
    aws_cloudwatch_metric_alarm.status_check_failed_system.alarm_name
  ]
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_arn" {
  description = "ARN of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.main.dashboard_arn
}

output "dashboard_url" {
  description = "URL to access the CloudWatch dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}