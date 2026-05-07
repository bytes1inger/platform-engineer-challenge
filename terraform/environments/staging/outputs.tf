output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used for IRSA role bindings"
  value       = module.eks.oidc_provider_arn
}

output "node_group_role_arn" {
  description = "IAM role ARN assigned to the managed node group"
  value       = module.eks.node_group_role_arn
}

output "app_sa_role_arn" {
  description = "IRSA role ARN to annotate the app-sa service account with"
  value       = module.eks.app_sa_role_arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for use in the CI/CD pipeline"
  value       = module.ecr.repository_url
}

output "app_bucket_name" {
  description = "S3 bucket created for the application and referenced by the IRSA policy"
  value       = aws_s3_bucket.app_data.bucket
}
