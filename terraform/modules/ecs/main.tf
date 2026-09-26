###############################################################################
# AuraBank – ECS Module
# Fargate cluster with one service per microservice.
# Services in private subnets; secrets pulled from Secrets Manager at runtime.
###############################################################################

# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.env}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-cluster"
  })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = var.env == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
  }
}

# ── IAM: Task Execution Role (pull images, write logs, read secrets) ───────────
resource "aws_iam_role" "task_execution" {
  name = "${var.project}-${var.env}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_basic" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "${var.project}-${var.env}-ecs-secrets-policy"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
        Resource = var.all_secret_arns
      }
    ]
  })
}

# ── IAM: Task Role (runtime permissions) ──────────────────────────────────────
resource "aws_iam_role" "task" {
  name = "${var.project}-${var.env}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

# ── CloudWatch Log Groups ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "services" {
  for_each          = toset(local.all_service_names)
  name              = "/aurabank/${var.env}/${each.key}"
  retention_in_days = var.env == "prod" ? 90 : 14

  tags = var.tags
}

locals {
  all_service_names = [
    "auth-service",
    "accounts-service",
    "transactions-service",
    "notifications-service",
    "api-gateway",
    "frontend-customers",
    "frontend-teller",
  ]

  # RDS connection strings use schema-specific user per service
  # Format: postgresql://<user>:<pass>@<host>:5432/aurabank?options=-csearch_path%3D<schema>
  # Password injected at runtime via Secrets Manager secret reference

  backend_services = {
    "auth-service" = {
      port        = 8001
      cpu         = var.svc_cpu
      memory      = var.svc_memory
      desired     = var.svc_desired_count
      schema      = "auth"
      secret_key  = "auth"
    }
    "accounts-service" = {
      port        = 8002
      cpu         = var.svc_cpu
      memory      = var.svc_memory
      desired     = var.svc_desired_count
      schema      = "accounts"
      secret_key  = "accounts"
    }
    "transactions-service" = {
      port        = 8003
      cpu         = var.svc_cpu
      memory      = var.svc_memory
      desired     = var.svc_desired_count
      schema      = "transactions"
      secret_key  = "transactions"
    }
    "notifications-service" = {
      port        = 8004
      cpu         = var.svc_cpu
      memory      = var.svc_memory
      desired     = var.svc_desired_count
      schema      = "notifications"
      secret_key  = "notifications"
    }
  }
}

# ── Task Definitions: Backend Services ────────────────────────────────────────
resource "aws_ecs_task_definition" "backend" {
  for_each = local.backend_services

  family                   = "${var.project}-${var.env}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = "${var.ecr_repo_urls[each.key]}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = each.value.port
        protocol      = "tcp"
      }]

      # Secrets injected from AWS Secrets Manager — never in plaintext
      secrets = [
        {
          name      = "DB_SECRET_JSON"
          valueFrom = var.schema_secret_arns[each.value.secret_key]
        },
        {
          name      = "JWT_SECRET_JSON"
          valueFrom = var.jwt_secret_arn
        }
      ]

      # Non-sensitive environment variables
      environment = [
        # DATABASE_URL built from schema user creds — see entrypoint wrapper
        { name = "DB_HOST",              value = var.rds_address },
        { name = "DB_PORT",              value = "5432" },
        { name = "DB_NAME",              value = "aurabank" },
        { name = "DB_SCHEMA",            value = each.value.schema },
        { name = "ACCOUNTS_URL",         value = "http://accounts-service.${var.project}-${var.env}.local:8002" },
        { name = "AUTH_URL",             value = "http://auth-service.${var.project}-${var.env}.local:8001" },
        { name = "TRANSACTIONS_URL",     value = "http://transactions-service.${var.project}-${var.env}.local:8003" },
        { name = "NOTIFICATIONS_URL",    value = "http://notifications-service.${var.project}-${var.env}.local:8004" },
        { name = "SQS_QUEUE_URL",         value = var.sqs_queue_url },
        { name = "SES_SENDER",            value = var.ses_sender },
        { name = "ENV",                  value = var.env },
     { name = "ALLOWED_ORIGINS",         value = "https://${var.customer_domain},https://${var.teller_domain}" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/aurabank/${var.env}/${each.key}"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -sf http://localhost:${each.value.port}/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(var.tags, {
    Service = each.key
  })
}

