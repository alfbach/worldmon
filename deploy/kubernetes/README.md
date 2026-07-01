# World Monitor — Kubernetes

Self-hosted stack matching `docker-compose.yml`: Redis, Upstash-compatible REST proxy, AIS relay, and the World Monitor app (nginx + Node sidecar).

## Build container images

The published `ghcr.io/koala73/worldmonitor` image is **frontend-only**. For Kubernetes self-hosting, build the three runtime images from this repo:

```bash
git clone https://github.com/koala73/worldmonitor.git
cd worldmonitor

docker build -t worldmonitor/app:latest -f Dockerfile .
docker build -t worldmonitor/ais-relay:latest -f Dockerfile.relay .
docker build -t worldmonitor/redis-rest:latest -f docker/Dockerfile.redis-rest docker/
```

Push to your registry and update `kustomization.yaml` `images:` entries.

## Deploy

```bash
# 1. Create secrets (required)
cp deploy/kubernetes/secrets.example.yaml deploy/kubernetes/secrets.yaml
# Generate values: openssl rand -hex 32
# Edit secrets.yaml — set REDIS_PASSWORD, REDIS_TOKEN, RELAY_SHARED_SECRET
kubectl apply -f deploy/kubernetes/secrets.yaml

# Optional API keys secret (uncomment block in secrets.example.yaml or create manually)
# kubectl create secret generic worldmonitor-api-keys -n worldmonitor \
#   --from-literal=GROQ_API_KEY= --from-literal=AISSTREAM_API_KEY=

# 2. Apply the stack
kubectl apply -k deploy/kubernetes/

# 3. Wait for pods
kubectl -n worldmonitor get pods -w
```

## Access

**Port forward (quick test):**

```bash
kubectl -n worldmonitor port-forward svc/worldmonitor 3000:8080
open http://localhost:3000
```

**Ingress:** edit `ingress.yaml` host (`worldmonitor.local`) and apply. Requires an NGINX Ingress Controller.

## Seed Redis data

Seed scripts run on a workstation with repo checkout and Node.js 22:

```bash
kubectl -n worldmonitor port-forward svc/redis-rest 8079:80 &
export UPSTASH_REDIS_REST_URL=http://localhost:8079
export UPSTASH_REDIS_REST_TOKEN="<REDIS_TOKEN from secrets.yaml>"
./scripts/run-seeders.sh
```

## Components

| Resource | Image | Port |
|----------|-------|------|
| `worldmonitor` | `worldmonitor/app` | 8080 |
| `ais-relay` | `worldmonitor/ais-relay` | 3004 |
| `redis-rest` | `worldmonitor/redis-rest` | 80 |
| `redis` | `redis:7-alpine` | 6379 |

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `worldmonitor` namespace |
| `secrets.example.yaml` | Template for core secrets |
| `redis.yaml` | Redis StatefulSet + PVC |
| `redis-rest.yaml` | Upstash-compatible REST proxy |
| `ais-relay.yaml` | AIS / OSINT relay |
| `worldmonitor.yaml` | Main application |
| `ingress.yaml` | Optional HTTP ingress |
| `kustomization.yaml` | Kustomize bundle + image overrides |

See also [SELF_HOSTING.md](../../SELF_HOSTING.md) for API keys and operational notes.
