###############################################################################
# AuraBank – Dev Environment – Main
# Orchestrates all modules for the dev deployment.
###############################################################################

locals {
  project = "aurabank"
  env     = "dev"

  common_tags = {
    Project     = local.project
    Environment = local.env
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# ── KMS Key (encrypts RDS, ECR, Secrets) ──────────────────────────────────────
resource "aws_kms_key" "main" {
  description             = "AuraBank ${local.env} encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.project}-${local.env}"
  target_key_id = aws_kms_key.main.key_id
}

# ── Secrets ────────────────────────────────────────────────────────────────────
module "secrets" {
  source = "../../modules/secrets"

  project             = local.project
  env                 = local.env
  rds_master_username = var.rds_master_username
  tags                = local.common_tags
}

# ── VPC ────────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  project              = local.project
  env                  = local.env
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  aws_region           = var.aws_region   # ← أضف السطر ده
  tags                 = local.common_tags
}

# ── Security Groups ────────────────────────────────────────────────────────────
module "security_groups" {
  source = "../../modules/security-groups"

  project                 = local.project
  env                     = local.env
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = module.vpc.vpc_cidr
  aws_region              = var.aws_region
  private_subnet_ids      = module.vpc.private_subnet_ids
  private_route_table_ids = module.vpc.private_route_table_ids
  tags                    = local.common_tags
}

# ── ECR ────────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  project                   = local.project
  env                       = local.env
  kms_key_arn               = aws_kms_key.main.arn
  ecr_image_retention_count = 5
  tags                      = local.common_tags
}

# ── RDS ────────────────────────────────────────────────────────────────────────
module "rds" {
  source = "../../modules/rds"

  project                  = local.project
  env                      = local.env
  private_subnet_ids       = module.vpc.private_subnet_ids
  rds_sg_id                = module.security_groups.rds_sg_id
  kms_key_arn              = aws_kms_key.main.arn
  rds_master_username      = var.rds_master_username
  rds_master_password      = module.secrets.rds_master_password
  rds_master_secret_arn    = module.secrets.rds_master_secret_arn
  schema_secret_arns       = module.secrets.schema_secret_arns
  db_instance_class        = var.db_instance_class
  db_allocated_storage     = 20
  db_max_allocated_storage = 50
  lambda_sg_id             = module.security_groups.lambda_db_init_sg_id
  tags                     = local.common_tags
  
  depends_on = [module.security_groups]
}

# ── ALB ────────────────────────────────────────────────────────────────────────
module "alb" {
  source = "../../modules/alb"

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
  teller_domain       = var.teller_domain
  customer_domain     = var.customer_domain
}

# ── WAF (us-east-1) ────────────────────────────────────────────────────────────
module "waf" {
  source = "../../modules/waf"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project            = local.project
  env                = local.env
  teller_allowed_ips = var.teller_allowed_ips
  customer_rate_limit = 1000
  teller_rate_limit   = 200
  tags               = local.common_tags
}

# ── CloudFront ─────────────────────────────────────────────────────────────────
module "cloudfront" {
  source = "../../modules/cloudfront"
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
  teller_allowed_countries      = ["EG"]
  tags                          = local.common_tags
}

# ── ECS ────────────────────────────────────────────────────────────────────────
module "ecs" {
  source = "../../modules/ecs"

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

  # Dev: smaller sizes, 1 replica, spot instances
  svc_cpu          = 256
  svc_memory       = 512
  gw_cpu           = 512
  gw_memory        = 1024
  fe_cpu           = 256
  fe_memory        = 512
  svc_desired_count = 1
  fe_desired_count  = 1
  max_capacity      = 2

  tags = local.common_tags
  sqs_queue_url    = module.messaging.sqs_queue_url
  sns_topic_arn    = module.messaging.sns_topic_arn
}

# ── CloudFront secret token ────────────────────────────────────────────────────
resource "random_password" "cf_secret" {
  length  = 32
  special = false
}

# ── Data Sources ───────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ── Route53 Records ────────────────────────────────────────────────────────────
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
    zone_id                = "Z2FDTNDATAQYW2" # CloudFront hosted zone ID (always this)
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

# ── Messaging (SQS + SNS) ──────────────────────────────────────────────────────
module "messaging" {
  source  = "../../modules/messaging"
  project = local.project
  env     = local.env
  tags    = local.common_tags
}
