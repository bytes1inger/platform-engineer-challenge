variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the EKS control plane"
  type        = list(string)
}

variable "node_group_subnet_ids" {
  description = "Subnet IDs for worker node groups (should be private)"
  type        = list(string)
}

variable "app_bucket_name" {
  description = "S3 bucket name for IRSA policy"
  type        = string
  default     = ""
}

variable "endpoint_public_access" {
  description = "Enable public access to the EKS API server"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint — restrict to known IPs"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
