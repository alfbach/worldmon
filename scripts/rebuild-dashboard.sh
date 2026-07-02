#!/usr/bin/env bash
# =============================================================================
# Force-rebuild and restart the self-hosted dashboard on Podman/Docker.
# Use when logs still show: export: redhat.repo: bad variable name
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/compose-utils.sh"

PORT="${WM_PORT:-3000}"
OPEN_FIREWALL=false

log() { printf '[rebuild-dashboard] %s\n' "$*"; }
die() { printf '[rebuild-dashboard] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --open-firewall) OPEN_FIREWALL=true; shift ;;
    -h|--help)
      echo "Usage: rebuild-dashboard.sh [--open-firewall]"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

compose_utils_read_bin || die "podman compose or docker compose required"
cd "${ROOT_DIR}"

log "Removing old worldmonitor container/image (if present) …"
if runtime="$(compose_utils_container_runtime)"; then
  "${runtime}" rm -f worldmonitor 2>/dev/null || true
  "${runtime}" rmi -f worldmonitor:latest localhost/worldmonitor:latest 2>/dev/null || true
fi

log "Building worldmonitor image (no cache) …"
"${COMPOSE_BIN[@]}" -f docker-compose.yml build --no-cache worldmonitor

log "Starting stack …"
"${COMPOSE_BIN[@]}" -f docker-compose.yml up -d redis redis-rest ais-relay worldmonitor

compose_utils_maybe_open_firewall "${PORT}" "${OPEN_FIREWALL}" log || true

log "Verifying entrypoint inside image …"
if ! compose_utils_container_runtime >/dev/null; then
  die "container runtime not found"
fi
runtime="$(compose_utils_container_runtime)"
if ! "${runtime}" run --rm --entrypoint grep localhost/worldmonitor:latest \
  WM_ENTRYPOINT_VERSION /app/entrypoint.sh >/dev/null 2>&1; then
  die "image still has old entrypoint — rebuild did not pick up docker/entrypoint.sh"
fi

log "Waiting for http://127.0.0.1:${PORT} …"
if compose_utils_wait_for_dashboard "${PORT}" 90; then
  log "Dashboard ready: http://localhost:${PORT}"
  exit 0
fi

compose_utils_diagnose_dashboard "${ROOT_DIR}" "${PORT}"
die "Dashboard not reachable after rebuild"
exit 1
