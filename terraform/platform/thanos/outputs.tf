output "bucket_name" {
  description = "S3 bucket name for Thanos blocks"
  value       = aws_s3_bucket.thanos.bucket
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.thanos.arn
}

output "irsa_role_arn" {
  description = "IAM role ARN for the Thanos sidecar IRSA annotation"
  value       = aws_iam_role.thanos_sidecar.arn
}

output "loki_irsa_role_arn" {
  description = "IAM role ARN for the Loki IRSA annotation"
  value       = aws_iam_role.loki.arn
}
