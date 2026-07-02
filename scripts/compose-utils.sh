#!/usr/bin/env bash
# =============================================================================
# Shared helpers for docker-compose.yml / podman compose startup scripts.
# =============================================================================

compose_utils_detect_cmd() {
  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    echo "podman compose"
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  if command -v podman-compose >/dev/null 2>&1; then
    echo "podman-compose"
    return 0
  fi
  if command -v uvx >/dev/null 2>&1; then
    echo "uvx podman-compose"
    return 0
  fi
  return 1
}

compose_utils_read_bin() {
  local cmd
  cmd="$(compose_utils_detect_cmd)" || return 1
  read -r -a COMPOSE_BIN <<< "${cmd}"
}

compose_utils_file() {
  local root_dir="${1:?root dir required}"
  printf '%s/docker-compose.yml' "${root_dir}"
}

compose_utils_ps() {
  local root_dir="${1:?root dir required}"
  compose_utils_read_bin || return 1
  (
    cd "${root_dir}" || exit 1
    "${COMPOSE_BIN[@]}" -f docker-compose.yml ps
  )
}

compose_utils_logs() {
  local root_dir="${1:?root dir required}"
  local service="${2:-worldmonitor}"
  local tail_lines="${3:-40}"
  compose_utils_read_bin || return 1
  (
    cd "${root_dir}" || exit 1
    "${COMPOSE_BIN[@]}" -f docker-compose.yml logs --tail="${tail_lines}" "${service}"
  )
}

compose_utils_container_runtime() {
  if command -v podman >/dev/null 2>&1; then
    echo podman
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    echo docker
    return 0
  fi
  return 1
}

compose_utils_wait_for_dashboard() {
  local port="${1:-3000}"
  local attempts="${2:-150}"
  local delay="${3:-2}"
  local url="http://127.0.0.1:${port}/api/health"

  while [[ "${attempts}" -gt 0 ]]; do
    if curl -fsS -o /dev/null "${url}" 2>/dev/null \
      || curl -fsS -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then
      return 0
    fi
    sleep "${delay}"
    attempts=$((attempts - 1))
  done
  return 1
}

compose_utils_firewall_hint() {
  local port="${1:-3000}"
  if [[ ! -f /etc/redhat-release ]] && [[ ! -f /etc/os-release ]]; then
    return 0
  fi
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    return 0
  fi
  if ! firewall-cmd --state >/dev/null 2>&1; then
    return 0
  fi
  cat <<EOF
  Rootless Podman on RHEL often needs firewalld opened for remote access:
    sudo firewall-cmd --add-port=${port}/tcp --permanent
    sudo firewall-cmd --reload
  localhost should work without this; use it to distinguish firewall vs container issues.
EOF
}

compose_utils_diagnose_dashboard() {
  local root_dir="${1:?root dir required}"
  local port="${2:-3000}"
  local runtime

  printf '\n'
  printf 'Dashboard not reachable on http://127.0.0.1:%s after waiting.\n' "${port}"
  printf 'Check container status:\n'
  compose_utils_ps "${root_dir}" 2>/dev/null || true
  printf '\nRecent worldmonitor logs:\n'
  compose_utils_logs "${root_dir}" worldmonitor 40 2>/dev/null || true

  if runtime="$(compose_utils_container_runtime)"; then
    printf '\nDirect container logs (%s):\n' "${runtime}"
    "${runtime}" logs --tail 40 worldmonitor 2>/dev/null || true
  fi

  compose_utils_firewall_hint "${port}"
  printf '\nRebuild stack: cd %s && podman compose up -d --build worldmonitor\n' "${root_dir}"
}
