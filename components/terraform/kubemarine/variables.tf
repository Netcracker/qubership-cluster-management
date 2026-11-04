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
  description = "Jump host VM (any <cloud>/vms output entry); Kubemarine reaches the nodes through it"
  type = object({
    address = string
  })
}

variable "nexus_address" {
  description = "Private address of the Nexus VM loaded by bundle/load.sh"
  type        = string
}

variable "mirrored_registries" {
  description = "Registries of application images; containerd pulls <registry>/<path> from Nexus (bundle/manifest.yaml app_images)"
  type        = list(string)
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_private_key" {
  description = "Key for the jump host and the nodes (TF_VAR_ssh_private_key from sops exec-env)"
  type        = string
  sensitive   = true
}

variable "kubemarine" {
  description = "Extra cluster.yaml fields (cluster_name, services, plugins, ...) merged over the generated ones"
  type        = any
  default     = {}
}
