import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';

const root = process.cwd();
const loader = join(root, 'scripts/load-dotenv.sh');

describe('load-dotenv.sh', () => {
  it('exports values without shell-evaluating angle brackets', () => {
    const dir = mkdtempSync(join(tmpdir(), 'wm-dotenv-'));
    try {
      const envPath = join(dir, '.env');
      writeFileSync(
        envPath,
        [
          'REDIS_TOKEN=abc123',
          'RESEND_FROM_EMAIL=WorldMonitor <alerts@worldmonitor.app>',
          'QUOTED="hello world"',
        ].join('\n'),
        'utf8',
      );

      const out = execFileSync('bash', [loader, envPath], { encoding: 'utf8' });
      assert.match(out, /export REDIS_TOKEN=abc123/);
      assert.match(out, /export RESEND_FROM_EMAIL='WorldMonitor <alerts@worldmonitor.app>'/);
      assert.match(out, /export QUOTED='hello world'/);

      const subset = execFileSync('bash', [loader, envPath, 'REDIS_TOKEN'], {
        encoding: 'utf8',
      });
      assert.match(subset, /export REDIS_TOKEN=abc123/);
      assert.doesNotMatch(subset, /RESEND_FROM_EMAIL/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
