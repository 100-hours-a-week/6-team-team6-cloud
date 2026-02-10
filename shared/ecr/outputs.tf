# shared/ecr/outputs.tf

output "repository_urls" {
  description = "ECR Repository URL 목록"
  value = {
    for k, v in aws_ecr_repository.services : k => v.repository_url
  }
}

output "repository_arns" {
  description = "ECR Repository ARN 목록"
  value = {
    for k, v in aws_ecr_repository.services : k => v.arn
  }
}

output "registry_id" {
  description = "ECR Registry ID (AWS Account ID)"
  value       = data.aws_caller_identity.current.account_id
}

output "usage_example" {
  description = "사용 예시"
  value = <<-EOT

    # ECR 로그인
    aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.ap-northeast-2.amazonaws.com

    # 이미지 빌드 & 푸시
    docker build -t billage-be:latest .
    docker tag billage-be:latest ${data.aws_caller_identity.current.account_id}.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest
    docker push ${data.aws_caller_identity.current.account_id}.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest

    # GitHub Actions에서 사용
    - uses: aws-actions/amazon-ecr-login@v2
    - run: |
        docker build -t $ECR_REGISTRY/billage-be:$IMAGE_TAG .
        docker push $ECR_REGISTRY/billage-be:$IMAGE_TAG

  EOT
}
