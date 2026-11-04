output "vpc_id" { value = google_compute_network.main.id }
output "vpc_cidr" { value = google_compute_subnetwork.main.ip_cidr_range }
output "subnet_id" { value = google_compute_subnetwork.main.id }
output "subnet_ids" { value = { main = google_compute_subnetwork.main.id } }
