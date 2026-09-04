import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import express from 'express';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import cookieParser from 'cookie-parser';
import multer from 'multer';

import { Store } from './lib/store.js';
import { Logger } from './lib/log.js';
import { authConfigFromEnv, Auth, hashPassword } from './lib/auth.js';
import { JobManager, jobError } from './lib/jobs.js';
import { PlanStore, factsHash } from './lib/plans.js';
import {
  HttpError, httpJsonError, validUuid, assertUuid, validCategoryList,
  assertStrategy, normalizeRemotePath, safeLabel, safeNotes, bool, sha256Hex
} from './lib/util.js';
import { withRouter, hostKeyId } from './lib/ssh.js';
import {
  remoteFacts, remoteCreate, remoteValidate, remotePackages, remoteRestore,
  remoteActivate, inspectArchiveLocally, upstreamPin
} from './lib/engine.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname);
const dataDir = path.resolve(process.env.DATA_DIR || '/data');
const app = express();

const logger = new Logger({ dir: path.join(dataDir, 'logs') });
const store = new Store(dataDir);
await store.init();
const jobs = new JobManager({ store, logger });
const plans = new PlanStore({ dir: path.join(dataDir, 'plans'), logger });
await plans.init();

// ---- Auth bootstrap (fail closed) ----
const authVerify = authConfigFromEnv(process.env);
const auth = new Auth({
  store, logger, verify: authVerify.verify,
  cookieSecure: process.env.COOKIE_SECURE === '1' || process.env.GCM_COOKIE_SECURE === '1',
  trustProxy: process.env.TRUST_PROXY === '1' || process.env.GCM_TRUST_PROXY === '1'
});
if (auth.trustProxy) app.set('trust proxy', 1);

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || '0.0.0.0';
const LOGIN_LIMIT = rateLimit({ windowMs: 60_000, limit: 10, standardHeaders: 'draft-8', legacyHeaders: false });
const API_LIMIT = rateLimit({ windowMs: 60_000, limit: 240, standardHeaders: 'draft-8', legacyHeaders: false });

app.disable('x-powered-by');
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'"],
      imgSrc: ["'self'", 'data:'],
      connectSrc: ["'self'"],
      frameAncestors: ["'none'"]
    }
  },
  crossOriginEmbedderPolicy: false
}));
app.use(API_LIMIT);
app.use(express.json({ limit: '2mb' }));
app.use(cookieParser());
app.use(express.static(path.join(root, 'public'), { maxAge: 0, setHeaders: (r) => r.setHeader('Cache-Control', 'no-store') }));

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 512 * 1024 * 1024, files: 1 }
});

const requireAuth = async (req, res, next) => {
  try {
    const id = req.cookies?.gcm_session;
    const session = await auth.loadSession(id);
    if (!session) return res.status(401).json({ error: 'Authentication required.' });
    req.session = session;
    next();
  } catch (error) {
    res.status(500).json({ error: 'Session error.' });
  }
};

const requireCsrf = async (req, res, next) => {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
  const supplied = req.get('x-csrf-token') || req.body?.csrf;
  if (!req.session || !supplied || supplied !== req.session.csrf) {
    logger.warn('http', 'csrf', 'server', { ip: req.ip, msg: 'CSRF validation failed' });
    return res.status(403).json({ error: 'CSRF validation failed. Refresh the page and try again.' });
  }
  next();
};

// ---- Connection resolution helpers ----

async function resolveConnection(body) {
  // body.routerId -> saved inventory (no password); body.connection -> ad-hoc.
  if (body.routerId) {
    const router = await store.router(body.routerId);
    return {
      host: router.host,
      port: router.port,
      username: router.username,
      authType: router.authType,
      // Saved routers never carry passwords; the operator supplies one per job
      // when password auth is used, or key/agent material is mounted.
      password: body.password || undefined,
      privateKey: body.privateKey || undefined,
      agent: router.authType === 'agent' ? undefined : undefined,
      acceptNewHostKey: false
    };
  }
  const c = body.connection || {};
  return {
    host: c.host,
    port: c.port ?? 22,
    username: c.username || 'root',
    authType: c.authType || (c.password ? 'password' : c.privateKey ? 'key' : 'agent'),
    password: c.password,
    privateKey: c.privateKey,
    acceptNewHostKey: bool(c.acceptNewHostKey)
  };
}

