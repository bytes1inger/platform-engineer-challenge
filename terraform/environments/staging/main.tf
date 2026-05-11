module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    "kubernetes.io/role/elb"                      = "1" # must be string "1" for ALB/NLB subnet discovery
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"             = "1" # must be string "1" for internal load balancer discovery
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------
# ECR — container image registry for the CI/CD pipeline
# -----------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  repository_name      = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true

  tags = local.common_tags
}

# -----------------------------------------------------------------
# S3 — application data bucket (referenced by the IRSA policy)
# -----------------------------------------------------------------

resource "aws_s3_bucket" "app_data" {
  bucket = "${var.project}-${var.environment}-${var.app_bucket_suffix}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "app_data" {
  bucket                  = aws_s3_bucket.app_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "eks" {
  source = "../../modules/eks-cluster"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version
  environment     = var.environment
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets # control plane ENIs must be in private subnets

  node_group_subnet_ids = module.vpc.private_subnets
  app_bucket_name       = aws_s3_bucket.app_data.bucket

  endpoint_public_access = var.endpoint_public_access
  public_access_cidrs    = var.public_access_cidrs

  tags = local.common_tags
}
