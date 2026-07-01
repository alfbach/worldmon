import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { readFile, access } from 'node:fs/promises';
import { constants } from 'node:fs';

import {
  ensureSelfHostEnvFile,
  generateSecretHex,
  readProjectNodeVersion,
  resolveNodeDistVersion,
  SELF_HOST_REQUIRED_ENV_KEYS,
} from '../scripts/bootstrap-worktree.mjs';

const quiet = () => {};

describe('self-host bootstrap helpers', () => {
  it('reads the Node.js version from .nvmrc', () => {
    const version = readProjectNodeVersion(process.cwd());
    assert.match(version, /^\d+/);
  });

  it('resolves major-only .nvmrc to a nodejs.org patch release', async () => {
    const spec = readProjectNodeVersion(process.cwd());
    const resolved = await resolveNodeDistVersion(process.cwd());
    assert.match(resolved, /^\d+\.\d+\.\d+$/);
    if (/^\d+$/.test(spec)) {
      assert.match(resolved, new RegExp(`^${spec}\\.`));
    } else {
      assert.equal(resolved, spec);
    }
  });

  it('generates 64-char hex secrets', () => {
    const secret = generateSecretHex(32);
    assert.equal(secret.length, 64);
    assert.match(secret, /^[0-9a-f]+$/);
  });

  it('creates .env from .env.example with required self-host secrets', () => {
    const root = mkdtempSync(join(tmpdir(), 'wm-selfhost-env-'));
    try {
      writeFileSync(
        join(root, '.env.example'),
        '# example\nREDIS_PASSWORD=\nREDIS_TOKEN=\nRELAY_SHARED_SECRET=\n',
        'utf8',
      );

      const result = ensureSelfHostEnvFile({ log: quiet, rootDir: root });

      assert.equal(result.created, true);
      assert.deepEqual(result.appended.sort(), [...SELF_HOST_REQUIRED_ENV_KEYS].sort());
      const env = readFileSync(join(root, '.env'), 'utf8');
      for (const key of SELF_HOST_REQUIRED_ENV_KEYS) {
        assert.match(env, new RegExp(`^${key}=[0-9a-f]{64}$`, 'm'));
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('does not overwrite existing self-host secret values', () => {
    const root = mkdtempSync(join(tmpdir(), 'wm-selfhost-env-'));
    try {
      writeFileSync(
        join(root, '.env'),
        'REDIS_PASSWORD=already-set\nREDIS_TOKEN=\nRELAY_SHARED_SECRET=keep-me\n',
        'utf8',
      );

      const result = ensureSelfHostEnvFile({ log: quiet, rootDir: root });

      assert.equal(result.created, false);
      assert.deepEqual(result.appended, ['REDIS_TOKEN']);
      const env = readFileSync(join(root, '.env'), 'utf8');
      assert.match(env, /^REDIS_PASSWORD=already-set$/m);
      assert.match(env, /^RELAY_SHARED_SECRET=keep-me$/m);
      assert.match(env, /^REDIS_TOKEN=[0-9a-f]{64}$/m);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('creates minimal .env without copying full .env.example', () => {
    const root = mkdtempSync(join(tmpdir(), 'wm-selfhost-env-'));
    try {
      writeFileSync(
        join(root, '.env.example'),
        'RESEND_FROM_EMAIL=WorldMonitor <alerts@worldmonitor.app>\nREDIS_PASSWORD=\n',
        'utf8',
      );

      ensureSelfHostEnvFile({ log: quiet, rootDir: root });

      const env = readFileSync(join(root, '.env'), 'utf8');
      assert.doesNotMatch(env, /RESEND_FROM_EMAIL/);
      assert.match(env, /RELAY_SHARED_SECRET=[0-9a-f]{64}/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe('RHEL 10 startup scripts', () => {
  const root = process.cwd();

  it('ships executable startup and setup scripts', async () => {
    for (const rel of [
      'scripts/startup.sh',
      'scripts/startup-docker.sh',
      'scripts/startup-rhel10.sh',
      'scripts/setup-host-rhel10.sh',
    ]) {
      const path = join(root, rel);
      assert.equal(existsSync(path), true, `${rel} must exist`);
      const content = await readFile(path, 'utf8');
      assert.match(content, /^#!\/usr\/bin\/env bash/m);
      assert.match(content, /set -euo pipefail/);
    }
  });

  it('startup script orchestrates bootstrap, compose, and seeders', async () => {
    const content = await readFile(join(root, 'scripts/startup-rhel10.sh'), 'utf8');
    assert.match(content, /bootstrap-worktree\.mjs/);
    assert.match(content, /docker-compose\.yml/);
    assert.match(content, /run-seeders\.sh/);
    assert.match(content, /--ensure-self-host-env/);
  });

  it('setup script installs dnf packages and optional user Node.js', async () => {
    const content = await readFile(join(root, 'scripts/setup-host-rhel10.sh'), 'utf8');
    assert.match(content, /dnf install/);
    assert.match(content, /podman/);
    assert.match(content, /nodejs\.org/);
    assert.match(content, /--node-only/);
  });

  it('npm scripts expose startup:rhel10 and setup:rhel10', async () => {
    const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
    assert.match(pkg.scripts.startup, /startup\.sh/);
    assert.match(pkg.scripts['startup:rhel10'], /startup\.sh --rhel10/);
    assert.match(pkg.scripts['setup:rhel10'], /setup-host-rhel10\.sh/);
  });

  it('unified startup.sh dispatches to platform scripts', async () => {
    const script = await readFile(join(root, 'scripts/startup.sh'), 'utf8');
    assert.match(script, /startup-rhel10\.sh/);
    assert.match(script, /deploy-openshift\.sh/);
    assert.match(script, /startup-docker\.sh/);
    await access(join(root, 'scripts/startup-docker.sh'), constants.X_OK);
  });
});
