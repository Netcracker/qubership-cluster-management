# Читаем Service консоли MinIO.
data "kubernetes_service_v1" "minio_console" {
  metadata {
    name      = "minio-console"
    namespace = "storage"
  }
}

locals {
  minio_console_node_port = one([
    for port in data.kubernetes_service_v1.minio_console.spec[0].port :
    port.node_port
    if port.name == "http"
  ])
}

# Разрешаем балансировщику обращаться к NodePort консоли.
resource "aws_vpc_security_group_egress_rule" "minio_console" {
  security_group_id = aws_security_group.alb.id

  ip_protocol = "tcp"
  from_port   = local.minio_console_node_port
  to_port     = local.minio_console_node_port
  cidr_ipv4   = "0.0.0.0/0"
}

# Создаём группу целей для консоли.
resource "aws_lb_target_group" "minio_console" {
  name        = "${var.environment}-minio-ip"
  vpc_id      = var.vpc_id
  target_type = "ip"

  protocol = "HTTP"
  port     = local.minio_console_node_port

  health_check {
    protocol = "HTTP"
    port     = "traffic-port"
    path     = "/"
    matcher  = "200"
  }
}

# Подключаем IP ноды и прочитанный NodePort.
resource "aws_lb_target_group_attachment" "minio_console" {
  target_group_arn  = aws_lb_target_group.minio_console.arn
  target_id         = data.aws_instance.node.private_ip
  port              = local.minio_console_node_port
  availability_zone = "all"
}

# Запросы с именем minio.localhost направляем в консоль.
resource "aws_lb_listener_rule" "minio_console" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.minio_console.arn
  }

  condition {
    host_header {
      values = ["minio.localhost"]
    }
  }
}

output "minio_console_node_port" {
  value = local.minio_console_node_port
}