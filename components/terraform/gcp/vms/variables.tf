variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "environment" { type = string }
variable "region" { type = string }
variable "project_id" { type = string }

variable "location" {
  description = "Zone for the VMs"
  type        = string
}
variable "vpc_id" { type = string }
variable "subnet_ids" {
  description = "Subnet IDs by key, as output by the network component"
  type        = map(string)
}
variable "image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2204-lts"
}
variable "admin_cidrs" {
  description = "Sources allowed to reach the jump host SSH, the Kubernetes API and ingress ports"
  type        = list(string)
}
variable "nodes" {
  description = "VMs by name; roles are Kubemarine roles; instance_type is the machine type"
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
