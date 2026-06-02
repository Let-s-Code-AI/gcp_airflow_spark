resource "google_storage_bucket" "dags" {
  name          = local.dag_bucket
  location      = var.region
  force_destroy = true # łatwe czyszczenie po kursie

  uniform_bucket_level_access = true
  depends_on                  = [google_project_service.apis]
}

# Folder per analityk
resource "google_storage_bucket_object" "analityk_dag_folders" {
  for_each = toset(var.analitycy)
  name     = "dags/${each.key}/.keep"
  bucket   = google_storage_bucket.dags.name
  content  = " "
}

# Bucket bootstrapowy — master zapisuje tu join-command, workerzy go pobierają
resource "google_storage_bucket" "bootstrap" {
  name          = local.join_bucket
  location      = var.region
  force_destroy = true
  depends_on    = [google_project_service.apis]
}

# ── IAM: VM SA ma dostęp do obu bucketów ──────────────────────────────────────
resource "google_storage_bucket_iam_member" "dags_rw" {
  bucket = google_storage_bucket.dags.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm_sa.email}"
}

resource "google_storage_bucket_iam_member" "bootstrap_rw" {
  bucket = google_storage_bucket.bootstrap.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm_sa.email}"
}
