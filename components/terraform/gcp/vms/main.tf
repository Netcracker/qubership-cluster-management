# A group of VMs (cluster nodes, Nexus or the jump host): each group is its own Atmos component and state.
# Without public = true a VM gets no external IP and, as the network has no Cloud NAT, no Internet access.
locals {
  tag = "${var.environment}-${var.name}"
}

# Kubernetes, etcd and the CNI (including IPIP/VXLAN) inside the group.
resource "google_compute_firewall" "internal" {
  name        = "${local.tag}-internal"
  network     = var.vpc_id
  source_tags = [local.tag]
  target_tags = [local.tag]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "ports" {
  name          = "${local.tag}-ports"
  network       = var.vpc_id
  source_ranges = var.allowed_cidrs
  target_tags   = [local.tag]

  allow {
    protocol = "tcp"
    ports    = [for port in var.ports : tostring(port)]
  }
}

# ponytail: metadata ssh-keys is ignored when the project enforces OS Login.
resource "google_compute_instance" "vm" {
  for_each = var.vms

  name         = "${var.environment}-${each.key}"
  zone         = var.location
  machine_type = each.value.instance_type
  tags         = [local.tag]

  boot_disk {
    initialize_params {
      image = var.image
      size  = each.value.volume_size
    }
  }

  network_interface {
    subnetwork = var.subnet_ids[each.value.subnet]

    dynamic "access_config" {
      for_each = var.public ? [1] : []
      content {}
    }
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }

  labels = {
    environment = var.environment
    role        = replace(join("_", concat([var.name], each.value.roles)), "-", "_")
    managed_by  = "terraform"
  }
}
