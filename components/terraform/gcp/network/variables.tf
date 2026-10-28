variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "environment" { type = string }
variable "region" { type = string }
variable "project_id" { type = string }

variable "subnet_cidr" { type = string }
variable "pod_cidr" {
  type    = string
  default = "10.100.0.0/16"
}
variable "service_cidr" {
  type    = string
  default = "10.110.0.0/20"
}