function hostKeyProviders() {
  const hostKeyProvider = async (key) => {
    const record = await store.knownHostKey(key);
    return record?.fingerprint || null;
  };
  const trustHostKey = async (key, record) => store.trustHostKey(key, record);
  return { hostKeyProvider, trustHostKey };
}

const GCM_CATEGORIES = 'wifi,lan,dhcp,dns,firewall,timezone,ddns,vpn,packages,persistent,custom-files,custom-binaries';

// ---- Health (unauthenticated, no sensitive info) ----
app.get('/api/health', async (_req, res) => {
  res.json({ ok: true, service: 'glinet-crossmodel-docker', upstream: await upstreamPin() });
});

// ---- Auth ----
app.post('/api/login', LOGIN_LIMIT, async (req, res) => {
  try {
    const password = String(req.body?.password ?? '');
    if (!password || !authVerify.verify(password)) {
      logger.warn('auth', 'login', 'server', { ip: req.ip, result: 'failed' });
      return res.status(401).json({ error: 'Invalid password.' });
    }
    const session = await auth.createSession();
    auth.setSessionCookie(res, session);
    logger.info('auth', 'login', 'server', { ip: req.ip, result: 'success' });
    res.json({ ok: true, csrf: session.csrf });
  } catch (error) {
    httpJsonError(res, error, logger, 'login');
  }
});

app.post('/api/logout', async (req, res) => {
  const id = req.cookies?.gcm_session;
  if (id) await auth.destroySession(id);
  await plans.revokeAllForSession(id);
  auth.clearSessionCookie(res);
  res.json({ ok: true });
});

app.get('/api/session', requireAuth, (req, res) => {
  res.json({ authenticated: true, csrf: req.session.csrf });
});

// ---- All state-changing API below requires auth + CSRF ----
app.use('/api', requireAuth, requireCsrf);

// ---- Router inventory ----
app.get('/api/routers', async (_req, res) => {
  try { res.json({ routers: await store.listRouters() }); }
  catch (error) { httpJsonError(res, error, logger, 'routers-list'); }
});

app.post('/api/routers/test', async (req, res) => {
  const opId = crypto.randomUUID();
  try {
    const connection = await resolveConnection(req.body);
    connection.acceptNewHostKey = bool(req.body.acceptNewHostKey);
    const { hostKeyProvider, trustHostKey } = hostKeyProviders();
    const result = await withRouter(connection, async ({ client, connection: resolved }) => {
      const { facts } = await remoteFacts({ client, opId, level: logger.levelName().toLowerCase() });
      return { facts, hostKeyId: hostKeyId(resolved.host, resolved.port) };
    }, { hostKeyProvider, trustHostKey, logger });
    // Re-read the trusted key so the UI can display the current fingerprint.
    const known = await store.knownHostKey(result.hostKeyId);
    res.json({ ok: true, facts: result.facts, fingerprint: known?.fingerprint || null, hostKeyId: result.hostKeyId });
  } catch (error) {
    httpJsonError(res, error, logger, 'routers-test');
  }
});

