#!/usr/bin/env bash
# =============================================================================
# World Monitor — RHEL 10 full startup
# =============================================================================
# One-shot setup for self-hosting on RHEL 10:
#   1. System packages (optional, requires sudo)
#   2. Node.js user install (optional)
#   3. npm ci + blog-site deps
#   4. Generate .env secrets for Docker stack
#   5. podman/docker compose up
#   6. Redis seeders
#
# Usage:
#   ./scripts/startup-rhel10.sh
#   ./scripts/startup-rhel10.sh --dev          # npm run dev after stack is up
#   ./scripts/startup-rhel10.sh --skip-system    # skip dnf (packages already installed)
#   ./scripts/startup-rhel10.sh --dry-run
#
# See SELF_HOSTING.md for API keys and docker-compose.override.yml.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/compose-utils.sh"
WM_NODE_DIR="${WM_NODE_DIR:-${HOME}/.local/worldmonitor/node}"
NPM_CACHE="${npm_config_cache:-/tmp/worldmonitor-npm-cache}"

SKIP_SYSTEM=false
SKIP_COMPOSE=false
SKIP_SEED=false
SKIP_INSTALL=false
INSTALL_SYSTEM=false
INSTALL_USER_NODE=false
START_DEV=false
DRY_RUN=false
COMPOSE_BUILD=true

log() { printf '[startup-rhel10] %s\n' "$*"; }
warn() { printf '[startup-rhel10] WARN: %s\n' "$*" >&2; }
die() { printf '[startup-rhel10] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: startup-rhel10.sh [options]

Options:
  --install-system   Run setup-host-rhel10.sh (sudo dnf packages + optional Node)
  --user-node        Install Node.js to ~/.local/worldmonitor/node (with --install-system)
  --skip-system      Skip host package installation (default)
  --skip-install     Skip npm ci when node_modules exists
  --skip-compose     Skip container stack startup
  --skip-seed        Skip Redis seeders after stack is up
  --no-build         podman/docker compose up without --build
  --dev              Start Vite dev server (npm run dev) after setup
  --dry-run          Print planned actions only
  -h, --help         Show this help

Environment:
  WM_NODE_DIR        Node.js install root (default: ~/.local/worldmonitor/node)
  npm_config_cache   npm cache directory (default: /tmp/worldmonitor-npm-cache)
  WM_PORT            Dashboard port (default: 3000, from docker-compose)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-system) INSTALL_SYSTEM=true; shift ;;
    --user-node) INSTALL_USER_NODE=true; shift ;;
    --skip-system) SKIP_SYSTEM=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    --skip-compose) SKIP_COMPOSE=true; shift ;;
    --skip-seed) SKIP_SEED=true; shift ;;
    --no-build) COMPOSE_BUILD=false; shift ;;
    --dev) START_DEV=true; shift ;;
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

ensure_node_on_path() {
  if command -v node >/dev/null 2>&1; then
    local major current
    major="$(node "${ROOT_DIR}/scripts/bootstrap-worktree.mjs" --print-node-version 2>/dev/null | cut -d. -f1 || true)"
    current="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)"
    if [[ -n "${major}" && "${current}" -ge "${major}" ]]; then
      log "Node.js $(node --version) on PATH"
      return 0
    fi
    warn "Node.js on PATH is v${current}; project requires major ${major:-22}+"
  fi

  local node_version node_dir
  if command -v node >/dev/null 2>&1; then
    node_version="$(node "${ROOT_DIR}/scripts/bootstrap-worktree.mjs" --resolve-node-dist-version 2>/dev/null || true)"
  fi
  if [[ -z "${node_version}" ]]; then
    node_version="$(tr -d ' \n\r' < "${ROOT_DIR}/.nvmrc")"
    if [[ -d "${WM_NODE_DIR}" ]]; then
      local latest_dir
      latest_dir="$(find "${WM_NODE_DIR}" -maxdepth 1 -type d -name "v${node_version}*" 2>/dev/null | sort -V | tail -1 || true)"
      if [[ -n "${latest_dir}" ]]; then
        node_version="$(basename "${latest_dir}" | sed 's/^v//')"
      fi
    fi
  fi
  node_dir="${WM_NODE_DIR}/v${node_version}"

  if [[ -x "${node_dir}/bin/node" ]]; then
    export PATH="${node_dir}/bin:${PATH}"
    log "Using Node.js from ${node_dir} ($(node --version))"
    return 0
  fi

  local path_snippet="${HOME}/.config/worldmonitor/path.sh"
  if [[ -f "${path_snippet}" ]]; then
    # shellcheck disable=SC1090
    source "${path_snippet}"
    if command -v node >/dev/null 2>&1; then
      log "Using Node.js from path snippet ($(node --version))"
      return 0
    fi
  fi

  die "Node.js ${node_version}+ not found. Run: ./scripts/setup-host-rhel10.sh --user-node (or --install-system --user-node)"
}

