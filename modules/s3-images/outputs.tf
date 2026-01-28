# modules/s3-images/outputs.tf

#==============================================================================
# S3 정보
#==============================================================================
output "bucket_name" {
  description = "S3 버킷 이름"
  value       = aws_s3_bucket.images.id
}

output "bucket_arn" {
  description = "S3 버킷 ARN"
  value       = aws_s3_bucket.images.arn
}

output "bucket_region" {
  description = "S3 버킷 리전"
  value       = aws_s3_bucket.images.region
}

#==============================================================================
# IAM User 정보 (로컬 개발용)
#==============================================================================
output "iam_user_name" {
  description = "IAM User 이름"
  value       = aws_iam_user.s3_images.name
}

output "iam_user_access_key_id" {
  description = "IAM User Access Key ID (로컬 개발용)"
  value       = aws_iam_access_key.s3_images.id
}

output "iam_user_secret_access_key" {
  description = "IAM User Secret Access Key (로컬 개발용)"
  value       = aws_iam_access_key.s3_images.secret
  sensitive   = true
}

#==============================================================================
# IAM Role 정보 (EC2 서버용)
#==============================================================================
output "ec2_instance_profile_name" {
  description = "EC2 Instance Profile 이름 (EC2에 연결 필요)"
  value       = aws_iam_instance_profile.ec2_s3_images.name
}

output "ec2_role_arn" {
  description = "EC2 IAM Role ARN"
  value       = aws_iam_role.ec2_s3_images.arn
}