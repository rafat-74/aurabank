output "alb_sg_id" {
  description = "Security Group ID for the ALB"
  value       = aws_security_group.alb.id
}

output "ecs_sg_id" {
  description = "Security Group ID for ECS tasks"
  value       = aws_security_group.ecs.id
}

output "ecs_teller_sg_id" {
  description = "Security Group ID for teller ECS tasks"
  value       = aws_security_group.ecs_teller.id
}

output "rds_sg_id" {
  description = "Security Group ID for RDS"
  value       = aws_security_group.rds.id
}

output "lambda_db_init_sg_id" {
  description = "Security Group ID for Lambda DB init"
  value       = aws_security_group.lambda_db_init.id
}
