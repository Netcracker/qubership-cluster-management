output "vpc_id" { value = google_compute_network.main.id }
output "subnet_id" { value = google_compute_subnetwork.main.id }
output "subnet_ids" { value = { main = google_compute_subnetwork.main.id } }
