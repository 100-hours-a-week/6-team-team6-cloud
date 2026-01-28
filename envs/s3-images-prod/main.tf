# envs/s3-images-prod/main.tf
# S3 이미지 저장소 + IAM 구성 (Production)
#
# 용도: Presigned URL 방식 이미지 업로드/다운로드
# - S3 버킷 (퍼블릭 차단, 암호화, CORS)
# - IAM User + Access Key (로컬 개발용)
# - IAM Role + Instance Profile (EC2 서버용)

module "s3_images" {
  source = "../../modules/s3-images"

  project_name         = var.project_name
  env                  = var.env
  cors_allowed_origins = var.cors_allowed_origins
  enable_versioning    = var.enable_versioning
}