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
variable "subnet_id" { type = string }
variable "manage_network_role_assignment" {
  description = "Create the AKS subnet role assignment; disable only for emulators without Azure RBAC APIs"
  type        = bool
  default     = true
}
variable "kubernetes_version" {
  type    = string
  default = null
}
variable "node_count" {
  type    = number
  default = 2
}
variable "vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}
variable "service_cidr" {
  type    = string
  default = "172.20.0.0/16"
}
variable "dns_service_ip" {
  type    = string
  default = "172.20.0.10"
}
