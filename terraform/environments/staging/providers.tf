terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # af-south-1 is an opt-in region whose regional STS endpoint is not active by default.
  # sts_region pins credential validation to us-east-1 (global STS) while all other
  # resources are still provisioned in af-south-1.
  sts_region = "us-east-1"
}
