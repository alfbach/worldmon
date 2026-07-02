#!/usr/bin/env bash
# =============================================================================
# Self-host diagnostic — run on the server when port 3000 is not reachable.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/compose-utils.sh"

PORT="${WM_PORT:-3000}"

printf 'World Monitor self-host diagnostic (%s)\n\n' "${ROOT_DIR}"

if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/api/health" 2>/dev/null; then
  printf 'OK: dashboard responds on http://127.0.0.1:%s/api/health\n' "${PORT}"
  exit 0
fi

compose_utils_diagnose_dashboard "${ROOT_DIR}" "${PORT}"
exit 1
