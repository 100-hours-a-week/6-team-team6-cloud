# modules/s3-images/main.tf
# S3 이미지 저장소 + IAM 리소스 정의
# Presigned URL 방식으로 이미지 업로드/다운로드

#==============================================================================
# S3 Bucket
#==============================================================================
resource "aws_s3_bucket" "images" {
  bucket = "${var.project_name}-images-${var.env}"

  tags = {
    Name = "${var.project_name}-images-${var.env}"
  }
}

# 퍼블릭 액세스 차단 (presigned URL로 접근하므로 퍼블릭 불필요)
resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 서버 사이드 암호화 (AES-256)
resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 버전 관리 (이미지 실수 삭제 방지)
resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# CORS 설정 (브라우저에서 presigned URL로 직접 업로드/다운로드)
resource "aws_s3_bucket_cors_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    expose_headers  = ["ETag", "Content-Type", "Content-Length"]
    max_age_seconds = 3600
  }
}

#==============================================================================
# IAM Policy - S3 이미지 버킷 접근 권한
#==============================================================================
resource "aws_iam_policy" "s3_images" {
  name        = "${var.project_name}-${var.env}-s3-images-policy"
  description = "S3 이미지 버킷 접근 권한 (presigned URL 생성용)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3ImagesBucketObject"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.images.arn}/*"
      },
      {
        Sid    = "AllowS3ImagesBucketList"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.images.arn
      }
    ]
  })

  tags = {
    Purpose = "S3 presigned URL"
  }
}

#==============================================================================
# IAM User - 로컬 개발용 (Access Key 발급)
#==============================================================================
resource "aws_iam_user" "s3_images" {
  name = "${var.project_name}-${var.env}-s3-images-user"

  tags = {
    Purpose = "S3 presigned URL - local dev"
  }
}

resource "aws_iam_user_policy_attachment" "s3_images" {
  user       = aws_iam_user.s3_images.name
  policy_arn = aws_iam_policy.s3_images.arn
}

resource "aws_iam_access_key" "s3_images" {
  user = aws_iam_user.s3_images.name
}

#==============================================================================
# IAM Role + Instance Profile - EC2 서버용
#==============================================================================
resource "aws_iam_role" "ec2_s3_images" {
  name = "${var.project_name}-${var.env}-ec2-s3-images-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_s3_images" {
  role       = aws_iam_role.ec2_s3_images.name
  policy_arn = aws_iam_policy.s3_images.arn
}

resource "aws_iam_instance_profile" "ec2_s3_images" {
  name = "${var.project_name}-${var.env}-ec2-s3-images-profile"
  role = aws_iam_role.ec2_s3_images.name
}