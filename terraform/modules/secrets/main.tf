###############################################################################
# AuraBank – Secrets Module
# All secrets live in AWS Secrets Manager. Zero plain-text secrets in code.
###############################################################################

# ── RDS Master Password ────────────────────────────────────────────────────────
resource "random_password" "rds_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "${var.project}/${var.env}/rds/master"
  description             = "AuraBank RDS master credentials"
  recovery_window_in_days = var.env == "prod" ? 30 : 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = var.rds_master_username
    password = random_password.rds_master.result
  })
}

# ── Per-schema DB credentials ─────────────────────────────────────────────────
locals {
  schemas = ["auth", "accounts", "transactions", "notifications"]
}

resource "random_password" "schema_user" {
  for_each         = toset(local.schemas)
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
}

resource "aws_secretsmanager_secret" "schema_creds" {
  for_each                = toset(local.schemas)
  name                    = "${var.project}/${var.env}/rds/${each.key}"
  description             = "AuraBank ${each.key} schema DB credentials"
  recovery_window_in_days = var.env == "prod" ? 30 : 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "schema_creds" {
  for_each  = toset(local.schemas)
  secret_id = aws_secretsmanager_secret.schema_creds[each.key].id
  secret_string = jsonencode({
    username = "${each.key}_user"
    password = random_password.schema_user[each.key].result
    dbname   = "${each.key}_db"
    schema   = each.key
  })
}

# ── JWT Secret ────────────────────────────────────────────────────────────────
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${var.project}/${var.env}/jwt-secret"
  description             = "AuraBank JWT signing secret"
  recovery_window_in_days = var.env == "prod" ? 30 : 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = jsonencode({ jwt_secret = random_password.jwt_secret.result })
}
