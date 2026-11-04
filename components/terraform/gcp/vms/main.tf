# ponytail: the private key sits in state; move it to Secret Manager once real projects are used.
resource "tls_private_key" "nodes" {
  algorithm = "ED25519"
}

locals {
  node_tag = "${var.environment}-node"
  jump_tag = "${var.environment}-jump"

  vms = merge(
    { for name, node in var.nodes : name => merge(node, { tag = local.node_tag }) },
    var.jump_host_enabled ? {
      jump = { roles = [], instance_type = "e2-small", subnet = keys(var.subnet_ids)[0], volume_size = 30, tag = local.jump_tag }
    } : {}
  )
}

# Kubernetes, etcd and the CNI (including IPIP/VXLAN) between nodes.
resource "google_compute_firewall" "internal" {
  name        = "${var.environment}-nodes-internal"
  network     = var.vpc_id
  source_tags = [local.node_tag]
  target_tags = [local.node_tag]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "ssh_from_jump" {
  name        = "${var.environment}-nodes-ssh"
  network     = var.vpc_id
  source_tags = [local.jump_tag]
  target_tags = [local.node_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "admin" {
  name          = "${var.environment}-nodes-admin"
  network       = var.vpc_id
  source_ranges = var.admin_cidrs
  target_tags   = [local.node_tag]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "6443"]
  }
}

resource "google_compute_firewall" "jump_ssh" {
  name          = "${var.environment}-jump-ssh"
  network       = var.vpc_id
  source_ranges = var.admin_cidrs
  target_tags   = [local.jump_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Nodes keep external IPs for outbound access to packages and images (the network has no Cloud NAT).
# ponytail: metadata ssh-keys is ignored when the project enforces OS Login.
resource "google_compute_instance" "vm" {
  for_each = local.vms

  name         = "${var.environment}-${each.key}"
  zone         = var.location
  machine_type = each.value.instance_type
  tags         = [each.value.tag]

  boot_disk {
    initialize_params {
      image = var.image
      size  = each.value.volume_size
    }
  }

  network_interface {
    subnetwork = var.subnet_ids[each.value.subnet]
    access_config {}
  }

  metadata = {
    ssh-keys = "ubuntu:${tls_private_key.nodes.public_key_openssh}"
  }

  labels = {
    environment = var.environment
    role        = each.key == "jump" ? "jump" : replace(join("_", each.value.roles), "-", "_")
    managed_by  = "terraform"
  }
}
