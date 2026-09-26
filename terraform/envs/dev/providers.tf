###############################################################################
# AuraBank – Dev Environment – Terraform Backend (S3 + DynamoDB)
# Run ONCE manually before using this env:
#   cd envs/dev && terraform init
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state: S3 bucket + DynamoDB lock table
  # The bucket and table are created by scripts/bootstrap_state.sh
  backend "s3" {
    bucket         = "aurabank-terraform-state-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"          
    encrypt        = true
    dynamodb_table = "aurabank-terraform-locks-dev"
  }
}

# ── Providers ──────────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aurabank"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# Second provider alias for us-east-1 (required for WAF + CloudFront ACM)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "aurabank"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
