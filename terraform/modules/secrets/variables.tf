variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "rds_master_username" {
  type    = string
  default = "aurabank_admin"
}

variable "tags" {
  type    = map(string)
  default = {}
}
