# S3 backend — an existing state bucket, under a key of its own so this stack's
# state stays isolated from anything else in the account.
# Native S3 locking (use_lockfile) means no DynamoDB table is required.
#
# Partial config: the bucket, region and AWS profile are account-specific, so
# they live in a gitignored backend.hcl. Copy backend.hcl.example and run:
#   terraform init -backend-config=backend.hcl

terraform {
  backend "s3" {
    key          = "environments/labs/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
