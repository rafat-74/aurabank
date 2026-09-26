output "customers_distribution_id" {
  value = aws_cloudfront_distribution.customers.id
}

output "customers_domain_name" {
  description = "CloudFront domain for customer portal"
  value       = aws_cloudfront_distribution.customers.domain_name
}

output "teller_distribution_id" {
  value = aws_cloudfront_distribution.teller.id
}

output "teller_domain_name" {
  description = "CloudFront domain for teller portal"
  value       = aws_cloudfront_distribution.teller.domain_name
}

output "cf_logs_bucket" {
  value = aws_s3_bucket.cf_logs.bucket
}
