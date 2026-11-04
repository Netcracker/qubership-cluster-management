locals {
  nexus_readiness_endpoint = var.nexus_readiness_url != null ? var.nexus_readiness_url : "http://${coalesce(aws_instance.nexus.public_ip, aws_instance.nexus.private_ip)}:8081/service/rest/v1/status/writable"
}

data "http" "nexus_ready" {
  count = var.nexus_wait_for_ready ? 1 : 0

  url                = local.nexus_readiness_endpoint
  request_timeout_ms = 5000

  retry {
    attempts     = 60
    min_delay_ms = 10000
    max_delay_ms = 10000
  }

  depends_on = [
    aws_instance.nexus,
    aws_vpc_security_group_ingress_rule.nexus_http
  ]

  lifecycle {
    precondition {
      condition     = var.local_endpoint == null || var.nexus_readiness_url != null
      error_message = "The local workflow must resolve Floci's published URL after VM creation."
    }

    postcondition {
      condition     = self.status_code == 200
      error_message = "Nexus readiness endpoint must return HTTP 200."
    }
  }
}
