resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      managed-by = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  timeout    = 600

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [kubernetes_namespace.argocd]
}

# ArgoCD discovers clusters via Secrets labelled with secret-type=cluster
resource "kubernetes_secret" "onprem_cluster" {
  metadata {
    name      = "${var.onprem_cluster_name}-secret"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name   = var.onprem_cluster_name
    server = var.onprem_cluster_server
    config = jsonencode({
      bearerToken = var.onprem_cluster_token
      tlsClientConfig = {
        insecure = true
      }
    })
  }

  depends_on = [helm_release.argocd]
}
