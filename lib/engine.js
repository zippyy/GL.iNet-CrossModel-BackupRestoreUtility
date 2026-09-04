import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execWithStdin, execCommand, sftpPut, sftpGet, RouterConnectionError } from './ssh.js';
import { HttpError } from './util.js';
import { sha256Hex } from './util.js';

// Remote runtime executor. The Docker controller never reimplements backup or
// restore policy in JavaScript: it streams the pinned canonical native runtime
// (core.sh + CLI, vendored under runtime/native/) to the managed router over
// SSH and runs it with `sh -s -- <args>` exactly like the native controller
// does (`cat core.sh cli | ssh sh -s -- args`). Archives move over SFTP and
// are SHA-256 verified; remote temporary files are always cleaned up.

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const RUNTIME_DIR = path.resolve(__dirname, '..', 'runtime', 'native');
export const UPSTREAM_PIN_FILE = path.resolve(__dirname, '..', 'runtime', 'UPSTREAM_MAIN_COMMIT');

export async function upstreamPin() {
  try {
    return (await fs.readFile(UPSTREAM_PIN_FILE, 'utf8')).trim();
  } catch {
    return 'unknown';
  }
}

export async function runtimeBundle() {
  // core.sh must be loaded first (it sets GCM_CORE_LOADED=1), then the CLI.
  const core = await fs.readFile(path.join(RUNTIME_DIR, 'core.sh'));
  const cli = await fs.readFile(path.join(RUNTIME_DIR, 'glinet-crossmodel'));
  return Buffer.concat([core, Buffer.from('\n'), cli]);
}

export function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

// Validate every value that will cross into a remote shell context.
function remoteArg(value, label, { allowEmpty = false, max = 2000 } = {}) {
  const text = String(value ?? '');
  if (!allowEmpty && !text) throw new HttpError(400, `${label} is required.`);
  if (text.length > max) throw new HttpError(400, `${label} is too long.`);
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(text)) throw new HttpError(400, `${label} contains control characters.`);
  return text;
}

function categoriesArg(value) {
  // Comma-separated category list; individual names validated by the native
  // engine, but reject anything that could break quoting or inject.
  const text = remoteArg(value, 'categories', { allowEmpty: true, max: 512 });
  if (!text) return '';
  if (!/^[a-z,-]+$/.test(text)) throw new HttpError(400, 'Invalid category list.');
  return text;
}

export function parsePlanJson(stdout) {
  // validate emits a single JSON object on stdout (see core.sh gcm_validate).
  const start = stdout.indexOf('{');
  const end = stdout.lastIndexOf('}');
  if (start < 0 || end <= start) throw new Error('Router validation returned no JSON plan.');
  try {
    return JSON.parse(stdout.slice(start, end + 1));
  } catch (error) {
    throw new Error(`Router validation returned malformed JSON: ${String(error.message).slice(0, 200)}`);
  }
}

export function parseReviewJson(stdout) {
  const start = stdout.indexOf('{');
  const end = stdout.lastIndexOf('}');
  if (start < 0 || end <= start) throw new Error('Package review returned no JSON.');
  try {
    return JSON.parse(stdout.slice(start, end + 1));
  } catch (error) {
    throw new Error(`Package review returned malformed JSON: ${String(error.message).slice(0, 200)}`);
  }
}

export function parseMarkerLine(line) {
  const match = String(line).match(/^(APPLIED|ADAPTED|PRESERVED|SKIPPED|DEFERRED|PENDING_ACTIVATION|RESTORE|ROLLBACK|PRE_RESTORE_SNAPSHOT|ROLLBACK_SNAPSHOT|CREATED|REMOTE_SOURCE|REMOTE_TARGET|ERROR)=(.*)$/);
  return match ? { kind: match[1], value: match[2].trim() } : null;
}

