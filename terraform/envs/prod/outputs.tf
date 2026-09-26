output "customer_portal_url" { value = "https://${var.customer_domain}" }
output "teller_portal_url" { value = "https://${var.teller_domain}" }
output "alb_dns_name" { value = module.alb.alb_dns_name; sensitive = true }
output "rds_endpoint" { value = module.rds.rds_endpoint; sensitive = true }
output "ecr_repositories" { value = module.ecr.repository_urls }
output "ecs_cluster_name" { value = module.ecs.cluster_name }
