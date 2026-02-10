# shared/ssm/outputs.tf

output "parameter_arns" {
  description = "생성된 SSM Parameter ARN 목록"
  value = merge(
    { for k, v in aws_ssm_parameter.config : k => v.arn },
    { for k, v in aws_ssm_parameter.secrets : k => v.arn }
  )
}

output "dev_parameters" {
  description = "Dev 환경 파라미터 경로"
  value = {
    config  = [for k, v in aws_ssm_parameter.config : v.name if startswith(k, "dev/")]
    secrets = [for k, v in aws_ssm_parameter.secrets : v.name if startswith(k, "dev/")]
  }
}

output "prod_parameters" {
  description = "Prod 환경 파라미터 경로"
  value = {
    config  = [for k, v in aws_ssm_parameter.config : v.name if startswith(k, "prod/")]
    secrets = [for k, v in aws_ssm_parameter.secrets : v.name if startswith(k, "prod/")]
  }
}

output "usage_example" {
  description = "사용 예시"
  value = <<-EOT

    # AWS CLI로 파라미터 조회
    aws ssm get-parameter --name "/billage/dev/be/db-url"
    aws ssm get-parameter --name "/billage/dev/be/db-password" --with-decryption

    # 경로별 전체 조회
    aws ssm get-parameters-by-path --path "/billage/dev/be" --with-decryption

    # Spring Boot에서 사용 (application.yml)
    spring:
      config:
        import: aws-parameterstore:/billage/$${ENV}/be/

  EOT
}