export function summarizeMarkers(stdout) {
  const summary = { applied: [], adapted: [], preserved: [], skipped: [], deferred: [], pendingActivation: false, restore: null, rollback: null, rollbackSnapshot: null, preRestoreSnapshot: null, created: null, remoteSource: null, remoteTarget: null };
  for (const raw of stdout.split(/\r?\n/)) {
    const marker = parseMarkerLine(raw);
    if (!marker) continue;
    switch (marker.kind) {
      case 'APPLIED': summary.applied.push(marker.value); break;
      case 'ADAPTED': summary.adapted.push(marker.value); break;
      case 'PRESERVED': summary.preserved.push(marker.value); break;
      case 'SKIPPED': summary.skipped.push(marker.value); break;
      case 'DEFERRED': summary.deferred.push(marker.value); break;
      case 'PENDING_ACTIVATION': summary.pendingActivation = true; break;
      case 'RESTORE': summary.restore = marker.value; break;
      case 'ROLLBACK': summary.rollback = marker.value; break;
      case 'ROLLBACK_SNAPSHOT': summary.rollbackSnapshot = marker.value; break;
      case 'PRE_RESTORE_SNAPSHOT': summary.preRestoreSnapshot = marker.value; break;
      case 'CREATED': summary.created = marker.value; break;
      case 'REMOTE_SOURCE': summary.remoteSource = marker.value; break;
      case 'REMOTE_TARGET': summary.remoteTarget = marker.value; break;
      default: break;
    }
  }
  return summary;
}

const REMOTE_TMP_BASE = '/tmp/gcm-docker';

function remoteScratch(opId) {
  const safe = String(opId || crypto.randomUUID()).replace(/[^a-f0-9-]/gi, '');
  return `${REMOTE_TMP_BASE}-${safe}`;
}

// Build the streamed remote command line. Mirrors native stream_cli.
function buildRemoteCommand({ opId, action, args, level = 'info', deferReload = false, trace = false, gcmPath = null }) {
  let cmd = `env GCM_OP_ID=${shellQuote(opId)} GCM_SCOPE=remote GCM_LOG_LEVEL=${shellQuote(level)}`;
  if (gcmPath) cmd += ` GCM_PATH=${shellQuote(gcmPath)}`;
  if (trace) cmd += ' GCM_TRACE=1';
  if (deferReload) cmd += ' GCM_DEFER_RELOAD=1';
  cmd += ' sh -s --';
  cmd += ` ${shellQuote(action)}`;
  for (const arg of args) cmd += ` ${shellQuote(arg)}`;
  return cmd;
}

export async function streamRuntime({ client, opId, action, args, level = 'info', deferReload = false, trace = false, gcmPath = null, timeout = 300000, onStdout = null }) {
  const bundle = await runtimeBundle();
  const command = buildRemoteCommand({ opId, action, args, level, deferReload, trace, gcmPath });
  return execWithStdin(client, command, bundle, {
    timeout,
    logger: null,
    op: opId,
    onStdout
  });
}

// SHA-256 verify a local file against a remote one, plus remote readability.
export async function verifyRemoteCopy(client, localPath, remotePath, opId) {
  const local = await sha256Hex(await fs.readFile(localPath));
  const result = await execCommand(client, `sha256sum ${shellQuote(remotePath)} 2>/dev/null`, { allowFailure: true, timeout: 30000 });
  const remote = String(result.stdout).trim().split(/\s+/)[0] || '';
  if (local !== remote) {
    throw new RouterConnectionError(`Remote transfer SHA-256 mismatch (local ${local}, remote ${remote || 'missing'}).`, { code: 'transfer-checksum-mismatch' });
  }
  await execCommand(client, `tar -tzf ${shellQuote(remotePath)} >/dev/null 2>&1`, { timeout: 60000 });
  return local;
}

export async function cleanupRemote(client, paths, opId) {
  if (!paths.length) return;
  const command = `rm -f ${paths.map((p) => shellQuote(p)).join(' ')}`;
  await execCommand(client, command, { allowFailure: true, timeout: 30000 });
}

// ---- Operations (all run the canonical runtime on the managed router) ----

