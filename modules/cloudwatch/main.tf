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

# =============================================================================
# CloudWatch Dashboard
# =============================================================================

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-ec2-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: 알람 상태
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          title  = "🚨 알람 상태"
          alarms = [
            aws_cloudwatch_metric_alarm.cpu_high.arn,
            aws_cloudwatch_metric_alarm.status_check_failed_instance.arn,
            aws_cloudwatch_metric_alarm.status_check_failed_system.arn
          ]
        }
      },
      # Row 2: CPU 사용률
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "CPU 사용률 (%)"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", var.instance_id, {
              label = local.instance_name
              color = "#1f77b4"
            }]
          ]
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
          yAxis = {
            left = {
              min = 0
              max = 100
            }
          }
          annotations = {
            horizontal = [
              {
                label = "임계값"
                value = var.cpu_threshold
                color = "#ff0000"
              }
            ]
          }
        }
      },
      # Row 2: 네트워크 In/Out
      {
        type   = "metric"
        x      = 12
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "네트워크 트래픽 (Bytes)"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", var.instance_id, {
              label = "Network In"
              color = "#2ca02c"
            }],
            ["AWS/EC2", "NetworkOut", "InstanceId", var.instance_id, {
              label = "Network Out"
              color = "#ff7f0e"
            }]
          ]
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
        }
      },
      # Row 3: 디스크 읽기/쓰기
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "디스크 I/O (Bytes)"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "DiskReadBytes", "InstanceId", var.instance_id, {
              label = "Disk Read"
              color = "#9467bd"
            }],
            ["AWS/EC2", "DiskWriteBytes", "InstanceId", var.instance_id, {
              label = "Disk Write"
              color = "#8c564b"
            }]
          ]
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
        }
      },
      # Row 3: 상태 체크
      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "상태 체크"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", var.instance_id, {
              label = "Status Check Failed"
              color = "#d62728"
            }],
            ["AWS/EC2", "StatusCheckFailed_Instance", "InstanceId", var.instance_id, {
              label = "Instance Check Failed"
              color = "#ff9896"
            }],
            ["AWS/EC2", "StatusCheckFailed_System", "InstanceId", var.instance_id, {
              label = "System Check Failed"
              color = "#ffbb78"
            }]
          ]
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Maximum"
          yAxis = {
            left = {
              min = 0
              max = 1
            }
          }
        }
      },
      # Row 4: CPU Credit (T 시리즈 인스턴스용)
      {
        type   = "metric"
        x      = 0
        y      = 15
        width  = 12
        height = 6
        properties = {
          title  = "CPU Credit Balance (T 시리즈)"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "CPUCreditBalance", "InstanceId", var.instance_id, {
              label = "Credit Balance"
              color = "#17becf"
            }]
          ]
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
        }
      },
      # Row 4: 인스턴스 정보
      {
        type   = "text"
        x      = 12
        y      = 15
        width  = 12
        height = 6
        properties = {
          markdown = <<-EOF
## 📊 ${local.instance_name}

| 항목 | 값 |
|------|-----|
| **Instance ID** | `${var.instance_id}` |
| **환경** | ${upper(var.environment)} |
| **CPU 임계값** | ${var.cpu_threshold}% |

### 알람 조건
- **CPU**: ${var.cpu_threshold}% 초과 시 (5분 x 2회)
- **Instance Status**: 체크 실패 시 (1분 x 2회)
- **System Status**: 체크 실패 시 (1분 x 2회)

### 바로가기
- [EC2 콘솔](https://ap-northeast-2.console.aws.amazon.com/ec2/home?region=ap-northeast-2#InstanceDetails:instanceId=${var.instance_id})
- [알람 목록](https://ap-northeast-2.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-2#alarmsV2:)
EOF
        }
      }
    ]
  })
}