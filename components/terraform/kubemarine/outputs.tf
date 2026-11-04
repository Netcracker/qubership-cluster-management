output "kubemarine_config" {
  description = "cluster.yaml the jump host installs from"
  value       = yamlencode(local.cluster)
}
