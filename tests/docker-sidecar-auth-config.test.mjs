import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import test from 'node:test';

const root = resolve(import.meta.dirname, '..');

function readProjectFile(path) {
  return readFileSync(resolve(root, path), 'utf8');
}

test('Docker entrypoint creates and exports an internal LOCAL_API_TOKEN when unset', () => {
  const entrypoint = readProjectFile('docker/entrypoint.sh');

  assert.match(entrypoint, /if \[ -z "\$\{LOCAL_API_TOKEN:-\}" \]; then/);
  assert.match(entrypoint, /openssl rand|randomBytes\(32\)/);
  assert.match(entrypoint, /export LOCAL_API_TOKEN/);
  assert.match(entrypoint, /envsubst '\$LOCAL_API_PORT \$LOCAL_API_TOKEN'/);
  assert.match(entrypoint, /nginx -t -c \/tmp\/nginx\.conf/);
  assert.match(entrypoint, /\[A-Za-z_\]\[A-Za-z0-9_\]\*\)/);
  assert.match(entrypoint, /WM_ENTRYPOINT_VERSION=3/);
  assert.match(entrypoint, /WM_USE_DOCKER_SECRETS/);
});

test('Docker nginx uses dynamic gzip only (no gzip_static module required)', () => {
  const nginx = readProjectFile('docker/nginx.conf');

  assert.doesNotMatch(nginx, /^\s*gzip_static\s+on;/m);
  assert.doesNotMatch(nginx, /load_module/);
  assert.match(nginx, /gzip on;/);
});

test('Docker nginx injects LOCAL_API_TOKEN on private sidecar proxy requests', () => {
  const nginx = readProjectFile('docker/nginx.conf');

  assert.match(nginx, /location \/api\/ \{/);
  assert.match(nginx, /proxy_pass http:\/\/127\.0\.0\.1:\$\{LOCAL_API_PORT\}/);
  assert.match(nginx, /proxy_set_header Authorization "Bearer \$\{LOCAL_API_TOKEN\}"/);
});

test('Docker healthcheck continues through nginx so the injected token is applied', () => {
  const dockerfile = readProjectFile('Dockerfile');

  assert.match(dockerfile, /HEALTHCHECK[\s\S]*wget -qO- http:\/\/localhost:8080\/api\/health/);
});
