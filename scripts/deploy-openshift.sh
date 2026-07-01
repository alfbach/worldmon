#!/usr/bin/env bash
# =============================================================================
# World Monitor — OpenShift 4 deploy
# =============================================================================
# Creates project "worldmon" (display name Worldmon), builds container images,
# applies the stack, exposes a Route, and optionally seeds Redis.
#
# Usage:
#   ./scripts/deploy-openshift.sh
#   ./scripts/deploy-openshift.sh --skip-build --skip-seed
#   ./scripts/deploy-openshift.sh --dry-run
#
# Requires: oc (logged in), podman or docker, openssl
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT="${OC_PROJECT:-worldmon}"
DISPLAY_NAME="${OC_DISPLAY_NAME:-Worldmon}"
DESCRIPTION="${OC_DESCRIPTION:-World Monitor OSINT dashboard}"
SKIP_BUILD=false
SKIP_SEED=false
DRY_RUN=false
CONTAINER_CMD=""

log() { printf '[deploy-openshift] %s\n' "$*" >&2; }
warn() { printf '[deploy-openshift] WARN: %s\n' "$*" >&2; }
die() { printf '[deploy-openshift] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: deploy-openshift.sh [options]

Creates OpenShift 4 project "${PROJECT}" and deploys the full World Monitor stack.

Options:
  --project <name>   OpenShift project/namespace (default: worldmon)
  --skip-build       Skip container image build and registry push
  --skip-seed        Skip Redis seed scripts after deploy
  --dry-run          Print planned steps without changing the cluster
  -h, --help         Show this help

Environment:
  OC_PROJECT         Project name (default: worldmon)
  OC_DISPLAY_NAME    Project display name (default: Worldmon)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || die "Missing value for --project"
      PROJECT="$2"
      shift 2
      ;;
    --skip-build) SKIP_BUILD=true; shift ;;
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

require_oc() {
  if [[ "$DRY_RUN" == true ]]; then
    if command -v oc >/dev/null 2>&1; then
      log "dry-run: oc available ($(oc version --client -o json 2>/dev/null | head -1 || echo client))"
    else
      warn "dry-run: oc not installed — cluster steps will be simulated only"
    fi
    return 0
  fi
  command -v oc >/dev/null 2>&1 || die "oc CLI not found — install OpenShift CLI 4.x"
  oc whoami >/dev/null 2>&1 || die "Not logged in — run: oc login <cluster-url>"
  log "OpenShift user: $(oc whoami)"
  log "Cluster: $(oc whoami --show-server)"
}

detect_container() {
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD=podman
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD=docker
  else
    die "podman or docker required for image builds (or pass --skip-build)"
  fi
}

ensure_project() {
  if [[ "$DRY_RUN" == true ]]; then
    log "would create/switch to project ${PROJECT} (display-name=${DISPLAY_NAME})"
    return 0
  fi
  if oc get project "${PROJECT}" >/dev/null 2>&1; then
    log "Project ${PROJECT} already exists — switching"
    oc project "${PROJECT}" >/dev/null
  else
    log "Creating project ${PROJECT} (display name: ${DISPLAY_NAME})"
    oc new-project "${PROJECT}" \
      --display-name="${DISPLAY_NAME}" \
      --description="${DESCRIPTION}" >/dev/null
  fi
}

secret_literal() {
  local key=$1
  if [[ "$DRY_RUN" == true ]]; then
    echo "dry-run-${key}"
    return 0
  fi
  openssl rand -hex 32
}

