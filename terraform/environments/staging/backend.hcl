# Backend configuration for the staging environment.
# Pass to terraform init with: terraform init -backend-config=backend.hcl
#
# NOTE: The state bucket is in us-east-1, not af-south-1. State buckets are
# intentionally kept in a stable central region — the infrastructure region
# (af-south-1, set in providers.tf) and the state storage region are independent.
#
# Pre-requisites (run once before terraform init):
#   aws s3api create-bucket --bucket acme-staging-tfstate-516341735012 --region us-east-1
#   aws s3api put-bucket-versioning --bucket acme-staging-tfstate-516341735012 --versioning-configuration Status=Enabled
#   aws dynamodb create-table --table-name acme-staging-tfstate-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST --region us-east-1

bucket         = "acme-staging-tfstate-516341735012"
key            = "staging/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "acme-staging-tfstate-lock"
encrypt        = true
