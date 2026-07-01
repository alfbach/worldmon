#!/usr/bin/env bash
# =============================================================================
# World Monitor — RHEL 10 host prerequisites
# =============================================================================
# Installs system packages required for self-hosting on RHEL 10 (and compatible
# clones: AlmaLinux 10, Rocky 10).
#
# Usage:
#   sudo ./scripts/setup-host-rhel10.sh
#   ./scripts/setup-host-rhel10.sh --user-node
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WM_NODE_DIR="${WM_NODE_DIR:-${HOME}/.local/worldmonitor/node}"

INSTALL_USER_NODE=false
DRY_RUN=false
DNF_ONLY=false
NODE_ONLY=false

log() { printf '[setup-rhel10] %s\n' "$*"; }
warn() { printf '[setup-rhel10] WARN: %s\n' "$*" >&2; }
die() { printf '[setup-rhel10] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: setup-host-rhel10.sh [options]

Options:
  --user-node       Install Node.js from nodejs.org into ~/.local/worldmonitor/node
  --node-dir <dir>  Override Node.js install directory (with --user-node)
  --dry-run         Print actions without changing the system
  --dnf-only        Internal: install dnf packages only (requires root)
  --node-only       Internal: install user Node.js only
  -h, --help        Show this help

Requires root (sudo) for dnf packages. Node.js user install runs as the invoking user.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-node) INSTALL_USER_NODE=true; shift ;;
    --node-dir)
      [[ $# -ge 2 ]] || die "Missing value for --node-dir"
      WM_NODE_DIR="$2"
      INSTALL_USER_NODE=true
      shift 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --dnf-only) DNF_ONLY=true; shift ;;
    --node-only) NODE_ONLY=true; shift ;;
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

require_rhel_family() {
  if [[ -f /etc/redhat-release ]]; then
    log "Detected: $(tr -d '\n' < /etc/redhat-release)"
    return 0
  fi
  if [[ -f /etc/os-release ]] && grep -qiE 'rhel|centos|rocky|almalinux|fedora' /etc/os-release; then
    log "Detected: $(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
    return 0
  fi
  warn "Not a recognized RHEL-family OS — continuing anyway"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

read_node_version() {
  if [[ -f "${ROOT_DIR}/.nvmrc" ]]; then
    tr -d ' \n\r' < "${ROOT_DIR}/.nvmrc"
    return 0
  fi
  die "Could not read Node.js version from ${ROOT_DIR}/.nvmrc"
}

install_dnf_packages() {
  if ! command -v dnf >/dev/null 2>&1; then
    die "dnf not found — this script targets RHEL 10 / dnf-based systems"
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "Elevating for dnf package install …"
    run sudo "${BASH_SOURCE[0]}" --dnf-only ${DRY_RUN:+--dry-run}
    return 0
  fi

  if dnf repolist 2>/dev/null | grep -qi epel; then
    log "EPEL repository already enabled"
  else
    log "Enabling EPEL (best-effort)"
    run dnf install -y epel-release || warn "epel-release unavailable — continuing"
  fi

  local packages=(
    git curl ca-certificates openssl tar gzip xz which findutils coreutils
    gcc gcc-c++ make python3 python3-pip
    podman podman-docker
  )

  log "Installing: ${packages[*]}"
  run dnf install -y "${packages[@]}"

  if podman compose version >/dev/null 2>&1; then
    log "podman compose available"
  elif command -v podman-compose >/dev/null 2>&1; then
    log "podman-compose available"
  else
    log "Installing podman-compose via pip"
    run python3 -m pip install --upgrade 'podman-compose>=1.0.6' || \
      warn "podman-compose pip install failed — use 'podman compose' or 'uvx podman-compose'"
  fi

  if command -v docker >/dev/null 2>&1; then
    log "docker CLI available ($(docker --version 2>/dev/null || echo podman shim))"
  fi

  log "System packages ready"
}

install_user_node() {
  local node_version arch node_dist node_dir archive url
  node_version="$(read_node_version)"
  arch="$(detect_arch)"
  node_dist="node-v${node_version}-linux-${arch}"
  node_dir="${WM_NODE_DIR}/v${node_version}"
  archive="${node_dist}.tar.xz"
  url="https://nodejs.org/dist/v${node_version}/${archive}"

  if [[ -x "${node_dir}/bin/node" ]]; then
    log "Node.js v${node_version} already installed at ${node_dir}"
    return 0
  fi

  log "Installing Node.js v${node_version} to ${node_dir}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  if [[ "$DRY_RUN" == true ]]; then
    log "would download ${url}"
    log "would extract to ${node_dir}"
    return 0
  fi

  curl -fsSL "${url}" -o "${tmp}/${archive}"
  mkdir -p "${node_dir}"
  tar -xJf "${tmp}/${archive}" -C "${tmp}"
  cp -a "${tmp}/${node_dist}/." "${node_dir}/"
  chmod +x "${node_dir}/bin/node"

  log "Node.js installed: $("${node_dir}/bin/node" --version)"

  local snippet="${HOME}/.config/worldmonitor/path.sh"
  mkdir -p "$(dirname "${snippet}")"
  cat > "${snippet}" <<EOF
# Generated by scripts/setup-host-rhel10.sh — source in ~/.bashrc
export PATH="${node_dir}/bin:\$PATH"
export npm_config_cache="\${npm_config_cache:-/tmp/worldmonitor-npm-cache}"
EOF
  log "Wrote ${snippet} (source from ~/.bashrc)"
}

main() {
  if [[ "$DNF_ONLY" == true ]]; then
    require_rhel_family
    install_dnf_packages
    exit 0
  fi

  if [[ "$NODE_ONLY" == true ]]; then
    install_user_node
    exit 0
  fi

  require_rhel_family
  install_dnf_packages

  if [[ "$INSTALL_USER_NODE" == true ]]; then
    if [[ -n "${SUDO_USER:-}" && "${EUID:-$(id -u)}" -eq 0 ]]; then
      run sudo -u "${SUDO_USER}" env WM_NODE_DIR="${WM_NODE_DIR}" ROOT_DIR="${ROOT_DIR}" \
        "${BASH_SOURCE[0]}" --node-only ${DRY_RUN:+--dry-run}
    else
      install_user_node
    fi
  fi

  log "Host setup complete"
}

main "$@"
