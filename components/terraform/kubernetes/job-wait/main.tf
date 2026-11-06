resource "kubernetes_namespace_v1" "example" {
  metadata {
    name = "job-wait"
  }
}

resource "kubernetes_job_v1" "example" {
  metadata {
    name      = "example-job"
    namespace = kubernetes_namespace_v1.example.metadata[0].name
  }

  wait_for_completion = true

  spec {
    completions             = 1
    backoff_limit           = 0
    active_deadline_seconds = 120

    template {
      metadata {
        labels = {
          app = "job-wait"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "task"
          image = "busybox:1.37"

          command = [
            "/bin/sh",
            "-c",
            "echo 'Task started'; sleep 30; echo 'Task completed'"
          ]
        }
      }
    }
  }

  timeouts {
    create = "5m"
  }
}