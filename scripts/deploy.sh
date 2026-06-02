#!/bin/bash
set -euo pipefail

# Skrypt do odpalenia całego kursu
# Użycie: ./scripts/deploy.sh <project_id>

PROJECT_ID=${1:-""}
if [[ -z "$PROJECT_ID" ]]; then
  echo "Użycie: $0 <gcp-project-id>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "==> Deploy dla projektu: $PROJECT_ID"

cd "$TF_DIR"
terraform init
terraform apply \
  -var="project_id=$PROJECT_ID" \
  -auto-approve

echo ""
echo "==> Czekam na zakończenie inicjalizacji (~8-12 min)..."
MASTER_IP=$(terraform output -raw master_external_ip)

for i in $(seq 1 40); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$MASTER_IP" \
    "grep -q 'SETUP ZAKOŃCZONY' /var/log/master-init.log" 2>/dev/null; then
    break
  fi
  echo "  Czekam... ($i/40)"
  sleep 20
done

echo ""
echo "===================================="
echo "Klaster gotowy!"
terraform output
echo "===================================="
echo "Airflow admin: admin / admin"
echo "Analitycy: analityk01-16 / analitykXXPass123!"
