###############################################################################
# AuraBank – RDS Module
# Single PostgreSQL 15 instance with 4 separate schemas (auth, accounts,
# transactions, notifications) + dedicated users per schema for isolation.
# Schema-level isolation replaces the 4 separate DB containers.
###############################################################################

# ── DB Subnet Group ────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-${var.env}-db-subnet-group"
  subnet_ids  = var.private_subnet_ids
  description = "AuraBank ${var.env} RDS subnet group"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-db-subnet-group"
  })
}

# ── Parameter Group ────────────────────────────────────────────────────────────
resource "aws_db_parameter_group" "main" {
  name        = "${var.project}-${var.env}-pg15"
  family      = "postgres15"
  description = "AuraBank ${var.env} PostgreSQL 15 parameters"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_duration"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # log queries slower than 1s
  }

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
    apply_method = "immediate" 
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-pg15-params"
  })
}

# ── RDS Instance ───────────────────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier = "${var.project}-${var.env}-rds"

  # Engine
  engine               = "postgres"
  engine_version       = "15.7"
  instance_class       = var.db_instance_class
  parameter_group_name = aws_db_parameter_group.main.name

  # Storage
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  # Master credentials (fetched from Secrets Manager at apply time)
  db_name  = "aurabank"
  username = var.rds_master_username
  password = var.rds_master_password

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false
  port                   = 5432

  # HA & Backups
  multi_az                = var.env == "prod" ? true : false
  backup_retention_period = var.env == "prod" ? 14 : 3
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
  deletion_protection     = var.env == "prod" ? true : false
  skip_final_snapshot     = var.env == "prod" ? false : true
  final_snapshot_identifier = var.env == "prod" ? "${var.project}-${var.env}-final-snapshot" : null

  # Monitoring
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true
  performance_insights_retention_period = var.env == "prod" ? 731 : 7

  # Auto minor version upgrade
  auto_minor_version_upgrade = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-rds"
  })
}

# ── Enhanced Monitoring Role ───────────────────────────────────────────────────
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project}-${var.env}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── Schema Init Lambda (runs SQL to create schemas + users post-deploy) ────────
# This Lambda is invoked once after RDS is up to bootstrap schemas.
resource "aws_lambda_function" "db_init" {
  function_name = "${var.project}-${var.env}-db-init"
  role          = aws_iam_role.lambda_db_init.arn
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = 120

  filename         = "${path.module}/db_init_lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/db_init_lambda.zip")

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = {
      DB_HOST                  = aws_db_instance.main.address
      DB_PORT                  = "5432"
      DB_NAME                  = "aurabank"
      MASTER_SECRET_ARN        = var.rds_master_secret_arn
      AUTH_SECRET_ARN          = var.schema_secret_arns["auth"]
      ACCOUNTS_SECRET_ARN      = var.schema_secret_arns["accounts"]
      TRANSACTIONS_SECRET_ARN  = var.schema_secret_arns["transactions"]
      NOTIFICATIONS_SECRET_ARN = var.schema_secret_arns["notifications"]
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-db-init"
  })
  
}

resource "aws_iam_role" "lambda_db_init" {
  name = "${var.project}-${var.env}-lambda-db-init-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda_db_init" {
  name = "${var.project}-${var.env}-lambda-db-init-policy"
  role = aws_iam_role.lambda_db_init.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = concat(
          [var.rds_master_secret_arn],
          values(var.schema_secret_arns)
        )
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"]
        Resource = "*"
      }
    ]
  })
}



# ── CloudWatch Alarms ──────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-${var.env}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU utilization is too high"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project}-${var.env}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120 # 5 GB in bytes
  alarm_description   = "RDS free storage is running low"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  tags = var.tags
}
