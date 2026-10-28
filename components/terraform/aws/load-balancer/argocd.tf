resource "aws_lb_target_group" "argocd" {
  name        = "${var.environment}-argocd-ip"
  vpc_id      = var.vpc_id
  target_type = "ip"

  protocol = "HTTP"
  port     = local.argocd_node_port

  health_check {
    protocol = "HTTP"
    port     = "traffic-port"
    path     = "/healthz"
    matcher  = "200"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "argocd" {
  target_group_arn  = aws_lb_target_group.argocd.arn
  target_id         = data.aws_instance.node.private_ip
  port              = local.argocd_node_port
  availability_zone = "all"
}

resource "aws_vpc_security_group_egress_rule" "argocd" {
  security_group_id = aws_security_group.alb.id

  ip_protocol = "tcp"
  from_port   = local.argocd_node_port
  to_port     = local.argocd_node_port
  cidr_ipv4   = "0.0.0.0/0"
}

# Запросы к /argocd направляем в группу Argo CD.
resource "aws_lb_listener_rule" "argocd" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.argocd.arn
  }

  condition {
    host_header {
      values = ["argocd.localhost"]
    }
  }
}


data "kubernetes_service_v1" "argocd" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
}

locals {
  argocd_node_port = one([
    for port in data.kubernetes_service_v1.argocd.spec[0].port :
    port.node_port
    if port.name == "http"
  ])
}

output "argocd_node_port" {
  value = local.argocd_node_port
}