ensure_secrets() {
  if [[ "$DRY_RUN" == true ]]; then
    log "would create secrets worldmonitor-core and worldmonitor-api-keys in ${PROJECT}"
    return 0
  fi

  if ! oc get secret worldmonitor-core -n "${PROJECT}" >/dev/null 2>&1; then
    log "Creating secret worldmonitor-core"
    oc create secret generic worldmonitor-core -n "${PROJECT}" \
      --from-literal=REDIS_PASSWORD="$(secret_literal REDIS_PASSWORD)" \
      --from-literal=REDIS_TOKEN="$(secret_literal REDIS_TOKEN)" \
      --from-literal=RELAY_SHARED_SECRET="$(secret_literal RELAY_SHARED_SECRET)"
  else
    log "Secret worldmonitor-core already exists"
  fi

  if ! oc get secret worldmonitor-api-keys -n "${PROJECT}" >/dev/null 2>&1; then
    log "Creating empty secret worldmonitor-api-keys (optional API keys)"
    oc create secret generic worldmonitor-api-keys -n "${PROJECT}" \
      --from-literal=GROQ_API_KEY="" \
      --from-literal=OPENROUTER_API_KEY="" \
      --from-literal=AISSTREAM_API_KEY="" \
      --from-literal=FINNHUB_API_KEY="" \
      --from-literal=FRED_API_KEY="" \
      --from-literal=EIA_API_KEY="" \
      --from-literal=NASA_FIRMS_API_KEY="" \
      --from-literal=ACLED_EMAIL="" \
      --from-literal=ACLED_PASSWORD="" \
      --from-literal=ACLED_ACCESS_TOKEN="" \
      --from-literal=CLOUDFLARE_API_TOKEN="" \
      --from-literal=AVIATIONSTACK_API="" \
      --from-literal=TRAVELPAYOUTS_API_TOKEN="" \
      --from-literal=LLM_API_URL="" \
      --from-literal=LLM_API_KEY="" \
      --from-literal=LLM_MODEL=""
  else
    log "Secret worldmonitor-api-keys already exists"
  fi
}

registry_login() {
  local registry token user
  if [[ "$DRY_RUN" == true ]]; then
    registry="registry.example.com"
    log "would login to registry ${registry}"
    echo "${registry}"
    return 0
  fi

  registry="$(oc registry info)"
  [[ -n "${registry}" ]] || die "Could not resolve OpenShift registry — is the registry route enabled?"

  token="$(oc whoami -t)"
  user="$(oc whoami)"
  echo "${token}" | "${CONTAINER_CMD}" login "${registry}" --username "${user}" --password-stdin >/dev/null
  log "Logged in to ${registry}"
  echo "${registry}"
}

build_and_push() {
  local registry=$1
  local component=$2
  local dockerfile=$3
  local context=$4
  local tag="${registry}/${PROJECT}/${component}:latest"

  log "Building ${component} → ${tag}"
  if [[ "$DRY_RUN" == true ]]; then
    log "would build: ${CONTAINER_CMD} build -t ${tag} -f ${dockerfile} ${context}"
    log "would push: ${CONTAINER_CMD} push ${tag}"
    return 0
  fi

  "${CONTAINER_CMD}" build -t "${tag}" -f "${dockerfile}" "${context}"
  "${CONTAINER_CMD}" push "${tag}"
}

build_images() {
  [[ "$SKIP_BUILD" == true ]] && { log "Skipping image build (--skip-build)"; return 0; }

  if [[ "$DRY_RUN" != true ]]; then
    detect_container
  else
    CONTAINER_CMD="${CONTAINER_CMD:-podman}"
  fi
  local registry
  registry="$(registry_login)"

  build_and_push "${registry}" app "${ROOT_DIR}/Dockerfile" "${ROOT_DIR}"
  build_and_push "${registry}" ais-relay "${ROOT_DIR}/Dockerfile.relay" "${ROOT_DIR}"
  build_and_push "${registry}" redis-rest "${ROOT_DIR}/docker/Dockerfile.redis-rest" "${ROOT_DIR}/docker"
}

