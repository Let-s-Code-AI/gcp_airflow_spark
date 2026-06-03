#!/usr/bin/env bash
# Skrypt do przełączania ruchu między slotami green i blue dla Airflow.
# Obsługuje: sprawdzenie stanu, przełączenie, rollback, deploy.
#
# Użycie:
#   ./green-blue-switch.sh status          — pokaż aktywny slot i stan podów
#   ./green-blue-switch.sh switch blue     — przełącz na blue (zero downtime)
#   ./green-blue-switch.sh switch green    — rollback na green (< 1 sek)
#   ./green-blue-switch.sh deploy blue     — wdróż nową wersję w slocie blue
#   ./green-blue-switch.sh rollback        — cofnij do poprzedniego slotu

set -euo pipefail

NAMESPACE="airflow"
SERVICE="airflow-active"
CHART_REPO="apache-airflow/airflow"
CHART_VERSION="1.15.0"
HELM_VALUES_DIR="$(cd "$(dirname "$0")/../helm/airflow" && pwd)"

# ── Kolory ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${NC}[$(date +%H:%M:%S)] $*${NC}"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── Pomocnicze funkcje ─────────────────────────────────────────────────────────

active_slot() {
  kubectl get svc "$SERVICE" -n "$NAMESPACE" \
    -o jsonpath='{.spec.selector.slot}' 2>/dev/null || echo "nieznany"
}

standby_slot() {
  [[ "$(active_slot)" == "green" ]] && echo "blue" || echo "green"
}

