resource "google_service_account" "vm_sa" {
  account_id   = "${var.course_name}-vm"
  display_name = "Course VM SA"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "vm_sa_roles" {
  for_each = toset([
    "roles/storage.objectAdmin",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.vm_sa.email}"
}

locals {
  ssh_pub_key = file(pathexpand(var.ssh_pub_key_path))
  common_metadata = {
    ssh-keys               = "ubuntu:${local.ssh_pub_key}"
    block-project-ssh-keys = "true"
  }
}

# ── Control plane ─────────────────────────────────────────────────────────────
resource "google_compute_instance" "master" {
  name         = "${var.course_name}-master"
  machine_type = var.master_machine_type
  zone         = var.zone
  tags         = ["course-node"]

  scheduling {
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {} # publiczne IP do SSH od instruktora
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = merge(local.common_metadata, {
    startup-script = templatefile("${path.module}/../scripts/master-init.sh", {
      project_id    = var.project_id
      join_bucket   = local.join_bucket
      dag_bucket    = local.dag_bucket
      students_json = jsonencode(var.students)
    })
  })

  depends_on = [
    google_storage_bucket.bootstrap,
    google_storage_bucket.dags,
    google_project_iam_member.vm_sa_roles,
  ]
}

# ── Worker nodes (Spark + Airflow workery) ────────────────────────────────────
resource "google_compute_instance" "worker" {
  count        = 2
  name         = "${var.course_name}-worker-${count.index + 1}"
  machine_type = var.worker_machine_type
  zone         = var.zone
  tags         = ["course-node"]

  scheduling {
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 100 # miejsce dla Spark shuffle i danych
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # bez publicznego IP — dostęp przez NAT lub SSH przez mastera
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = merge(local.common_metadata, {
    startup-script = templatefile("${path.module}/../scripts/worker-join.sh", {
      join_bucket = local.join_bucket
      worker_id   = count.index + 1
    })
  })

  depends_on = [google_compute_instance.master]
}
