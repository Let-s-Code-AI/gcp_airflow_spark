output "master_external_ip" {
  description = "IP mastera — tutaj SSH i UI"
  value       = google_compute_instance.master.network_interface[0].access_config[0].nat_ip
}

output "master_internal_ip" {
  value = google_compute_instance.master.network_interface[0].network_ip
}

output "worker_internal_ips" {
  value = { for k, w in google_compute_instance.worker : "worker-${k} (${w.zone})" => w.network_interface[0].network_ip }
}

output "dag_bucket" {
  value = google_storage_bucket.dags.name
}

output "airflow_ui" {
  value = "http://${google_compute_instance.master.network_interface[0].access_config[0].nat_ip}:8080"
}

output "spark_master_ui" {
  value = "http://${google_compute_instance.master.network_interface[0].access_config[0].nat_ip}:8181"
}

output "ssh_command" {
  value = "ssh ubuntu@${google_compute_instance.master.network_interface[0].access_config[0].nat_ip}"
}
