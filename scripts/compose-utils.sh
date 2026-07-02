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

compose_utils_ps() {
  local root_dir="${1:?root dir required}"
  compose_utils_read_bin || return 1
  (
    cd "${root_dir}" || exit 1
    "${COMPOSE_BIN[@]}" -f docker-compose.yml ps -a
  )
}

compose_utils_logs() {
  local root_dir="${1:?root dir required}"
  local service="${2:-worldmonitor}"
  local tail_lines="${3:-80}"
  compose_utils_read_bin || return 1
  (
    cd "${root_dir}" || exit 1
    "${COMPOSE_BIN[@]}" -f docker-compose.yml logs --tail="${tail_lines}" "${service}" 2>&1
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

compose_utils_worldmonitor_container_id() {
  local runtime
  runtime="$(compose_utils_container_runtime)" || return 1
  "${runtime}" ps -a \
    --filter "name=worldmonitor" \
    --filter "name=^worldmonitor$" \
    --format '{{.ID}}' 2>/dev/null | head -1
}

compose_utils_worldmonitor_container_state() {
  local runtime id
  runtime="$(compose_utils_container_runtime)" || return 1
  id="$("${runtime}" ps -a --filter "name=worldmonitor" --format '{{.ID}} {{.Names}} {{.Status}}' 2>/dev/null \
    | awk '$2 == "worldmonitor" { print; exit }')"
  if [[ -n "${id}" ]]; then
    printf '%s\n' "${id}"
    return 0
  fi
  "${runtime}" ps -a --filter "name=worldmonitor" --format '{{.ID}} {{.Names}} {{.Status}}' 2>/dev/null | head -1
}

compose_utils_port_listening() {
  local port="${1:-3000}"
  if command -v ss >/dev/null 2>&1; then
    ss -tln "sport = :${port}" 2>/dev/null | grep -q ":${port}" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -q ":${port} " && return 0
  fi
  return 1
}

compose_utils_is_rhel_family() {
  [[ -f /etc/redhat-release ]] && return 0
  [[ -f /etc/os-release ]] && grep -qiE 'rhel|centos|rocky|almalinux|fedora' /etc/os-release
}

compose_utils_firewalld_active() {
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

compose_utils_firewall_port_open() {
  local port="${1:-3000}"
  compose_utils_firewalld_active && firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1
}

# Rootless Podman on RHEL often requires an explicit firewalld rule before
# published ports answer — sometimes even on 127.0.0.1 (Red Hat #7044062).
compose_utils_maybe_open_firewall() {
  local port="${1:-3000}"
  local open="${2:-false}"
  local log_fn="${3:-printf}"

  if ! compose_utils_is_rhel_family; then
    return 0
  fi
  if ! compose_utils_firewalld_active; then
    return 0
  fi
  if compose_utils_firewall_port_open "${port}"; then
    "${log_fn}" "[compose] firewalld: port ${port}/tcp already allowed"
    return 0
  fi

  "${log_fn}" "[compose] WARN: firewalld is active but port ${port}/tcp is not open (common rootless Podman issue on RHEL)" >&2
  if [[ "${open}" == true ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo firewall-cmd --add-port="${port}/tcp" --permanent
      sudo firewall-cmd --reload
      "${log_fn}" "[compose] Opened firewalld port ${port}/tcp"
      return 0
    fi
    "${log_fn}" "[compose] WARN: --open-firewall set but sudo not available" >&2
  fi
  "${log_fn}" "[compose] Fix: sudo firewall-cmd --add-port=${port}/tcp --permanent && sudo firewall-cmd --reload" >&2
  return 1
}

compose_utils_build_service() {
  local root_dir="${1:?root dir required}"
  local service="${2:-worldmonitor}"
  compose_utils_read_bin || return 1
  (
    cd "${root_dir}" || exit 1
    "${COMPOSE_BIN[@]}" -f docker-compose.yml build "${service}"
  )
}

compose_utils_wait_for_dashboard() {
  local port="${1:-3000}"
  local attempts="${2:-${WM_DASHBOARD_WAIT_ATTEMPTS:-900}}"
  local delay="${3:-2}"
  local url="http://127.0.0.1:${port}/api/health"
  local log_every="${WM_DASHBOARD_WAIT_LOG_EVERY:-15}"
  local tick=0

  while [[ "${attempts}" -gt 0 ]]; do
    if curl -fsS -o /dev/null "${url}" 2>/dev/null \
      || curl -fsS -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then
      return 0
    fi
    tick=$((tick + 1))
    if (( tick % log_every == 0 )); then
      local state=""
      state="$(compose_utils_worldmonitor_container_state 2>/dev/null || true)"
      if [[ -n "${state}" ]]; then
        printf '[compose] still waiting (%ss left ~%ss) — worldmonitor: %s\n' \
          "$((attempts * delay))" "$((tick * delay))" "${state}" >&2
      else
        printf '[compose] still waiting (%ss left ~%ss) — worldmonitor container not found yet (image may still be building)\n' \
          "$((attempts * delay))" "$((tick * delay))" >&2
      fi
    fi
    sleep "${delay}"
    attempts=$((attempts - 1))
  done
  return 1
}

compose_utils_firewall_hint() {
  local port="${1:-3000}"
  if ! compose_utils_is_rhel_family; then
    return 0
  fi
  if ! compose_utils_firewalld_active; then
    return 0
  fi
  cat <<EOF
  RHEL rootless Podman + firewalld: open the published port (often required even for localhost):
    sudo firewall-cmd --add-port=${port}/tcp --permanent
    sudo firewall-cmd --reload
  Or re-run startup with: ./scripts/startup.sh --rhel10 --open-firewall
EOF
}

compose_utils_diagnose_dashboard() {
  local root_dir="${1:?root dir required}"
  local port="${2:-3000}"
  local runtime

  printf '\n=== Dashboard diagnostic ===\n'
  printf 'Target: http://127.0.0.1:%s\n\n' "${port}"

  printf '--- compose ps -a ---\n'
  compose_utils_ps "${root_dir}" 2>&1 || true
  printf '\n'

  if runtime="$(compose_utils_container_runtime)"; then
    printf '--- podman/docker ps (worldmonitor) ---\n'
    "${runtime}" ps -a --filter "name=worldmonitor" 2>&1 || true
    printf '\n'

    printf '--- image present? ---\n'
    if "${runtime}" image exists worldmonitor:latest 2>/dev/null; then
      printf 'worldmonitor:latest: yes\n'
    else
      printf 'worldmonitor:latest: NO — build probably failed. Run:\n'
      printf '  cd %s && podman compose build worldmonitor\n' "${root_dir}"
    fi
    printf '\n'

    printf '--- host port %s listening? ---\n' "${port}"
    if compose_utils_port_listening "${port}"; then
      printf 'yes (ss/netstat shows :%s)\n' "${port}"
    else
      printf 'NO — nothing is bound on :%s\n' "${port}"
    fi
    printf '\n'

    printf '--- recent worldmonitor logs ---\n'
    compose_utils_logs "${root_dir}" worldmonitor 80 2>&1 || true
    printf '\n--- direct container logs (%s) ---\n' "${runtime}"
    "${runtime}" logs --tail 80 worldmonitor 2>&1 \
      || printf '(no container named worldmonitor — check compose build output)\n'
  fi

  compose_utils_firewall_hint "${port}"
  cat <<EOF

--- next steps ---
  1. Build in foreground to see errors:
       cd ${root_dir} && podman compose build worldmonitor
  2. Start dashboard container:
       podman compose up -d worldmonitor
  3. Dev fallback (Vite on :${port}, backend containers only):
       ./scripts/startup.sh --rhel10 --dev --open-firewall
EOF
}