app.post('/api/routers', async (req, res) => {
  try {
    const body = req.body || {};
    const host = String(body.host || '').trim();
    const port = Number(body.port ?? 22);
    const username = String(body.username || 'root').trim();
    const authType = body.authType || 'password';
    const acceptNewHostKey = bool(body.acceptNewHostKey);
    if (!host || !/^[A-Za-z0-9._:-]+$/.test(host) || host.includes('..')) throw new HttpError(400, 'Enter a valid router host.');
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new HttpError(400, 'Invalid port.');
    if (!['password', 'key', 'agent'].includes(authType)) throw new HttpError(400, 'Invalid auth type.');

    // The router must be reachable and its host key accepted before saving.
    const connection = { host, port, username, authType, password: body.password, privateKey: body.privateKey, acceptNewHostKey: acceptNewHostKey || false };
    const { hostKeyProvider, trustHostKey } = hostKeyProviders();
    const existingKey = await store.knownHostKey(hostKeyId(host, port));
    if (!existingKey && !acceptNewHostKey) {
      throw new HttpError(409, 'Unknown host key. Test the connection with "accept new host key" enabled first.');
    }
    if (acceptNewHostKey) connection.acceptNewHostKey = true;
    const { facts } = await withRouter(connection, async ({ client, connection: resolved }) => {
      const { facts } = await remoteFacts({ client, opId: crypto.randomUUID(), level: 'info' });
      return { facts };
    }, { hostKeyProvider, trustHostKey, logger });

    const id = crypto.randomUUID();
    const router = {
      id,
      name: safeLabel(body.name, host),
      host, port, username, authType,
      createdAt: new Date().toISOString(),
      lastCheckedAt: new Date().toISOString(),
      model: facts.source_model || facts.model || null,
      firmware: facts.firmware_version || facts.firmware || null,
      openwrt: facts.openwrt_version || facts.openwrt || null,
      architecture: facts.architecture || null,
      packageManager: facts.package_manager || detectPackageManager(facts),
      fingerprint: (await store.knownHostKey(hostKeyId(host, port)))?.fingerprint || null,
      keyPath: authType === 'key' ? (body.keyPath || null) : null
    };
    await store.saveRouter(router);
    res.status(201).json({ router });
  } catch (error) {
    httpJsonError(res, error, logger, 'routers-create');
  }
});

function detectPackageManager(facts) {
  const pm = facts.package_manager;
  if (pm) return pm;
  // The native facts JSON carries package manager info when available.
  return null;
}

app.put('/api/routers/:id', async (req, res) => {
  try {
    const id = assertUuid(req.params.id, 'router id');
    const existing = await store.router(id);
    const allowed = ['name', 'keyPath'];
    const patch = {};
    for (const key of allowed) if (req.body?.[key] !== undefined) patch[key] = key === 'name' ? safeLabel(req.body[key], existing.name) : String(req.body[key]).slice(0, 512);
    const updated = { ...existing, ...patch, updatedAt: new Date().toISOString() };
    await store.saveRouter(updated);
    res.json({ router: updated });
  } catch (error) { httpJsonError(res, error, logger, 'routers-update'); }
});

app.delete('/api/routers/:id', async (req, res) => {
  try {
    const id = assertUuid(req.params.id, 'router id');
    await store.deleteRouter(id);
    res.status(204).end();
  } catch (error) { httpJsonError(res, error, logger, 'routers-delete'); }
});

app.post('/api/routers/:id/forget-key', async (req, res) => {
  try {
    const router = await store.router(req.params.id);
    await store.forgetHostKey(hostKeyId(router.host, router.port));
    res.json({ ok: true });
  } catch (error) { httpJsonError(res, error, logger, 'routers-forget-key'); }
});

// ---- Profile library ----
app.get('/api/profiles', async (_req, res) => {
  try { res.json({ profiles: await store.listProfiles() }); }
  catch (error) { httpJsonError(res, error, logger, 'profiles-list'); }
});

