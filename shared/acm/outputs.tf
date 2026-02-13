# shared/acm/outputs.tf

output "certificate_arn" {
  description = "ACM 인증서 ARN"
  value       = aws_acm_certificate.wildcard.arn
}

output "certificate_domain" {
  description = "인증서 도메인"
  value       = aws_acm_certificate.wildcard.domain_name
}

output "certificate_status" {
  description = "인증서 상태"
  value       = aws_acm_certificate.wildcard.status
}
