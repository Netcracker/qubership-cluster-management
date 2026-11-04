variable "tenant" {
  type    = string
  default = null
}

variable "stage" {
  type    = string
  default = null
}

variable "cloud" {
  description = "Cloud identifier supplied by Atmos as deployment context"
  type        = string
  default     = null
}

variable "environment" {
  type = string
}

variable "nodes" {
  description = "Cluster VMs as output by any <cloud>/vms component; roles are Kubemarine roles"
  type = list(object({
    name             = string
    roles            = list(string)
    address          = string
    internal_address = string
  }))
}

variable "jump_host" {
  description = "SSH host inside the node network that runs Kubemarine; null once the jump host is destroyed"
  type = object({
    address = string
    user    = string
  })
  default = null
}

variable "ssh_private_key" {
  description = "Key for the jump host and the nodes"
  type        = string
  sensitive   = true
}

variable "kubemarine" {
  description = "Extra cluster.yaml fields (cluster_name, node_defaults, services, plugins, ...) merged over the generated ones"
  type        = any
  default     = {}
}

variable "kubemarine_version" {
  type    = string
  default = "0.55.0"
}
