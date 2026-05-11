output "argocd_manager_token" {
  description = "Service account token for ArgoCD to manage this cluster — pass to terraform/platform"
  value       = kubernetes_secret.argocd_manager_token.data["token"]
  sensitive   = true
}

output "cluster_name" {
  description = "Cluster name label used in ArgoCD registration"
  value       = var.cluster_name
}
