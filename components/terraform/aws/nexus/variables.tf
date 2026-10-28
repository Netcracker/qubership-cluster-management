variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "tenant" {
  type = string
}

variable "stage" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "nexus_version" {
  type = string
}
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "local_endpoint" {
  description = "Floci endpoint; null uses the real AWS APIs and normal credential chain"
  type        = string
  default     = null
}
