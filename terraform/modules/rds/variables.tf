variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "rds_sg_id" {
  type = string
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "rds_master_username" {
  type = string
}

variable "rds_master_password" {
  type      = string
  sensitive = true
}

variable "rds_master_secret_arn" {
  type = string
}

variable "schema_secret_arns" {
  type = map(string)
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 100
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "lambda_sg_id" {
  description = "Security Group ID for the DB init Lambda"
  type        = string
}
