# -----------------------------------------------------------------
# Namespaces
# -----------------------------------------------------------------

resource "kubernetes_namespace" "apps" {
  metadata {
    name   = "apps"
    labels = local.common_labels
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name   = "monitoring"
    labels = local.common_labels
  }
}

# -----------------------------------------------------------------
# ArgoCD service account — used by the EKS ArgoCD to manage this cluster
# -----------------------------------------------------------------

resource "kubernetes_namespace" "argocd" {
  metadata {
    name   = "argocd"
    labels = local.common_labels
  }
}

resource "kubernetes_service_account" "argocd_manager" {
  metadata {
    name      = "argocd-manager"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "argocd_manager" {
  metadata {
    name = "argocd-manager"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argocd_manager.metadata[0].name
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }
}

resource "kubernetes_secret" "argocd_manager_token" {
  metadata {
    name      = "argocd-manager-token"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.argocd_manager.metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"
}
