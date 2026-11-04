# ponytail: the private key sits in state; move it to a secret manager once real accounts are used.
resource "tls_private_key" "nodes" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "nodes" {
  key_name   = "${var.environment}-nodes"
  public_key = tls_private_key.nodes.public_key_openssh
}

resource "aws_security_group" "nodes" {
  name        = "${var.environment}-nodes"
  description = "Cluster nodes: free traffic inside the group, admin ports from outside"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "outbound" {
  security_group_id = aws_security_group.nodes.id

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

# Kubernetes, etcd and the CNI (including IPIP/VXLAN) between nodes.
resource "aws_vpc_security_group_ingress_rule" "internal" {
  security_group_id = aws_security_group.nodes.id

  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
}

# SSH only from the jump host; nodes keep public IPs because the subnets have no NAT.
resource "aws_vpc_security_group_ingress_rule" "ssh_from_jump" {
  security_group_id = aws_security_group.nodes.id

  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.jump.id
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  for_each = {
    for pair in setproduct([80, 443, 6443], var.admin_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.nodes.id

  ip_protocol = "tcp"
  from_port   = each.value.port
  to_port     = each.value.port
  cidr_ipv4   = each.value.cidr
}

resource "aws_instance" "node" {
  for_each = var.nodes

  ami                         = var.ami_id
  instance_type               = each.value.instance_type
  subnet_id                   = var.subnet_ids[each.value.subnet]
  key_name                    = aws_key_pair.nodes.key_name
  associate_public_ip_address = true

  vpc_security_group_ids = [aws_security_group.nodes.id]

  root_block_device {
    volume_size = each.value.volume_size
  }

  tags = {
    Name        = "${var.environment}-${each.key}"
    Environment = var.environment
    Role        = join(",", each.value.roles)
    ManagedBy   = "terraform"
  }

  depends_on = [
    aws_vpc_security_group_egress_rule.outbound
  ]
}

# Ephemeral jump host for the kubemarine component: jump_host_enabled=true creates it, false destroys it.
resource "aws_security_group" "jump" {
  name        = "${var.environment}-jump"
  description = "Kubemarine jump host: SSH from admins"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "jump_outbound" {
  security_group_id = aws_security_group.jump.id

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "jump_ssh" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.jump.id

  ip_protocol = "tcp"
  from_port   = 22
  to_port     = 22
  cidr_ipv4   = each.value
}

resource "aws_instance" "jump" {
  count = var.jump_host_enabled ? 1 : 0

  ami                         = var.ami_id
  instance_type               = "t3.small"
  subnet_id                   = values(var.subnet_ids)[0]
  key_name                    = aws_key_pair.nodes.key_name
  associate_public_ip_address = true

  vpc_security_group_ids = [aws_security_group.jump.id]

  tags = {
    Name        = "${var.environment}-jump"
    Environment = var.environment
    Role        = "jump"
    ManagedBy   = "terraform"
  }

  depends_on = [
    aws_vpc_security_group_egress_rule.jump_outbound
  ]
}
