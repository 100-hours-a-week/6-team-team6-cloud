provider "aws" {
  region = "ap-northeast-2"
}

# 1. S3 버킷 생성 (Terraform State 저장용)
resource "aws_s3_bucket" "tf_state" {
  bucket = "billage-terraform-state-prod" # backend.tf에 적은 이름과 동일해야 함

  # 실수로 삭제 방지
  lifecycle {
    prevent_destroy = true
  }
}

# 1-1. S3 버저닝 활성화 (복구가능)
resource "aws_s3_bucket_versioning" "tf_state_versioning" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 1-2. S3 암호화 설정 (보안)
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state_encryption" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 1-3. S3 퍼블릭 액세스 차단
resource "aws_s3_bucket_public_access_block" "tf_state_public_access" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2. DynamoDB 테이블 생성 (Terraform Locking 용)
resource "aws_dynamodb_table" "tf_lock" {
  name         = "billage-terraform-lock-prod" # backend.tf에 적은 이름과 동일해야 함
  billing_mode = "PAY_PER_REQUEST"             # 온디맨드 (쓴 만큼만 과금, 프리티어 커버 가능)
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}