provider "aws" {
  region     = var.aws_region
  sts_region = "us-east-1"
}

data "aws_caller_identity" "current" {}
