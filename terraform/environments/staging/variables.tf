variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "af-south-1"
}

variable "project" {
  description = "Project name — used in resource naming and tags"
  type        = string
  default     = "acme"
}

variable "environment" {
  description = "Deployment environment (staging, production)"
  type        = string
  default     = "staging"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "List of CIDRs for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.10.0.0/19", "10.10.32.0/19", "10.10.64.0/19"]
}

variable "public_subnet_cidrs" {
  description = "List of CIDRs for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.10.96.0/19", "10.10.128.0/19", "10.10.160.0/19"]
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.30"
}

variable "ecr_repository_name" {
  description = "ECR repository name for the application image"
  type        = string
  default     = "acme/api-service"
}

variable "app_bucket_suffix" {
  description = "Suffix appended to the project+environment prefix for the app data S3 bucket"
  type        = string
  default     = "app-data"
}

variable "endpoint_public_access" {
  description = "Enable public access to the EKS API server — restrict public_access_cidrs to known IPs"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint"
  type        = list(string)
  default     = []
}
