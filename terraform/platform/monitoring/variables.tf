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

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "thanos_bucket_name" {
  description = "S3 bucket name for Thanos blocks — output from platform/thanos"
  type        = string
}

variable "thanos_irsa_role_arn" {
  description = "IAM role ARN for the Thanos sidecar IRSA — output from platform/thanos"
  type        = string
}
