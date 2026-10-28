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

variable "resource_group_name" { type = string }
variable "vpc_id" { type = string }
variable "backend_addresses" {
  description = "Stable private backend addresses; AKS-managed pools are not discovered automatically"
  type        = map(string)
  validation {
    condition     = length(var.backend_addresses) > 0
    error_message = "At least one backend address must be supplied."
  }
}
variable "frontend_port" {
  type    = number
  default = 80
}
variable "backend_port" {
  type    = number
  default = 80
}