app.post('/api/profiles/import', upload.single('profile'), async (req, res) => {
  try {
    if (!req.file) throw new HttpError(400, 'Choose a backup archive to import.');
    const buffer = req.file.buffer;
    const name = String(req.file.originalname || 'profile').toLowerCase();
    const isTarGz = buffer.length > 2 && buffer[0] === 0x1f && buffer[1] === 0x8b;
    const looksJson = !isTarGz && buffer.length < 64 * 1024 * 1024;
    let kind;
    let legacyFormat = null;
    let inspection = null;

    if (isTarGz || name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
      kind = 'v2';
    } else if (looksJson) {
      // Content-based legacy detection (never trust extension alone).
      try {
        const text = buffer.toString('utf8').slice(0, 4 * 1024 * 1024);
        const parsed = JSON.parse(text);
        const format = parsed?.format;
        if (format === 'glinet-portable-profile/v1' || format === 'glinet-portable-profile/v2') {
          kind = 'legacy-unverified';
          legacyFormat = format;
        } else {
          throw new HttpError(400, 'Not a supported portable profile (v2 tar.gz or legacy JSON).');
        }
      } catch (error) {
        if (error instanceof HttpError) throw error;
        throw new HttpError(400, 'Not a supported portable profile archive.');
      }
    } else {
      throw new HttpError(400, 'Not a supported portable profile archive.');
    }

    const id = crypto.randomUUID();
    const sha256 = sha256Hex(buffer);

    if (kind === 'v2') {
      // Verify the archive with the canonical engine BEFORE storing it.
      const tmp = path.join(os.tmpdir(), `gcm-import-${id}.tar.gz`);
      await fs.writeFile(tmp, buffer);
      try {
        inspection = await inspectArchiveLocally(tmp);
        if (inspection.format !== 'glinet-crossmodel/v2') {
          throw new HttpError(400, `Unsupported archive format: ${inspection.format || 'unknown'}`);
        }
      } finally {
        await fs.rm(tmp, { force: true });
      }
      const meta = {
        id, kind: 'v2', fileName: `${id}.tar.gz`,
        label: safeLabel(req.body?.label || inspection.profile_name || inspection.profile_uuid, 'Imported profile'),
        notes: safeNotes(req.body?.notes || inspection.notes),
        strategy: inspection.backup_strategy,
        source: { model: inspection.source_model, firmware: inspection.firmware_version, architecture: inspection.architecture, openwrt: inspection.openwrt_version },
        integrity: 'verified',
        sha256,
        createdAt: new Date().toISOString()
      };
      await store.storeProfile(id, buffer, meta);
      res.status(201).json({ profile: await store.profileMeta(id) });
    } else {
      // Legacy JSON: store clearly labeled, never verified.
      let parsed;
      try { parsed = JSON.parse(buffer.toString('utf8')); } catch { throw new HttpError(400, 'Legacy profile is not valid JSON.'); }
      const meta = {
        id, kind: 'legacy-unverified', fileName: `${id}.json`, legacyFormat,
        label: safeLabel(req.body?.label || parsed?.label, 'Legacy profile'),
        notes: safeNotes(req.body?.notes || ''),
        strategy: 'legacy-portable',
        source: parsed?.source ? { model: parsed.source.model || parsed.source.boardName, architecture: parsed.source.architecture } : null,
        integrity: 'unverified-legacy',
        sha256,
        createdAt: new Date().toISOString()
      };
      await store.storeProfile(id, buffer, meta);
      res.status(201).json({ profile: await store.profileMeta(id) });
    }
  } catch (error) {
    httpJsonError(res, error, logger, 'profiles-import');
  }
});

app.get('/api/profiles/:id/download', async (req, res) => {
  try {
    const id = assertUuid(req.params.id, 'profile id');
    const meta = await store.profileMeta(id);
    const bytes = await store.readProfileBytes(id);
    const ext = meta.kind === 'legacy-unverified' ? 'json' : 'tar.gz';
    res.setHeader('Content-Disposition', `attachment; filename="glinet-crossmodel-${id}.${ext}"`);
    res.type(meta.kind === 'legacy-unverified' ? 'application/json' : 'application/gzip');
    res.send(bytes);
  } catch (error) { httpJsonError(res, error, logger, 'profiles-download'); }
});

app.get('/api/profiles/:id/inspect', async (req, res) => {
  try {
    const id = assertUuid(req.params.id, 'profile id');
    const meta = await store.profileMeta(id);
    if (meta.kind === 'legacy-unverified') {
      const bytes = await store.readProfileBytes(id);
      const parsed = JSON.parse(bytes.toString('utf8'));
      res.json({
        kind: 'legacy-unverified',
        legacyFormat: meta.legacyFormat,
        label: parsed.label || meta.label,
        createdAt: parsed.createdAt || meta.createdAt,
        source: parsed.source || null,
        selected: parsed.selected || null,
        warning: 'This is a legacy Docker JSON profile. It has no v2 archive integrity guarantee and cannot be restored by this edition.'
      });
      return;
    }
    const tmp = path.join(os.tmpdir(), `gcm-inspect-${id}.tar.gz`);
    await fs.writeFile(tmp, await store.readProfileBytes(id));
    try {
      const manifest = await inspectArchiveLocally(tmp);
      res.json({ kind: 'v2', integrity: 'verified', ...manifest, sha256: meta.sha256 });
    } finally {
      await fs.rm(tmp, { force: true });
    }
  } catch (error) { httpJsonError(res, error, logger, 'profiles-inspect'); }
});

