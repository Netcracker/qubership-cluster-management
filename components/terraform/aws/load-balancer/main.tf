resource "aws_security_group" "alb" {
  name        = "${var.environment}-argocd-alb"
  description = "Network access for the Argo CD ALB"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.alb.id

  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
  cidr_ipv4   = "0.0.0.0/0"
}


resource "aws_lb" "argocd" {
  name               = "${var.environment}-argocd"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb.id]
  subnets         = values(var.subnet_ids)

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}


data "aws_instance" "node" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }

  filter {
    name   = "tag:eks:cluster-name"
    values = ["${var.environment}-eks"]
  }
}


resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.argocd.arn

  protocol = "HTTP"
  port     = 80

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.argocd.arn
  }
}