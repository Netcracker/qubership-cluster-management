resource "azurerm_resource_group" "main" {
  name     = "${var.environment}-rg"
  location = var.region
}
resource "azurerm_virtual_network" "main" {
  name                = "${var.environment}-vnet"
  location            = var.region
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vpc_cidr]
}
resource "azurerm_subnet" "main" {
  for_each             = var.subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [each.value.cidr_block]
}
