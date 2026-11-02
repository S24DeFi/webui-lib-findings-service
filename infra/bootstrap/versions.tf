terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state on purpose: this stack creates the bucket every other stack stores its
  # state in, so it cannot use that bucket itself on first apply. It holds no secrets.
  # Keep terraform.tfstate out of git (see .gitignore) and back it up, or migrate it into
  # the bucket afterwards with `terraform init -migrate-state`.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "findings-service"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
