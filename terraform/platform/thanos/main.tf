resource "aws_s3_bucket" "thanos" {
  bucket        = "acme-staging-thanos-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

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

# IRSA role — no long-lived credentials in the EKS cluster
locals {
  s3_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = [aws_s3_bucket.thanos.arn, "${aws_s3_bucket.thanos.arn}/*"]
    }]
  })
}

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
  name   = "thanos-sidecar-s3"
  role   = aws_iam_role.thanos_sidecar.id
  policy = local.s3_policy
}

resource "aws_iam_role" "loki" {
  name = "acme-staging-loki"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_url}:sub" = "system:serviceaccount:monitoring:loki"
          "${var.oidc_issuer_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "loki_s3" {
  name   = "loki-s3"
  role   = aws_iam_role.loki.id
  policy = local.s3_policy
}
