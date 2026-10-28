resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${var.environment}-aks"
  location            = var.region
  resource_group_name = var.resource_group_name
}
resource "azurerm_role_assignment" "network" {
  count                = var.manage_network_role_assignment ? 1 : 0
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}
resource "azurerm_kubernetes_cluster" "main" {
  name                              = "${var.environment}-aks"
  location                          = var.region
  resource_group_name               = var.resource_group_name
  dns_prefix                        = var.environment
  kubernetes_version                = var.kubernetes_version
  role_based_access_control_enabled = true
  default_node_pool {
    name           = "system"
    node_count     = var.node_count
    vm_size        = var.vm_size
    vnet_subnet_id = var.subnet_id
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }
  network_profile {
    network_plugin = "azure"
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }
  depends_on = [azurerm_role_assignment.network]
}
