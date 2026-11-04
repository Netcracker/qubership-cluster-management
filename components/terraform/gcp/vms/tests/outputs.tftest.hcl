mock_provider "google" {}

variables {
  environment = "t-s"
  region      = "europe-west3"
  project_id  = "p"
  location    = "europe-west3-a"
  vpc_id      = "projects/p/global/networks/vpc"
  subnet_ids  = { main = "projects/p/regions/europe-west3/subnetworks/main" }
  admin_cidrs = ["10.0.0.0/8"]
  nodes = {
    cp-1 = { roles = ["control-plane", "worker"], instance_type = "e2-standard-4", subnet = "main" }
  }
}

run "without_jump_host" {
  assert {
    condition     = length(output.nodes) == 1 && output.nodes[0].name == "cp-1" && output.jump_host == null
    error_message = "Unexpected outputs: ${jsonencode(output.nodes)}"
  }

  assert {
    condition     = google_compute_instance.vm["cp-1"].tags == toset(["t-s-node"])
    error_message = "Nodes must carry the node firewall tag"
  }
}

run "with_jump_host" {
  variables {
    jump_host_enabled = true
  }

  assert {
    condition     = output.jump_host.user == "ubuntu" && google_compute_instance.vm["jump"].tags == toset(["t-s-jump"])
    error_message = "jump_host_enabled must create the jump host with the jump firewall tag"
  }
}
