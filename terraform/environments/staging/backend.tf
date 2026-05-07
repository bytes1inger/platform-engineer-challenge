terraform {
  # Partial backend configuration — actual values are supplied at init time via:
  #   terraform init -backend-config=backend.hcl
  #
  # Terraform's backend block is evaluated before providers and data sources,
  # so variable interpolation is not available here. The backend.hcl file holds
  # the environment-specific values (bucket, key, region, dynamodb_table).
  backend "s3" {}
}
