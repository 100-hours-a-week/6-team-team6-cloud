# v2/envs/dev/backend.tf
# Terraform Backend 설정 - v2 Dev 환경

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-dev"
    key            = "v2/dev/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-dev"
  }
}
