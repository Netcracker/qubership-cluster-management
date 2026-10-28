output "cluster_name" { value = azurerm_kubernetes_cluster.main.name }
output "cluster_id" { value = azurerm_kubernetes_cluster.main.id }
output "resource_group_name" { value = var.resource_group_name }
output "cluster_endpoint" {
  # Floci currently labels user credentials as clusterAdmin, so the provider may omit kube_config.
  value     = try(azurerm_kubernetes_cluster.main.kube_config[0].host, "https://${azurerm_kubernetes_cluster.main.fqdn}")
  sensitive = true
}
