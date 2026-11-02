variable "name" {
  description = "Prefix for resource names, e.g. findings-dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC to place the database security group in."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated database subnets, in at least two availability zones."
  type        = list(string)
}

variable "client_security_group_id" {
  description = "Security group of the application tasks; the only source allowed to connect."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "multi_az" {
  description = "Standby replica in a second AZ. Doubles cost; off for a learning environment."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention. Restore drills need at least 1."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "Keep at least one day of backups so restore can be practised."
  }
}

variable "deletion_protection" {
  description = "Block `terraform destroy` on the database. Turn off before teardown."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the snapshot on destroy. True suits synthetic data only."
  type        = bool
  default     = true
}
