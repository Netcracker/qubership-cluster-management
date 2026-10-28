variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "tenant" {
  description = "Customer identifier supplied by Atmos"
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "IPv4 address range for the VPC"
  type        = string
}

variable "stage" {
  description = "Stage name from the Atmos configuration"
  type        = string
}

variable "subnets" {
  description = "VPC subnets"
  type = map(object({
    cidr_block        = string
    availability_zone = string
  }))
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
