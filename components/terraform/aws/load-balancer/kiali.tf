# Разрешаем балансировщику обращаться к NodePort Kiali.
resource "aws_vpc_security_group_egress_rule" "kiali" {
  security_group_id = aws_security_group.alb.id

  ip_protocol = "tcp"
  from_port   = local.kiali_node_port
  to_port     = local.kiali_node_port
  cidr_ipv4   = "0.0.0.0/0"
}

# Отдельная группа целей для Kiali.
resource "aws_lb_target_group" "kiali" {
  name        = "${var.environment}-kiali-ip"
  vpc_id      = var.vpc_id
  target_type = "ip"

  protocol = "HTTP"
  port     = local.kiali_node_port

  health_check {
    protocol = "HTTP"
    port     = "traffic-port"
    path     = "/healthz"
    matcher  = "200"
  }
}

# Регистрируем IP нашей ноды и порт Kiali в этой группе.
resource "aws_lb_target_group_attachment" "kiali" {
  target_group_arn  = aws_lb_target_group.kiali.arn
  target_id         = data.aws_instance.node.private_ip
  port              = local.kiali_node_port
  availability_zone = "all"
}

# Запросы к /kiali направляем в группу Kiali.
resource "aws_lb_listener_rule" "kiali" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kiali.arn
  }

  condition {
    host_header {
      values = ["kiali.localhost"]
    }
  }
}

/// Получаем информацию о сервисе Kiali в Kubernetes.

data "kubernetes_service_v1" "kiali" {
  metadata {
    name      = "kiali"
    namespace = "istio-system"
  }
}

// Получаем NodePort сервиса Kiali в Kubernetes.
locals {
  kiali_node_port = one([
    for port in data.kubernetes_service_v1.kiali.spec[0].port :
    port.node_port
    if port.name == "http"
  ])
}

// Выводим NodePort сервиса Kiali.
output "kiali_node_port" {
  value = local.kiali_node_port
}