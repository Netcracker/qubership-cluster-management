output "kubemarine_config" {
  description = "Generated cluster.yaml without the local keyfile path; the dump of the last run is in .local-runtime/kubemarine/<environment>"
  value       = yamlencode(local.cluster)
}