app.patch('/api/profiles/:id', async (req, res) => {
  try {
    const id = assertUuid(req.params.id, 'profile id');
    const patch = {};
    if (req.body?.label !== undefined) patch.label = safeLabel(req.body.label);
    if (req.body?.notes !== undefined) patch.notes = safeNotes(req.body.notes);
    const meta = await store.updateProfileMeta(id, patch);
    res.json({ profile: meta });
  } catch (error) { httpJsonError(res, error, logger, 'profiles-update'); }
});

app.delete('/api/profiles/:id', async (req, res) => {
  try {
    const id = assertUuid(req.params.id, 'profile id');
    await store.deleteProfile(id);
    res.status(204).end();
  } catch (error) { httpJsonError(res, error, logger, 'profiles-delete'); }
});

// ---- Jobs (backup / validate / packages / restore / activate) ----

// Per-run connection secrets live only in this in-memory map, keyed by job id.
// They are never written to /data/jobs/*.json and never logged.
const jobSecrets = new Map();

function jobConnection(job) {
  const c = job.payload?.connection || {};
  const secret = jobSecrets.get(job.id) || {};
  return {
    host: c.host,
    port: c.port ?? 22,
    username: c.username || 'root',
    authType: c.authType || 'password',
    password: secret.password,
    privateKey: secret.privateKey,
    acceptNewHostKey: false
  };
}

