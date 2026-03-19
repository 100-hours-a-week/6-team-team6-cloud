# shared/vpc-peering/kubeadm-prod-to-dev/main.tf
# VPC Peering: kubeadm-prod ↔ dev (shared services 연결)
#
# kubeadm-prod Pod에서 dev VPC의 RDS, Kafka, RabbitMQ, Qdrant에 접근하기 위한 구성.
# Calico natOutgoing: true → Pod IP(192.168.x.x)가 노드 IP(10.30.x.x)로 SNAT되므로
# 별도 SNAT instance 없이 VPC peering만으로 연결 가능.

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Component = "vpc-peering-kubeadm-prod-to-dev"
    }
  }
}

#==============================================================================
# VPC Peering Connection
# 같은 계정/리전이므로 auto_accept = true
#==============================================================================
resource "aws_vpc_peering_connection" "kubeadm_prod_to_dev" {
  vpc_id      = var.kubeadm_prod_vpc_id
  peer_vpc_id = var.dev_vpc_id
  auto_accept = true

  tags = {
    Name = "${var.project_name}-kubeadm-prod-to-dev-peering"
  }
}

#==============================================================================
# Routes: kubeadm-prod → dev (10.0.0.0/16)
#==============================================================================
resource "aws_route" "kubeadm_prod_to_dev" {
  count                     = length(var.kubeadm_prod_route_table_ids)
  route_table_id            = var.kubeadm_prod_route_table_ids[count.index]
  destination_cidr_block    = var.dev_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.kubeadm_prod_to_dev.id
}

#==============================================================================
# Routes: dev → kubeadm-prod (10.30.0.0/16)
# 응답 패킷이 kubeadm-prod 노드로 돌아가기 위한 경로
#==============================================================================
resource "aws_route" "dev_to_kubeadm_prod" {
  count                     = length(var.dev_route_table_ids)
  route_table_id            = var.dev_route_table_ids[count.index]
  destination_cidr_block    = var.kubeadm_prod_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.kubeadm_prod_to_dev.id
}

#==============================================================================
# Security Group Rules: dev VPC 서비스에 kubeadm-prod CIDR 허용
#==============================================================================

# RDS - MySQL 3306
resource "aws_vpc_security_group_ingress_rule" "rds_from_kubeadm_prod" {
  security_group_id = var.dev_rds_sg_id
  description       = "MySQL from kubeadm-prod VPC"
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  cidr_ipv4         = var.kubeadm_prod_vpc_cidr
}

# Kafka - 9092
resource "aws_vpc_security_group_ingress_rule" "kafka_from_kubeadm_prod" {
  security_group_id = var.dev_kafka_sg_id
  description       = "Kafka from kubeadm-prod VPC"
  from_port         = 9092
  to_port           = 9092
  ip_protocol       = "tcp"
  cidr_ipv4         = var.kubeadm_prod_vpc_cidr
}

# RabbitMQ - AMQP 5672
resource "aws_vpc_security_group_ingress_rule" "rabbitmq_amqp_from_kubeadm_prod" {
  security_group_id = var.dev_rabbitmq_sg_id
  description       = "RabbitMQ AMQP from kubeadm-prod VPC"
  from_port         = 5672
  to_port           = 5672
  ip_protocol       = "tcp"
  cidr_ipv4         = var.kubeadm_prod_vpc_cidr
}

# RabbitMQ - STOMP 61613
resource "aws_vpc_security_group_ingress_rule" "rabbitmq_stomp_from_kubeadm_prod" {
  security_group_id = var.dev_rabbitmq_sg_id
  description       = "RabbitMQ STOMP from kubeadm-prod VPC"
  from_port         = 61613
  to_port           = 61613
  ip_protocol       = "tcp"
  cidr_ipv4         = var.kubeadm_prod_vpc_cidr
}

# Qdrant - HTTP 6333
resource "aws_vpc_security_group_ingress_rule" "qdrant_http_from_kubeadm_prod" {
  security_group_id = var.dev_qdrant_sg_id
  description       = "Qdrant HTTP from kubeadm-prod VPC"
  from_port         = 6333
  to_port           = 6333
  ip_protocol       = "tcp"
  cidr_ipv4         = var.kubeadm_prod_vpc_cidr
}

# Qdrant - gRPC 6334
resource "aws_vpc_security_group_ingress_rule" "qdrant_grpc_from_kubeadm_prod" {
  security_group_id = var.dev_qdrant_sg_id
  description       = "Qdrant gRPC from kubeadm-prod VPC"
  from_port         = 6334
  to_port           = 6334
  ip_protocol       = "tcp"
  cidr_ipv4         = var.kubeadm_prod_vpc_cidr
}
