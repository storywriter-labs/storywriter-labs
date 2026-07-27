# StoryWriter Labs — Ghost CMS
# Standalone Terraform config for a single Ghost instance. Deliberately kept in
# its own repo and its own state, so a `terraform apply` here cannot touch any
# other stack in the account.

terraform {
  # 1.10+ required: the S3 backend's native use_lockfile locking (see backend.tf)
  # does not exist in earlier versions.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
