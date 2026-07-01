#!/usr/bin/env bash
# =============================================================================
# World Monitor — unified startup entry point
# =============================================================================
# Dispatches to the right platform script:
#   ./scripts/startup.sh --rhel10 [options]     → startup-rhel10.sh
#   ./scripts/startup.sh --openshift [options]  → deploy-openshift.sh
#   ./scripts/startup.sh --docker [options]     → startup-docker.sh
#   ./scripts/startup.sh [options]              → auto-detect (RHEL → rhel10)
#
# Examples:
#   ./scripts/startup.sh --rhel10 --install-system --user-node
#   ./scripts/startup.sh --openshift
#   ./scripts/startup.sh --docker
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: startup.sh [--rhel10 | --openshift | --docker] [options…]

Targets:
  --rhel10      RHEL 10 / AlmaLinux / Rocky (Podman/Docker Compose)
  --openshift   OpenShift 4 project "worldmon"
  --docker      Generic Docker/Podman Compose (any Linux/macOS with compose)

With no target flag, auto-detects RHEL-family Linux and runs --rhel10;
otherwise runs --docker.

Pass --help to the underlying script, e.g.:
  ./scripts/startup.sh --rhel10 --help
  ./scripts/startup.sh --openshift --dry-run
EOF
}

is_rhel_family() {
  if [[ -f /etc/redhat-release ]]; then
    return 0
  fi
  if [[ -f /etc/os-release ]] && grep -qiE 'rhel|centos|rocky|almalinux|fedora' /etc/os-release; then
    return 0
  fi
  return 1
}

TARGET="${WM_STARTUP_TARGET:-auto}"

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --rhel10|--rhel)
      TARGET=rhel10
      shift
      ;;
    --openshift|--oc)
      TARGET=openshift
      shift
      ;;
    --docker|--compose)
      TARGET=docker
      shift
      ;;
  esac
fi

if [[ "$TARGET" == auto ]]; then
  if is_rhel_family; then
    TARGET=rhel10
  else
    TARGET=docker
  fi
fi

case "$TARGET" in
  rhel10)
    exec "${SCRIPT_DIR}/startup-rhel10.sh" "$@"
    ;;
  openshift)
    exec "${SCRIPT_DIR}/deploy-openshift.sh" "$@"
    ;;
  docker)
    exec "${SCRIPT_DIR}/startup-docker.sh" "$@"
    ;;
  *)
    echo "Unknown startup target: ${TARGET}" >&2
    usage >&2
    exit 1
    ;;
esac
