terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-prod"
    key            = "kubeadm/envs/prod/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-prod"
  }
}
