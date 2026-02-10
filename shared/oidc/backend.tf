# shared/oidc/backend.tf

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-management"
    key            = "shared/oidc/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-management"
  }
}