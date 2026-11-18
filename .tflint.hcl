# Konfiguracja TFLint — uruchamiana z katalogu terraform/:
#   tflint --init --config=../.tflint.hcl
#   tflint --config=../.tflint.hcl
tflint {
  required_version = ">= 0.66"
}

config {
  call_module_type = "local"
}

plugin "google" {
  enabled = true
  version = "0.41.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
