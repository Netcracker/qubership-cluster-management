# Same outputs in every <cloud>/vms component; the kubemarine component consumes them.
output "nodes" {
  value = [
    for name, node in var.nodes : {
      name             = name
      roles            = node.roles
      address          = coalesce(aws_instance.node[name].public_ip, aws_instance.node[name].private_ip)
      internal_address = aws_instance.node[name].private_ip
    }
  ]
}

output "jump_host" {
  value = var.jump_host_enabled ? { address = aws_instance.jump[0].public_ip, user = "ubuntu" } : null
}

output "ssh_private_key" {
  description = "Key for the ubuntu user on the jump host and the nodes"
  value       = tls_private_key.nodes.private_key_openssh
  sensitive   = true
}
