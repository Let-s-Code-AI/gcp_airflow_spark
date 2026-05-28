resource "google_compute_network" "vpc" {
  name                    = "${var.course_name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.course_name}-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_router" "router" {
  name    = "${var.course_name}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.course_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ── Firewall ───────────────────────────────────────────────────────────────────

# SSH + UI (Airflow 8080, Spark 8080/7077/4040) dla instruktora
resource "google_compute_firewall" "allow_ui" {
  name    = "${var.course_name}-allow-ui"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22", "8080", "7077", "4040", "6443"]
  }

  source_ranges = [var.allowed_cidr]
  target_tags   = ["course-node"]
}

# komunikacja wewnętrzna między nodami K8s
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.course_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }

  source_tags = ["course-node"]
  target_tags = ["course-node"]
}
