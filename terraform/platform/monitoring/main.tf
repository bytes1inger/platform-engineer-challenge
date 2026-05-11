resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      managed-by = "terraform"
    }
  }
}

# Object store config consumed by Thanos sidecar and Thanos Query
resource "kubernetes_secret" "thanos_objstore" {
  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "objstore.yml" = yamlencode({
      type = "S3"
      config = {
        bucket   = var.thanos_bucket_name
        endpoint = "s3.af-south-1.amazonaws.com"
        region   = "af-south-1"
      }
    })
  }

  depends_on = [kubernetes_namespace.monitoring]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.1.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 900

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password
      sidecar = {
        datasources = {
          # Disable the auto-provisioned local Prometheus datasource so Thanos
          # can be the sole default (Grafana enforces one-default-per-org).
          defaultDatasourceEnabled = false
        }
      }
      additionalDataSources = [
        {
          name      = "Thanos"
          type      = "prometheus"
          url       = "http://thanos-query.monitoring.svc.cluster.local:9090"
          access    = "proxy"
          isDefault = true
        },
        {
          name   = "Loki"
          type   = "loki"
          url    = "http://loki.monitoring.svc.cluster.local:3100"
          access = "proxy"
        }
      ]
    }
    prometheus = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.thanos_irsa_role_arn
        }
      }
      prometheusSpec = {
        retention = "15d"
        externalLabels = {
          cluster = "eks-af-south-1"
        }
        thanos = {
          objectStorageConfig = {
            secret = {
              type = "S3"
              config = {
                bucket   = var.thanos_bucket_name
                endpoint = "s3.af-south-1.amazonaws.com"
                region   = "af-south-1"
              }
            }
          }
        }
      }
    }
  })]

  depends_on = [kubernetes_namespace.monitoring, kubernetes_secret.thanos_objstore]
}

# -----------------------------------------------------------------
# Thanos Query — unified query layer across both clusters
# Uses official quay.io/thanos/thanos image (bitnami removed from Docker Hub)
# -----------------------------------------------------------------

resource "kubernetes_deployment" "thanos_query" {
  metadata {
    name      = "thanos-query"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "thanos-query" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "thanos-query" } }

    template {
      metadata { labels = { app = "thanos-query" } }

      spec {
        container {
          name  = "thanos-query"
          image = "quay.io/thanos/thanos:v0.39.2"

          args = [
            "query",
            "--http-address=0.0.0.0:9090",
            "--grpc-address=0.0.0.0:10901",
            "--endpoint=dnssrv+_grpc._tcp.kube-prometheus-stack-thanos-discovery.monitoring.svc.cluster.local",
            "--query.replica-label=prometheus_replica",
          ]

          port {
            name           = "http"
            container_port = 9090
          }
          port {
            name           = "grpc"
            container_port = 10901
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_service" "thanos_query" {
  metadata {
    name      = "thanos-query"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { app = "thanos-query" }
  }

  spec {
    selector = { app = "thanos-query" }
    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
    port {
      name        = "grpc"
      port        = 10901
      target_port = 10901
    }
    type = "ClusterIP"
  }
}
