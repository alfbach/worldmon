#!/usr/bin/env bash
# =============================================================================
# Start the self-hosted dashboard container (after build or reboot).
# =============================================================================
# Usage:
#   ./scripts/start-dashboard.sh
#   ./scripts/start-dashboard.sh --open-firewall
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/compose-utils.sh"

OPEN_FIREWALL=false
PORT="${WM_PORT:-3000}"

log() { printf '[start-dashboard] %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --open-firewall) OPEN_FIREWALL=true; shift ;;
    -h|--help)
      echo "Usage: start-dashboard.sh [--open-firewall]"
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

cd "${ROOT_DIR}"

if ! compose_utils_read_bin; then
  printf '[start-dashboard] ERROR: podman compose or docker compose required\n' >&2
  exit 1
fi

log "Starting backend + worldmonitor (port ${PORT}) …"
compose_utils_start_dashboard_stack "${ROOT_DIR}" false
compose_utils_ensure_dashboard_started "${ROOT_DIR}" log || true
compose_utils_maybe_open_firewall "${PORT}" "${OPEN_FIREWALL}" log || true

log "Waiting for http://127.0.0.1:${PORT} …"
if compose_utils_wait_for_dashboard "${PORT}" 60; then
  log "Dashboard ready: http://localhost:${PORT}"
  exit 0
fi

compose_utils_diagnose_dashboard "${ROOT_DIR}" "${PORT}"
exit 1