# ── Task Definitions: API Gateway ─────────────────────────────────────────────
resource "aws_ecs_task_definition" "api_gateway" {
  family                   = "${var.project}-${var.env}-api-gateway"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.gw_cpu
  memory                   = var.gw_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "api-gateway"
    image     = "${var.ecr_repo_urls["api-gateway"]}:${var.image_tag}"
    essential = true

    portMappings = [{ containerPort = 8000, protocol = "tcp" }]

    secrets = [
      { name = "JWT_SECRET_JSON", valueFrom = var.jwt_secret_arn }
    ]

    environment = [
      { name = "AUTH_URL",          value = "http://auth-service.${var.project}-${var.env}.local:8001" },
      { name = "ACCOUNTS_URL",      value = "http://accounts-service.${var.project}-${var.env}.local:8002" },
      { name = "TRANSACTIONS_URL",  value = "http://transactions-service.${var.project}-${var.env}.local:8003" },
      { name = "NOTIFICATIONS_URL", value = "http://notifications-service.${var.project}-${var.env}.local:8004" },
      { name = "SQS_QUEUE_URL",      value = var.sqs_queue_url },
      { name = "SNS_TOPIC_ARN",      value = var.sns_topic_arn },
      { name = "ENV",               value = var.env },
      { name = "ALLOWED_ORIGINS",   value = "https://${var.customer_domain},https://${var.teller_domain}" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/aurabank/${var.env}/api-gateway"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -sf http://localhost:8000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = merge(var.tags, { Service = "api-gateway" })
}

# ── Task Definitions: Frontend Customers ──────────────────────────────────────
resource "aws_ecs_task_definition" "frontend_customers" {
  family                   = "${var.project}-${var.env}-frontend-customers"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fe_cpu
  memory                   = var.fe_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "frontend-customers"
    image     = "${var.ecr_repo_urls["frontend-customers"]}:${var.image_tag}"
    essential = true

    portMappings = [{ containerPort = 80, protocol = "tcp" }]

    environment = [
      { name = "API_URL", value = "https://${var.domain_name}/api" },
      { name = "ENV",     value = var.env },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/aurabank/${var.env}/frontend-customers"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = merge(var.tags, { Service = "frontend-customers" })
}

# ── Task Definitions: Frontend Teller ─────────────────────────────────────────
resource "aws_ecs_task_definition" "frontend_teller" {
  family                   = "${var.project}-${var.env}-frontend-teller"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fe_cpu
  memory                   = var.fe_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "frontend-teller"
    image     = "${var.ecr_repo_urls["frontend-teller"]}:${var.image_tag}"
    essential = true

    portMappings = [{ containerPort = 80, protocol = "tcp" }]

    environment = [
      { name = "API_URL", value = "https://${var.domain_name}/api" },
      { name = "ENV",     value = var.env },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/aurabank/${var.env}/frontend-teller"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = merge(var.tags, { Service = "frontend-teller" })
}

# ── Service Discovery Namespace (private DNS for inter-service calls) ──────────
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.project}-${var.env}.local"
  description = "AuraBank ${var.env} internal service discovery"
  vpc         = var.vpc_id

  tags = var.tags
}

# ── ECS Services: Backend ──────────────────────────────────────────────────────
resource "aws_service_discovery_service" "backend" {
  for_each = local.backend_services

  name = each.key

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "backend" {
  for_each = local.backend_services

  name            = "${var.project}-${var.env}-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend[each.key].arn
  desired_count   = each.value.desired
  launch_type     = var.env == "prod" ? "FARGATE" : null

  dynamic "capacity_provider_strategy" {
    for_each = var.env != "prod" ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
    }
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.backend[each.key].arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  tags = merge(var.tags, { Service = each.key })

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}

# ── ECS Service: API Gateway ───────────────────────────────────────────────────
resource "aws_service_discovery_service" "api_gateway" {
  name = "api-gateway"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config { failure_threshold = 1 }
}

resource "aws_ecs_service" "api_gateway" {
  name            = "${var.project}-${var.env}-api-gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_gateway.arn
  desired_count   = var.svc_desired_count

  capacity_provider_strategy {
    capacity_provider = var.env == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.tg_api_gateway_arn
    container_name   = "api-gateway"
    container_port   = 8000
  }

  service_registries {
    registry_arn = aws_service_discovery_service.api_gateway.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = merge(var.tags, { Service = "api-gateway" })

  lifecycle { ignore_changes = [desired_count, task_definition] }
}

# ── ECS Service: Frontend Customers ───────────────────────────────────────────
resource "aws_ecs_service" "frontend_customers" {
  name            = "${var.project}-${var.env}-frontend-customers"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend_customers.arn
  desired_count   = var.fe_desired_count

  capacity_provider_strategy {
    capacity_provider = var.env == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.tg_frontend_customers_arn
    container_name   = "frontend-customers"
    container_port   = 80
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = merge(var.tags, { Service = "frontend-customers" })

  lifecycle { ignore_changes = [desired_count, task_definition] }
}

# ── ECS Service: Frontend Teller ───────────────────────────────────────────────
resource "aws_ecs_service" "frontend_teller" {
  name            = "${var.project}-${var.env}-frontend-teller"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend_teller.arn
  desired_count   = var.fe_desired_count

  capacity_provider_strategy {
    capacity_provider = var.env == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_teller_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.tg_frontend_teller_arn
    container_name   = "frontend-teller"
    container_port   = 80
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = merge(var.tags, { Service = "frontend-teller" })

  lifecycle { ignore_changes = [desired_count, task_definition] }
}

# ── Auto Scaling ───────────────────────────────────────────────────────────────
resource "aws_appautoscaling_target" "api_gateway" {
  max_capacity       = var.max_capacity
  min_capacity       = var.svc_desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api_gateway.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "api_gateway_cpu" {
  name               = "${var.project}-${var.env}-api-gw-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api_gateway.resource_id
  scalable_dimension = aws_appautoscaling_target.api_gateway.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api_gateway.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
