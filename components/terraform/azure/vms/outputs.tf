# Same outputs in every <cloud>/vms component; the kubemarine component consumes them.
output "nodes" {
  value = [
    for name, node in var.nodes : {
      name             = name
      roles            = node.roles
      address          = azurerm_public_ip.vm[name].ip_address
      internal_address = azurerm_linux_virtual_machine.vm[name].private_ip_address
    }
  ]
}

output "jump_host" {
  value = var.jump_host_enabled ? { address = azurerm_public_ip.vm["jump"].ip_address, user = "ubuntu" } : null
}

output "ssh_private_key" {
  description = "Key for the ubuntu user on the jump host and the nodes"
  value       = tls_private_key.nodes.private_key_openssh
  sensitive   = true
}
