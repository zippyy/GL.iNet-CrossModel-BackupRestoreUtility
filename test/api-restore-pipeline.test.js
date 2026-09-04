// API -> job -> SSH -> canonical runtime restore pipeline proof (Blocker 3).
//
// This is NOT a mocked job-layer test. It drives the REAL controller over
// HTTP (server.js on an ephemeral port), through authentication + CSRF, job
// creation, the persisted job runner, real ssh2 transport, SFTP archive
// transfer, and the STREAMED VENDORED CANONICAL RUNTIME executing on an
// in-process ssh2 router. The only test-controlled surfaces are the router
// environment (the canonical runtime's own documented sandbox overrides,
// mirroring the native harness) and deterministic failure injection after a
// real target mutation.
//
// Three canonical executions are proven end to end:
//   1. control:        restore succeeds and the sandbox target is mutated;
//   2. rolled-back:    restore mutates the target, a later apply phase fails,
//                      the REAL canonical rollback runs, and the target tree
//                      hash is byte-identical to pre-state; the job ends
//                      `rolled-back` and the API exposes failure + verified
//                      rollback markers;
//   3. rollback-failed: restore fails AND rollback cannot complete (its
//                      restore path is blocked), the job ends
//                      `rollback-failed` and the API exposes it.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

import { generateKeys, startFakeRouter } from './fake-router.js';

// ---- Real controller bootstrap -------------------------------------------
// server.js reads its configuration from the environment at import time, so
// set an isolated data dir + admin secret + ephemeral port BEFORE importing.
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gcm-pipeline-'));
const dataDir = path.join(work, 'data');
const secretFile = path.join(work, 'admin-secret');
fs.writeFileSync(secretFile, 'pipeline-admin-secret-123\n');
process.env.DATA_DIR = dataDir;
process.env.GCM_ADMIN_PASSWORD_FILE = secretFile;
process.env.PORT = '0';
process.env.GCM_LOG_LEVEL = 'ERROR';
process.env.GCM_FILE_LOG = '0';
process.env.GCM_SYSLOG = '0';

const { server: httpServer } = await import('../server.js');
if (!httpServer.address()) {
  await new Promise((resolve) => httpServer.once('listening', resolve));
}

const isRoot = typeof process.getuid === 'function' && process.getuid() === 0;
const ROUTER_PASSWORD = 'router-secret-pw';
const ADMIN_PASSWORD = 'pipeline-admin-secret-123';

// ---- Router-side sandbox (canonical runtime env overrides) ----------------
// Mirrors how the native test harness redirects the runtime at its documented
// sandbox roots. The streamed runtime is byte-identical to the pinned main
// revision; only its environment points every mutation at a scratch tree.
let activeSandbox = null; // swapped per sub-case; the execHook reads it live

function makeSandbox(label, { blockTmpAsFile = false } = {}) {
  const root = path.join(work, `sandbox-${label}-${crypto.randomBytes(3).toString('hex')}`);
  const target = path.join(root, 'target');
  const delta = path.join(root, 'delta');
  const rollback = path.join(root, 'rollback');
  const staged = path.join(root, 'staged');
  fs.mkdirSync(path.join(target, 'etc', 'config'), { recursive: true });
  fs.mkdirSync(delta, { recursive: true });
  fs.mkdirSync(rollback, { recursive: true });
  fs.mkdirSync(staged, { recursive: true });
  if (blockTmpAsFile) {
    fs.writeFileSync(path.join(target, 'tmp'), 'I am a file, not a directory\n');
  } else {
    fs.mkdirSync(path.join(target, 'tmp'), { recursive: true });
  }
  return {
    root, target, delta, rollback, staged,
    env: {
      GCM_ROLLBACK_ROOT: rollback,
      GCM_ROLLBACK_TARGET_ROOT: target,
      GCM_CONFIG_TARGET_ROOT: target,
      GCM_EXTRA_TARGET_ROOT: target,
      GCM_STAGED_ROOT: staged,
      GCM_STAGED_TARGET_ROOT: target,
      GCM_UCI_DELTA_DIR: delta,
      GCM_LOG_LEVEL: 'error',
      GCM_FILE_LOG: '0',
      GCM_SYSLOG: '0'
    }
  };
}

