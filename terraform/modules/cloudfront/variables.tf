variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "customer_domain" {
  type = string
}

variable "teller_domain" {
  type = string
}

variable "acm_certificate_arn_us_east_1" {
  type = string
}

variable "customers_waf_arn" {
  type = string
}

variable "teller_waf_arn" {
  type = string
}

variable "cloudfront_secret_token" {
  type      = string
  sensitive = true
}

variable "cf_logs_bucket" {
  type = string
}

variable "cf_price_class" {
  type    = string
  default = "PriceClass_100"
}

variable "teller_allowed_countries" {
  type    = list(string)
  default = ["EG"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
