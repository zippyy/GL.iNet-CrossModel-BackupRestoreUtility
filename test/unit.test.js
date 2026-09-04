// Unit proofs for the controller's own logic:
//   - input validation (paths, UUIDs, categories, strategies)
//   - auth (scrypt round trip, fail-closed startup)
//   - log redaction and level gating
//   - store atomicity + profile immutability + router/job secret stripping
//   - plan-token binding drift
//   - engine marker/plan/review parsing + shell quoting
//   - job state machine transitions
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

import {
  HttpError, validUuid, assertUuid, normalizeRemotePath, validCategoryList,
  validStrategy, safeLabel, bool, sha256Hex
} from '../lib/util.js';
import { hashPassword, verifyPassword, authConfigFromEnv, Auth } from '../lib/auth.js';
import { Logger, formatEntry } from '../lib/log.js';
import { Store } from '../lib/store.js';
import { PlanStore, factsHash } from '../lib/plans.js';
import { JobManager } from '../lib/jobs.js';
import { parsePlanJson, parseReviewJson, summarizeMarkers, shellQuote } from '../lib/engine.js';

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gcm-unit-'));

// ---- Input validation -------------------------------------------------------
test('util: UUID validation', () => {
  const good = '11111111-1111-1111-1111-111111111111';
  assert.equal(validUuid(good), true);
  assert.equal(validUuid('../../etc'), false);
  assert.equal(validUuid('not-a-uuid'), false);
  assert.throws(() => assertUuid('../../etc'), HttpError);
  assert.equal(assertUuid(good), good);
});

test('util: remote path normalization rejects traversal and control characters', () => {
  assert.equal(normalizeRemotePath('/root/scripts/fix.sh'), '/root/scripts/fix.sh');
  assert.equal(normalizeRemotePath('/usr/local/bin/tool'), '/usr/local/bin/tool');
  assert.throws(() => normalizeRemotePath('/../etc/shadow'), HttpError);
  assert.throws(() => normalizeRemotePath('../etc/shadow'), HttpError); // must be absolute
  assert.throws(() => normalizeRemotePath('/etc/../shadow'), HttpError);
  assert.throws(() => normalizeRemotePath('/etc/shadow\x00'), HttpError);
  assert.throws(() => normalizeRemotePath('relative/path'), HttpError);
  assert.throws(() => normalizeRemotePath(''), HttpError);
  assert.throws(() => normalizeRemotePath('/'.repeat(600)), HttpError);
});

test('util: categories and strategies are allowlisted', () => {
  assert.equal(validCategoryList('wifi,lan,dhcp'), 'wifi,lan,dhcp');
  assert.equal(validCategoryList(['firewall', 'vpn']), 'firewall,vpn');
  assert.throws(() => validCategoryList('wifi,../../etc'), HttpError);
  assert.throws(() => validCategoryList('teleport'), HttpError);
  assert.equal(validStrategy('portable'), true);
  assert.equal(validStrategy('teleport'), false);
  assert.equal(safeLabel('  x  '), 'x');
  assert.equal(safeLabel('', 'fallback'), 'fallback');
  assert.equal(bool('true'), true);
  assert.equal(bool(0), false);
  assert.match(sha256Hex('abc'), /^[0-9a-f]{64}$/);
});

// ---- Auth -------------------------------------------------------------------
test('auth: scrypt hash round trip and fail-closed startup', () => {
  const hash = hashPassword('correct horse battery staple');
  assert.equal(verifyPassword('correct horse battery staple', hash), true);
  assert.equal(verifyPassword('wrong', hash), false);
  assert.throws(() => authConfigFromEnv({}), /No admin credential/);
  assert.throws(() => authConfigFromEnv({ ADMIN_PASSWORD: 'short' }), /at least 8/);
  assert.throws(() => authConfigFromEnv({ ADMIN_PASSWORD_HASH: 'not:a:hash' }), /scrypt/);
  const cfg = authConfigFromEnv({ ADMIN_PASSWORD: 'long-enough-password' });
  assert.equal(cfg.verify('long-enough-password'), true);
  assert.equal(cfg.verify('wrong'), false);
});

test('auth: sessions create/load/destroy with expiry', async () => {
  const store = new Store(path.join(work, 'auth-store'));
  await store.init();
  const auth = new Auth({ store, logger: new Logger({ dir: null }), verify: () => true });
  const session = await auth.createSession();
  assert.ok(session.csrf.length >= 32);
  const loaded = await auth.loadSession(session.id);
  assert.equal(loaded.csrf, session.csrf);
  // Expired sessions must not load.
  const file = path.join(store.sessionDir, `${session.id}.json`);
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  raw.expiresAt = Date.now() - 1000;
  fs.writeFileSync(file, JSON.stringify(raw));
  assert.equal(await auth.loadSession(session.id), null);
  await auth.destroySession(session.id);
  assert.equal(await auth.loadSession(session.id), null);
});