detect_compose_cmd() {
  if compose_utils_detect_cmd; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "podman compose"
    return 0
  fi
  die "No compose runner found. Install podman (recommended on RHEL) or docker compose."
}

install_npm_deps() {
  cd "${ROOT_DIR}"
  export npm_config_cache="${NPM_CACHE}"
  mkdir -p "${NPM_CACHE}"

  local bootstrap_args=(--ensure-self-host-env --skip-env)
  if [[ "$SKIP_INSTALL" == true ]]; then
    bootstrap_args+=(--skip-install)
  else
    bootstrap_args+=(--force-install)
  fi
  if [[ "$DRY_RUN" == true ]]; then
    bootstrap_args+=(--dry-run)
  fi

  log "Installing npm dependencies (npm ci) …"
  run node "${ROOT_DIR}/scripts/bootstrap-worktree.mjs" "${bootstrap_args[@]}"
}

wait_for_redis_proxy() {
  local url="${UPSTASH_REDIS_REST_URL:-http://localhost:8079}"
  local token="${REDIS_TOKEN:-${UPSTASH_REDIS_REST_TOKEN:-}}"
  local attempts=30

  log "Waiting for Redis REST proxy at ${url} …"
  while [[ $attempts -gt 0 ]]; do
    if curl -fsS -o /dev/null -w '' -H "Authorization: Bearer ${token}" "${url}/ping" 2>/dev/null \
      || curl -fsS -o /dev/null -w '' "${url}/" 2>/dev/null; then
      log "Redis REST proxy is reachable"
      return 0
    fi
    sleep 2
    attempts=$((attempts - 1))
  done
  warn "Redis REST proxy not confirmed ready — seeders may fail on first run"
}

start_compose_stack() {
  local compose_cmd compose_args=(-f "${ROOT_DIR}/docker-compose.yml")
  compose_cmd="$(detect_compose_cmd)"
  read -r -a compose_bin <<< "${compose_cmd}"

  if [[ "$COMPOSE_BUILD" == true ]]; then
    compose_args+=(up -d --build)
  else
    compose_args+=(up -d)
  fi

  log "Starting stack: ${compose_cmd} ${compose_args[*]}"
  cd "${ROOT_DIR}"
  # Compose reads .env from the project directory — do not source it (values may
  # contain shell metacharacters, e.g. RESEND_FROM_EMAIL="Name <addr>").
  run "${compose_bin[@]}" "${compose_args[@]}"
}

run_seeders() {
  log "Running Redis seeders …"
  run "${ROOT_DIR}/scripts/run-seeders.sh"
}

start_dev_server() {
  log "Starting Vite dev server (npm run dev) …"
  cd "${ROOT_DIR}"
  run npm run dev
}

main() {
  log "World Monitor startup (RHEL 10) — ${ROOT_DIR}"

  if [[ "$INSTALL_SYSTEM" == true && "$SKIP_SYSTEM" != true ]]; then
    local setup_args=()
    [[ "$INSTALL_USER_NODE" == true ]] && setup_args+=(--user-node)
    [[ "$DRY_RUN" == true ]] && setup_args+=(--dry-run)
    run "${ROOT_DIR}/scripts/setup-host-rhel10.sh" "${setup_args[@]}"
  elif [[ "$SKIP_SYSTEM" != true && ! -f /etc/redhat-release ]] && [[ "$DRY_RUN" != true ]]; then
    warn "Not on RHEL — skipping system package check (use --install-system on RHEL)"
  fi

  ensure_node_on_path
  install_npm_deps

  if [[ "$SKIP_COMPOSE" != true ]]; then
    start_compose_stack
    if [[ "$SKIP_SEED" != true && "$DRY_RUN" != true ]]; then
      if [[ -f "${ROOT_DIR}/.env" ]]; then
        set -a
        # shellcheck disable=SC1090
        eval "$(bash "${ROOT_DIR}/scripts/load-dotenv.sh" "${ROOT_DIR}/.env" REDIS_TOKEN UPSTASH_REDIS_REST_TOKEN UPSTASH_REDIS_REST_URL)"
        set +a
      fi
      wait_for_redis_proxy
      run_seeders
    fi
  fi

  local port="${WM_PORT:-3000}"
  log "Setup complete."
  if [[ "$SKIP_COMPOSE" != true && "$DRY_RUN" != true ]]; then
    log "Waiting for dashboard on http://127.0.0.1:${port} (first build may take several minutes) …"
    if compose_utils_wait_for_dashboard "${port}"; then
      log "Dashboard ready: http://localhost:${port}"
    else
      compose_utils_diagnose_dashboard "${ROOT_DIR}" "${port}"
      die "Dashboard not reachable on port ${port}"
    fi
  fi

  if [[ "$START_DEV" == true ]]; then
    start_dev_server
  elif [[ "$DRY_RUN" != true ]]; then
    log "Dev server: npm run dev"
    log "Re-seed:      ./scripts/run-seeders.sh"
  fi
}

main "$@"
