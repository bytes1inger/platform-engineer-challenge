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
  timeout    = 600

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
# Thanos — S3 object storage for metrics blocks
# -----------------------------------------------------------------

resource "aws_s3_bucket" "thanos" {
  bucket = "acme-staging-thanos-${data.aws_caller_identity.current.account_id}"
  tags = {
    ManagedBy = "terraform"
    Purpose   = "thanos-metrics-blocks"
  }
}

resource "aws_s3_bucket_versioning" "thanos" {
  bucket = aws_s3_bucket.thanos.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "thanos" {
  bucket = aws_s3_bucket.thanos.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "thanos" {
  bucket                  = aws_s3_bucket.thanos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IRSA role for Thanos sidecar on EKS — no long-lived credentials in cluster
resource "aws_iam_role" "thanos_sidecar" {
  name = "acme-staging-thanos-sidecar"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_url}:sub" = "system:serviceaccount:monitoring:kube-prometheus-stack-prometheus"
          "${var.oidc_issuer_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "thanos_sidecar_s3" {
  name = "thanos-sidecar-s3"
  role = aws_iam_role.thanos_sidecar.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ]
      Resource = [
        aws_s3_bucket.thanos.arn,
        "${aws_s3_bucket.thanos.arn}/*"
      ]
    }]
  })
}

# Object store config Secret consumed by Thanos sidecar and Thanos Query
resource "kubernetes_secret" "thanos_objstore" {
  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "objstore.yml" = yamlencode({
      type = "S3"
      config = {
        bucket   = aws_s3_bucket.thanos.bucket
        endpoint = "s3.af-south-1.amazonaws.com"
        region   = "af-south-1"
      }
    })
  }

  depends_on = [kubernetes_namespace.monitoring]
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
  timeout    = 600

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password
      additionalDataSources = [{
        name   = "Thanos"
        type   = "prometheus"
        url    = "http://thanos-query.monitoring.svc.cluster.local:9090"
        access = "proxy"
        isDefault = true
      }]
    }
    prometheus = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.thanos_sidecar.arn
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
                bucket   = aws_s3_bucket.thanos.bucket
                endpoint = "s3.af-south-1.amazonaws.com"
                region   = "af-south-1"
              }
            }
          }
        }
      }
    }
  })]

  depends_on = [kubernetes_namespace.monitoring, aws_s3_bucket.thanos, kubernetes_secret.thanos_objstore]
}

# -----------------------------------------------------------------
# Thanos Query — unified query layer across both clusters
# -----------------------------------------------------------------

resource "helm_release" "thanos" {
  name       = "thanos"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "thanos"
  version    = "15.7.21"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 300

  values = [yamlencode({
    query = {
      enabled = true
      stores  = ["dnssrv+_grpc._tcp.kube-prometheus-stack-thanos-discovery.monitoring.svc.cluster.local"]
      replicaLabel = ["prometheus_replica"]
    }
    queryFrontend = { enabled = false }
    compactor = {
      enabled = true
      retentionResolutionRaw = "90d"
      retentionResolution5m  = "1y"
      retentionResolution1h  = "2y"
    }
    storegateway = { enabled = true }
    ruler        = { enabled = false }
    receive      = { enabled = false }
    existingObjstoreSecret = kubernetes_secret.thanos_objstore.metadata[0].name
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
