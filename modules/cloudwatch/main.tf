# =============================================================================
# CloudWatch Monitoring Module
# =============================================================================
# This module creates:
# - SNS Topic for alarm notifications
# - CloudWatch Alarms for EC2 monitoring
# - Lambda function for Discord notifications (optional)
# =============================================================================

locals {
  name_prefix   = "${var.project_name}-${var.environment}"
  instance_name = var.instance_name != "" ? var.instance_name : "${local.name_prefix}-server"

  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  tags = merge(local.default_tags, var.tags)
}

# =============================================================================
# SNS Topic for Alarms
# =============================================================================

resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-cloudwatch-alarms"

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-cloudwatch-alarms"
  })
}

# Email subscription
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# =============================================================================
# CloudWatch Alarms
# =============================================================================

# CPU Utilization Alarm
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name_prefix}-cpu-utilization-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.cpu_evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = var.cpu_period
  statistic           = "Average"
  threshold           = var.cpu_threshold
  alarm_description   = "[${upper(var.environment)}] ${local.instance_name} CPU 사용률이 ${var.cpu_threshold}%를 초과했습니다."
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.instance_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.tags
}

# Instance Status Check Failed Alarm
resource "aws_cloudwatch_metric_alarm" "status_check_failed_instance" {
  alarm_name          = "${local.name_prefix}-status-check-failed-instance"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed_Instance"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "[${upper(var.environment)}] ${local.instance_name} 인스턴스 상태 체크 실패! 서버에 문제가 발생했습니다."
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = var.instance_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.tags
}

# System Status Check Failed Alarm (AWS Infrastructure issue)
resource "aws_cloudwatch_metric_alarm" "status_check_failed_system" {
  alarm_name          = "${local.name_prefix}-status-check-failed-system"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed_System"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "[${upper(var.environment)}] ${local.instance_name} 시스템 상태 체크 실패! AWS 인프라에 문제가 발생했습니다."
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = var.instance_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.tags
}