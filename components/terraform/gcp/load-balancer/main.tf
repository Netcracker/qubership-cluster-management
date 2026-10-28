# Regional external passthrough TCP load balancer for explicitly supplied VM instances.
resource "google_compute_address" "main" {
  name   = "${var.environment}-lb"
  region = var.region
}
resource "google_compute_http_health_check" "main" {
  name         = "${var.environment}-lb"
  port         = var.health_check_port
  request_path = var.health_check_path
}
resource "google_compute_target_pool" "main" {
  name          = "${var.environment}-lb"
  region        = var.region
  instances     = var.backend_instances
  health_checks = [google_compute_http_health_check.main.id]
}
resource "google_compute_forwarding_rule" "main" {
  name        = "${var.environment}-lb"
  region      = var.region
  ip_address  = google_compute_address.main.address
  ip_protocol = "TCP"
  port_range  = var.port_range
  target      = google_compute_target_pool.main.id
}
