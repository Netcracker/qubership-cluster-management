resource "kubernetes_namespace_v1" "nginx" {
  metadata {
    name = "nginx-readiness"
  }
}

resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.nginx.metadata[0].name
  }

  wait_for_rollout = true

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "nginx-readiness"
      }
    }

    template {
      metadata {
        labels = {
          app = "nginx-readiness"
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:1.28-alpine"

          port {
            container_port = 80
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }

            initial_delay_seconds = 20
            period_seconds        = 5
            timeout_seconds       = 2
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }

            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
  }
}

resource "kubernetes_service_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.nginx.metadata[0].name
  }

  spec {
    selector = {
      app = "nginx-readiness"
    }

    port {
      port        = 80
      target_port = 80
    }

    type = "ClusterIP"
  }
}
