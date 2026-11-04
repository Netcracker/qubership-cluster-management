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
variable "subnet_ids" {
  description = "Subnet IDs by key, as output by the network component"
  type        = map(string)
}
variable "admin_cidrs" {
  description = "Sources allowed to reach the jump host SSH, the Kubernetes API and ingress ports"
  type        = list(string)
}
variable "nodes" {
  description = "VMs by name; roles are Kubemarine roles; instance_type is the VM size"
  type = map(object({
    roles         = list(string)
    instance_type = string
    subnet        = string
    volume_size   = optional(number, 50)
  }))
  validation {
    condition     = !contains(keys(var.nodes), "jump")
    error_message = "The node name jump is reserved for the jump host."
  }
}
variable "jump_host_enabled" {
  description = "true creates the jump host the kubemarine component installs from; false destroys it"
  type        = bool
  default     = false
}
