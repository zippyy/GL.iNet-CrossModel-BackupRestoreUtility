// Runtime-drift guard.
//
// Verifies that every vendored file under runtime/native/ is byte-identical to
// the pinned main commit (runtime/UPSTREAM_MAIN_COMMIT) as recorded in
// runtime/native/SHA256SUMS, and reports whether origin/main has moved past
// the pin.
//
//   - vendored content altered from the pin  -> HARD FAILURE
//   - newer main exists than the pin         -> explicit drift report (WARN)
//     (a maintainer reruns scripts/sync-native-runtime.sh <new-sha>)
//
// Runs from the repository root and requires the git history that contains the
// pin (the docker branch and main share this repository's object store). If
// the pin commit is not present (shallow checkout), it falls back to verifying
// against the checked-in SHA256SUMS only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pin = fs.readFileSync(path.join(root, 'runtime', 'UPSTREAM_MAIN_COMMIT'), 'utf8').trim();
assert.match(pin, /^[0-9a-f]{40}$/, 'pin must be a full SHA-1');

const runtimeDir = path.join(root, 'runtime', 'native');
const expectedFiles = ['core.sh', 'glinet-crossmodel', 'glinet-crossmodel-backup', 'glinet-crossmodel-remote', 'glinet-crossmodel-validate'];

function gitShow(commit, file) {
  const result = spawnSync('git', ['show', `${commit}:${file}`], { cwd: root, encoding: 'utf8' });
  if (result.status !== 0) return null;
  return result.stdout;
}

test('runtime pin is a full SHA-1', () => {
  assert.match(pin, /^[0-9a-f]{40}$/);
});

test('every vendored runtime file is byte-identical to the pinned main commit', () => {
  for (const file of expectedFiles) {
    const onDisk = fs.readFileSync(path.join(runtimeDir, file), 'utf8');
    const upstream = gitShow(pin, `openwrt/luci-app-glinet-crossmodel-backup/root/${upstreamPathFor(file)}`);
    assert.ok(upstream !== null, `pin commit ${pin} must contain ${file}`);
    assert.equal(
      crypto.createHash('sha256').update(onDisk).digest('hex'),
      crypto.createHash('sha256').update(upstream).digest('hex'),
      `${file} differs from the pinned main revision — rerun scripts/sync-native-runtime.sh ${pin}`
    );
  }
});

test('vendored SHA256SUMS matches the on-disk files', () => {
  const result = spawnSync('sha256sum', ['-c', path.join(runtimeDir, 'SHA256SUMS')], { cwd: runtimeDir, encoding: 'utf8' });
  assert.equal(result.status, 0, `SHA256SUMS verification failed:\n${result.stdout || result.stderr}`);
});

test('reports whether main has moved past the pin (informational)', () => {
  const head = spawnSync('git', ['rev-parse', 'origin/main'], { cwd: root, encoding: 'utf8' });
  if (head.status !== 0) return; // no remote ref in this checkout; skip
  const originMain = head.stdout.trim();
  if (/^[0-9a-f]{40}$/.test(originMain) && originMain !== pin) {
    // Deliberately informational only: newer main is not a hard failure, but
    // it is surfaced in test output for maintainers.
    console.log(`# DRIFT-INFO: runtime pinned at ${pin.slice(0, 12)}; origin/main is ${originMain.slice(0, 12)}. Rerun scripts/sync-native-runtime.sh <new-sha> after reviewing main changes.`);
  }
});

function upstreamPathFor(basename) {
  switch (basename) {
    case 'core.sh': return 'usr/lib/glinet-crossmodel/core.sh';
    case 'glinet-crossmodel': return 'usr/bin/glinet-crossmodel';
    default: return `usr/libexec/${basename}`;
  }
}
