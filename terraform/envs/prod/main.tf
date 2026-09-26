###############################################################################
# AuraBank – Prod Environment – Main
# Same modules as dev but with production-grade sizing & HA settings.
###############################################################################

locals {
  project = "aurabank"
  env     = "prod"

  common_tags = {
    Project     = local.project
    Environment = local.env
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

resource "aws_kms_key" "main" {
  description             = "AuraBank ${local.env} encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.project}-${local.env}"
  target_key_id = aws_kms_key.main.key_id
}

module "secrets" {
  source              = "../../modules/secrets"
  project             = local.project
  env                 = local.env
  rds_master_username = var.rds_master_username
  tags                = local.common_tags
}

module "vpc" {
  source               = "../../modules/vpc"
  project              = local.project
  env                  = local.env
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.common_tags
}

module "security_groups" {
  source                  = "../../modules/security-groups"
  project                 = local.project
  env                     = local.env
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = module.vpc.vpc_cidr
  aws_region              = var.aws_region
  private_subnet_ids      = module.vpc.private_subnet_ids
  private_route_table_ids = module.vpc.private_route_table_ids
  tags                    = local.common_tags
}

module "ecr" {
  source                    = "../../modules/ecr"
  project                   = local.project
  env                       = local.env
  kms_key_arn               = aws_kms_key.main.arn
  ecr_image_retention_count = 20
  tags                      = local.common_tags
}

module "rds" {
  source                   = "../../modules/rds"
  project                  = local.project
  env                      = local.env
  private_subnet_ids       = module.vpc.private_subnet_ids
  rds_sg_id                = module.security_groups.rds_sg_id
  kms_key_arn              = aws_kms_key.main.arn
  rds_master_username      = var.rds_master_username
  rds_master_password      = module.secrets.rds_master_password
  rds_master_secret_arn    = module.secrets.rds_master_secret_arn
  schema_secret_arns       = module.secrets.schema_secret_arns
  db_instance_class        = var.db_instance_class   # e.g. db.t3.medium in prod
  db_allocated_storage     = 50
  db_max_allocated_storage = 500
  tags                     = local.common_tags
}

module "alb" {
  source              = "../../modules/alb"
  project             = local.project
  env                 = local.env
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  alb_sg_id           = module.security_groups.alb_sg_id
  acm_certificate_arn = var.acm_certificate_arn
  aws_account_id      = data.aws_caller_identity.current.account_id
  aws_region          = var.aws_region
  alb_account_id      = var.alb_account_id
  tags                = local.common_tags
}

module "waf" {
  source = "../../modules/waf"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }
  project             = local.project
  env                 = local.env
  teller_allowed_ips  = var.teller_allowed_ips
  customer_rate_limit = 3000
  teller_rate_limit   = 500
  tags                = local.common_tags
}

module "cloudfront" {
  source                        = "../../modules/cloudfront"
  project                       = local.project
  env                           = local.env
  alb_dns_name                  = module.alb.alb_dns_name
  customer_domain               = var.customer_domain
  teller_domain                 = var.teller_domain
  acm_certificate_arn_us_east_1 = var.acm_certificate_arn_us_east_1
  customers_waf_arn             = module.waf.customers_waf_arn
  teller_waf_arn                = module.waf.teller_waf_arn
  cloudfront_secret_token       = random_password.cf_secret.result
  cf_logs_bucket                = "${local.project}-${local.env}-cf-logs-${data.aws_caller_identity.current.account_id}"
  cf_price_class                = "PriceClass_All"
  teller_allowed_countries      = var.teller_allowed_countries
  tags                          = local.common_tags
}

module "ecs" {
  source             = "../../modules/ecs"
  project            = local.project
  env                = local.env
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  ecs_sg_id          = module.security_groups.ecs_sg_id
  ecs_teller_sg_id   = module.security_groups.ecs_teller_sg_id
  ecr_repo_urls      = module.ecr.repository_urls
  image_tag          = var.image_tag
  rds_address        = module.rds.rds_address
  schema_secret_arns = module.secrets.schema_secret_arns
  jwt_secret_arn     = module.secrets.jwt_secret_arn

  all_secret_arns = concat(
    values(module.secrets.schema_secret_arns),
    [module.secrets.jwt_secret_arn, module.secrets.rds_master_secret_arn]
  )

  tg_api_gateway_arn        = module.alb.tg_api_gateway_arn
  tg_frontend_customers_arn = module.alb.tg_frontend_customers_arn
  tg_frontend_teller_arn    = module.alb.tg_frontend_teller_arn
  domain_name               = var.customer_domain
  customer_domain           = var.customer_domain
  teller_domain             = var.teller_domain

  # Prod: larger, 2+ replicas, on-demand Fargate
  svc_cpu           = 512
  svc_memory        = 1024
  gw_cpu            = 1024
  gw_memory         = 2048
  fe_cpu            = 256
  fe_memory         = 512
  svc_desired_count = 2
  fe_desired_count  = 2
  max_capacity      = 10

  tags = local.common_tags
}

resource "random_password" "cf_secret" {
  length  = 32
  special = false
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "main" {
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "customers" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.customer_domain
  type    = "A"
  alias {
    name                   = module.cloudfront.customers_domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "teller" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.teller_domain
  type    = "A"
  alias {
    name                   = module.cloudfront.teller_domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}
