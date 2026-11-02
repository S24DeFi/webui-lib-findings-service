output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Subnets for internet-facing load balancers."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "Subnets for application tasks (no internet route)."
  value       = [for s in aws_subnet.private : s.id]
}

output "database_subnet_ids" {
  description = "Isolated subnets for RDS."
  value       = [for s in aws_subnet.database : s.id]
}

output "s3_prefix_list_id" {
  description = "Prefix list for the S3 gateway endpoint, for security group egress rules."
  value       = aws_vpc_endpoint.s3.prefix_list_id
}
