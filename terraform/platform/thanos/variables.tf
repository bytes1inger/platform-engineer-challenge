variable "aws_region" {
  description = "AWS region where EKS is deployed"
  type        = string
  default     = "af-south-1"
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA — output from terraform/environments/staging"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (without https://) — output from terraform/environments/staging"
  type        = string
}
