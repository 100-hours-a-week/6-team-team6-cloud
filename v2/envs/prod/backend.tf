# v2/envs/prod/backend.tf

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-prod"
    key            = "v2/prod/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-prod"
  }
}