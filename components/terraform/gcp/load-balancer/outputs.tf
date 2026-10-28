output "ip_address" { value = google_compute_address.main.address }
output "load_balancer_id" { value = google_compute_forwarding_rule.main.id }
