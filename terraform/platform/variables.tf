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

variable "argocd_chart_version" {
  description = "Argo CD Helm chart version"
  type        = string
  default     = "7.7.3"
}

variable "onprem_cluster_server" {
  description = "API server URL for the on-prem cluster (Tailscale IP + port)"
  type        = string
}

variable "onprem_cluster_token" {
  description = "Service account bearer token for ArgoCD to authenticate to the on-prem cluster"
  type        = string
  sensitive   = true
}

variable "onprem_cluster_name" {
  description = "Name registered in ArgoCD for the on-prem cluster"
  type        = string
  default     = "omen-onprem"
}

variable "grafana_admin_password" {
  description = "Grafana admin password — store in a tfvars file that is gitignored"
  type        = string
  sensitive   = true
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA — output from terraform/environments/staging"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (without https://) — output from terraform/environments/staging"
  type        = string
}
