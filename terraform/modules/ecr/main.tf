###############################################################################
# AuraBank – ECR Module
# Creates one ECR repository per service with lifecycle policies,
# image scanning, and encryption.
###############################################################################

locals {
  services = [
    "auth-service",
    "accounts-service",
    "transactions-service",
    "notifications-service",
    "api-gateway",
    "frontend-customers",
    "frontend-teller",
  ]
}

resource "aws_ecr_repository" "services" {
  for_each             = toset(local.services)
  name                 = "${var.project}/${var.env}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # No overwriting tags in prod

  image_scanning_configuration {
    scan_on_push = true # Vulnerability scan on every push
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, {
    Name    = "${var.project}-${var.env}-${each.key}"
    Service = each.key
  })
}

# ── Lifecycle Policy (keep last N images, delete untagged after 1 day) ─────────
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only last ${var.ecr_image_retention_count} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "sha"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_image_retention_count
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── ECR Repository Policy (allow ECS task role to pull) ───────────────────────
data "aws_caller_identity" "current" {}

resource "aws_ecr_repository_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
}
