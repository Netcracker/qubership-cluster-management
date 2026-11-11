# Same output in every <cloud>/vms component; the kubemarine component and local/lab.sh consume it.
output "vms" {
  value = [
    for name, vm in var.vms : {
      name             = name
      roles            = vm.roles
      address          = var.public ? azurerm_public_ip.vm[name].ip_address : azurerm_linux_virtual_machine.vm[name].private_ip_address
      internal_address = azurerm_linux_virtual_machine.vm[name].private_ip_address
    }
  ]
}
