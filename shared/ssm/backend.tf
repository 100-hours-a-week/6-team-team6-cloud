# shared/ssm/backend.tf

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-management"
    key            = "shared/ssm/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-management"
  }
}
