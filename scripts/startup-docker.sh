#!/usr/bin/env bash
# =============================================================================
# World Monitor — Docker / Podman Compose startup (generic)
# =============================================================================
# Starts the self-hosted stack via docker-compose.yml on any host with
# Docker or Podman Compose. For RHEL 10 prefer: ./scripts/startup.sh --rhel10
#
# Usage:
#   ./scripts/startup-docker.sh
#   ./scripts/startup-docker.sh --skip-seed --skip-install
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/compose-utils.sh"

SKIP_INSTALL=false
SKIP_SEED=false
SKIP_COMPOSE=false
DRY_RUN=false

log() { printf '[startup-docker] %s\n' "$*" >&2; }
die() { printf '[startup-docker] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: startup-docker.sh [options]

Options:
  --skip-install   Skip npm ci when node_modules exists
  --skip-compose   Skip container stack startup
  --skip-seed      Skip Redis seeders
  --dry-run        Print planned steps only
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-install) SKIP_INSTALL=true; shift ;;
    --skip-compose) SKIP_COMPOSE=true; shift ;;
    --skip-seed) SKIP_SEED=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == true ]]; then
    log "would run: $*"
  else
    "$@"
  fi
}

detect_compose_cmd() {
  if compose_utils_detect_cmd; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "docker compose"
    return 0
  fi
  die "No compose runner found — install Docker Compose or Podman Compose"
}

ensure_node() {
  command -v node >/dev/null 2>&1 || die "Node.js 22+ required — install Node or use ./scripts/startup.sh --rhel10"
}

install_deps() {
  ensure_node
  local args=(--ensure-self-host-env --skip-env)
  [[ "$SKIP_INSTALL" == true ]] && args+=(--skip-install) || args+=(--force-install)
  [[ "$DRY_RUN" == true ]] && args+=(--dry-run)
  log "Installing npm dependencies …"
  run node "${ROOT_DIR}/scripts/bootstrap-worktree.mjs" "${args[@]}"
}

start_compose() {
  [[ "$SKIP_COMPOSE" == true ]] && return 0
  local compose_cmd compose_args=(-f "${ROOT_DIR}/docker-compose.yml" up -d --build)
  compose_cmd="$(detect_compose_cmd)"
  read -r -a compose_bin <<< "${compose_cmd}"
  cd "${ROOT_DIR}"
  log "Starting stack: ${compose_cmd} ${compose_args[*]}"
  # Compose reads .env from the project directory — do not source it.
  run "${compose_bin[@]}" "${compose_args[@]}"
}

run_seeders() {
  [[ "$SKIP_SEED" == true ]] && return 0
  log "Running Redis seeders …"
  run "${ROOT_DIR}/scripts/run-seeders.sh"
}

main() {
  log "World Monitor Docker/Podman startup — ${ROOT_DIR}"
  install_deps
  start_compose
  run_seeders
  local port="${WM_PORT:-3000}"
  if [[ "$SKIP_COMPOSE" != true && "$DRY_RUN" != true ]]; then
    log "Waiting for dashboard on http://127.0.0.1:${port} …"
    if compose_utils_wait_for_dashboard "${port}"; then
      log "Setup complete — dashboard: http://localhost:${port}"
    else
      compose_utils_diagnose_dashboard "${ROOT_DIR}" "${port}"
      die "Dashboard not reachable on port ${port}"
    fi
  else
    log "Setup complete — dashboard: http://localhost:${port}"
  fi
}

main "$@"
