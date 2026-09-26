variable "aws_region" { type = string; default = "eu-west-1" }
variable "owner" { type = string; default = "aurabank-team" }
variable "vpc_cidr" { type = string; default = "10.20.0.0/16" }
variable "azs" { type = list(string); default = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
variable "public_subnet_cidrs" { type = list(string); default = ["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"] }
variable "private_subnet_cidrs" { type = list(string); default = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"] }
variable "rds_master_username" { type = string; default = "aurabank_admin" }
variable "db_instance_class" { type = string; default = "db.t3.medium" }
variable "hosted_zone_name" { type = string }
variable "customer_domain" { type = string }
variable "teller_domain" { type = string }
variable "acm_certificate_arn" { type = string }
variable "acm_certificate_arn_us_east_1" { type = string }
variable "alb_account_id" { type = string }
variable "teller_allowed_ips" { type = list(string) }
variable "teller_allowed_countries" { type = list(string); default = ["EG"] }
variable "image_tag" { type = string }
