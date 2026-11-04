variables {
  environment     = "t-s"
  ssh_private_key = "key"
  nodes = [{
    name             = "cp-1"
    roles            = ["control-plane", "worker"]
    address          = "203.0.113.5"
    internal_address = "10.0.0.5"
  }]
  kubemarine = {
    cluster_name  = "k8s.example.com"
    node_defaults = { keyfile = "/ignored" }
    plugins       = { calico = { mode = "vxlan" } }
  }
}

run "inventory" {
  command = plan

  assert {
    condition = yamldecode(output.kubemarine_config) == {
      cluster_name  = "k8s.example.com"
      node_defaults = { username = "ubuntu", keyfile = "/var/lib/kubemarine/ssh_key" }
      plugins       = { calico = { mode = "vxlan" } }
      nodes = [{
        name             = "cp-1"
        roles            = ["control-plane", "worker"]
        address          = "203.0.113.5"
        internal_address = "10.0.0.5"
        connect_to       = "10.0.0.5"
      }]
    }
    error_message = "Unexpected Kubemarine inventory: ${output.kubemarine_config}"
  }
}
