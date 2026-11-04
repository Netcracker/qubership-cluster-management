locals {
  workdir = "/var/lib/kubemarine"

  cluster = merge(
    { cluster_name = "${var.environment}.local" },
    var.kubemarine,
    {
      node_defaults = merge({ username = "ubuntu" }, try(var.kubemarine.node_defaults, {}), { keyfile = "${local.workdir}/ssh_key" })
      nodes         = [for node in var.nodes : merge(node, { connect_to = node.internal_address })]
    }
  )
}

# Reinstalls only when the inventory or version changes; a new jump host alone does not trigger it.
resource "terraform_data" "install" {
  triggers_replace = [sha256(yamlencode(local.cluster)), var.kubemarine_version]

  connection {
    host        = try(var.jump_host.address, null)
    user        = try(var.jump_host.user, null)
    private_key = var.ssh_private_key
    timeout     = "10m"
  }

  provisioner "file" {
    content     = yamlencode(local.cluster)
    destination = "/tmp/cluster.yaml"
  }

  provisioner "file" {
    content     = var.ssh_private_key
    destination = "/tmp/kubemarine_ssh_key"
  }

  # ponytail: apt assumes a Debian/Ubuntu jump host; add a package-manager switch when another image is needed.
  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "cloud-init status --wait >/dev/null 2>&1 || true",
      "sudo install -d -o \"$(id -u)\" ${local.workdir}",
      "install -m 600 /tmp/kubemarine_ssh_key ${local.workdir}/ssh_key && rm /tmp/kubemarine_ssh_key",
      "mv /tmp/cluster.yaml ${local.workdir}/cluster.yaml",
      "sudo apt-get update -q && sudo apt-get -o DPkg::Lock::Timeout=180 install -y -q python3-venv",
      "python3 -m venv ${local.workdir}/venv",
      "${local.workdir}/venv/bin/pip install -q 'kubemarine==${var.kubemarine_version}'",
      "cd ${local.workdir} && venv/bin/kubemarine install --config cluster.yaml",
    ]
  }
}
