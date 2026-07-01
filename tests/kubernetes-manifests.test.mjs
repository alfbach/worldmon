import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';

const K8S_DIR = join(process.cwd(), 'deploy/kubernetes');

describe('kubernetes manifests', () => {
  it('ships the expected manifest files', async () => {
    const files = await readdir(K8S_DIR);
    for (const name of [
      'namespace.yaml',
      'secrets.example.yaml',
      'redis.yaml',
      'redis-rest.yaml',
      'ais-relay.yaml',
      'worldmonitor.yaml',
      'ingress.yaml',
      'kustomization.yaml',
      'README.md',
    ]) {
      assert.equal(files.includes(name), true, `missing deploy/kubernetes/${name}`);
    }
  });

  it('kustomization references all stack resources', async () => {
    const kustomization = await readFile(join(K8S_DIR, 'kustomization.yaml'), 'utf8');
    for (const resource of [
      'namespace.yaml',
      'redis.yaml',
      'redis-rest.yaml',
      'ais-relay.yaml',
      'worldmonitor.yaml',
      'ingress.yaml',
    ]) {
      assert.match(kustomization, new RegExp(resource.replace('.', '\\.')));
    }
  });

  it('worldmonitor deployment uses the self-host app image and health probe', async () => {
    const app = await readFile(join(K8S_DIR, 'worldmonitor.yaml'), 'utf8');
    assert.match(app, /image: worldmonitor\/app:latest/);
    assert.match(app, /path: \/api\/health/);
    assert.match(app, /UPSTASH_REDIS_REST_URL/);
    assert.match(app, /WS_RELAY_URL/);
  });

  it('secrets example documents required core keys', async () => {
    const secrets = await readFile(join(K8S_DIR, 'secrets.example.yaml'), 'utf8');
    for (const key of ['REDIS_PASSWORD', 'REDIS_TOKEN', 'RELAY_SHARED_SECRET']) {
      assert.match(secrets, new RegExp(`${key}:`));
    }
  });
});