// ---- Logging ----------------------------------------------------------------
test('log: sensitive field names redact values; level gating works', () => {
  const entries = [];
  const logger = new Logger({ dir: null, level: 'INFO' });
  logger.subscribe((e) => entries.push(e));
  logger.info('op-1', 'ssh', 'connect', { host: '192.168.8.1', password: 'super-secret-pw', msg: 'connecting' });
  logger.debug('op-1', 'ssh', 'connect', { msg: 'hidden at INFO' });
  assert.equal(entries.length, 1);
  assert.equal(entries[0].fields.password, '[REDACTED]');
  assert.equal(formatEntry(entries[0]).includes('super-secret-pw'), false);
  logger.setLevel('DEBUG');
  logger.debug('op-2', 'core', 'apply', { privateKey: 'abc123xyz', msg: 'visible now' });
  assert.equal(entries.length, 2);
  assert.equal(entries[1].fields.privateKey, '[REDACTED]');
  logger.setLevel('TRACE');
  logger.trace('op-3', 'core', 'apply', { msg: 'trace line' });
  assert.equal(entries.length, 3);
});

// ---- Store ------------------------------------------------------------------
test('store: profile bytes are immutable; metadata is a sidecar', async () => {
  const store = new Store(path.join(work, 'store-1'));
  await store.init();
  const id = crypto.randomUUID();
  const bytes = Buffer.from('profile-bytes-v1');
  await store.storeProfile(id, bytes, { id, kind: 'v2', label: 'original', strategy: 'portable', integrity: 'verified', sha256: sha256Hex(bytes) });
  await store.updateProfileMeta(id, { label: 'renamed', notes: 'notes' });
  const meta = await store.profileMeta(id);
  assert.equal(meta.label, 'renamed');
  // Bytes must be untouched by metadata changes.
  assert.deepEqual(await store.readProfileBytes(id), bytes);
  // Import of the same id must be rejected (immutability).
  await assert.rejects(() => store.storeProfile(id, Buffer.from('other'), { id }), /already exists/);
  const list = await store.listProfiles();
  assert.equal(list.length, 1);
  assert.equal(list[0].size, bytes.length);
  await store.deleteProfile(id);
  assert.equal((await store.listProfiles()).length, 0);
});

test('store: router records never persist passwords; jobs strip secrets', async () => {
  const store = new Store(path.join(work, 'store-2'));
  await store.init();
  const rid = crypto.randomUUID();
  await store.saveRouter({ id: rid, name: 'R1', host: '192.168.8.1', port: 22, username: 'root', authType: 'password', password: 'sekrit', fingerprint: 'abc' });
  const router = await store.router(rid);
  assert.equal(router.password, undefined);
  assert.equal(router.fingerprint, 'abc');
  const rawRouter = fs.readFileSync(path.join(store.routersDir, `${rid}.json`), 'utf8');
  assert.equal(rawRouter.includes('sekrit'), false);

  const jid = crypto.randomUUID();
  await store.saveJob({ id: jid, state: 'running', payload: { connection: { host: 'x' } }, password: 'job-sekrit', privateKey: 'job-key' });
  const job = await store.job(jid);
  assert.equal(job.password, undefined);
  assert.equal(job.privateKey, undefined);
  const rawJob = fs.readFileSync(path.join(store.jobsDir, `${jid}.json`), 'utf8');
  assert.equal(rawJob.includes('job-sekrit'), false);
  assert.equal(rawJob.includes('job-key'), false);
});

test('store: known-hosts trust/forget round trip', async () => {
  const store = new Store(path.join(work, 'store-3'));
  await store.init();
  await store.trustHostKey('192.168.8.1:22', { fingerprint: 'abc123', host: '192.168.8.1', port: 22 });
  assert.equal((await store.knownHostKey('192.168.8.1:22')).fingerprint, 'abc123');
  await store.forgetHostKey('192.168.8.1:22');
  assert.equal(await store.knownHostKey('192.168.8.1:22'), null);
});

test('store: pruning never removes profiles tied to active jobs', async () => {
  const store = new Store(path.join(work, 'store-4'));
  await store.init();
  store.policy.maxProfiles = 2;
  store.policy.maxTotalBytes = 1024 * 1024;
  store.policy.pruneOnCreate = false;
  const ids = [];
  for (let i = 0; i < 4; i++) {
    const id = crypto.randomUUID();
    ids.push(id);
    await store.storeProfile(id, Buffer.from(`profile-${i}`), { id, kind: 'v2', label: `p${i}`, createdAt: new Date(Date.now() + i * 1000).toISOString() });
  }
  // A running restore job references the newest profile; pruning must keep it
  // (mirrors the native rule that an active restore's rollback snapshot is
  // never deleted).
  await store.saveJob({ id: crypto.randomUUID(), state: 'running', profileId: ids[3], payload: {} });
  const removed = await store.prune();
  const remaining = (await store.listProfiles()).map((p) => p.id);
  assert.ok(remaining.includes(ids[3]), 'active restore profile must survive pruning');
  assert.ok(remaining.length <= 2, 'pruning must enforce maxProfiles');
  assert.equal(removed.includes(ids[3]), false);
});

