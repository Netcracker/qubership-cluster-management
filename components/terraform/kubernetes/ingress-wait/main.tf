resource "kubernetes_ingress_v1" "nginx" {
  metadata {
    name      = "nginx-wait"
    namespace = "nginx-readiness"
  }

  spec {
    ingress_class_name = var.ingress_class_name

    default_backend {
      service {
        name = "nginx"

        port {
          number = 80
        }
      }
    }
  }

  wait_for_load_balancer = true

  timeouts {
    create = "5m"
  }
}