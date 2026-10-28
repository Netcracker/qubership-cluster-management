variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "stage" {
  type = string
}

variable "environment" {
  type = string
}

variable "kubeconfig_path" {
  description = "Kubeconfig for this deployment; null preserves the environment-based path"
  type        = string
  default     = null
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = map(string)
}

variable "tenant" {
  type    = string
  default = null
}

variable "headlamp_node_port" {
  type = number
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
