# shared/rds/prod/backend.tf
# Terraform Backend 설정 - Prod RDS

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-prod"
    key            = "shared/rds/prod/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-prod"
  }
}
