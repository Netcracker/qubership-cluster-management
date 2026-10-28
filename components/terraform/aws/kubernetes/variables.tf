variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "stage" {
  description = "Name of the stage from Atmos"
  type        = string
}

variable "tenant" {
  description = "Customer identifier supplied by Atmos"
  type        = string
  default     = null
}

variable "environment" {
  description = "Name of the environment"
  type        = string
}

variable "subnet_ids" {
  description = "IDs of the subnets for the cluster"
  type        = map(string)
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
