# shared/kafka/prod/backend.tf

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-prod"
    key            = "shared/kafka/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-prod"
  }
}