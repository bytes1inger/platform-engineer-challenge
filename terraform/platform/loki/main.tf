resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.6.2"
  namespace  = "monitoring"
  timeout    = 300

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      auth_enabled = false
      commonConfig = {
        replication_factor = 1
      }
      # bucketNames sits at storage level, s3 config is in the s3 sub-key
      storage = {
        type = "s3"
        bucketNames = {
          chunks = var.loki_bucket_name
          ruler  = var.loki_bucket_name
          admin  = var.loki_bucket_name
        }
        s3 = {
          region = "af-south-1"
        }
      }
      schemaConfig = {
        configs = [{
          from         = "2024-01-01"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index = {
            prefix = "loki_index_"
            period = "24h"
          }
        }]
      }
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.loki_irsa_role_arn
      }
    }
    singleBinary = {
      replicas = 1
      persistence = { enabled = false }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
      extraVolumes = [{
        name     = "loki-data"
        emptyDir = {}
      }]
      extraVolumeMounts = [{
        name      = "loki-data"
        mountPath = "/var/loki"
      }]
    }
    # Disable caches — avoids PVC provisioning (in-tree EBS driver not available on this EKS)
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    read    = { replicas = 0 }
    write   = { replicas = 0 }
    backend = { replicas = 0 }
    grafana-agent-operator = { enabled = false }
  })]
}
