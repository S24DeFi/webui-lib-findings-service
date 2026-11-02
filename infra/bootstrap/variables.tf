variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI roles."
  type        = string
  default     = "adswebwork/webui-lib-findings-service"
}

variable "deploy_environment" {
  description = "GitHub environment whose jobs may assume the apply role. Protect it with required reviewers."
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = "Prefix shared by every IAM role and policy the apply role is allowed to manage."
  type        = string
  default     = "findings"
}
