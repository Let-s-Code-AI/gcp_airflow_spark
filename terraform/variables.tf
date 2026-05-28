variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-west1-b"
}

variable "course_name" {
  type    = string
  default = "airflow-spark-course"
}

variable "students" {
  description = "Lista loginów studentów — tworzone jako konta Airflow"
  type        = list(string)
  default = [
    "student01", "student02", "student03", "student04",
    "student05", "student06", "student07", "student08",
    "student09", "student10", "student11", "student12",
    "student13", "student14", "student15", "student16"
  ]
}

# control-plane: potrzebuje tylko zarządzać klastrem, nie uruchamia podów
variable "master_machine_type" {
  type    = string
  default = "e2-standard-2" # 2 vCPU, 8 GB
}

# workerzy: Airflow workery + Spark executory
variable "worker_machine_type" {
  type    = string
  default = "e2-standard-4" # 4 vCPU, 16 GB × 2 nody = 8 vCPU / 32 GB łącznie
}

variable "allowed_cidr" {
  description = "CIDR skąd dostęp do UI (np. IP sali/instruktora). 0.0.0.0/0 = wszyscy."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_pub_key_path" {
  description = "Ścieżka do publicznego klucza SSH"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}
