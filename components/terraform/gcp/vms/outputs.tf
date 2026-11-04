# Same outputs in every <cloud>/vms component; the kubemarine component consumes them.
output "nodes" {
  value = [
    for name, node in var.nodes : {
      name             = name
      roles            = node.roles
      address          = google_compute_instance.vm[name].network_interface[0].access_config[0].nat_ip
      internal_address = google_compute_instance.vm[name].network_interface[0].network_ip
    }
  ]
}

output "jump_host" {
  value = var.jump_host_enabled ? { address = google_compute_instance.vm["jump"].network_interface[0].access_config[0].nat_ip, user = "ubuntu" } : null
}

output "ssh_private_key" {
  description = "Key for the ubuntu user on the jump host and the nodes"
  value       = tls_private_key.nodes.private_key_openssh
  sensitive   = true
}
