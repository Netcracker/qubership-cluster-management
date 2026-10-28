resource "azurerm_public_ip" "main" {
  name                = "${var.environment}-lb"
  location            = var.region
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_lb" "main" {
  name                = "${var.environment}-lb"
  location            = var.region
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.main.id
  }
}
resource "azurerm_lb_backend_address_pool" "main" {
  name            = "backends"
  loadbalancer_id = azurerm_lb.main.id
}
resource "azurerm_lb_backend_address_pool_address" "main" {
  for_each                = var.backend_addresses
  name                    = each.key
  backend_address_pool_id = azurerm_lb_backend_address_pool.main.id
  virtual_network_id      = var.vpc_id
  ip_address              = each.value
}
resource "azurerm_lb_probe" "main" {
  name            = "tcp"
  loadbalancer_id = azurerm_lb.main.id
  protocol        = "Tcp"
  port            = var.backend_port
}
resource "azurerm_lb_rule" "main" {
  name                           = "tcp"
  loadbalancer_id                = azurerm_lb.main.id
  protocol                       = "Tcp"
  frontend_port                  = var.frontend_port
  backend_port                   = var.backend_port
  frontend_ip_configuration_name = "public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.main.id
}
