variable "region" {
  description = "AWS region. us-east-1 has the widest Bedrock model and AgentCore availability."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name, used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block (/16)."
  type        = string
  default     = "10.40.0.0/16"
}

variable "image_tag" {
  description = "Image tag to run, normally the git commit SHA pushed by CI."
  type        = string
}

variable "public" {
  description = "Expose the load balancer to the internet. Requires certificate_arn and explicit owner authorization."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS."
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "Source ranges for a public listener. Ignored while internal."
  type        = list(string)
  default     = []
}