app.post('/api/jobs', async (req, res) => {
  try {
    const body = req.body || {};
    const type = String(body.type || '');
    if (!['facts', 'backup', 'validate', 'packages', 'restore', 'activate'].includes(type)) {
      throw new HttpError(400, 'Invalid job type.');
    }

    // Resolve connection (never persisted).
    const connectionInput = await resolveConnection(body);
    const routerId = body.routerId || null;
    const profileId = body.profileId ? assertUuid(body.profileId, 'profile id') : null;

    // Sanitized payload for persistence: connection identity only, no secrets.
    const payload = {
      type,
      routerId,
      profileId,
      connection: {
        host: connectionInput.host,
        port: connectionInput.port,
        username: connectionInput.username,
        authType: connectionInput.authType
      },
      request: {
        strategy: body.strategy || null,
        categories: typeof body.categories === 'string' ? body.categories : (Array.isArray(body.categories) ? body.categories.join(',') : null),
        label: safeLabel(body.label, null),
        preserveLanIp: bool(body.preserveLanIp),
        dangerousOverride: bool(body.dangerousOverride),
        directCustomFiles: bool(body.directCustomFiles),
        packages: String(body.packages || ''),
        planToken: String(body.planToken || '')
      }
    };
    const correlationId = crypto.randomUUID();
    const job = await jobs.create({
      type,
      routerId,
      routerLabel: body.routerId ? (await store.router(body.routerId).catch(() => null))?.name || null : connectionInput.host,
      profileId,
      correlationId,
      payload
    });

    // Hold the secrets in memory for the duration of the job run.
    if (connectionInput.password !== undefined || connectionInput.privateKey !== undefined) {
      jobSecrets.set(job.id, {
        password: connectionInput.password,
        privateKey: connectionInput.privateKey
      });
    }

    const level = logger.levelName().toLowerCase();

    // Launch asynchronously (fire and forget; state persists under /data/jobs).
    jobs.run(job.id, async ({ jobId, note }) => {
      const current = await store.job(jobId);
      const conn = jobConnection(current);
      const profileBytes = profileId ? await store.readProfileBytes(profileId) : null;
      const profileMeta = profileId ? await store.profileMeta(profileId) : null;

      const op = async (task) => {
        const { hostKeyProvider, trustHostKey } = hostKeyProviders();
        return withRouter(conn, task, { hostKeyProvider, trustHostKey, logger });
      };

      switch (type) {
        case 'facts': {
          return op(async ({ client }) => {
            const { facts } = await remoteFacts({ client, opId: correlationId, level });
            return { result: { facts } };
          });
        }
        case 'backup': {
          const strategy = assertStrategy(body.strategy || 'portable');
          const categories = validCategoryList(body.categories || GCM_CATEGORIES);
          const scripts = Array.isArray(body.scripts) ? body.scripts.map((p) => normalizeRemotePath(p)).slice(0, 100) : [];
          const binaries = Array.isArray(body.binaries) ? body.binaries.map((p) => normalizeRemotePath(p)).slice(0, 50) : [];
          const label = safeLabel(body.label, 'Backup');
          const notes = safeNotes(body.notes);
          const newId = crypto.randomUUID();
          const tmpArchive = path.join(os.tmpdir(), `gcm-backup-${newId}.tar.gz`);
          const remote = await op(async ({ client }) => {
            return remoteCreate({
              client, opId: correlationId, strategy, profileId: newId,
              name: label, notes, categories, scripts, binaries,
              outputFile: tmpArchive, level, timeout: 900000
            });
          });
          const bytes = await fs.readFile(tmpArchive);
          await fs.rm(tmpArchive, { force: true });
          const sha256 = sha256Hex(bytes);
          // Inspect locally to build metadata (canonical engine verifies).
          const inspectTmp = path.join(os.tmpdir(), `gcm-inspect-${newId}.tar.gz`);
          await fs.writeFile(inspectTmp, bytes);
          let inspection;
          try { inspection = await inspectArchiveLocally(inspectTmp); } finally { await fs.rm(inspectTmp, { force: true }); }
          const meta = {
            id: newId, kind: 'v2', fileName: `${newId}.tar.gz`,
            label, notes, strategy,
            source: { model: inspection.source_model, firmware: inspection.firmware_version, architecture: inspection.architecture, openwrt: inspection.openwrt_version },
            integrity: 'verified', sha256,
            createdAt: new Date().toISOString(),
            jobId: jobId
          };
          await store.storeProfile(newId, bytes, meta);
          return { result: { profileId: newId, sha256, size: bytes.length, markers: remote.markers } };
        }
        case 'validate': {
          if (!profileId) throw new HttpError(400, 'A profile is required for validation.');
          if (profileMeta?.kind === 'legacy-unverified') {
            throw new HttpError(400, 'Legacy JSON profiles cannot be validated or restored by this edition. Export the profile and create a fresh v2 backup from the source router instead.');
          }
          const categories = validCategoryList(body.categories || GCM_CATEGORIES);
          const dangerousOverride = bool(body.dangerousOverride);
          const preserveLanIp = bool(body.preserveLanIp);
          const tmpArchive = path.join(os.tmpdir(), `gcm-validate-${jobId}.tar.gz`);
          await fs.writeFile(tmpArchive, profileBytes);
          const { plan } = await op(async ({ client }) =>
            // The plan's target object is the authoritative fact snapshot for
            // the plan-token binding (validate runs against the live target).
            remoteValidate({ client, opId: correlationId, archiveFile: tmpArchive, categories, dangerousOverride, preserveLanIp, level })
          );
          await fs.rm(tmpArchive, { force: true });
          const targetHash = factsHash(plan.target);
          const token = await plans.issue({
            sessionId: req.session?.id || null,
            routerId,
            profileSha256: profileMeta.sha256,
            targetFactsHash: targetHash,
            strategy: plan.backup_strategy,
            categories,
            packages: String(body.packages || ''),
            directCustomFiles: bool(body.directCustomFiles),
            dangerousOverride,
            allowLegacy: false,
            preserveLanIp
          });
          return { result: { plan, planToken: token.id, targetFactsHash: targetHash } };
        }
        case 'packages': {
          if (!profileId) throw new HttpError(400, 'A profile is required for package review.');
          const tmpArchive = path.join(os.tmpdir(), `gcm-packages-${jobId}.tar.gz`);
          await fs.writeFile(tmpArchive, profileBytes);
          try {
            const { review } = await op(async ({ client }) => remotePackages({ client, opId: correlationId, archiveFile: tmpArchive, level }));
            return { result: { review } };
          } finally {
            await fs.rm(tmpArchive, { force: true });
          }
        }
        case 'restore': {
          if (!profileId) throw new HttpError(400, 'A profile is required for restore.');
          if (profileMeta?.kind === 'legacy-unverified') {
            throw new HttpError(400, 'Legacy JSON profiles cannot be restored by this edition. Create a fresh v2 backup instead.');
          }
          const planToken = String(body.planToken || '');
          if (!planToken) throw new HttpError(400, 'A restore plan token is required. Run validation first.');
          const categories = validCategoryList(body.categories || GCM_CATEGORIES);
          const packages = String(body.packages || '');
          const directCustomFiles = bool(body.directCustomFiles);
          const dangerousOverride = bool(body.dangerousOverride);
          const preserveLanIp = bool(body.preserveLanIp);
          const profileSha256 = profileMeta.sha256;
          const tmpArchive = path.join(os.tmpdir(), `gcm-restore-${jobId}.tar.gz`);
          await fs.writeFile(tmpArchive, profileBytes);
          // Consume the plan token; must be the exact validated state.
          const binding = {
            sessionId: req.session?.id || null,
            routerId,
            profileSha256,
            targetFactsHash: String(body.targetFactsHash || ''),
            strategy: String(body.strategy || ''),
            categories,
            packages,
            directCustomFiles,
            dangerousOverride,
            allowLegacy: false,
            preserveLanIp
          };
          await plans.consume(planToken, binding);
          let outcome;
          try {
            outcome = await op(async ({ client }) => remoteRestore({
              client, opId: correlationId, archiveFile: tmpArchive,
              categories, packages, directCustomFiles, dangerousOverride,
              allowLegacy: false, preserveLanIp, level, timeout: 1800000,
              onStdout: (chunk) => { for (const line of String(chunk).split('\n').slice(0, 5)) { if (line.trim()) note('progress', { line: line.slice(0, 500) }); } }
            }));
          } finally {
            await fs.rm(tmpArchive, { force: true });
          }
          const markers = outcome.markers;
          if (outcome.outcome === 'rolled-back' || outcome.outcome === 'rollback-failed') {
            const err = jobError(outcome.outcome === 'rollback-failed'
              ? 'Restore failed AND rollback failed. The target may be inconsistent; inspect the rollback snapshot immediately.'
              : 'Restore failed; the target was rolled back to its pre-restore state.', {
              rollbackState: outcome.outcome,
              markers
            });
            throw err;
          }
          if (outcome.outcome !== 'succeeded') {
            throw new Error(`Restore did not succeed: ${outcome.outcome}`);
          }
          return { result: { outcome: 'succeeded', markers, rollbackSnapshot: markers.rollbackSnapshot || null, deferred: markers.deferred } };
        }
        case 'activate': {
          const r = await op(async ({ client }) => remoteActivate({ client, opId: correlationId, level }));
          return { result: { markers: r.markers } };
        }
        default:
          throw new HttpError(400, 'Unsupported job type.');
      }
    }).then(async (outcome) => {
      // Attach rollback snapshot to the persisted job for retention policy.
      if (outcome?.result?.rollbackSnapshot) {
        const current = await store.job(job.id).catch(() => null);
        if (current) await store.saveJob({ ...current, rollbackSnapshot: outcome.result.rollbackSnapshot });
      }
    }).catch(() => { /* state persisted by job manager */ })
      .finally(() => jobSecrets.delete(job.id));

    res.status(202).json({ job: await store.job(job.id) });
  } catch (error) {
    httpJsonError(res, error, logger, 'jobs-create');
  }
});

