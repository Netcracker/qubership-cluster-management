output "resource_group_name" { value = azurerm_resource_group.main.name }
output "vpc_id" { value = azurerm_virtual_network.main.id }
output "vpc_cidr" { value = var.vpc_cidr }
output "subnet_ids" { value = { for k, v in azurerm_subnet.main : k => v.id } }