// Run a router command with the active sandbox environment (PATH inherited so
// the canonical runtime finds sha256sum/tar/sed on the host).
function runShellSandboxed(command, inputStream) {
  return new Promise((resolve) => {
    const child = spawn('/bin/sh', ['-c', command], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, ...activeSandbox.env }
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => { stdout += c.toString('utf8'); });
    child.stderr.on('data', (c) => { stderr += c.toString('utf8'); });
    if (inputStream) {
      inputStream.pipe(child.stdin);
      inputStream.on('error', () => { try { child.stdin.end(); } catch { /* closed */ } });
    } else {
      child.stdin.end();
    }
    child.on('close', (code) => resolve({ stdout, stderr, code: code ?? 0 }));
  });
}

// The clone archive carries one persistent extra member: extra/tmp/<PROBE>.
// The canonical snapshot resolves extra members against the REAL root
// (target="/$relative"), so the probe MUST exist at the literal /tmp/<PROBE>
// path — NOT os.tmpdir() (macOS returns /var/folders/.../T, which the runtime
// never looks at). It captures that file into the snapshot root, apply
// overwrites the sandbox target copy, and rollback restores it byte-for-byte.
const PROBE = `gcm-pipeline-${crypto.randomUUID()}`;
const REAL_PROBE = path.join('/tmp', PROBE);
const PRE_CONTENT = 'PRE-STATE-CONTENT\n';
const MUTATED_CONTENT = 'MUTATED-BY-RESTORE\n';

function writePreState() {
  // The sandbox "router" copy only exists when target/tmp is a directory; the
  // rollback-failed sandbox deliberately makes target/tmp a FILE so both the
  // apply and the rollback restore path are blocked. The real /tmp probe is
  // always written (the canonical snapshot physically captures it).
  const targetTmp = path.join(activeSandbox.target, 'tmp');
  if (fs.existsSync(targetTmp) && fs.statSync(targetTmp).isDirectory()) {
    fs.writeFileSync(path.join(targetTmp, PROBE), PRE_CONTENT);
  }
  fs.writeFileSync(REAL_PROBE, PRE_CONTENT);
}

function hashTargetTree() {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) out.push(`${crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex')}  ${path.relative(activeSandbox.target, full)}`);
    }
  };
  walk(activeSandbox.target);
  return out.sort().join('\n');
}

