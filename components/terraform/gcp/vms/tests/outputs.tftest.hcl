mock_provider "google" {}

variables {
  environment    = "t-s"
  region         = "europe-west3"
  project_id     = "p"
  name           = "nodes"
  location       = "europe-west3-a"
  vpc_id         = "projects/p/global/networks/vpc"
  subnet_ids     = { main = "projects/p/regions/europe-west3/subnetworks/main" }
  ssh_public_key = "ssh-ed25519 AAAA"
  allowed_cidrs  = ["10.0.0.0/16"]
  vms = {
    cp-1 = { roles = ["control-plane", "worker"], instance_type = "e2-standard-4", subnet = "main" }
  }
}

run "private" {
  assert {
    condition     = length(google_compute_instance.vm["cp-1"].network_interface[0].access_config) == 0
    error_message = "A private group gets no external IP"
  }

  assert {
    condition     = output.vms[0].name == "cp-1" && google_compute_instance.vm["cp-1"].tags == toset(["t-s-nodes"])
    error_message = "VMs carry the group tag the firewall rules target"
  }
}

run "public" {
  variables {
    public = true
  }

  assert {
    condition     = length(google_compute_instance.vm["cp-1"].network_interface[0].access_config) == 1
    error_message = "A public group gets an external IP"
  }
}
