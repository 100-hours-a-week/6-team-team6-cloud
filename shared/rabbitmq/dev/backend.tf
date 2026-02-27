# shared/rabbitmq/dev/backend.tf
# Terraform Backend 설정 - Dev RabbitMQ

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-dev"
    key            = "shared/rabbitmq/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-dev"
  }
}