app.get('/api/jobs', async (_req, res) => {
  try { res.json({ jobs: await store.listJobs() }); }
  catch (error) { httpJsonError(res, error, logger, 'jobs-list'); }
});

app.get('/api/jobs/:id', async (req, res) => {
  try {
    const id = assertUuid(req.params.id, 'job id');
    const job = await store.job(id);
    const { payload, ...safeJob } = job;
    res.json({ job: safeJob });
  } catch (error) { httpJsonError(res, error, logger, 'jobs-get'); }
});

// ---- Diagnostics ----
app.get('/api/logs', requireAuth, (req, res) => {
  try {
    const limit = Math.min(Number(req.query.limit) || 200, 2000);
    const entries = logger.recent(limit);
    res.json({ level: logger.levelName(), logs: entries });
  } catch (error) { httpJsonError(res, error, logger, 'logs-get'); }
});

app.get('/api/logs/download', requireAuth, async (_req, res) => {
  try {
    const file = path.join(dataDir, 'logs', 'docker.log');
    const exists = await fs.access(file).then(() => true, () => false);
    if (!exists) return res.status(404).json({ error: 'No log file yet.' });
    res.download(file, 'glinet-crossmodel-docker.log');
  } catch (error) { httpJsonError(res, error, logger, 'logs-download'); }
});

