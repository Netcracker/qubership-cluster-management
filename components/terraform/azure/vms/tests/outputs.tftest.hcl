mock_provider "azurerm" {
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/ip", ip_address = "203.0.113.5" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { private_ip_address = "10.0.0.5" }
  }
}

variables {
  environment         = "t-s"
  region              = "northeurope"
  resource_group_name = "rg"
  subnet_ids          = { a = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/a" }
  admin_cidrs         = ["10.0.0.0/8"]
  nodes = {
    cp-1 = { roles = ["control-plane", "worker"], instance_type = "Standard_D4s_v5", subnet = "a" }
  }
}

run "without_jump_host" {
  assert {
    condition = jsonencode(output.nodes) == jsonencode([{
      address          = "203.0.113.5"
      internal_address = "10.0.0.5"
      name             = "cp-1"
      roles            = ["control-plane", "worker"]
    }])
    error_message = "Unexpected nodes output: ${jsonencode(output.nodes)}"
  }

  assert {
    condition     = output.jump_host == null && length(azurerm_linux_virtual_machine.vm) == 1
    error_message = "Jump host must exist only while jump_host_enabled is true"
  }
}

run "with_jump_host" {
  variables {
    jump_host_enabled = true
  }

  assert {
    condition     = output.jump_host == { address = "203.0.113.5", user = "ubuntu" }
    error_message = "jump_host_enabled must create the jump host"
  }

}
