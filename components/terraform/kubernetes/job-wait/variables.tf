variable "kubeconfig_path" {
  description = "Path to the kubeconfig used to access the existing cluster"
  type        = string
}

# Deployment context inherited from the Atmos stack.
variable "cloud" {
  type    = string
  default = null
}

variable "tenant" {
  type    = string
  default = null
}

variable "stage" {
  type    = string
  default = null
}

variable "environment" {
  type    = string
  default = null
}

variable "region" {
  type    = string
  default = null
}

variable "local_endpoint" {
  type    = string
  default = null
}