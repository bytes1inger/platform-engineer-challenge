locals {
  common_labels = {
    environment = var.environment
    cluster     = var.cluster_name
    managed-by  = "terraform"
  }
}
