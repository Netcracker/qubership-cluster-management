mock_provider "aws" {
  mock_resource "aws_instance" {
    defaults = { public_ip = "203.0.113.5", private_ip = "10.0.0.5" }
  }
}

variables {
  environment    = "t-s"
  name           = "nodes"
  vpc_id         = "vpc-1"
  subnet_ids     = { a = "subnet-a" }
  ami_id         = "ami-1"
  ssh_public_key = "ssh-ed25519 AAAA"
  ports          = [22, 6443]
  allowed_cidrs  = ["10.0.0.0/16"]
  vms = {
    cp-1 = { roles = ["control-plane", "worker"], instance_type = "m5.large", subnet = "a" }
  }
}

run "private" {
  assert {
    condition = jsonencode(output.vms) == jsonencode([{
      address          = "10.0.0.5"
      internal_address = "10.0.0.5"
      name             = "cp-1"
      roles            = ["control-plane", "worker"]
    }])
    error_message = "Unexpected vms output: ${jsonencode(output.vms)}"
  }

  assert {
    condition     = !aws_instance.vm["cp-1"].associate_public_ip_address && length(aws_vpc_security_group_ingress_rule.ports) == 2
    error_message = "A private group gets no public IP and one rule per port and CIDR"
  }
}

run "public" {
  variables {
    public = true
  }

  assert {
    condition     = output.vms[0].address == "203.0.113.5"
    error_message = "A public group reports its public address"
  }
}