// ---- Canonical v2 clone archive builder ------------------------------------
async function buildCloneArchive() {
  const tree = path.join(work, `archive-tree-${crypto.randomBytes(4).toString('hex')}`);
  const prefix = path.join(tree, 'glinet-crossmodel');
  fs.mkdirSync(path.join(prefix, 'extra', 'tmp'), { recursive: true });
  fs.mkdirSync(path.join(prefix, 'artifacts', 'files'), { recursive: true });
  fs.mkdirSync(path.join(prefix, 'uci'), { recursive: true });
  fs.mkdirSync(path.join(prefix, 'source'), { recursive: true });
  const manifest = {
    format: 'glinet-crossmodel/v2',
    format_version: 2,
    tool_version: '2.0.0',
    backup_strategy: 'clone',
    profile_uuid: crypto.randomUUID(),
    profile_name: 'Pipeline clone fixture',
    notes: 'API->job->SSH->runtime pipeline proof',
    source_model: 'Test-Router',
    firmware_version: '4.8.2',
    openwrt_version: '23.05',
    architecture: process.arch === 'arm64' ? 'arm64' : 'x86_64',
    kernel_version: '6.6',
    device_fingerprint: ''
  };
  fs.writeFileSync(path.join(prefix, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  fs.writeFileSync(path.join(prefix, 'backup-info.txt'), 'pipeline fixture\n');
  fs.writeFileSync(path.join(prefix, 'packages.json'), '{}\n');
  // Persistent extra member = mutation vector: the archive carries MUTATED
  // content; the target starts with PRE content.
  fs.writeFileSync(path.join(prefix, 'extra', 'tmp', PROBE), MUTATED_CONTENT);
  // Custom-file artifact: when the custom-files category is selected, staging
  // under the real /root tree fails for a non-root runtime user (the
  // container runs non-root too) — the injected post-mutation failure.
  fs.writeFileSync(path.join(prefix, 'artifacts', 'files', 'stage-me.txt'), 'custom staged file\n');

  const checksums = spawn('sh', ['-c', 'cd "$1" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r f; do sha256sum "$f"; done > glinet-crossmodel/checksums.sha256', 'sh', tree]);
  const checksumErr = [];
  checksums.stderr.on('data', (c) => checksumErr.push(c.toString()));
  await new Promise((resolve, reject) => checksums.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`checksums failed: ${checksumErr.join('')}`)))));

  const archive = path.join(work, `fixture-${crypto.randomBytes(4).toString('hex')}.tar.gz`);
  const tar = spawn('tar', ['-C', tree, '-czf', archive, 'glinet-crossmodel']);
  const tarErr = [];
  tar.stderr.on('data', (c) => tarErr.push(c.toString()));
  await new Promise((resolve, reject) => tar.on('close', (code) => (code === 0 ? resolve(archive) : reject(new Error(`tar failed: ${tarErr.join('')}`)))));
  return archive;
}

// ---- HTTP helpers (real auth + CSRF over fetch) ----------------------------
let baseUrl;
let cookie;
let csrf;

async function api(pathname, { method = 'GET', body, form } = {}) {
  const headers = { Accept: 'application/json' };
  if (cookie) headers.Cookie = cookie;
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['X-CSRF-Token'] = csrf || '';
  }
  if (form !== undefined) headers['X-CSRF-Token'] = csrf || '';
  const res = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : form !== undefined ? form : undefined
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text }; }
  data._status = res.status;
  return data;
}

async function pollJobUntilTerminal(jobId, seen) {
  const deadline = Date.now() + 90_000;
  for (;;) {
    const data = await api(`/api/jobs/${jobId}`);
    const job = data.job;
    seen.add(job.state);
    if (!['queued', 'running'].includes(job.state)) return job;
    if (Date.now() > deadline) throw new Error(`job ${jobId} did not reach a terminal state (states seen: ${[...seen].join(',')})`);
    await new Promise((r) => setTimeout(r, 150));
  }
}

// ---- Fixtures ---------------------------------------------------------------
let router;
let hostKeyMaterial;
let clientKey;
let routerId;
let profileId;

