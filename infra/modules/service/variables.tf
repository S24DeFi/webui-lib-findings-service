variable "name" {
  description = "Prefix for resource names, e.g. findings-dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR, used to scope task egress to the interface endpoints."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets for a public load balancer."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnets for tasks, and for the load balancer when internal."
  type        = list(string)
}

variable "s3_prefix_list_id" {
  description = "S3 gateway endpoint prefix list, for task egress to ECR layers."
  type        = string
}

variable "database_host" {
  description = "Database hostname."
  type        = string
}

variable "database_port" {
  description = "Database port."
  type        = number
}

variable "database_name" {
  description = "Database name."
  type        = string
}

variable "database_secret_arn" {
  description = "Secrets Manager secret with username and password keys."
  type        = string
}

variable "database_security_group_id" {
  description = "Database security group, for task egress."
  type        = string
}

variable "image_tag" {
  description = "Image tag in this module's ECR repository, normally the git commit SHA."
  type        = string
}

variable "desired_count" {
  description = "Running tasks. Rate limiting is per process (README), so more than one task loosens it."
  type        = number
  default     = 1
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 512
}

variable "public" {
  description = "Internet-facing load balancer. Requires certificate_arn and owner authorization; the app has no authentication yet."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. Empty serves HTTP, which is only permitted on an internal load balancer."
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "Source ranges allowed to reach the load balancer listener."
  type        = list(string)
}

variable "enable_execute_command" {
  description = "Allow ECS Exec sessions into running tasks (needs the ssmmessages endpoint)."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Application log retention."
  type        = number
  default     = 14
}

variable "force_delete_images" {
  description = "Let `terraform destroy` delete the ECR repository while it still holds images."
  type        = bool
  default     = true
}
