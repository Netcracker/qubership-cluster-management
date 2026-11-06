# A group of VMs (cluster nodes, Nexus or the jump host): each group is its own Atmos component and state.
# VNet traffic (Kubernetes, etcd, SSH from the jump host) passes the default NSG rules; Azure drops IPIP,
# so Calico must use VXLAN.
resource "azurerm_network_security_group" "main" {
  name                = "${var.environment}-${var.name}"
  location            = var.region
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "ports"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = [for port in var.ports : tostring(port)]
    source_address_prefixes    = var.allowed_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "vm" {
  for_each = var.public ? var.vms : {}

  name                = "${var.environment}-${each.key}"
  location            = var.region
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "vm" {
  for_each = var.vms

  name                = "${var.environment}-${each.key}"
  location            = var.region
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "main"
    subnet_id                     = var.subnet_ids[each.value.subnet]
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.public ? azurerm_public_ip.vm[each.key].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  for_each = var.vms

  network_interface_id      = azurerm_network_interface.vm[each.key].id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = var.vms

  name                  = "${var.environment}-${each.key}"
  location              = var.region
  resource_group_name   = var.resource_group_name
  size                  = each.value.instance_type
  admin_username        = "ubuntu"
  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  admin_ssh_key {
    username   = "ubuntu"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = each.value.volume_size
  }

  source_image_reference {
    publisher = var.image.publisher
    offer     = var.image.offer
    sku       = var.image.sku
    version   = var.image.version
  }

  tags = {
    Environment = var.environment
    Role        = join(",", concat([var.name], each.value.roles))
    ManagedBy   = "terraform"
  }
}
