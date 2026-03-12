variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "control_plane_subnet_ids" {
  type = map(string)
}

variable "control_plane_instance_ids" {
  type = map(string)
}

variable "private_dns_zone_name" {
  type = string
}

variable "kube_apiserver_record_name" {
  type = string
}

variable "tags" {
  type = map(string)
}

locals {
  nlb_name = substr("${var.cluster_name}-api", 0, 32)
  tg_name  = substr("${var.cluster_name}-api-tg", 0, 32)
}

resource "aws_lb" "kube_apiserver" {
  name                             = local.nlb_name
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = values(var.control_plane_subnet_ids)
  enable_cross_zone_load_balancing = true

  tags = merge(
    var.tags,
    {
      Name = local.nlb_name
    }
  )
}

resource "aws_lb_target_group" "kube_apiserver" {
  name        = local.tg_name
  port        = 6443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled  = true
    protocol = "TCP"
    port     = "6443"
  }

  tags = merge(
    var.tags,
    {
      Name = local.tg_name
    }
  )
}

resource "aws_lb_target_group_attachment" "control_plane" {
  for_each = var.control_plane_instance_ids

  target_group_arn = aws_lb_target_group.kube_apiserver.arn
  target_id        = each.value
  port             = 6443
}

resource "aws_lb_listener" "kube_apiserver" {
  load_balancer_arn = aws_lb.kube_apiserver.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kube_apiserver.arn
  }
}

resource "aws_route53_zone" "private" {
  name = var.private_dns_zone_name

  vpc {
    vpc_id = var.vpc_id
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-private-zone"
    }
  )
}

resource "aws_route53_record" "kube_apiserver" {
  zone_id = aws_route53_zone.private.zone_id
  name    = var.kube_apiserver_record_name
  type    = "A"

  alias {
    name                   = aws_lb.kube_apiserver.dns_name
    zone_id                = aws_lb.kube_apiserver.zone_id
    evaluate_target_health = true
  }
}

output "nlb_dns_name" {
  value = aws_lb.kube_apiserver.dns_name
}

output "private_hosted_zone_id" {
  value = aws_route53_zone.private.zone_id
}

output "kube_apiserver_fqdn" {
  value = aws_route53_record.kube_apiserver.fqdn
}
