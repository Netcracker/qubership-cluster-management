variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "environment" { type = string }
variable "region" { type = string }
variable "project_id" { type = string }

variable "backend_instances" {
  description = "Self-links of backend VMs; manage ingress and health-check firewall rules for these VMs separately"
  type        = list(string)
  validation {
    condition     = length(var.backend_instances) > 0
    error_message = "At least one backend VM self-link must be supplied."
  }
}
variable "port_range" {
  type    = string
  default = "80"
}
variable "health_check_port" {
  type    = number
  default = 80
}
variable "health_check_path" {
  type    = string
  default = "/"
}