export async function remoteFacts({ client, opId, level, gcmPath = null }) {
  const result = await streamRuntime({ client, opId, action: 'facts', args: [], level, gcmPath, timeout: 60000 });
  const start = result.stdout.indexOf('{');
  const end = result.stdout.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw new RouterConnectionError('Router facts returned no JSON.', { code: 'facts-parse-failed' });
  }
  try {
    const facts = JSON.parse(result.stdout.slice(start, end + 1));
    return { facts, raw: result };
  } catch (error) {
    throw new RouterConnectionError(`Router facts were malformed: ${String(error.message).slice(0, 200)}`, { code: 'facts-parse-failed' });
  }
}

export async function remoteCreate({
  client, opId, strategy, profileId, name, notes, categories,
  scripts = [], binaries = [], outputFile, level = 'info', gcmPath = null, timeout = 600000
}) {
  const scratch = remoteScratch(opId);
  const remoteArchive = `${scratch}.tar.gz`;
  const remoteScripts = `${scratch}-scripts`;
  const remoteBinaries = `${scratch}-binaries`;
  const remotePaths = [remoteArchive, remoteScripts, remoteBinaries];

  try {
    // The CLI expects list files on the router, one absolute path per line,
    // or /dev/null when nothing is selected (mirrors native remote_create).
    const writeList = async (entries, remotePath) => {
      if (!entries.length) return;
      const local = path.join(os.tmpdir(), `${opId}-${crypto.randomBytes(4).toString('hex')}`);
      await fs.writeFile(local, entries.map((p) => String(p)).join('\n') + '\n');
      try {
        await sftpPut(client, local, remotePath);
        await execCommand(client, `chmod 0600 ${shellQuote(remotePath)}`, { timeout: 15000 });
      } finally {
        await fs.rm(local, { force: true });
      }
    };
    await writeList(scripts, remoteScripts);
    await writeList(binaries, remoteBinaries);

    const args = [
      '--output', remoteArchive,
      '--strategy', remoteArg(strategy, 'strategy'),
      '--id', remoteArg(profileId, 'profile id'),
      '--name', remoteArg(name || '', 'name', { allowEmpty: true, max: 200 }),
      '--notes', remoteArg(notes || '', 'notes', { allowEmpty: true, max: 4000 }),
      '--categories', categoriesArg(categories),
      '--scripts-list', scripts.length ? remoteScripts : '/dev/null',
      '--binaries-list', binaries.length ? remoteBinaries : '/dev/null'
    ];
    const result = await streamRuntime({ client, opId, action: 'create', args, level, timeout });
    await sftpGet(client, remoteArchive, outputFile);
    await verifyRemoteCopy(client, outputFile, remoteArchive, opId);
    return { archive: outputFile, sha256: await sha256Hex(await fs.readFile(outputFile)), markers: summarizeMarkers(result.stdout), raw: result };
  } finally {
    await cleanupRemote(client, remotePaths, opId);
  }
}

export async function remoteValidate({
  client, opId, archiveFile, categories, dangerousOverride = false,
  preserveLanIp = false, level = 'info', timeout = 300000
}) {
  const scratch = remoteScratch(opId);
  const remoteArchive = `${scratch}-validate.tar.gz`;
  try {
    await sftpPut(client, archiveFile, remoteArchive);
    await execCommand(client, `chmod 0600 ${shellQuote(remoteArchive)}`, { timeout: 15000 });
    await verifyRemoteCopy(client, archiveFile, remoteArchive, opId);
    const args = [remoteArchive, '--categories', categoriesArg(categories)];
    if (dangerousOverride) args.push('--dangerous-device-override');
    if (preserveLanIp) args.push('--preserve-destination-lan-ip');
    const result = await streamRuntime({ client, opId, action: 'validate', args, level, timeout });
    const plan = parsePlanJson(result.stdout);
    return { plan, raw: result };
  } finally {
    await cleanupRemote(client, [remoteArchive], opId);
  }
}

