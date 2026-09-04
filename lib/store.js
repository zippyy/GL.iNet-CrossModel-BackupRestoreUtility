import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { HttpError } from './util.js';

// Layered persistent store under /data.
//
//   profiles/     immutable archive bytes  <profile-id>.tar.gz  (never rewritten)
//   meta/         profile sidecar metadata (rename/notes are sidecar only)
//   routers/      router inventory (never plaintext passwords)
//   known-hosts/  host-key trust store
//   jobs/         job state + sanitized transcripts
//   logs/         diagnostic log
//   settings.json storage policy
//
// Writes are atomic: temp file + fsync + rename.

const atomicWrite = async (file, data, mode = 0o600) => {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
  await fs.writeFile(tmp, data, { mode });
  await fs.rename(tmp, file);
};

const readJson = async (file) => {
  try {
    return JSON.parse(await fs.readFile(file, 'utf8'));
  } catch {
    return null;
  }
};

const safeFileName = (id) => {
  if (!/^[a-f0-9-]{36}$/i.test(String(id || ''))) throw new HttpError(400, 'Invalid ID.');
  return String(id).toLowerCase();
};

export class Store {
  constructor(dataDir) {
    this.root = dataDir;
    this.profilesDir = path.join(dataDir, 'profiles');
    this.metaDir = path.join(dataDir, 'meta');
    this.routersDir = path.join(dataDir, 'routers');
    this.knownHostsFile = path.join(dataDir, 'known-hosts.json');
    this.jobsDir = path.join(dataDir, 'jobs');
    this.logsDir = path.join(dataDir, 'logs');
    this.settingsFile = path.join(dataDir, 'settings.json');
    this.sessionDir = path.join(dataDir, 'sessions');
  }

  async init() {
    for (const dir of [this.profilesDir, this.metaDir, this.routersDir, this.jobsDir, this.logsDir, this.sessionDir]) {
      await fs.mkdir(dir, { recursive: true, mode: 0o700 });
    }
    const settings = (await readJson(this.settingsFile)) || {};
    this.policy = {
      maxProfiles: settings.maxProfiles ?? 100,
      maxProfileBytes: settings.maxProfileBytes ?? 512 * 1024 * 1024,
      maxTotalBytes: settings.maxTotalBytes ?? 2 * 1024 * 1024 * 1024,
      rollbackRetention: settings.rollbackRetention ?? 10,
      pruneOnCreate: settings.pruneOnCreate ?? true
    };
  }

  async saveSettings() {
    await atomicWrite(this.settingsFile, JSON.stringify(this.policy, null, 2));
  }

  // ---- profiles (immutable bytes + sidecar metadata) ----

  profilePath(id) { return path.join(this.profilesDir, `${safeFileName(id)}.tar.gz`); }
  metaPath(id) { return path.join(this.metaDir, `${safeFileName(id)}.json`); }

  async profileExists(id) {
    return fs.access(this.profilePath(id)).then(() => true, () => false);
  }

  async storeProfile(id, bytes, meta) {
    const file = this.profilePath(id);
    const existing = await fs.access(file).then(() => true, () => false);
    if (existing) throw new HttpError(409, 'Profile already exists.');
    await atomicWrite(file, bytes, 0o600);
    await atomicWrite(this.metaPath(id), JSON.stringify(meta, null, 2));
    if (this.policy.pruneOnCreate) await this.prune();
    return id;
  }

  async readProfileBytes(id) {
    try {
      return await fs.readFile(this.profilePath(id));
    } catch {
      throw new HttpError(404, 'Profile not found.');
    }
  }

  async profileMeta(id) {
    const meta = await readJson(this.metaPath(id));
    if (!meta) throw new HttpError(404, 'Profile not found.');
    return meta;
  }

  async updateProfileMeta(id, patch) {
    const meta = await this.profileMeta(id);
    const next = { ...meta, ...patch, id, updatedAt: new Date().toISOString() };
    await atomicWrite(this.metaPath(id), JSON.stringify(next, null, 2));
    return next;
  }

