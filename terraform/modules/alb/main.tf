###############################################################################
# AuraBank – ALB Module
# One ALB with:
#   - HTTPS listener (port 443) → routes by path/host
#   - HTTP listener (port 80)  → redirect to HTTPS
#   - Target groups per ECS service
###############################################################################

resource "aws_lb" "main" {
  name               = "${var.project}-${var.env}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.env == "prod" ? true : false

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "${var.project}-${var.env}-alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-alb"
  })
}

# ── HTTP → HTTPS Redirect ──────────────────────────────────────────────────────
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ── HTTPS Listener ─────────────────────────────────────────────────────────────
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  # Default → customer frontend
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_customers.arn
  }
}

# ── Target Groups ─────────────────────────────────────────────────────────────

# Frontend Customers (default route)
resource "aws_lb_target_group" "frontend_customers" {
  name        = "${var.project}-${var.env}-tg-customers"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for Fargate

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-tg-customers"
  })
}

# Frontend Teller (restricted by WAF to allowed IPs)
resource "aws_lb_target_group" "frontend_teller" {
  name        = "${var.project}-${var.env}-tg-teller"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-tg-teller"
  })
}

# API Gateway
resource "aws_lb_target_group" "api_gateway" {
  name        = "${var.project}-${var.env}-tg-api"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-tg-api"
  })
}

# ── Listener Rules ────────────────────────────────────────────────────────────

# /api/* → API Gateway
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_gateway.arn
  }

  condition {
    path_pattern {
      values = ["/api/*", "/health"]
    }
  }
}

# Teller Frontend → host-based routing
resource "aws_lb_listener_rule" "teller" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_teller.arn
  }

  condition {
    host_header {
      values = [var.teller_domain]
    }
  }
}

# Customers Frontend → host-based routing
resource "aws_lb_listener_rule" "customers" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 6

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_customers.arn
  }

  condition {
    host_header {
      values = [var.customer_domain]
    }
  }
}

# ── S3 Bucket for ALB Access Logs ─────────────────────────────────────────────
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.project}-${var.env}-alb-logs-${var.aws_account_id}"
  force_destroy = var.env != "prod"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-alb-logs"
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter { prefix = "" }

    expiration {
      days = var.env == "prod" ? 90 : 14
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.alb_account_id}:root" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/*"
    }]
  })
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Teller /api/* → API Gateway (host + path based)
resource "aws_lb_listener_rule" "teller_api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 3

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_gateway.arn
  }

  condition {
    host_header {
      values = [var.teller_domain]
    }
  }

  condition {
    path_pattern {
      values = ["/api/*", "/health"]
    }
  }
}

# Customers /api/* → API Gateway (host + path based)
resource "aws_lb_listener_rule" "customers_api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 4

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_gateway.arn
  }

  condition {
    host_header {
      values = [var.customer_domain]
    }
  }

  condition {
    path_pattern {
      values = ["/api/*", "/health"]
    }
  }
}
