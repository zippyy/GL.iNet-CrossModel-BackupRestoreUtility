#!/usr/bin/env node
// Lightweight repo lint for the Docker edition:
//   - node --check every JS file
//   - JSON validity of package.json / package-lock.json
//   - vendored runtime pin file present + SHA256SUMS consistent
//   - no credentials/placeholders leaked into tracked files
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let failures = 0;

const fail = (msg) => { console.error(`FAIL ${msg}`); failures += 1; };
const ok = (msg) => { console.log(`ok   ${msg}`); };

// 1. JS syntax
const jsFiles = [];
const walk = (dir) => {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'data' || entry.name === 'runtime') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith('.js')) jsFiles.push(full);
  }
};
walk(root);
for (const file of jsFiles) {
  const result = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
  if (result.status !== 0) fail(`syntax ${path.relative(root, file)}: ${result.stderr.trim()}`);
}
ok(`node --check on ${jsFiles.length} JS files`);

// 2. JSON validity
for (const file of ['package.json', 'package-lock.json']) {
  try { JSON.parse(fs.readFileSync(path.join(root, file), 'utf8')); ok(`JSON ${file}`); }
  catch (error) { fail(`JSON ${file}: ${error.message}`); }
}

// 3. Vendored runtime pin + checksums
const pinFile = path.join(root, 'runtime', 'UPSTREAM_MAIN_COMMIT');
const sumsFile = path.join(root, 'runtime', 'native', 'SHA256SUMS');
const runtimeDir = path.join(root, 'runtime', 'native');
if (!fs.existsSync(pinFile)) {
  fail('runtime/UPSTREAM_MAIN_COMMIT is missing (run scripts/sync-native-runtime.sh)');
} else {
  const pin = fs.readFileSync(pinFile, 'utf8').trim();
  if (!/^[0-9a-f]{40}$/.test(pin)) fail(`invalid pin: ${pin}`);
  else ok(`runtime pin ${pin}`);
  if (!fs.existsSync(sumsFile)) {
    fail('runtime/native/SHA256SUMS is missing');
  } else {
    const result = spawnSync('sha256sum', ['-c', sumsFile], { cwd: runtimeDir, encoding: 'utf8' });
    if (result.status !== 0) fail(`SHA256SUMS verification: ${result.stderr || result.stdout}`);
    else ok('vendored runtime SHA256SUMS verify');
  }
}

// 4. No obvious secret material in tracked source. Test fixtures are excluded
//    from the leak scan: they intentionally carry throwaway credentials
//    (router-secret-pw, ephemeral admin secrets) to exercise the auth paths,
//    and those values are never valid against any real deployment. The lint
//    script itself is excluded because its source contains the literal
//    pattern text (self-reference).
const secretScan = spawnSync('git', ['grep', '-nE', '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ADMIN_PASSWORD=.{4,}|password["\']?\\s*[:=]\\s*["\'][^"\']{4,})', '--', ':!runtime/native/*', ':!package-lock.json', ':!test/*', ':!docs/*', ':!scripts/lint.js'], { cwd: root, encoding: 'utf8' });
if (secretScan.status === 0 && secretScan.stdout.trim()) {
  fail(`possible secret material in tracked files:\n${secretScan.stdout.slice(0, 2000)}`);
} else {
  ok('no secret material in tracked source');
}

if (failures) {
  console.error(`\n${failures} lint failure(s)`);
  process.exit(1);
}
console.log('\nAll lint checks passed.');
