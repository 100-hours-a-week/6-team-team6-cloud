# shared/vpc-peering/kubeadm-prod-to-dev/backend.tf

terraform {
  backend "s3" {
    bucket         = "billage-terraform-state-dev"
    key            = "shared/vpc-peering/kubeadm-prod-to-dev/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "billage-terraform-lock-dev"
  }
}