before(async () => {
  // Canonical runtime target identity: the sandbox router reports a stable
  // model/board via the host /tmp/sysinfo files the runtime reads.
  fs.mkdirSync('/tmp/sysinfo', { recursive: true });
  fs.writeFileSync('/tmp/sysinfo/model', 'Test-Router\n');
  fs.writeFileSync('/tmp/sysinfo/board_name', 'test-board\n');

  hostKeyMaterial = generateKeys(path.join(work, 'hostkeys'), 'pipeline_host');
  clientKey = generateKeys(path.join(work, 'clientkey'), 'pipeline_client');
  activeSandbox = makeSandbox('bootstrap');
  router = await startFakeRouter({
    password: ROUTER_PASSWORD,
    hostKey: hostKeyMaterial,
    clientKeyRaw: clientKey.publicKeyRaw,
    execHook: runShellSandboxed,
    sftpRoot: '/'
  });

  const port = httpServer.address().port;
  baseUrl = `http://127.0.0.1:${port}`;

  // ONE login; capture the session cookie and its CSRF token from the same
  // response (the token is session-bound; mixing sessions fails CSRF).
  const loginRes = await fetch(`${baseUrl}/api/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: ADMIN_PASSWORD })
  });
  assert.equal(loginRes.status, 200, 'valid admin login must succeed');
  const loginData = await loginRes.json();
  csrf = loginData.csrf;
  const setCookies = loginRes.headers.getSetCookie();
  assert.ok(setCookies.length >= 1, 'login must set the session cookie');
  cookie = setCookies[0].split(';')[0];
  assert.ok(cookie.startsWith('gcm_session='), 'session cookie name');

  // Save the router (real SSH test connection first; accept-new persists the
  // fingerprint through withRouter — an HTTP-level regression proof).
  const probe = await api('/api/routers/test', {
    method: 'POST',
    body: { host: router.host, port: router.port, username: 'root', authType: 'password', password: ROUTER_PASSWORD, acceptNewHostKey: true }
  });
  assert.equal(probe._status, 200, `router test connection failed: ${probe.error || probe._status}`);
  assert.ok(probe.fingerprint, 'accept-new through the HTTP path must persist a fingerprint');
  const created = await api('/api/routers', {
    method: 'POST',
    body: { name: 'pipeline-router', host: router.host, port: router.port, username: 'root', authType: 'password', password: ROUTER_PASSWORD }
  });
  assert.equal(created._status, 201, `router save failed: ${created.error || created._status}`);
  routerId = created.router.id;

  // Import the clone archive; the server verifies it with the canonical
  // engine before storing.
  const archiveFile = await buildCloneArchive();
  const form = new FormData();
  form.append('profile', new Blob([fs.readFileSync(archiveFile)], { type: 'application/gzip' }), 'pipeline.tar.gz');
  form.append('label', 'pipeline clone');
  const imported = await api('/api/profiles/import', { method: 'POST', form });
  assert.equal(imported._status, 201, `profile import failed: ${imported.error || imported._status}`);
  profileId = imported.profile.id;
  assert.equal(imported.profile.kind, 'v2');
});

after(async () => {
  try { await router.close(); } catch { /* already closed */ }
  try { await new Promise((resolve) => httpServer.close(resolve)); } catch { /* closed */ }
  try { fs.rmSync(REAL_PROBE, { force: true }); } catch { /* ignore */ }
  fs.rmSync('/tmp/sysinfo/model', { force: true });
  fs.rmSync('/tmp/sysinfo/board_name', { force: true });
  fs.rmSync(work, { recursive: true, force: true });
});

async function submitValidate(categories) {
  const vjob = await api('/api/jobs', {
    method: 'POST',
    body: { type: 'validate', routerId, profileId, password: ROUTER_PASSWORD, categories, preserveLanIp: false, dangerousOverride: false }
  });
  assert.equal(vjob._status, 202, `validate job create failed: ${vjob.error || vjob._status}`);
  const vDone = await pollJobUntilTerminal(vjob.job.id, new Set());
  assert.equal(vDone.state, 'succeeded', `validation must succeed: ${vDone.error || vDone.state}`);
  assert.ok(vDone.result.planToken, 'validation must issue a plan token');
  assert.ok(vDone.result.targetFactsHash, 'validation must report the target facts hash');
  assert.equal(vDone.result.plan.compatible, true, 'clone plan must be compatible with the sandbox target');
  return vDone;
}

async function submitRestore(categories, planToken, targetFactsHash, strategy) {
  const rjob = await api('/api/jobs', {
    method: 'POST',
    body: {
      type: 'restore', routerId, profileId, password: ROUTER_PASSWORD,
      categories, preserveLanIp: false, dangerousOverride: false, directCustomFiles: false, packages: '',
      planToken, targetFactsHash, strategy
    }
  });
  assert.equal(rjob._status, 202, `restore job create failed: ${rjob.error || rjob._status}`);
  return rjob.job.id;
}

// One full pipeline: fresh sandbox -> pre-state -> validate -> restore.
async function runPipeline({ categories, sandboxLabel, sandboxOpts = {} }) {
  activeSandbox = makeSandbox(sandboxLabel, sandboxOpts);
  writePreState();
  const preHash = hashTargetTree();
  const vDone = await submitValidate(categories);
  const jobId = await submitRestore(categories, vDone.result.planToken, vDone.result.targetFactsHash, vDone.result.plan.backup_strategy);
  const seen = new Set();
  const done = await pollJobUntilTerminal(jobId, seen);
  const postHash = hashTargetTree();
  return { done, seen, preHash, postHash };
}

test('pipeline: control restore succeeds through API->job->SSH->runtime and mutates the target', { timeout: 120000 }, async () => {
  const { done, seen, preHash, postHash } = await runPipeline({ categories: 'lan', sandboxLabel: 'control' });
  assert.equal(done.state, 'succeeded', `control restore must succeed (seen ${[...seen].join(',')}): ${done.error || done.state}`);
  assert.match(done.result?.markers?.restore || '', /^success/, 'canonical RESTORE=success marker must be reported');
  assert.match(done.result?.markers?.rollbackSnapshot || '', /pre-restore\.tar\.gz$/, 'rollback snapshot path must be reported on success');
  // The mutation must have been applied (control proves the apply path is real).
  assert.equal(fs.readFileSync(path.join(activeSandbox.target, 'tmp', PROBE), 'utf8'), MUTATED_CONTENT);
  assert.notEqual(postHash, preHash, 'a successful restore must change the target tree');
});

test('pipeline: injected post-mutation restore failure rolls back to byte-identical pre-state (job=rolled-back)', { timeout: 120000 }, async (t) => {
  if (isRoot) {
    // The injected failure stages custom files under the real /root tree,
    // which only fails for a non-root runtime user (the container and CI run
    // non-root). Root would let the staging succeed and the restore finish.
    t.skip('requires a non-root runtime user (container/CI parity); skipping as root');
    return;
  }
  const { done, seen, preHash, postHash } = await runPipeline({ categories: 'lan,custom-files', sandboxLabel: 'rollback-case' });

  assert.equal(done.state, 'rolled-back', `job must end rolled-back (seen: ${[...seen].join(',')}): ${done.error || done.state}`);
  assert.match(done.error || '', /rolled back to its pre-restore state/, 'API must expose the rollback outcome');
  assert.match(done.result?.rollback || '', /^rolled-back$/, 'job result must report rollback state');
  // The canonical marker chain must be visible through the API.
  const markers = done.markers || {};
  assert.match(String(markers.restore || ''), /^failed/, 'canonical RESTORE=failed marker must be reported');
  assert.match(String(markers.rollback || ''), /^verified/, 'canonical ROLLBACK=verified marker must be reported');
  assert.equal(postHash, preHash, 'post-rollback target tree must be byte-identical to pre-state');
  assert.equal(fs.readFileSync(path.join(activeSandbox.target, 'tmp', PROBE), 'utf8'), PRE_CONTENT, 'the mutated probe file must be restored to its pre-state bytes');
});

test('pipeline: restore fails AND rollback fails -> job ends rollback-failed and the API exposes it', { timeout: 120000 }, async () => {
  // Sandbox target /tmp is a FILE: the persistent-extra apply cannot create
  // its member (mkdir fails) AND rollback cannot restore the captured root
  // file either, so the canonical engine reports ROLLBACK=failed.
  const { done, seen } = await runPipeline({ categories: 'lan', sandboxLabel: 'rollback-failed-case', sandboxOpts: { blockTmpAsFile: true } });

  assert.equal(done.state, 'rollback-failed', `job must end rollback-failed (seen: ${[...seen].join(',')}): ${done.error || done.state}`);
  assert.match(done.error || '', /rollback failed/i, 'API must expose that rollback also failed');
  assert.match(done.result?.rollback || '', /^rollback-failed$/, 'job result must report rollback-failed state');
  const markers = done.markers || {};
  assert.match(String(markers.restore || ''), /^failed/, 'canonical RESTORE=failed marker must be reported');
  assert.match(String(markers.rollback || ''), /^failed/, 'canonical ROLLBACK=failed marker must be reported');
});
