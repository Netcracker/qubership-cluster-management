variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
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
  type = string
}

variable "name" {
  description = "Group name: resource name prefix and the first Role tag"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnet IDs by key, as output by the network component"
  type        = map(string)
}

variable "ami_id" {
  type = string
}

variable "ssh_public_key" {
  description = "Public half of the SOPS-stored key (TF_VAR_ssh_public_key from sops exec-env)"
  type        = string
}

variable "vms" {
  description = "VMs by name; roles are Kubemarine roles (balancer, control-plane, worker) or empty"
  type = map(object({
    roles         = optional(list(string), [])
    instance_type = string
    subnet        = string
    volume_size   = optional(number, 50)
  }))
}

variable "public" {
  description = "Give the VMs public IPs; the subnet must route to the Internet"
  type        = bool
  default     = false
}

variable "ports" {
  description = "TCP ports open to allowed_cidrs"
  type        = list(number)
  default     = [22]
}

variable "allowed_cidrs" {
  description = "Sources for ports: the VPC CIDR for private groups, operator CIDRs for the jump host"
  type        = list(string)
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
