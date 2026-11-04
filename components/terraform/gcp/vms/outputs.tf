# Same output in every <cloud>/vms component; the kubemarine component and local/lab.sh consume it.
output "vms" {
  value = [
    for name, vm in var.vms : {
      name             = name
      roles            = vm.roles
      address          = var.public ? google_compute_instance.vm[name].network_interface[0].access_config[0].nat_ip : google_compute_instance.vm[name].network_interface[0].network_ip
      internal_address = google_compute_instance.vm[name].network_interface[0].network_ip
    }
  ]
}
