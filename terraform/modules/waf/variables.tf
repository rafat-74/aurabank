variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "teller_allowed_ips" {
  description = "List of CIDR blocks allowed to access teller frontend"
  type        = list(string)
}

variable "customer_rate_limit" {
  type    = number
  default = 2000
}

variable "teller_rate_limit" {
  type    = number
  default = 500
}

variable "tags" {
  type    = map(string)
  default = {}
}
