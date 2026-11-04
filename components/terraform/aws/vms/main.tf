# A group of VMs (cluster nodes, Nexus or the jump host): each group is its own Atmos component and state.
resource "aws_key_pair" "main" {
  key_name   = "${var.environment}-${var.name}"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "main" {
  name        = "${var.environment}-${var.name}"
  description = "${var.name}: free traffic inside the group, listed ports from allowed CIDRs"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "outbound" {
  security_group_id = aws_security_group.main.id

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

# Kubernetes, etcd and the CNI (including IPIP/VXLAN) between nodes.
resource "aws_vpc_security_group_ingress_rule" "internal" {
  security_group_id = aws_security_group.main.id

  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.main.id
}

resource "aws_vpc_security_group_ingress_rule" "ports" {
  for_each = {
    for pair in setproduct(var.ports, var.allowed_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.main.id

  ip_protocol = "tcp"
  from_port   = each.value.port
  to_port     = each.value.port
  cidr_ipv4   = each.value.cidr
}

resource "aws_instance" "vm" {
  for_each = var.vms

  ami                         = var.ami_id
  instance_type               = each.value.instance_type
  subnet_id                   = var.subnet_ids[each.value.subnet]
  key_name                    = aws_key_pair.main.key_name
  associate_public_ip_address = var.public

  vpc_security_group_ids = [aws_security_group.main.id]

  root_block_device {
    volume_size = each.value.volume_size
  }

  tags = {
    Name        = "${var.environment}-${each.key}"
    Environment = var.environment
    Role        = join(",", concat([var.name], each.value.roles))
    ManagedBy   = "terraform"
  }

  depends_on = [
    aws_vpc_security_group_egress_rule.outbound
  ]
}
