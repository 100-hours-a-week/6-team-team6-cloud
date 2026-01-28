# envs/s3-images-prod/outputs.tf
# terraform apply 후 출력되는 정보

#==============================================================================
# S3 정보 (백엔드 개발자에게 전달)
#==============================================================================
output "bucket_name" {
  description = "S3 버킷 이름"
  value       = module.s3_images.bucket_name
}

output "bucket_region" {
  description = "S3 버킷 리전"
  value       = module.s3_images.bucket_region
}

#==============================================================================
# IAM User 정보 (로컬 개발용)
#==============================================================================
output "iam_user_access_key_id" {
  description = "Access Key ID"
  value       = module.s3_images.iam_user_access_key_id
}

output "iam_user_secret_access_key" {
  description = "Secret Access Key - terraform output -raw iam_user_secret_access_key 로 확인"
  value       = module.s3_images.iam_user_secret_access_key
  sensitive   = true
}

#==============================================================================
# EC2 Instance Profile (서버 배포용)
#==============================================================================
output "ec2_instance_profile_name" {
  description = "EC2에 연결할 Instance Profile 이름"
  value       = module.s3_images.ec2_instance_profile_name
}

#==============================================================================
# 백엔드 개발자 전달 정보 요약
#==============================================================================
output "backend_developer_info" {
  description = "백엔드 개발자에게 전달할 설정 정보"
  value       = <<-EOT

    === S3 이미지 저장소 설정 정보 (Production) ===

    [S3 설정]
    Bucket Name : ${module.s3_images.bucket_name}
    Region      : ${module.s3_images.bucket_region}

    [IAM 자격증명]
    Access Key ID     : ${module.s3_images.iam_user_access_key_id}
    Secret Access Key : (sensitive) terraform output -raw iam_user_secret_access_key 로 확인

    [EC2 서버 배포 시]
    Instance Profile  : ${module.s3_images.ec2_instance_profile_name}
    → EC2 콘솔에서 인스턴스에 IAM Role 연결 필요

    [Spring Boot application.yml 예시]
    cloud:
      aws:
        s3:
          bucket: ${module.s3_images.bucket_name}
        region:
          static: ${module.s3_images.bucket_region}

  EOT
}