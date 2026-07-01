# World Monitor — OpenShift 4

Deploy the self-hosted stack into a new OpenShift 4 project **`worldmon`** (display name **Worldmon**).

## One-command deploy

Requires [OpenShift CLI (`oc`)](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) 4.x, logged in to your cluster, and **Podman** or **Docker** for image builds.

```bash
git clone https://github.com/koala73/worldmonitor.git
cd worldmonitor
./scripts/deploy-openshift.sh
```

The script will:

1. Create project `worldmon` (display name **Worldmon**)
2. Generate core secrets (`REDIS_PASSWORD`, `REDIS_TOKEN`, `RELAY_SHARED_SECRET`)
3. Build and push three container images to the cluster registry
4. Apply Deployments, Services, Redis PVC, and an edge-TLS **Route**
5. Wait for rollouts and print the dashboard URL

## Options

| Flag | Purpose |
|------|---------|
| `--skip-build` | Skip image build/push (images already in registry) |
| `--skip-seed` | Skip Redis seed job |
| `--dry-run` | Print planned steps only |
| `--project <name>` | Override project name (default: `worldmon`) |

```bash
npm run deploy:openshift
npm run deploy:openshift -- --skip-build
```

## Manual steps

```bash
oc new-project worldmon --display-name="Worldmon"
cp deploy/kubernetes/secrets.example.yaml /tmp/secrets.yaml
# edit REDIS_PASSWORD, REDIS_TOKEN, RELAY_SHARED_SECRET
oc apply -f /tmp/secrets.yaml -n worldmon

# build images — see deploy/kubernetes/README.md
REGISTRY="$(oc registry info)"
podman build -t "${REGISTRY}/worldmon/app:latest" -f Dockerfile .
# … push app, ais-relay, redis-rest …

oc apply -k deploy/openshift/
oc get route worldmonitor -n worldmon
```

## Seed Redis

```bash
kubectl -n worldmon port-forward svc/redis-rest 8079:80 &
export UPSTASH_REDIS_REST_URL=http://localhost:8079
export UPSTASH_REDIS_REST_TOKEN="$(oc get secret worldmonitor-core -n worldmon -o jsonpath='{.data.REDIS_TOKEN}' | base64 -d)"
./scripts/run-seeders.sh
```

Or run `./scripts/deploy-openshift.sh` without `--skip-seed` (requires Node.js 22 on the workstation).

## Registry access

Image push uses `oc registry info`. If push fails, ask your cluster admin to expose the registry route, or use `--skip-build` and import pre-built images:

```bash
oc import-image worldmon/app:latest --from=your-registry/worldmon/app:latest --confirm -n worldmon
```

See [SELF_HOSTING.md](../../SELF_HOSTING.md) for API keys and operations.
