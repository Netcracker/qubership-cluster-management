# ponytail: the private key sits in state; move it to Key Vault once real subscriptions are used.
resource "tls_private_key" "nodes" {
  algorithm = "ED25519"
}

locals {
  vms = merge(
    { for name, node in var.nodes : name => merge(node, { nsg = "nodes" }) },
    var.jump_host_enabled ? {
      jump = { roles = [], instance_type = "Standard_B2s", subnet = keys(var.subnet_ids)[0], volume_size = 30, nsg = "jump" }
    } : {}
  )
}

# VNet traffic (Kubernetes, etcd, SSH from the jump host) is allowed by the default NSG rules;
# Internet traffic is denied except for the ports below. Azure drops IPIP, so Calico must use VXLAN.
resource "azurerm_network_security_group" "main" {
  for_each = {
    nodes = ["80", "443", "6443"]
    jump  = ["22"]
  }

  name                = "${var.environment}-${each.key}"
  location            = var.region
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = each.value
    source_address_prefixes    = var.admin_cidrs
    destination_address_prefix = "*"
  }
}

# Nodes keep public IPs for outbound access to packages and images.
resource "azurerm_public_ip" "vm" {
  for_each = local.vms

  name                = "${var.environment}-${each.key}"
  location            = var.region
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "vm" {
  for_each = local.vms

  name                = "${var.environment}-${each.key}"
  location            = var.region
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "main"
    subnet_id                     = var.subnet_ids[each.value.subnet]
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  for_each = local.vms

  network_interface_id      = azurerm_network_interface.vm[each.key].id
  network_security_group_id = azurerm_network_security_group.main[each.value.nsg].id
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.vms

  name                  = "${var.environment}-${each.key}"
  location              = var.region
  resource_group_name   = var.resource_group_name
  size                  = each.value.instance_type
  admin_username        = "ubuntu"
  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  admin_ssh_key {
    username   = "ubuntu"
    public_key = tls_private_key.nodes.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = each.value.volume_size
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = {
    Environment = var.environment
    Role        = each.key == "jump" ? "jump" : join(",", each.value.roles)
    ManagedBy   = "terraform"
  }
}
