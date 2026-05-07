locals {
  cluster_name = "${var.project}-${var.environment}-eks"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