// ---- Plan tokens ------------------------------------------------------------
test('plans: one-use token bound to the validated state', async () => {
  const dir = path.join(work, 'plans');
  const plans = new PlanStore({ dir, logger: new Logger({ dir: null }) });
  await plans.init();
  const sessionId = crypto.randomUUID();
  const binding = {
    sessionId,
    routerId: crypto.randomUUID(),
    profileSha256: sha256Hex('profile'),
    targetFactsHash: sha256Hex('facts'),
    strategy: 'portable',
    categories: 'wifi,lan',
    packages: '',
    directCustomFiles: false,
    dangerousOverride: false,
    allowLegacy: false,
    preserveLanIp: true
  };
  const token = await plans.issue(binding);
  // Correct binding consumes successfully.
  await plans.consume(token.id, binding);
  // Reuse is rejected.
  await assert.rejects(() => plans.consume(token.id, binding), /already used/);
  // A drifted binding is rejected.
  const token2 = await plans.issue(binding);
  await assert.rejects(
    () => plans.consume(token2.id, { ...binding, profileSha256: sha256Hex('different') }),
    /no longer matches: profile/
  );
  // Wrong session is rejected.
  const token3 = await plans.issue(binding);
  await assert.rejects(() => plans.consume(token3.id, { ...binding, sessionId: crypto.randomUUID() }), /another session/);
  // Expired tokens are rejected.
  const token4 = await plans.issue(binding);
  const f = path.join(dir, `${token4.id}.json`);
  const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
  raw.expiresAt = Date.now() - 1000;
  fs.writeFileSync(f, JSON.stringify(raw));
  await assert.rejects(() => plans.consume(token4.id, binding), /expired/);
});

test('plans: factsHash is stable and order-insensitive', () => {
  const a = factsHash({ source_model: 'GL-MT6000', firmware_version: '4.8.2', architecture: 'aarch64' });
  const b = factsHash({ source_model: 'GL-MT6000', firmware_version: '4.8.2', architecture: 'aarch64' });
  const c = factsHash({ source_model: 'GL-MT3000', firmware_version: '4.8.2', architecture: 'aarch64' });
  assert.equal(a, b);
  assert.notEqual(a, c);
});

// ---- Engine parsing ---------------------------------------------------------
test('engine: plan/review JSON parsing and marker summaries', () => {
  const plan = parsePlanJson('{"archive_kind":"v2","backup_strategy":"clone","compatible":true}\n');
  assert.equal(plan.backup_strategy, 'clone');
  assert.throws(() => parsePlanJson('no json here'), /no JSON/);
  const review = parseReviewJson('{"feed_reachable":true,"already_installed_same":["a"]}\n');
  assert.equal(review.feed_reachable, true);

  const stdout = [
    'APPLIED=portable:lan-logical-settings',
    'PRESERVED=target-factory-identity:source-overrides-sanitized-and-hardware-defaults-retained',
    'DEFERRED=network-firewall-wireless-reload;controller-success-received-first',
    'ROLLBACK_SNAPSHOT=/root/glinet-crossmodel/rollback/xyz/pre-restore.tar.gz',
    'RESTORE=success',
    'ERROR: something failed'
  ].join('\n');
  const summary = summarizeMarkers(stdout);
  assert.deepEqual(summary.applied, ['portable:lan-logical-settings']);
  assert.equal(summary.preserved.length, 1);
  assert.equal(summary.deferred.length, 1);
  assert.equal(summary.restore, 'success');
  assert.equal(summary.rollbackSnapshot, '/root/glinet-crossmodel/rollback/xyz/pre-restore.tar.gz');
  assert.equal(shellQuote("it's"), `'it'"'"'s'`);
});

// ---- Job manager ------------------------------------------------------------
test('jobs: state transitions succeed/fail/rolled-back', async () => {
  const store = new Store(path.join(work, 'jobs'));
  await store.init();
  const jobs = new JobManager({ store, logger: new Logger({ dir: null }) });
  const job = await jobs.create({ type: 'facts', correlationId: crypto.randomUUID(), payload: {} });
  assert.equal(job.state, 'queued');
  const okOutcome = await jobs.run(job.id, async () => ({ result: { ok: true } }));
  assert.equal(okOutcome.state, 'succeeded');
  assert.equal((await store.job(job.id)).state, 'succeeded');

  const job2 = await jobs.create({ type: 'restore', correlationId: crypto.randomUUID(), payload: {} });
  const failOutcome = await jobs.run(job2.id, async () => { throw Object.assign(new Error('apply failed'), { rollbackState: 'rolled-back' }); });
  assert.equal(failOutcome.state, 'rolled-back');
  assert.equal((await store.job(job2.id)).state, 'rolled-back');
  assert.match((await store.job(job2.id)).error, /apply failed/);

  const job3 = await jobs.create({ type: 'restore', correlationId: crypto.randomUUID(), payload: {} });
  const badOutcome = await jobs.run(job3.id, async () => { throw Object.assign(new Error('both failed'), { rollbackState: 'rollback-failed' }); });
  assert.equal(badOutcome.state, 'rollback-failed');
  assert.equal((await store.job(job3.id)).state, 'rollback-failed');
});
