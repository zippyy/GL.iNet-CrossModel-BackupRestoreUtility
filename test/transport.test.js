// Transport-level proofs against a REAL in-process ssh2 router:
//   - host-key trust: accept-new persists, same key succeeds later,
//     changed key on the same host:port is a HARD failure;
//   - password auth and public-key auth;
//   - the streamed canonical runtime genuinely executes over SSH
//     (remoteFacts returns parseable facts JSON);
//   - SFTP round trip through the fixture;
//   - credentials never leak into errors or logs.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

import { generateKeys, startFakeRouter } from './fake-router.js';
import { connectRouter, hostKeyId, execCommand } from '../lib/ssh.js';
import { remoteFacts, upstreamPin } from '../lib/engine.js';
import { Logger } from '../lib/log.js';

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gcm-transport-'));
const hostKeys = {
  a: generateKeys(path.join(work, 'keys-a'), 'host_a'),
  b: generateKeys(path.join(work, 'keys-b'), 'host_b')
};
const clientKey = generateKeys(path.join(work, 'client'), 'client');

// In-memory trust store (mirrors /data/known-hosts.json semantics).
const trustStore = new Map();
const hostKeyProvider = async (key) => trustStore.get(key)?.fingerprint || null;
const trustHostKey = async (key, record) => trustStore.set(key, record);
const mockLogger = new Logger({ dir: null, level: 'TRACE' });
const capturedLogs = [];
mockLogger.subscribe((e) => capturedLogs.push(e));

let routerA; // host keys A, password auth + client publickey auth
let routerPort;

// Connect helper that ALWAYS closes the client (try/finally) so a failed
// assertion can never leave an open ssh2 connection hanging the suite.
async function withClient(connection, fn) {
  const { client } = await connectRouter(connection, { logger: mockLogger, trustHostKey });
  try {
    return await fn(client);
  } finally {
    client.end();
  }
}

before(async () => {
  routerA = await startFakeRouter({
    password: 'router-secret-pw',
    hostKey: hostKeys.a,
    clientKeyRaw: clientKey.publicKeyRaw
  });
  routerPort = routerA.port;
});

after(async () => {
  await routerA.close().catch(() => {});
  fs.rmSync(work, { recursive: true, force: true });
});

const base = (router, extra = {}) => ({
  host: router.host,
  port: router.port,
  username: 'root',
  authType: 'password',
  password: 'router-secret-pw',
  hostKeyProvider,
  ...extra
});

test('first connection requires explicit accept-new and persists the fingerprint', { timeout: 20000 }, async () => {
  const key = hostKeyId(routerA.host, routerA.port);
  assert.equal(trustStore.has(key), false);

  // Without acceptNewHostKey: hard unknown-host-key refusal.
  await assert.rejects(connectRouter(base(routerA), { logger: mockLogger, trustHostKey }), (err) => err.code === 'unknown-host-key');

  // With acceptNewHostKey: connects and the fingerprint is persisted.
  await withClient(base(routerA, { acceptNewHostKey: true }), async () => {});
  assert.ok(trustStore.has(key), 'fingerprint must be persisted after accept-new');
  assert.ok(trustStore.get(key).fingerprint, 'persisted record must carry the fingerprint');
});

test('same host key is accepted on later connections', { timeout: 20000 }, async () => {
  await withClient(base(routerA), async () => {});
});

test('a changed host key on the same host:port is a HARD failure, never replaced', { timeout: 20000 }, async () => {
  const key = hostKeyId(routerA.host, routerA.port);
  assert.ok(trustStore.has(key), 'test 1 must have persisted the key');
  const oldFingerprint = trustStore.get(key).fingerprint;

  // Replace the router on the SAME port with DIFFERENT host keys (B).
  await routerA.close().catch(() => {});
  routerA = await startFakeRouter({
    password: 'router-secret-pw',
    hostKey: hostKeys.b,
    clientKeyRaw: clientKey.publicKeyRaw,
    port: routerPort
  });
  try {
    await assert.rejects(
      connectRouter(base(routerA), { logger: mockLogger, trustHostKey }),
      (err) => err.code === 'host-key-mismatch',
      'changed host key must hard-fail'
    );
  } finally {
    assert.equal(trustStore.get(key).fingerprint, oldFingerprint, 'trusted fingerprint must never be replaced silently');
    // ALWAYS restore router A with its original keys so later tests are not
    // poisoned by a leftover wrong-key router.
    await routerA.close().catch(() => {});
    routerA = await startFakeRouter({
      password: 'router-secret-pw',
      hostKey: hostKeys.a,
      clientKeyRaw: clientKey.publicKeyRaw,
      port: routerPort
    });
  }
});

test('wrong password is rejected without leaking the credential', { timeout: 20000 }, async () => {
  capturedLogs.length = 0;
  await assert.rejects(
    connectRouter(base(routerA, { password: 'totally-wrong-password-xyz' }), { logger: mockLogger, trustHostKey }),
    (err) => err.code === 'authentication-failure'
  );
  const serialized = JSON.stringify(capturedLogs);
  assert.equal(serialized.includes('totally-wrong-password-xyz'), false, 'password must not appear in logs');
});

test('public-key authentication connects', { timeout: 20000 }, async () => {
  await withClient({
    host: routerA.host,
    port: routerA.port,
    username: 'root',
    authType: 'key',
    privateKey: fs.readFileSync(clientKey.privateFile, 'utf8'),
    hostKeyProvider
  }, async () => {});
});

test('streamed canonical runtime executes over SSH (remoteFacts returns JSON)', { timeout: 30000 }, async () => {
  await withClient(base(routerA), async (client) => {
    const { facts } = await remoteFacts({ client, opId: crypto.randomUUID(), level: 'error' });
    // Canonical facts JSON shape (core.sh gcm_facts_json).
    assert.ok(facts.tool_version, 'facts must carry tool_version');
    assert.ok(facts.adapter, 'facts must carry adapter');
    assert.ok(typeof facts.model === 'string', 'facts must carry model');
    assert.ok(typeof facts.architecture === 'string', 'facts must carry architecture');
    assert.ok(Array.isArray(facts.bands), 'facts must carry a bands array');
    assert.ok(typeof facts.device_fingerprint === 'string', 'facts must carry device_fingerprint');
  });
});

test('SFTP round trip uploads and downloads byte-identical content', { timeout: 30000 }, async () => {
  await withClient(base(routerA), async (client) => {
    const local = path.join(work, 'sftp-payload.bin');
    const payload = crypto.randomBytes(64 * 1024);
    fs.writeFileSync(local, payload);
    const remote = `/tmp/gcm-test-${crypto.randomBytes(4).toString('hex')}.bin`;
    const back = path.join(work, 'sftp-back.bin');

    const sftp = await new Promise((resolve, reject) => client.sftp((err, s) => (err ? reject(err) : resolve(s))));
    await new Promise((resolve, reject) => sftp.fastPut(local, remote, (err) => (err ? reject(err) : resolve())));
    await new Promise((resolve, reject) => sftp.fastGet(remote, back, (err) => (err ? reject(err) : resolve())));
    await execCommand(client, `rm -f '${remote}'`, { allowFailure: true });

    assert.deepEqual(fs.readFileSync(back), payload, 'SFTP round trip must be byte-identical');
    fs.rmSync(back, { force: true });
    fs.rmSync(local, { force: true });
  });
});

test('runtime pin file exists and is a full SHA-1', async () => {
  const pin = await upstreamPin();
  assert.match(pin, /^[0-9a-f]{40}$/);
});
