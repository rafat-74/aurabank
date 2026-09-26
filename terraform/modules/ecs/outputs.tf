output "cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "service_names" {
  description = "Map of service → ECS service name"
  value = merge(
    { for k, v in aws_ecs_service.backend : k => v.name },
    {
      "api-gateway"        = aws_ecs_service.api_gateway.name
      "frontend-customers" = aws_ecs_service.frontend_customers.name
      "frontend-teller"    = aws_ecs_service.frontend_teller.name
    }
  )
}

output "service_discovery_namespace" {
  value = aws_service_discovery_private_dns_namespace.main.name
}