app.post('/api/logs/clear', requireAuth, async (_req, res) => {
  try {
    await fs.rm(path.join(dataDir, 'logs', 'docker.log'), { force: true });
    await fs.rm(path.join(dataDir, 'logs', 'docker.log.1'), { force: true });
    res.json({ ok: true });
  } catch (error) { httpJsonError(res, error, logger, 'logs-clear'); }
});

app.post('/api/settings/log-level', requireAuth, async (req, res) => {
  try {
    const level = String(req.body?.level || '').toUpperCase();
    if (!['INFO', 'DEBUG', 'TRACE'].includes(level)) throw new HttpError(400, 'Level must be INFO, DEBUG, or TRACE.');
    logger.setLevel(level);
    res.json({ level: logger.levelName() });
  } catch (error) { httpJsonError(res, error, logger, 'settings-log-level'); }
});

// ---- Settings / storage policy ----
app.get('/api/settings', requireAuth, async (_req, res) => {
  try { res.json({ settings: store.policy }); }
  catch (error) { httpJsonError(res, error, logger, 'settings-get'); }
});

app.put('/api/settings', requireAuth, async (req, res) => {
  try {
    const body = req.body?.settings || {};
    const next = { ...store.policy };
    for (const key of ['maxProfiles', 'maxTotalBytes', 'rollbackRetention']) {
      const value = Number(body[key]);
      if (Number.isInteger(value) && value > 0) next[key] = value;
    }
    if (typeof body.pruneOnCreate === 'boolean') next.pruneOnCreate = body.pruneOnCreate;
    store.policy = next;
    await store.saveSettings();
    res.json({ settings: store.policy });
  } catch (error) { httpJsonError(res, error, logger, 'settings-update'); }
});

// ---- App info ----
app.get('/api/info', requireAuth, async (_req, res) => {
  res.json({
    edition: 'docker',
    version: '2.0.0-docker.1',
    upstreamMainCommit: await upstreamPin(),
    categories: GCM_CATEGORIES.split(',')
  });
});

// ---- SPA fallback ----
app.get('/', (_req, res) => res.sendFile(path.join(root, 'public', 'index.html')));

// ---- Error handler (no stack traces, no internal paths) ----
app.use((error, _req, res, _next) => {
  logger.error('http', 'server', 'unhandled', { error: String(error?.message || error).slice(0, 500) });
  if (res.headersSent) return;
  res.status(error instanceof HttpError ? error.status : 500).json({ error: error instanceof HttpError ? error.message : 'Internal server error.' });
});

const server = app.listen(PORT, HOST, () => {
  logger.info('server', 'startup', 'server', { port: PORT, host: HOST, dataDir });
  console.log(`GL.iNet Cross-Model Backup / Restore (Docker edition) listening on ${HOST}:${PORT}`);
});

// Graceful shutdown.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info('server', 'shutdown', 'server', { signal });
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
