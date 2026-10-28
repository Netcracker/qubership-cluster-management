
# Разрешаем балансировщику обращаться к NodePort Headlamp.
resource "aws_vpc_security_group_egress_rule" "headlamp" {
  security_group_id = aws_security_group.alb.id

  ip_protocol = "tcp"
  from_port   = var.headlamp_node_port
  to_port     = var.headlamp_node_port
  cidr_ipv4   = "0.0.0.0/0"
}

# Группа целей для Headlamp.
resource "aws_lb_target_group" "headlamp" {
  name        = "${var.environment}-headlamp-ip"
  vpc_id      = var.vpc_id
  target_type = "ip"

  protocol = "HTTP"
  port     = var.headlamp_node_port

  health_check {
    protocol = "HTTP"
    port     = "traffic-port"
    path     = "/"
    matcher  = "200-399"
  }
}

# Регистрируем IP ноды и NodePort.
resource "aws_lb_target_group_attachment" "headlamp" {
  target_group_arn  = aws_lb_target_group.headlamp.arn
  target_id         = data.aws_instance.node.private_ip
  port              = var.headlamp_node_port
  availability_zone = "all"
}

# Запросы к headlamp.localhost направляем в Headlamp.
resource "aws_lb_listener_rule" "headlamp" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 2

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.headlamp.arn
  }

  condition {
    host_header {
      values = ["headlamp.localhost"]
    }
  }
}

output "headlamp_node_port" {
  value = var.headlamp_node_port
}