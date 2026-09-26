variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "ecr_image_retention_count" {
  type    = number
  default = 10
}

variable "tags" {
  type    = map(string)
  default = {}
}
