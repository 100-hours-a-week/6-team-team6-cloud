# -----------------------------------------------------------------------------
# Chaos Engineering Infrastructure — NAT Instance FIS Experiment
#
# FIS로 NAT Instance를 중단시켜 외부 통신 장애(ECR, RunPod, Kakao OAuth)의
# 영향 범위와 장애 전파를 측정하기 위한 인프라.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# FIS IAM Role — FIS 서비스가 EC2 인스턴스를 중지/시작할 수 있는 권한
# -----------------------------------------------------------------------------

resource "aws_iam_role" "fis" {
  name = "${var.cluster_name}-fis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "fis.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-fis-role"
  })
}

resource "aws_iam_role_policy" "fis_ec2" {
  name = "${var.cluster_name}-fis-ec2-stop"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Role" = "nat"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SNS Topic — 카오스 실험 알림
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "chaos_alerts" {
  name = "${var.cluster_name}-chaos-alerts"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-chaos-alerts"
  })
}

resource "aws_sns_topic_subscription" "chaos_email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.chaos_alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# -----------------------------------------------------------------------------
# CloudWatch Alarms
# -----------------------------------------------------------------------------

# NAT Instance 상태 체크 실패 알람
resource "aws_cloudwatch_metric_alarm" "nat_status_check" {
  alarm_name          = "${var.cluster_name}-nat-status-check-failed"
  alarm_description   = "NAT Instance status check failed — instance down or impaired"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = var.nat_instance_id
  }

  alarm_actions = [aws_sns_topic.chaos_alerts.arn]
  ok_actions    = [aws_sns_topic.chaos_alerts.arn]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-status-check"
  })
}

# FIS 긴급 중단용 알람 (Stop Condition)
# 실험이 예상 범위를 초과하면 자동 중단
resource "aws_cloudwatch_metric_alarm" "chaos_emergency_stop" {
  alarm_name          = "${var.cluster_name}-chaos-emergency-stop"
  alarm_description   = "Emergency stop for FIS experiments — NAT down too long"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 15 # 15분 연속 실패 시 → 실험 자동 중단
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.nat_instance_id
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-chaos-emergency-stop"
  })
}

# NAT 대역폭 포화 감지 (시나리오 B용)
resource "aws_cloudwatch_metric_alarm" "nat_bandwidth_high" {
  alarm_name          = "${var.cluster_name}-nat-bandwidth-high"
  alarm_description   = "NAT Instance outbound bandwidth exceeding baseline (t3.nano ~32Mbps)"
  namespace           = "AWS/EC2"
  metric_name         = "NetworkOut"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 20000000 # ~20MB/5min ≈ 5.3Mbps sustained (warning before saturation)
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.nat_instance_id
  }

  alarm_actions = [aws_sns_topic.chaos_alerts.arn]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-bandwidth-high"
  })
}

# -----------------------------------------------------------------------------
# FIS Experiment Template — 시나리오 A: NAT Instance 완전 중단
# -----------------------------------------------------------------------------

resource "aws_fis_experiment_template" "nat_stop" {
  description = "${var.cluster_name} NAT Instance stop — chaos experiment scenario A"
  role_arn    = aws_iam_role.fis.arn

  target {
    name           = "natInstance"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "Name"
      value = "${var.cluster_name}-nat"
    }

    resource_tag {
      key   = "Role"
      value = "nat"
    }
  }

  action {
    name        = "stopNatInstance"
    action_id   = "aws:ec2:stop-instances"
    description = "NAT Instance 강제 중단 (10분 후 자동 재시작)"
    target {
      key   = "Instances"
      value = "natInstance"
    }
    parameter {
      key   = "startInstancesAfterDuration"
      value = "PT10M"
    }
  }

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.chaos_emergency_stop.arn
  }

  tags = merge(var.tags, {
    Name       = "${var.cluster_name}-fis-nat-stop"
    Experiment = "nat-instance-stop"
  })
}
