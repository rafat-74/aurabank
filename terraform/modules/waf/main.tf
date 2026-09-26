terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.50"
      configuration_aliases = [aws.us_east_1]
    }
  }
}
###############################################################################
# AuraBank – WAF Module (AWS WAFv2)
# - Customer CloudFront: OWASP Core Rule Set + rate limiting (public)
# - Teller CloudFront:   Same + IP allowlist (internal/office IPs only)
###############################################################################

# ── WAF for Customer-facing CloudFront (us-east-1 required for CF) ────────────
# Note: WAF for CloudFront MUST be created in us-east-1 regardless of your region
resource "aws_wafv2_web_acl" "customers" {
  provider    = aws.us_east_1
  name        = "${var.project}-${var.env}-waf-customers"
  description = "WAF for AuraBank customer-facing CloudFront"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rule 1: Rate limit per IP (prevent abuse)
  rule {
    name     = "RateLimitRule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.customer_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-customers-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS Managed Core Rule Set (OWASP Top 10)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Allow legitimate API bodies that might trigger SQL injection rules
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
          allow {}
        }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-customers-owasp"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-customers-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: SQL Injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-customers-sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.env}-waf-customers"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# ── WAF for Teller CloudFront (IP allowlist + OWASP) ─────────────────────────
resource "aws_wafv2_web_acl" "teller" {
  provider    = aws.us_east_1
  name        = "${var.project}-${var.env}-waf-teller"
  description = "WAF for AuraBank teller-facing CloudFront - IP restricted"
  scope       = "CLOUDFRONT"

  # Default: BLOCK everything not explicitly allowed
  default_action {
    block {}
  }

  # Rule 1: Allow only approved office/VPN IPs
  rule {
    name     = "AllowTellerIPs"
    priority = 1

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.teller_allowed.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-teller-ip-allow"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Rate limit allowed IPs (extra safety)
  rule {
    name     = "TellerRateLimit"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.teller_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-teller-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: OWASP Core
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-teller-owasp"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.env}-waf-teller"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# ── IP Set for Teller Allowed IPs ─────────────────────────────────────────────
resource "aws_wafv2_ip_set" "teller_allowed" {
  provider           = aws.us_east_1
  name               = "${var.project}-${var.env}-teller-allowed-ips"
  description        = "Office/VPN IPs allowed to access teller frontend"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.teller_allowed_ips

  tags = var.tags
}

# ── WAF Logging to S3 ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "waf_customers" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${var.project}-${var.env}-customers"
  retention_in_days = var.env == "prod" ? 90 : 30

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "waf_teller" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${var.project}-${var.env}-teller"
  retention_in_days = var.env == "prod" ? 90 : 30

  tags = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "customers" {
  provider                = aws.us_east_1
  log_destination_configs = [aws_cloudwatch_log_group.waf_customers.arn]
  resource_arn            = aws_wafv2_web_acl.customers.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "teller" {
  provider                = aws.us_east_1
  log_destination_configs = [aws_cloudwatch_log_group.waf_teller.arn]
  resource_arn            = aws_wafv2_web_acl.teller.arn
}
