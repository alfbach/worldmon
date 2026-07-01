#!/usr/bin/env bash
# =============================================================================
# Safely export variables from a dotenv file without shell-evaluating values.
# =============================================================================
# Usage:
#   eval "$(scripts/load-dotenv.sh /path/to/.env)"
#   eval "$(scripts/load-dotenv.sh /path/to/.env REDIS_TOKEN REDIS_PASSWORD)"
#
# Dotenv files are NOT guaranteed to be valid bash (e.g. email "Name <addr>").
# Docker/Podman Compose reads .env natively; use this helper only when a shell
# script needs a subset of keys in its environment.
# =============================================================================

set -euo pipefail

ENV_FILE="${1:-}"
shift || true

if [[ -z "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
  exit 0
fi

python3 - "${ENV_FILE}" "$@" <<'PY'
import re
import shlex
import sys

path = sys.argv[1]
keys = set(sys.argv[2:]) if len(sys.argv) > 2 else None

with open(path, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2)
        if keys is not None and key not in keys:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        print(f"export {key}={shlex.quote(value)}")
PY
