terraform {
  # 1.10+ for S3-native state locking (use_lockfile); no DynamoDB lock table needed.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource is tagged without each module having to remember to.
  default_tags {
    tags = {
      Project     = "findings-service"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "S24DeFi/webui-lib-findings-service"
    }
  }
}