# Szuka deploymentu po etykiecie slot= i component= — niezależne od nazwy release'u
deployment_for() {
  local slot="$1" component="$2"
  kubectl get deployment -n "$NAMESPACE" \
    -l "slot=${slot},component=${component}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

webserver_ready() {
  local slot="$1"
  local deploy
  deploy=$(deployment_for "$slot" "webserver")
  [[ -z "$deploy" ]] && return 1
  local ready
  ready=$(kubectl get deployment "$deploy" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [[ "${ready:-0}" -ge 1 ]]
}

# ── Komendy ───────────────────────────────────────────────────────────────────

cmd_status() {
  local active
  active=$(active_slot)

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║        GREEN-BLUE STATUS — Airflow           ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  printf "  Service:      %s (NodePort 30080)\n" "$SERVICE"
  printf "  Aktywny slot: "
  if [[ "$active" == "green" ]]; then
    echo -e "${GREEN}● GREEN${NC}"
  else
    echo -e "${BLUE}● BLUE${NC}"
  fi
  echo ""

  for slot in green blue; do
    local marker=""
    [[ "$slot" == "$active" ]] && marker=" ← PRODUKCJA" || marker=" (standby)"

    printf "  [%s]%s\n" "$(echo "$slot" | tr '[:lower:]' '[:upper:]')" "$marker"

    local ws_deploy sched_deploy
    ws_deploy=$(deployment_for "$slot" "webserver")
    sched_deploy=$(deployment_for "$slot" "scheduler")

    if [[ -n "$ws_deploy" ]]; then
      local version ws_ready sched_ready
      version=$(kubectl get deployment "$ws_deploy" -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d: -f2 || echo "?")
      ws_ready=$(kubectl get deployment "$ws_deploy" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      sched_ready=$(kubectl get deployment "$sched_deploy" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

      printf "    Release:    %s\n" "$(kubectl get deployment "$ws_deploy" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.release}' 2>/dev/null || echo "?")"
      printf "    Wersja:     %s\n" "$version"
      printf "    Webserver:  %s repliki gotowe\n" "${ws_ready:-0}"
      printf "    Scheduler:  %s repliki gotowe\n" "${sched_ready:-0}"
    else
      printf "    brak wdrożenia z etykietą slot=%s\n" "$slot"
    fi
    echo ""
  done
}

cmd_deploy() {
  local slot="$1"
  local release="airflow-${slot}"
  local values_file="${HELM_VALUES_DIR}/values-${slot}.yaml"

  [[ -f "$values_file" ]] || error "Brak pliku values: $values_file"

  log "Wdrażam slot $slot jako release '$release'..."

  if helm status "$release" -n "$NAMESPACE" &>/dev/null; then
    warn "Release '$release' już istnieje — upgraduję"
    helm upgrade "$release" "$CHART_REPO" \
      --namespace "$NAMESPACE" \
      --version "$CHART_VERSION" \
      --values "$values_file" \
      --timeout 10m \
      --wait
  else
    helm install "$release" "$CHART_REPO" \
      --namespace "$NAMESPACE" \
      --version "$CHART_VERSION" \
      --values "$values_file" \
      --timeout 10m \
      --wait
  fi

  ok "Slot $slot wdrożony ($release)"
  log "Webserver gotowy. Przełącz ruch: $0 switch $slot"
}

cmd_switch() {
  local target="$1"
  local current
  current=$(active_slot)

  [[ "$target" == "green" || "$target" == "blue" ]] \
    || error "Nieprawidłowy slot: $target. Użyj: green lub blue"

  if [[ "$target" == "$current" ]]; then
    warn "Slot $target jest już aktywny — nic nie zmieniam"
    exit 0
  fi

  local target_sched current_sched
  target_sched=$(deployment_for "$target" "scheduler")
  current_sched=$(deployment_for "$current" "scheduler")

  log "Przełączam: ${current} → ${target}"

  # Krok 1: Sprawdź gotowość webservera docelowego slotu
  log "Sprawdzam gotowość webservera (slot: $target)..."
  webserver_ready "$target" \
    || error "Webserver slotu $target nie jest gotowy. Wdróż go najpierw: $0 deploy $target"
  ok "Webserver $target gotowy"

  # Krok 2: Uruchom scheduler w docelowym slocie (był wyłączony w standby)
  if [[ -n "$target_sched" ]]; then
    log "Uruchamiam scheduler w slocie $target ($target_sched)..."
    kubectl scale deployment "$target_sched" -n "$NAMESPACE" --replicas=1
    kubectl rollout status deployment/"$target_sched" -n "$NAMESPACE" --timeout=120s
    ok "Scheduler $target gotowy"
  fi

  # Krok 3: Przełącz Service — zero downtime (< 1 sekunda)
  log "Przełączam Service '$SERVICE' → slot $target..."
  kubectl patch svc "$SERVICE" -n "$NAMESPACE" \
    -p "{\"spec\":{\"selector\":{\"slot\":\"${target}\"}}}"
  ok "Ruch produkcyjny kierowany na slot $target"

  # Krok 4: Wyłącz scheduler starego slotu (unikamy podwójnego schedulera)
  if [[ -n "$current_sched" ]]; then
    log "Wyłączam scheduler starego slotu ($current)..."
    kubectl scale deployment "$current_sched" -n "$NAMESPACE" --replicas=0
    ok "Scheduler $current zatrzymany"
  fi

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Przełączenie zakończone! Zero downtime.  ${NC}"
  echo -e "${GREEN}  Aktywny slot:  $target                   ${NC}"
  echo -e "${GREEN}  Rollback:      $0 switch $current        ${NC}"
  echo -e "${GREEN}══════════════════════════════════════════${NC}"
}

# ── Entry point ───────────────────────────────────────────────────────────────

COMMAND="${1:-status}"

case "$COMMAND" in
  status)
    cmd_status
    ;;
  switch)
    [[ $# -ge 2 ]] || error "Użycie: $0 switch <green|blue>"
    cmd_switch "$2"
    ;;
  deploy)
    [[ $# -ge 2 ]] || error "Użycie: $0 deploy <green|blue>"
    cmd_deploy "$2"
    ;;
  rollback)
    cmd_switch "$(standby_slot)"
    ;;
  *)
    echo "Użycie: $0 <status|switch|deploy|rollback>"
    echo ""
    echo "  status         — pokaż aktywny slot i stan podów"
    echo "  deploy <slot>  — wdróż nową wersję w slocie (green|blue)"
    echo "  switch <slot>  — przełącz ruch na slot (zero downtime)"
    echo "  rollback       — cofnij do poprzedniego slotu (< 1 sek)"
    exit 1
    ;;
esac
