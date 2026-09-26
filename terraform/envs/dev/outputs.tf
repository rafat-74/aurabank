output "customer_portal_url" {
  description = "Customer portal URL"
  value       = "https://${var.customer_domain}"
}

output "teller_portal_url" {
  description = "Teller portal URL (IP-restricted)"
  value       = "https://${var.teller_domain}"
}

output "alb_dns_name" {
  description = "ALB DNS (do not use directly — always go through CloudFront)"
  value       = module.alb.alb_dns_name
}

output "rds_endpoint" {
  description = "RDS endpoint (internal, not publicly accessible)"
  value       = module.rds.rds_endpoint
  sensitive   = true
}

output "ecr_repositories" {
  description = "ECR repository URLs for pushing Docker images"
  value       = module.ecr.repository_urls
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "cloudwatch_log_groups" {
  description = "Log group prefix for all services"
  value       = "/aurabank/${local.env}/<service-name>"
}

output "next_steps" {
  value = <<-EOT
    ✅ Infrastructure deployed!

    Next steps:
    1. Build & push Docker images:
       cd ../../ && ./scripts/push_images.sh dev ${var.aws_region} ${data.aws_caller_identity.current.account_id}

    2. Run DB schema init (Lambda):
       aws lambda invoke --function-name aurabank-dev-db-init /tmp/out.json

    3. Access your app:
       Customer Portal: https://${var.customer_domain}
       Teller Portal:   https://${var.teller_domain}

    4. View logs:
       aws logs tail /aurabank/dev/api-gateway --follow
  EOT
}
