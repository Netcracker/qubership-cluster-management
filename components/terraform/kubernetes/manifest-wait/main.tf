resource "kubernetes_namespace_v1" "example" {
  metadata {
    name = "manifest-wait"
  }
}

resource "kubernetes_manifest" "nginx" {
  manifest = {
    apiVersion = "v1"
    kind       = "Pod"

    metadata = {
      name      = "example-pod"
      namespace = kubernetes_namespace_v1.example.metadata[0].name

      annotations = {
        "test.terraform.io" = "test"
      }

      labels = {
        app = "nginx"
      }
    }

    spec = {
      containers = [
        {
          name  = "nginx"
          image = "nginx:1.28-alpine"

          readinessProbe = {
            initialDelaySeconds = 10

            httpGet = {
              path = "/"
              port = 80
            }
          }
        }
      ]
    }
  }

  wait {
    fields = {
      "metadata.annotations[\"test.terraform.io\"]" = "^test$"
      "status.containerStatuses[0].restartCount"   = "^0$"
      "status.containerStatuses[0].ready"          = "^true$"
      "status.podIP"                              = "^(\\d+(\\.|$)){4}"
      "status.phase"                              = "^Running$"
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
    delete = "2m"
  }
}