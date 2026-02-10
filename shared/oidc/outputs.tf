# shared/oidc/outputs.tf

output "github_oidc_provider_arn" {
  description = "GitHub OIDC Provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions IAM Role ARN (GitHub Actions workflow에서 사용)"
  value       = aws_iam_role.github_actions.arn
}

output "github_actions_role_name" {
  description = "GitHub Actions IAM Role Name"
  value       = aws_iam_role.github_actions.name
}

# GitHub Actions workflow에서 사용할 값 출력
output "workflow_config" {
  description = "GitHub Actions workflow 설정 예시"
  value = <<-EOT

    # .github/workflows/deploy.yml 에 추가:

    permissions:
      id-token: write
      contents: read

    jobs:
      deploy:
        runs-on: ubuntu-latest
        steps:
          - name: Configure AWS credentials
            uses: aws-actions/configure-aws-credentials@v4
            with:
              role-to-assume: ${aws_iam_role.github_actions.arn}
              aws-region: ap-northeast-2

  EOT
}