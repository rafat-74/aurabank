variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "acm_certificate_arn" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "alb_account_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "teller_domain" {
  description = "Teller portal domain"
  type        = string
}

variable "customer_domain" {
  description = "Customer portal domain"
  type        = string
}
