output "repository_url" {
  description = "ECR repository to push images to."
  value       = aws_ecr_repository.this.repository_url
}

output "load_balancer_dns_name" {
  description = "Load balancer hostname."
  value       = aws_lb.this.dns_name
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "task_security_group_id" {
  description = "Security group attached to the application tasks."
  value       = aws_security_group.tasks.id
}

output "task_role_name" {
  description = "Role the application code runs as; later PRs attach Bedrock permissions here."
  value       = aws_iam_role.task.name
}

output "log_group_name" {
  description = "Application log group."
  value       = aws_cloudwatch_log_group.this.name
}
