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
