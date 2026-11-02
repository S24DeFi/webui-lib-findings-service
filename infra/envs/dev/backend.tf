# Bucket and region come from a backend config file so no account-specific value is
# committed: terraform init -backend-config=backend.hcl (see backend.hcl.example).
terraform {
  backend "s3" {
    key          = "findings/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
