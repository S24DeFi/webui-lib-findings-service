variable "name" {
  description = "Prefix for resource names, e.g. findings-dev."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block. Must be /16 so each tier can take /24s."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && endswith(var.cidr, "/16")
    error_message = "cidr must be a valid IPv4 /16 block."
  }
}

variable "az_count" {
  description = "Availability zones to span. RDS subnet groups need at least two."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "interface_endpoints" {
  description = "AWS services reached through interface endpoints instead of a NAT gateway. Each costs per AZ-hour."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "logs", "secretsmanager", "bedrock-runtime"]
}

variable "log_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 14
}
