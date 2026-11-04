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
variable "name" {
  description = "Group name: resource name prefix and the first Role tag"
  type        = string
}

variable "resource_group_name" { type = string }
variable "subnet_ids" {
  description = "Subnet IDs by key, as output by the network component"
  type        = map(string)
}
variable "image" {
  type = object({ publisher = string, offer = string, sku = string, version = string })
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
variable "ssh_public_key" {
  description = "Public half of the SOPS-stored key (TF_VAR_ssh_public_key from sops exec-env)"
  type        = string
}
variable "vms" {
  description = "VMs by name; roles are Kubemarine roles or empty; instance_type is the VM size"
  type = map(object({
    roles         = optional(list(string), [])
    instance_type = string
    subnet        = string
    volume_size   = optional(number, 50)
  }))
}
variable "public" {
  description = "Give the VMs public IPs"
  type        = bool
  default     = false
}
variable "ports" {
  description = "TCP ports open to allowed_cidrs"
  type        = list(number)
  default     = [22]
}
variable "allowed_cidrs" {
  description = "Sources for ports: the VNet CIDR for private groups, operator CIDRs for the jump host"
  type        = list(string)
}
