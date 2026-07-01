import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import { join } from 'node:path';
import { constants } from 'node:fs';

const ROOT = process.cwd();
const OPENSHIFT_DIR = join(ROOT, 'deploy/openshift');
const DEPLOY_SCRIPT = join(ROOT, 'scripts/deploy-openshift.sh');

describe('OpenShift 4 deploy', () => {
  it('ships deploy-openshift.sh and openshift manifests', async () => {
    await access(DEPLOY_SCRIPT, constants.X_OK);
    const kustomization = await readFile(join(OPENSHIFT_DIR, 'kustomization.yaml'), 'utf8');
    assert.match(kustomization, /namespace: worldmon/);
    assert.match(kustomization, /route\.yaml/);
    const route = await readFile(join(OPENSHIFT_DIR, 'route.yaml'), 'utf8');
    assert.match(route, /route\.openshift\.io\/v1/);
    assert.match(route, /name: worldmonitor/);
  });

  it('deploy script creates project worldmon and applies stack', async () => {
    const script = await readFile(DEPLOY_SCRIPT, 'utf8');
    assert.match(script, /oc new-project/);
    assert.match(script, /worldmon/);
    assert.match(script, /Worldmon/);
    assert.match(script, /deploy\/openshift/);
    assert.match(script, /worldmonitor-core/);
    assert.match(script, /oc get route worldmonitor/);
  });

  it('npm script exposes deploy:openshift', async () => {
    const pkg = JSON.parse(await readFile(join(ROOT, 'package.json'), 'utf8'));
    assert.match(pkg.scripts['deploy:openshift'], /deploy-openshift\.sh/);
  });
});