export async function remotePackages({ client, opId, archiveFile, level = 'info', timeout = 300000 }) {
  const scratch = remoteScratch(opId);
  const remoteArchive = `${scratch}-packages.tar.gz`;
  try {
    await sftpPut(client, archiveFile, remoteArchive);
    await verifyRemoteCopy(client, archiveFile, remoteArchive, opId);
    const result = await streamRuntime({ client, opId, action: 'packages', args: [remoteArchive], level, timeout });
    return { review: parseReviewJson(result.stdout), raw: result };
  } finally {
    await cleanupRemote(client, [remoteArchive], opId);
  }
}

export async function remoteRestore({
  client, opId, archiveFile, categories, packages = '', directCustomFiles = false,
  dangerousOverride = false, allowLegacy = false, preserveLanIp = false,
  level = 'info', timeout = 900000, onStdout = null
}) {
  const scratch = remoteScratch(opId);
  const remoteArchive = `${scratch}-restore.tar.gz`;
  try {
    await sftpPut(client, archiveFile, remoteArchive);
    await verifyRemoteCopy(client, archiveFile, remoteArchive, opId);
    const args = [remoteArchive, '--categories', categoriesArg(categories)];
    if (packages) {
      if (!/^[A-Za-z0-9+._,-]{1,4000}$/.test(packages)) throw new HttpError(400, 'Invalid package selection.');
      args.push('--packages', packages);
    }
    if (directCustomFiles) args.push('--direct-custom-files');
    if (dangerousOverride) args.push('--dangerous-device-override');
    if (allowLegacy) args.push('--allow-legacy');
    if (preserveLanIp) args.push('--preserve-destination-lan-ip');
    const result = await streamRuntime({
      client, opId, action: 'restore', args, level,
      deferReload: true, timeout, onStdout
    });
    const markers = summarizeMarkers(result.stdout);
    let outcome = 'failed';
    if (markers.restore === 'success') outcome = 'succeeded';
    if (String(markers.restore || '').startsWith('failed')) {
      outcome = markers.rollback && markers.rollback.startsWith('verified') ? 'rolled-back' : 'rollback-failed';
    }
    return { outcome, markers, raw: result };
  } finally {
    await cleanupRemote(client, [remoteArchive], opId);
  }
}

export async function remoteActivate({ client, opId, level = 'info', timeout = 120000 }) {
  const result = await streamRuntime({ client, opId, action: 'activate', args: [], level, timeout });
  const markers = summarizeMarkers(result.stdout);
  return { markers, raw: result };
}

// ---- Host-side inspection of an archive (used for imported/uploaded v2
// archives and library listing). Safe: tar listing + sha256 + sed only.
// Requires sha256sum on the host (present in the runtime container).
export async function inspectArchiveLocally(archiveFile, { level = 'error' } = {}) {
  const cli = path.join(RUNTIME_DIR, 'glinet-crossmodel');
  const { spawnSync } = await import('node:child_process');
  const result = spawnSync('/bin/sh', [cli, 'inspect', archiveFile], {
    encoding: 'utf8',
    timeout: 60000,
    maxBuffer: 32 * 1024 * 1024,
    env: {
      ...process.env,
      GCM_LIB: path.join(RUNTIME_DIR, 'core.sh'),
      GCM_OP_ID: '00000000-0000-0000-0000-000000000000',
      GCM_LOG_LEVEL: level,
      GCM_FILE_LOG: '0',
      GCM_SYSLOG: '0',
      GCM_LOG_DIR: path.join(os.tmpdir(), 'gcm-local-inspect'),
      GCM_PATH: '/usr/bin:/bin:/usr/sbin:/sbin'
    }
  });
  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || '').trim().slice(0, 500);
    throw new HttpError(400, `Archive inspection failed: ${detail || 'unknown error'}`);
  }
  const out = String(result.stdout || '').trim();
  const start = out.indexOf('{');
  const end = out.lastIndexOf('}');
  if (start < 0 || end <= start) throw new HttpError(400, 'Archive inspection returned no manifest.');
  try {
    return JSON.parse(out.slice(start, end + 1));
  } catch {
    throw new HttpError(400, 'Archive inspection returned malformed metadata.');
  }
}

export { RouterConnectionError };
