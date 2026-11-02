output "repository_url" {
  description = "Push images here, tagged with the commit SHA."
  value       = module.service.repository_url
}

output "load_balancer_dns_name" {
  description = "Service endpoint (internal unless public = true)."
  value       = module.service.load_balancer_dns_name
}

output "cluster_name" {
  description = "ECS cluster, for `aws ecs` commands."
  value       = module.service.cluster_name
}

output "service_name" {
  description = "ECS service, for `aws ecs update-service`."
  value       = module.service.service_name
}

output "log_group_name" {
  description = "Application logs, for `aws logs tail`."
  value       = module.service.log_group_name
}
