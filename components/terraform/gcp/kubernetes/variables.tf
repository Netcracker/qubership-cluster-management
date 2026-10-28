variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "environment" { type = string }
variable "region" { type = string }
variable "project_id" { type = string }

variable "location" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "admin_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Supply at least one valid operator CIDR for Kubernetes API access."
  }
}
variable "node_count" {
  type    = number
  default = 2
}
variable "machine_type" {
  type    = string
  default = "e2-standard-2"
}
variable "disk_size_gb" {
  type    = number
  default = 50
}
variable "deletion_protection" {
  type    = bool
  default = true
}
