output "cluster_name" { value = google_container_cluster.main.name }
output "location" { value = google_container_cluster.main.location }
output "cluster_endpoint" { value = "https://${google_container_cluster.main.endpoint}" }
output "cluster_ca_data" {
  value     = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive = true
}
