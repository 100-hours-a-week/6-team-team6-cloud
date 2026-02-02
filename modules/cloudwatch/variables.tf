# =============================================================================
# CloudWatch Monitoring Module - Variables
# =============================================================================

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "billage"
}

variable "aws_region" {
  description = "AWS region for dashboard widgets"
  type        = string
  default     = "ap-northeast-2"
}

# -----------------------------------------------------------------------------
# EC2 Monitoring
# -----------------------------------------------------------------------------

variable "instance_id" {
  description = "EC2 Instance ID to monitor"
  type        = string
}

variable "instance_name" {
  description = "EC2 Instance name for alarm descriptions"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Alarm Thresholds
# -----------------------------------------------------------------------------

variable "cpu_threshold" {
  description = "CPU utilization threshold percentage for alarm"
  type        = number
  default     = 80
}

variable "cpu_evaluation_periods" {
  description = "Number of periods to evaluate for CPU alarm"
  type        = number
  default     = 2
}

variable "cpu_period" {
  description = "Period in seconds for CPU metrics"
  type        = number
  default     = 300 # 5 minutes
}

# -----------------------------------------------------------------------------
# Notification Settings
# -----------------------------------------------------------------------------

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
}

variable "discord_webhook_url" {
  description = "Discord webhook URL for notifications"
  type        = string
  default     = ""
}

variable "enable_discord" {
  description = "Enable Discord notifications"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}