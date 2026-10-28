variable "tenant" {
  description = "Customer identifier supplied by Atmos"
  type        = string
  default     = null
}

variable "stage" {
  description = "Environment stage supplied by Atmos"
  type        = string
  default     = null
}

variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "environment" { type = string }
variable "region" { type = string }

variable "vpc_cidr" { type = string }
variable "subnets" {
  type = map(object({ cidr_block = string }))
}