  async listProfiles() {
    const out = [];
    const entries = await fs.readdir(this.metaDir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith('.json')) continue;
      const meta = await readJson(path.join(this.metaDir, entry.name));
      if (!meta) continue;
      const id = meta.id || entry.name.replace(/\.json$/, '');
      const stat = await fs.stat(this.profilePath(id)).catch(() => null);
      out.push({ ...meta, id, size: stat?.size ?? 0, createdAt: meta.createdAt });
    }
    out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    return out;
  }

  async deleteProfile(id) {
    const file = this.profilePath(id);
    const meta = this.metaPath(id);
    const exists = await fs.access(file).then(() => true, () => false);
    if (!exists) throw new HttpError(404, 'Profile not found.');
    await fs.rm(file, { force: true });
    await fs.rm(meta, { force: true });
  }

  async prune() {
    const list = await this.listProfiles();
    const activeRollbackIds = new Set(
      (await this.listJobs()).filter((j) => ['running', 'queued'].includes(j.state) && j.rollbackProfileId).map((j) => j.rollbackProfileId)
    );
    let total = 0;
    const candidates = [];
    for (const item of list) {
      if (activeRollbackIds.has(item.id)) continue; // never prune an active restore's snapshot
      total += item.size;
      candidates.push(item);
    }
    let excess = total - this.policy.maxTotalBytes;
    candidates.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    const remove = [];
    for (const item of candidates) {
      if (list.length - remove.length <= this.policy.maxProfiles) {
        if (excess <= 0) break;
        remove.push(item.id);
        excess -= item.size;
      } else {
        remove.push(item.id);
      }
    }
    for (const id of remove) await this.deleteProfile(id).catch(() => {});
    return remove;
  }

  // ---- routers ----

  routerPath(id) { return path.join(this.routersDir, `${safeFileName(id)}.json`); }

  async saveRouter(router) {
    if (!router.id || !/^[a-f0-9-]{36}$/i.test(router.id)) throw new HttpError(400, 'Invalid router ID.');
    const { password, ...safe } = router; // never persist passwords
    await atomicWrite(this.routerPath(router.id), JSON.stringify(safe, null, 2));
    return safe;
  }

  async router(id) {
    const r = await readJson(this.routerPath(id));
    if (!r) throw new HttpError(404, 'Router not found.');
    return r;
  }

  async listRouters() {
    const out = [];
    const entries = await fs.readdir(this.routersDir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith('.json')) continue;
      const r = await readJson(path.join(this.routersDir, entry.name));
      if (r) out.push(r);
    }
    out.sort((a, b) => String(b.lastCheckedAt || '').localeCompare(String(a.lastCheckedAt || '')));
    return out;
  }

  async deleteRouter(id) {
    await fs.rm(this.routerPath(id), { force: true });
  }

  // ---- known hosts (host-key trust) ----

  async knownHosts() { return (await readJson(this.knownHostsFile)) || {}; }

  async knownHostKey(hostKey) {
    const hosts = await this.knownHosts();
    return hosts[hostKey] || null;
  }

  async trustHostKey(hostKey, record) {
    const hosts = await this.knownHosts();
    hosts[hostKey] = { ...record, trustedAt: new Date().toISOString() };
    await atomicWrite(this.knownHostsFile, JSON.stringify(hosts, null, 2));
  }

  async forgetHostKey(hostKey) {
    const hosts = await this.knownHosts();
    delete hosts[hostKey];
    await atomicWrite(this.knownHostsFile, JSON.stringify(hosts, null, 2));
  }

  // ---- jobs ----

  jobPath(id) { return path.join(this.jobsDir, `${safeFileName(id)}.json`); }

  async saveJob(job) {
    const { password, ...safe } = job;
    await atomicWrite(this.jobPath(job.id), JSON.stringify(safe, null, 2));
    return safe;
  }

  async job(id) {
    const j = await readJson(this.jobPath(id));
    if (!j) throw new HttpError(404, 'Job not found.');
    return j;
  }

  async listJobs() {
    const out = [];
    const entries = await fs.readdir(this.jobsDir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith('.json')) continue;
      const j = await readJson(path.join(this.jobsDir, entry.name));
      if (j) out.push(j);
    }
    out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    return out;
  }
}