write_overlay() {
  local overlay_dir=$1
  local registry=$2

  mkdir -p "${overlay_dir}"
  cat > "${overlay_dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ${ROOT_DIR}/deploy/openshift

namespace: ${PROJECT}

images:
  - name: worldmon/app
    newName: ${registry}/${PROJECT}/app
    newTag: latest
  - name: worldmon/ais-relay
    newName: ${registry}/${PROJECT}/ais-relay
    newTag: latest
  - name: worldmon/redis-rest
    newName: ${registry}/${PROJECT}/redis-rest
    newTag: latest
EOF
}

apply_stack() {
  local overlay_dir registry
  overlay_dir="$(mktemp -d)"

  if [[ "$SKIP_BUILD" == true ]]; then
    registry="image-registry.openshift-image-registry.svc:5000"
    warn "Using in-cluster registry hostname — ensure images exist at ${registry}/${PROJECT}/*"
  else
    registry="$(oc registry info 2>/dev/null || true)"
    [[ -n "${registry}" ]] || registry="image-registry.openshift-image-registry.svc:5000"
  fi

  write_overlay "${overlay_dir}" "${registry}"

  log "Applying manifests to project ${PROJECT}"
  if [[ "$DRY_RUN" == true ]]; then
    log "would run: oc apply -k ${overlay_dir}"
    rm -rf "${overlay_dir}"
    return 0
  fi

  oc apply -k "${overlay_dir}"
  rm -rf "${overlay_dir}"
}

wait_for_rollout() {
  if [[ "$DRY_RUN" == true ]]; then
    log "would wait for deployments: worldmonitor redis-rest ais-relay"
    return 0
  fi
  for dep in redis-rest ais-relay worldmonitor; do
    log "Waiting for deployment/${dep} …"
    oc rollout status "deployment/${dep}" -n "${PROJECT}" --timeout=600s
  done
  log "Waiting for statefulset/redis …"
  oc rollout status "statefulset/redis" -n "${PROJECT}" --timeout=600s
}

print_route() {
  if [[ "$DRY_RUN" == true ]]; then
    log "would print route URL for worldmonitor"
    return 0
  fi
  local host
  host="$(oc get route worldmonitor -n "${PROJECT}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    log "Dashboard URL: https://${host}"
  else
    warn "Route not ready — check: oc get route -n ${PROJECT}"
  fi
}

run_seeders() {
  [[ "$SKIP_SEED" == true ]] && { log "Skipping seeders (--skip-seed)"; return 0; }

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not on PATH — skip seeding. Run manually:"
    warn "  oc -n ${PROJECT} port-forward svc/redis-rest 8079:80"
    warn "  export UPSTASH_REDIS_REST_TOKEN=\$(oc get secret worldmonitor-core -n ${PROJECT} -o jsonpath='{.data.REDIS_TOKEN}' | base64 -d)"
    warn "  ./scripts/run-seeders.sh"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "would port-forward redis-rest and run ./scripts/run-seeders.sh"
    return 0
  fi

  local token pf_pid
  token="$(oc get secret worldmonitor-core -n "${PROJECT}" -o jsonpath='{.data.REDIS_TOKEN}' | base64 -d)"
  export UPSTASH_REDIS_REST_URL=http://127.0.0.1:8079
  export UPSTASH_REDIS_REST_TOKEN="${token}"
  export REDIS_TOKEN="${token}"

  log "Port-forwarding redis-rest for seeders …"
  oc port-forward "svc/redis-rest" 8079:80 -n "${PROJECT}" >/dev/null 2>&1 &
  pf_pid=$!
  trap 'kill "${pf_pid}" 2>/dev/null || true' RETURN

  sleep 2
  run "${ROOT_DIR}/scripts/run-seeders.sh" || warn "Some seeders failed — stack is still usable"
  kill "${pf_pid}" 2>/dev/null || true
  trap - RETURN
}

main() {
  log "World Monitor → OpenShift 4 project \"${PROJECT}\" (${DISPLAY_NAME})"
  require_oc
  ensure_project
  ensure_secrets
  build_images
  apply_stack
  wait_for_rollout
  print_route
  run_seeders
  log "Deploy complete."
}

main "$@"
