output "alb_arn" {
  value = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB (point your Route53 record here)"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB (for Route53 alias records)"
  value       = aws_lb.main.zone_id
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "tg_frontend_customers_arn" {
  value = aws_lb_target_group.frontend_customers.arn
}

output "tg_frontend_teller_arn" {
  value = aws_lb_target_group.frontend_teller.arn
}

output "tg_api_gateway_arn" {
  value = aws_lb_target_group.api_gateway.arn
}

output "alb_logs_bucket" {
  value = aws_s3_bucket.alb_logs.bucket
}
