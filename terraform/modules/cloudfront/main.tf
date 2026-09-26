###############################################################################
# AuraBank – CloudFront Module
# Distribution 1: customer-facing (public, any IP)
# Distribution 2: teller-facing  (WAF IP-restricted)
# Both terminate SSL and route /api/* to ALB, /* to respective frontend.
###############################################################################

locals {
  # Custom header added by CloudFront → ALB uses this to verify requests
  # came through CloudFront and weren't direct-hit
  cf_secret_header_name  = "X-CloudFront-Secret"
  cf_secret_header_value = var.cloudfront_secret_token
}

# ── Customer Distribution ─────────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "customers" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "AuraBank ${var.env} - Customer Portal"
  price_class         = var.cf_price_class
  aliases             = [var.customer_domain]
  web_acl_id          = var.customers_waf_arn
  wait_for_deployment = false

  # Origin 1: ALB (API + frontend via path routing)
  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = local.cf_secret_header_name
      value = local.cf_secret_header_value
    }
  }

  # Behavior 1: /api/* → ALB, no caching (dynamic)
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # Behavior 2: /* → Customer frontend (cache HTML/assets)
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
      headers      = ["Origin", "Authorization", "Host"]
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none" # Customers worldwide
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn_us_east_1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html" # SPA fallback
    error_caching_min_ttl = 300
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 300
  }

  logging_config {
    include_cookies = false
    bucket          = "${var.cf_logs_bucket}.s3.amazonaws.com"
    prefix          = "customers/"
  }

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.env}-cf-customers"
    Audience = "customers"
  })
}

# ── Teller Distribution (IP-restricted via WAF) ────────────────────────────────
resource "aws_cloudfront_distribution" "teller" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "AuraBank ${var.env} - Teller Portal (restricted)"
  price_class         = var.cf_price_class
  aliases             = [var.teller_domain]
  web_acl_id          = var.teller_waf_arn
  wait_for_deployment = false

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb-teller-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = local.cf_secret_header_name
      value = local.cf_secret_header_value
    }
  }

  # /api/* → ALB (no cache)
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-teller-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-teller-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
      headers      = ["Origin", "Authorization", "Host"]
    }

    min_ttl     = 0
    default_ttl = 300   # Shorter cache for teller
    max_ttl     = 3600
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = var.teller_allowed_countries
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn_us_east_1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  logging_config {
    include_cookies = false
    bucket          = "${var.cf_logs_bucket}.s3.amazonaws.com"
    prefix          = "teller/"
  }

  tags = merge(var.tags, {
    Name     = "${var.project}-${var.env}-cf-teller"
    Audience = "teller"
  })
}

# ── Managed Cache/Request Policies (AWS-provided) ─────────────────────────────
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# ── S3 Bucket for CloudFront Logs ─────────────────────────────────────────────
resource "aws_s3_bucket" "cf_logs" {
  bucket        = var.cf_logs_bucket
  force_destroy = var.env != "prod"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-cf-logs"
  })
}

resource "aws_s3_bucket_ownership_controls" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "cf_logs" {
  depends_on = [aws_s3_bucket_ownership_controls.cf_logs]
  bucket     = aws_s3_bucket.cf_logs.id
  acl        = "log-delivery-write"
}

resource "aws_s3_bucket_lifecycle_configuration" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter { prefix = "" }
    expiration {
      days = var.env == "prod" ? 90 : 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cf_logs" {
  bucket                  = aws_s3_bucket.cf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
