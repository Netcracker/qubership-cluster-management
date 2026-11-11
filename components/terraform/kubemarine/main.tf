locals {
  # Repository names and ports created by bundle/load.sh.
  nexus_files  = "http://${var.nexus_address}:8081/repository/bundle"
  nexus_images = "http://${var.nexus_address}:8082"

  cluster = merge(
    { cluster_name = "${var.environment}.local" },
    var.kubemarine,
    {
      node_defaults = merge(try(var.kubemarine.node_defaults, {}), { username = var.ssh_user, gateway = "jump" })
      gateway_nodes = [{ name = "jump", address = var.jump_host.address, username = var.ssh_user }]
      nodes = [
        for node in var.nodes : {
          name             = node.name
          address          = node.internal_address
          internal_address = node.internal_address
          roles            = node.roles
        }
      ]
      # Kubemarine's own images and binaries: <mirror>/kube-apiserver, <files>/kubernetes/kubeadm/..., see bundle/manifest.yaml.
      registry = {
        endpoints       = [local.nexus_images]
        mirror_registry = "registry.cluster.local"
        thirdparties    = "${local.nexus_files}/files"
      }
      services = merge(try(var.kubemarine.services, {}), {
        packages = merge(try(var.kubemarine.services.packages, {}), {
          package_manager = {
            replace-repositories = true
            repositories         = ["deb [trusted=yes] ${local.nexus_files}/apt ./"]
          }
        })
        cri = merge(try(var.kubemarine.services.cri, {}), {
          containerdRegistriesConfig = {
            for registry in var.mirrored_registries : registry => {
              "host.\"${local.nexus_images}/v2/${registry}\"" = { capabilities = ["pull", "resolve"], override_path = true }
            }
          }
        })
      })
    }
  )

  workdir = abspath("${path.root}/../../../.local-runtime/kubemarine/${var.environment}")
  keyfile = "${local.workdir}/id_ed25519"
}

# Runs once per environment: later inventory changes go through Kubemarine procedures (add_node, upgrade, ...);
# reinstall with -replace=terraform_data.install. Runs in the tools image, where kubemarine is installed.
resource "terraform_data" "install" {
  triggers_replace = [var.environment]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -eu
      mkdir -p '${local.workdir}' && cd '${local.workdir}'
      trap 'rm -f id_ed25519' EXIT
      (umask 077 && printf '%s\n' "$SSH_PRIVATE_KEY" > id_ed25519)
      printf '%s' "$CLUSTER_YAML" > cluster.yaml
      kubemarine install --config cluster.yaml
    EOT
    environment = {
      SSH_PRIVATE_KEY = var.ssh_private_key
      CLUSTER_YAML = yamlencode(merge(local.cluster, {
        node_defaults = merge(local.cluster.node_defaults, { keyfile = local.keyfile })
        gateway_nodes = [merge(local.cluster.gateway_nodes[0], { keyfile = local.keyfile })]
      }))
    }
  }
}
