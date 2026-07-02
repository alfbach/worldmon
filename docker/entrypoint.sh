#!/bin/sh
set -eu

# Docker secrets → env var bridge
# Reads /run/secrets/KEYNAME files and exports as env vars.
# Secrets take priority over env vars set via docker-compose environment block.
# Skip non-env names (RHEL/Podman may mount unrelated files like redhat.repo).
if [ -d /run/secrets ]; then
  for secret_file in /run/secrets/*; do
    [ -f "$secret_file" ] || continue
    key=$(basename "$secret_file")
    case "$key" in
      [A-Za-z_][A-Za-z0-9_]*) ;;
      *) continue ;;
    esac
    value=$(cat "$secret_file" | tr -d '\n')
    export "$key"="$value"
  done
fi

export LOCAL_API_PORT="${LOCAL_API_PORT:-46123}"
if [ -z "${LOCAL_API_TOKEN:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    LOCAL_API_TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
  else
    LOCAL_API_TOKEN="$(node -e 'import { randomBytes } from "node:crypto"; console.log(randomBytes(32).toString("base64url"));')"
  fi
  export LOCAL_API_TOKEN
fi

if ! envsubst '$LOCAL_API_PORT $LOCAL_API_TOKEN' < /etc/nginx/nginx.conf.template > /tmp/nginx.conf; then
  echo '[entrypoint] envsubst failed while rendering nginx config' >&2
  exit 1
fi

if ! /usr/sbin/nginx -t -c /tmp/nginx.conf 2>&1; then
  echo '[entrypoint] nginx config test failed (see above)' >&2
  exit 1
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/worldmonitor.conf
