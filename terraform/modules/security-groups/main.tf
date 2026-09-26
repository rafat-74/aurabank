###############################################################################
# AuraBank – Security Groups Module
# Principle: least privilege — each group allows only what's needed
###############################################################################

# ── ALB Security Group (public-facing) ───────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.env}-sg-alb"
  description = "Allow HTTPS from Internet via WAF"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # WAF filters before reaching ALB
  }

  ingress {
    description = "HTTP redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-sg-alb"
  })
}

# ── ECS Services Security Group ───────────────────────────────────────────────
resource "aws_security_group" "ecs" {
  name        = "${var.project}-${var.env}-sg-ecs"
  description = "ECS tasks - allow traffic from ALB only"
  vpc_id      = var.vpc_id

  # API Gateway port (8000) — from ALB
  ingress {
    description     = "API Gateway from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Frontend Customer (80) — from ALB
  ingress {
    description     = "Frontend customers from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Internal service-to-service (8001-8004)
  ingress {
    description = "Internal microservice communication"
    from_port   = 8001
    to_port     = 8004
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound (for pulling images, calling AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-sg-ecs"
  })
}

# ── Teller ECS Security Group (restricted) ────────────────────────────────────
resource "aws_security_group" "ecs_teller" {
  name        = "${var.project}-${var.env}-sg-ecs-teller"
  description = "Teller frontend - allow only from ALB with WAF IP restrictions"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Teller frontend from ALB (WAF-filtered)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-sg-ecs-teller"
  })
}

# ── RDS Security Group ────────────────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.env}-sg-rds"
  description = "RDS PostgreSQL - allow only from ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    description = "Allow responses back to ECS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  lifecycle {
    ignore_changes = [ingress]   # ← أضف السطر ده
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-sg-rds"
  })
}
# ── VPC Endpoints Security Group ──────────────────────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-${var.env}-sg-vpc-endpoints"
  description = "For ECR, Secrets Manager, CloudWatch VPC endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from private subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-sg-vpc-endpoints"
  })
}

# ── VPC Endpoints (reduce NAT costs, improve security) ───────────────────────
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-vpce-ecr-api"
  })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-vpce-ecr-dkr"
  })
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-vpce-secrets"
  })
}


resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-vpce-s3"
  })
}

# ── Lambda DB Init Security Group ─────────────────────────────────────────────
resource "aws_security_group" "lambda_db_init" {
  name        = "${var.project}-${var.env}-sg-lambda-db-init"
  description = "Lambda DB init - allows outbound to RDS and AWS APIs"
  vpc_id      = var.vpc_id

  # Outbound to RDS (using VPC CIDR to avoid circular dependency)
  egress {
    description = "PostgreSQL to RDS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Outbound HTTPS for Secrets Manager, CloudWatch via VPC endpoints
  egress {
    description = "HTTPS for AWS APIs via VPC endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-sg-lambda-db-init"
  })
}

# ── Separate ingress rule to break the cycle ───────────────────────────────────
# Allow Lambda DB init to connect to RDS (defined after both SGs exist)
resource "aws_vpc_security_group_ingress_rule" "rds_from_lambda" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.lambda_db_init.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from Lambda DB init"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-rds-from-lambda"
  })
}
