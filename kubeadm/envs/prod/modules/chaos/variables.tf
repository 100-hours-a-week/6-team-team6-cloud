variable "cluster_name" {
  description = "Cluster name for resource naming"
  type        = string
}

variable "env" {
  description = "Environment name"
  type        = string
}

variable "nat_instance_id" {
  description = "NAT Instance ID to target in FIS experiments"
  type        = string
}

variable "alarm_email" {
  description = "Email address for chaos experiment alert notifications"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
