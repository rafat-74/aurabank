variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_sg_id" {
  type = string
}

variable "ecs_teller_sg_id" {
  type = string
}

variable "ecr_repo_urls" {
  type = map(string)
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "rds_address" {
  type = string
}

variable "schema_secret_arns" {
  type = map(string)
}

variable "jwt_secret_arn" {
  type = string
}

variable "all_secret_arns" {
  type = list(string)
}

variable "tg_api_gateway_arn" {
  type = string
}

variable "tg_frontend_customers_arn" {
  type = string
}

variable "tg_frontend_teller_arn" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "customer_domain" {
  type = string
}

variable "teller_domain" {
  type = string
}

variable "svc_cpu" {
  type    = number
  default = 256
}

variable "svc_memory" {
  type    = number
  default = 512
}

variable "gw_cpu" {
  type    = number
  default = 512
}

variable "gw_memory" {
  type    = number
  default = 1024
}

variable "fe_cpu" {
  type    = number
  default = 256
}

variable "fe_memory" {
  type    = number
  default = 512
}

variable "svc_desired_count" {
  type    = number
  default = 1
}

variable "fe_desired_count" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 4
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "sqs_queue_url" {
  description = "SQS queue URL for notifications"
  type        = string
  default     = ""
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for SMS"
  type        = string
  default     = ""
}

variable "ses_sender" {
  description = "SES verified sender email"
  type        = string
  default     = "ahmedhassana3063850z@gmail.com"
}
