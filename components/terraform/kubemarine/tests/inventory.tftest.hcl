variables {
  environment         = "t-s"
  ssh_private_key     = "key"
  nexus_address       = "10.0.1.10"
  mirrored_registries = ["docker.io", "quay.io"]
  jump_host           = { address = "203.0.113.5" }
  nodes = [{
    name             = "cp-1"
    roles            = ["control-plane", "worker"]
    address          = "10.0.1.5"
    internal_address = "10.0.1.5"
  }]
  kubemarine = {
    cluster_name = "k8s.example.com"
    plugins      = { calico = { mode = "vxlan" } }
    services     = { cri = { containerRuntime = "containerd" } }
  }
}

run "inventory" {
  command = plan

  assert {
    condition = yamldecode(output.kubemarine_config) == {
      cluster_name  = "k8s.example.com"
      plugins       = { calico = { mode = "vxlan" } }
      node_defaults = { username = "ubuntu", gateway = "jump" }
      gateway_nodes = [{ name = "jump", address = "203.0.113.5", username = "ubuntu" }]
      nodes = [{
        name             = "cp-1"
        address          = "10.0.1.5"
        internal_address = "10.0.1.5"
        roles            = ["control-plane", "worker"]
      }]
      registry = {
        endpoints       = ["http://10.0.1.10:8082"]
        mirror_registry = "registry.cluster.local"
        thirdparties    = "http://10.0.1.10:8081/repository/bundle/files"
      }
      services = {
        packages = {
          package_manager = {
            replace-repositories = true
            repositories         = ["deb [trusted=yes] http://10.0.1.10:8081/repository/bundle/apt ./"]
          }
        }
        cri = {
          containerRuntime = "containerd"
          containerdRegistriesConfig = {
            for r in ["docker.io", "quay.io"] : r => {
              "host.\"http://10.0.1.10:8082/v2/${r}\"" = { capabilities = ["pull", "resolve"], override_path = true }
            }
          }
        }
      }
    }
    error_message = "Unexpected Kubemarine inventory: ${output.kubemarine_config}"
  }
}
