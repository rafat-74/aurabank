output "customers_waf_arn" {
  description = "WAF ACL ARN for customer-facing CloudFront"
  value       = aws_wafv2_web_acl.customers.arn
}

output "teller_waf_arn" {
  description = "WAF ACL ARN for teller-facing CloudFront"
  value       = aws_wafv2_web_acl.teller.arn
}
