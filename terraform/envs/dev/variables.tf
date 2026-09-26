###############################################################################
# AuraBank – Dev Environment – Variable Definitions
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Team/owner tag for resources"
  type        = string
  default     = "aurabank-team"
}

# ── Networking ─────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.10.0/24", "10.10.11.0/24"]
}

# ── Database ───────────────────────────────────────────────────────────────────
variable "rds_master_username" {
  type    = string
  default = "aurabank_admin"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

# ── DNS & TLS ──────────────────────────────────────────────────────────────────
variable "hosted_zone_name" {
  description = "Route53 hosted zone (e.g. aurabank.example.com)"
  type        = string
}

variable "customer_domain" {
  description = "Customer portal domain (e.g. app.aurabank.example.com)"
  type        = string
}

variable "teller_domain" {
  description = "Teller portal domain (e.g. teller.aurabank.example.com)"
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN in your main region (for ALB)"
  type        = string
}

variable "acm_certificate_arn_us_east_1" {
  description = "ACM certificate ARN in us-east-1 (for CloudFront)"
  type        = string
}

# ── ALB ───────────────────────────────────────────────────────────────────────
variable "alb_account_id" {
  description = "AWS ALB service account ID for your region (see AWS docs)"
  type        = string
  # eu-west-1 = 156460612806
  # us-east-1 = 127311923021
  # eu-central-1 = 054676820928
  # See: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
}

# ── Security ───────────────────────────────────────────────────────────────────
variable "teller_allowed_ips" {
  description = "Office/VPN CIDR blocks allowed to reach teller portal"
  type        = list(string)
  # Example: ["197.121.133.107/32", "198.51.100.0/24", "154.237.223.80/24", "197.43.234.199/32", "154.238.210.70/32", ]
}

# ── ECS Image ─────────────────────────────────────────────────────────────────
variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}
