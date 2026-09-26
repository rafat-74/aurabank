output "rds_master_secret_arn" {
  description = "ARN of the RDS master credentials secret"
  value       = aws_secretsmanager_secret.rds_master.arn
}

output "rds_master_secret_name" {
  value = aws_secretsmanager_secret.rds_master.name
}

output "schema_secret_arns" {
  description = "Map of schema name → secret ARN"
  value       = { for k, v in aws_secretsmanager_secret.schema_creds : k => v.arn }
}

output "schema_secret_names" {
  description = "Map of schema name → secret name"
  value       = { for k, v in aws_secretsmanager_secret.schema_creds : k => v.name }
}

output "jwt_secret_arn" {
  description = "ARN of the JWT secret"
  value       = aws_secretsmanager_secret.jwt.arn
}

output "rds_master_password" {
  description = "RDS master password (sensitive)"
  value       = random_password.rds_master.result
  sensitive   = true
}
