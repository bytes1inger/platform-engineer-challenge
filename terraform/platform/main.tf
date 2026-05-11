# -----------------------------------------------------------------
# ArgoCD
# -----------------------------------------------------------------

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

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [kubernetes_namespace.argocd]
}

# -----------------------------------------------------------------
# Register on-prem cluster with ArgoCD
# ArgoCD discovers clusters via Secrets labelled as cluster type
# -----------------------------------------------------------------

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

# -----------------------------------------------------------------
# Monitoring — kube-prometheus-stack
# -----------------------------------------------------------------

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      managed-by = "terraform"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.1.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "7d"
  }

  depends_on = [kubernetes_namespace.monitoring]
}
