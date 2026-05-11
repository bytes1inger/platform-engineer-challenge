variable "aws_region" {
  description = "AWS region where EKS is deployed"
  type        = string
  default     = "af-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "acme-staging-eks"
}

variable "loki_bucket_name" {
  description = "S3 bucket name for Loki chunks — reuses the Thanos bucket"
  type        = string
}

variable "loki_irsa_role_arn" {
  description = "IAM role ARN for Loki IRSA — output from platform/thanos"
  type        = string
}
