variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "tenant" {
  type = string
}

variable "stage" {
  type = string
}

variable "environment" {
  type = string
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

variable "admin_cidrs" {
  description = "Sources allowed to reach the jump host SSH, the Kubernetes API and ingress ports"
  type        = list(string)
}

variable "nodes" {
  description = "VMs by name; roles are Kubemarine roles: balancer, control-plane, worker"
  type = map(object({
    roles         = list(string)
    instance_type = string
    subnet        = string
    volume_size   = optional(number, 50)
  }))
}

variable "jump_host_enabled" {
  description = "true creates the jump host the kubemarine component installs from; false destroys it"
  type        = bool
  default     = false
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
