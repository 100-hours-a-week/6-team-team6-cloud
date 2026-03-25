output "fis_experiment_template_id" {
  description = "FIS experiment template ID for NAT Instance stop scenario"
  value       = aws_fis_experiment_template.nat_stop.id
}

output "fis_role_arn" {
  description = "IAM role ARN used by FIS to stop/start EC2 instances"
  value       = aws_iam_role.fis.arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN for chaos experiment notifications"
  value       = aws_sns_topic.chaos_alerts.arn
}
