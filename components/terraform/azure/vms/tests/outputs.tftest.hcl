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
  name                = "nodes"
  resource_group_name = "rg"
  subnet_ids          = { a = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/a" }
  ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICeTO2fHfUH3mH3AHcLdWKcWLFOtDcaTzcZE0SEVNmPm test"
  allowed_cidrs       = ["10.0.0.0/16"]
  vms = {
    cp-1 = { roles = ["control-plane", "worker"], instance_type = "Standard_D4s_v5", subnet = "a" }
  }
}

run "private" {
  assert {
    condition = jsonencode(output.vms) == jsonencode([{
      address          = "10.0.0.5"
      internal_address = "10.0.0.5"
      name             = "cp-1"
      roles            = ["control-plane", "worker"]
    }])
    error_message = "Unexpected vms output: ${jsonencode(output.vms)}"
  }

  assert {
    condition     = length(azurerm_public_ip.vm) == 0
    error_message = "A private group gets no public IPs"
  }
}

run "public" {
  variables {
    public = true
  }

  assert {
    condition     = output.vms[0].address == "203.0.113.5"
    error_message = "A public group reports its public address"
  }
}
