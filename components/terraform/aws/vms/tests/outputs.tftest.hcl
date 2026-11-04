mock_provider "aws" {
  mock_resource "aws_instance" {
    defaults = { public_ip = "", private_ip = "10.0.0.5" }
  }
}

variables {
  tenant      = "t"
  stage       = "s"
  environment = "t-s"
  vpc_id      = "vpc-1"
  subnet_ids  = { a = "subnet-a" }
  ami_id      = "ami-1"
  admin_cidrs = ["10.0.0.0/8"]
  nodes = {
    cp-1 = { roles = ["control-plane", "worker"], instance_type = "m5.large", subnet = "a" }
  }
}

run "without_jump_host" {
  assert {
    condition = jsonencode(output.nodes) == jsonencode([{
      address          = "10.0.0.5"
      internal_address = "10.0.0.5"
      name             = "cp-1"
      roles            = ["control-plane", "worker"]
    }])
    error_message = "Unexpected nodes output: ${jsonencode(output.nodes)}"
  }

  assert {
    condition     = output.jump_host == null
    error_message = "Jump host must exist only while jump_host_enabled is true"
  }
}

run "with_jump_host" {
  variables {
    jump_host_enabled = true
  }

  assert {
    condition     = output.jump_host == { address = "", user = "ubuntu" }
    error_message = "jump_host_enabled must create the jump host"
  }
}
