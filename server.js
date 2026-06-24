import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import multer from 'multer';
import { withRouter, RouterConnectionError, run } from './lib/ssh.js';

const app = express();
const root = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.resolve(process.env.DATA_DIR || path.join(root, 'data'));
const backupDir = path.join(dataDir, 'backups');
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 64 * 1024 * 1024 } });
await fs.mkdir(backupDir, { recursive: true });

app.disable('x-powered-by');
app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));
app.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: 'draft-8', legacyHeaders: false }));
app.use(express.json({ limit: '1mb' }));
app.use(express.static(path.join(root, 'public'), { maxAge: 0, setHeaders: (r) => r.setHeader('Cache-Control', 'no-store') }));

const configCategories = {
  network: ['network', 'dhcp'],
  wireless: ['wireless'],
  vpn: ['wireguard', 'openvpn'],
  firewall: ['firewall'],
  adguard: ['adguardhome'],
  ddns: ['ddns'],
  system: ['system']
};
const categoryNames = [...Object.keys(configCategories), 'packages', 'scripts', 'binaries'];
const MAX_ARTIFACT_BYTES = 8 * 1024 * 1024;
const MAX_ARTIFACT_TOTAL = 32 * 1024 * 1024;
const CORE_PACKAGE = /^(base-files|busybox|dnsmasq|dropbear|firewall|fw4|kernel|libc|libgcc|libpthread|logd|musl|netifd|opkg|procd|rpcd|ubus|uci|uclient-fetch|usign|urngd|wpad.*|kmod-.*)$/;

function shell(value) { return `'${String(value).replace(/'/g, `'"'"'`)}'`; }
function id(value) {
  if (!/^[a-f0-9-]{36}$/i.test(String(value || ''))) throw new Error('Invalid backup ID.');
  return String(value).toLowerCase();
}
function fileFor(value) { return path.join(backupDir, `${id(value)}.json`); }
function selected(input = {}) { return Object.fromEntries(categoryNames.map((key) => [key, Boolean(input[key])])); }
function safeLabel(value) { return String(value || '').trim().slice(0, 100) || 'Untitled backup'; }
function replyError(response, error) {
  const status = error instanceof RouterConnectionError ? 422 : 400;
  response.status(status).json({ error: error?.message || 'Request failed.' });
}
function normalizePath(value) {
  const raw = String(value || '').trim();
  if (!raw || raw.length > 512 || !raw.startsWith('/') || /[\x00-\x1f]/.test(raw)) throw new Error(`Invalid custom path: ${raw || '(empty)'}`);
  const normalized = path.posix.normalize(raw);
  if (normalized !== raw || normalized === '/' || normalized.includes('/../') || normalized.endsWith('/..')) throw new Error(`Unsafe custom path: ${raw}`);
  return normalized;
}
function normalizePathList(value, limit) {
  const values = Array.isArray(value) ? value : String(value || '').split(/\r?\n|,/);
  const output = [...new Set(values.map((item) => String(item).trim()).filter(Boolean).map(normalizePath))];
  if (output.length > limit) throw new Error(`Choose no more than ${limit} custom files in this section.`);
  return output;
}
function safeMode(value) { return /^[0-7]{3,4}$/.test(String(value || '')) ? String(value) : '600'; }
function safePackage(value) { return /^[A-Za-z0-9][A-Za-z0-9+._-]{0,127}$/.test(String(value || '')); }
function artifactSummary(profile) {
  const artifacts = profile.artifacts || {};
  return {
    packageCount: artifacts.packages?.packages?.length || 0,
    scriptCount: artifacts.scripts?.length || 0,
    binaryCount: artifacts.binaries?.length || 0,
    artifactBytes: [...(artifacts.scripts || []), ...(artifacts.binaries || [])].reduce((sum, item) => sum + Number(item.size || 0), 0)
  };
}

async function exists(client, config) {
  const result = await run(client, `uci -q show ${shell(config)}`, { allowFailure: true });
  return result.code === 0 && Boolean(result.stdout.trim());
}
async function opkgArchitectures(client) {
  const result = await run(client, 'opkg print-architecture 2>/dev/null', { allowFailure: true });
  return result.stdout.split(/\r?\n/).map((line) => line.trim().split(/\s+/)[1]).filter(Boolean);
}
async function routerFacts(client) {
  const board = await run(client, 'cat /etc/board.json 2>/dev/null || ubus call system board', { allowFailure: true });
  let raw = {};
  try { raw = JSON.parse(board.stdout); } catch { raw = {}; }
  const wireless = await run(client, 'uci -q show wireless', { allowFailure: true });
  const text = wireless.stdout.toLowerCase();
  const bands = [];
  if (/6g|6ghz|11ax6/.test(text)) bands.push('6 GHz');
  if (/5g|11a|11ac|11ax/.test(text)) bands.push('5 GHz');
  if (/2g|11g|11b/.test(text)) bands.push('2.4 GHz');
  const architecture = (await run(client, 'uname -m', { allowFailure: true })).stdout.trim() || 'unknown';
  return {
    model: raw?.model?.name || raw?.model || 'GL.iNet / OpenWrt router',
    boardName: raw?.board_name || raw?.boardName || 'unknown',
    firmware: raw?.release?.version || raw?.distribution?.version || 'unknown',
    architecture,
    opkgArchitectures: await opkgArchitectures(client),
    bands: [...new Set(bands)],
    detectedAt: new Date().toISOString()
  };
}
async function packageManifest(client) {
  const result = await run(client, 'opkg list-installed 2>/dev/null', { allowFailure: true });
  if (result.code !== 0 && !result.stdout.trim()) return { packages: [], architectures: await opkgArchitectures(client), unavailable: true };
  const packages = result.stdout.split(/\r?\n/).map((line) => {
    const match = line.match(/^([^\s]+)\s+-\s+(.+)$/);
    return match && safePackage(match[1]) ? { name: match[1], version: match[2].trim() } : null;
  }).filter(Boolean);
  return { packages, architectures: await opkgArchitectures(client), unavailable: false };
}
async function readArtifact(client, remotePath, kind) {
  const filePath = normalizePath(remotePath);
  const meta = await run(client, `if [ -f ${shell(filePath)} ] && [ ! -L ${shell(filePath)} ]; then printf '%s ' "$(wc -c < ${shell(filePath)})"; stat -c '%a' ${shell(filePath)} 2>/dev/null || printf '600'; else exit 44; fi`, { allowFailure: true });
  if (meta.code !== 0) throw new Error(`${filePath} is not a regular file on the source router.`);
  const [sizeText, modeText] = meta.stdout.trim().split(/\s+/);
  const size = Number(sizeText);
  if (!Number.isSafeInteger(size) || size < 0) throw new Error(`Could not determine size for ${filePath}.`);
  if (size > MAX_ARTIFACT_BYTES) throw new Error(`${filePath} is ${(size / 1024 / 1024).toFixed(1)} MB. Individual custom files are limited to 8 MB.`);
  const magic = (await run(client, `dd if=${shell(filePath)} bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'`, { allowFailure: true })).stdout.trim().toLowerCase();
  const isElf = magic === '7f454c46';
  if (kind === 'binaries' && !isElf) throw new Error(`${filePath} is not an ELF binary. Put shell and other text files in Custom scripts & files.`);
  const data = (await run(client, `base64 ${shell(filePath)} | tr -d '\n'`, { timeout: Math.max(30_000, size * 10), allowFailure: false })).stdout.trim();
  if (!data || !/^[A-Za-z0-9+/=]+$/.test(data)) throw new Error(`Could not encode ${filePath} for backup.`);
  return { path: filePath, mode: safeMode(modeText), size, kind, format: isElf ? 'elf' : 'file', contentBase64: data };
}
async function writeArtifact(client, artifact, destination) {
  const target = normalizePath(destination);
  const dir = path.posix.dirname(target);
  const mode = safeMode(artifact.mode);
  const content = String(artifact.contentBase64 || '');
  if (!content || !/^[A-Za-z0-9+/=]+$/.test(content)) throw new Error(`Backup artifact for ${artifact.path} is invalid.`);
  await run(client, `mkdir -p ${shell(dir)} && umask 077 && printf %s ${shell(content)} | base64 -d > ${shell(target)} && chmod ${shell(mode)} ${shell(target)}`, { timeout: Math.max(30_000, Number(artifact.size || 0) * 10) });
  return target;
}
async function save(profile) {
  await fs.writeFile(fileFor(profile.id), JSON.stringify(profile, null, 2), { mode: 0o600 });
  return profile;
}
async function load(value) { return JSON.parse(await fs.readFile(fileFor(value), 'utf8')); }
async function list() {
  const entries = await fs.readdir(backupDir, { withFileTypes: true });
  const output = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith('.json')) continue;
    try {
      const profile = JSON.parse(await fs.readFile(path.join(backupDir, entry.name), 'utf8'));
      output.push({ id: profile.id, label: profile.label, createdAt: profile.createdAt, source: profile.source, selected: profile.selected, artifacts: artifactSummary(profile) });
    } catch {}
  }
  return output.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}

app.get('/api/health', (_request, response) => response.json({ ok: true }));
app.post('/api/routers/test', async (request, response) => {
  try { response.json({ ok: true, router: await withRouter(request.body?.connection || request.body, routerFacts) }); }
  catch (error) { replyError(response, error); }
});
app.get('/api/backups', async (_request, response) => response.json({ backups: await list() }));
app.post('/api/backups', async (request, response) => {
  try {
    const wanted = selected(request.body?.selected);
    const scriptPaths = wanted.scripts ? normalizePathList(request.body?.scriptPaths, 20) : [];
    const binaryPaths = wanted.binaries ? normalizePathList(request.body?.binaryPaths, 10) : [];
    const profile = await withRouter(request.body?.connection, async (client) => {
      const configs = {};
      for (const [category, names] of Object.entries(configCategories)) {
        if (!wanted[category]) continue;
        configs[category] = {};
        for (const name of names) if (await exists(client, name)) configs[category][name] = (await run(client, `uci -q export ${shell(name)}`)).stdout;
      }
      const artifacts = {};
      if (wanted.packages) artifacts.packages = await packageManifest(client);
      let totalBytes = 0;
      for (const [kind, paths] of [['scripts', scriptPaths], ['binaries', binaryPaths]]) {
        if (!wanted[kind]) continue;
        artifacts[kind] = [];
        for (const artifactPath of paths) {
          const artifact = await readArtifact(client, artifactPath, kind);
          totalBytes += artifact.size;
          if (totalBytes > MAX_ARTIFACT_TOTAL) throw new Error('All selected scripts and binaries together exceed the 32 MB portable-profile limit.');
          artifacts[kind].push(artifact);
        }
      }
      return { format: 'glinet-portable-profile/v2', id: crypto.randomUUID(), label: safeLabel(request.body?.label), createdAt: new Date().toISOString(), source: await routerFacts(client), selected: wanted, configs, artifacts };
    });
    await save(profile);
    response.status(201).json({ backup: { id: profile.id, label: profile.label, createdAt: profile.createdAt, source: profile.source, selected: profile.selected, artifacts: artifactSummary(profile) } });
  } catch (error) { replyError(response, error); }
});
app.post('/api/backups/import', upload.single('backup'), async (request, response) => {
  try {
    if (!request.file) throw new Error('Choose a JSON backup file.');
    const profile = JSON.parse(request.file.buffer.toString('utf8'));
    if (!['glinet-portable-profile/v1', 'glinet-portable-profile/v2'].includes(profile.format) || typeof profile.configs !== 'object') throw new Error('That is not a supported portable backup.');
    profile.id = crypto.randomUUID();
    profile.label = safeLabel(request.body?.label || profile.label);
    await save(profile);
    response.status(201).json({ backup: { id: profile.id, label: profile.label, createdAt: profile.createdAt, source: profile.source, selected: profile.selected, artifacts: artifactSummary(profile) } });
  } catch (error) { replyError(response, error); }
});
app.get('/api/backups/:backupId/download', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    response.setHeader('Content-Disposition', `attachment; filename="glinet-portable-${profile.id}.json"`);
    response.type('application/json').send(JSON.stringify(profile, null, 2));
  } catch (error) { replyError(response, error); }
});
app.delete('/api/backups/:backupId', async (request, response) => {
  try { await fs.rm(fileFor(request.params.backupId)); response.status(204).end(); }
  catch (error) { replyError(response, error); }
});
app.post('/api/backups/:backupId/validate', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const target = await withRouter(request.body?.target, routerFacts);
    const artifacts = artifactSummary(profile);
    const warnings = [];
    if (profile.selected?.wireless && !target.bands.length) warnings.push('Target radio bands could not be detected; review Wi-Fi settings before applying.');
    if (profile.selected?.network) warnings.push('Network settings are exported for review only: physical ports, interface names, switch layout, and VLAN device mapping are never auto-applied across models.');
    if (profile.selected?.system) warnings.push('System users, passwords, hardware-specific values, and firmware settings are never restored.');
    if (artifacts.packageCount) warnings.push(`${artifacts.packageCount} package entries are a manifest, not .ipk files. Restoring them resolves packages from the target router's currently configured feeds; core and kmod packages are skipped.`);
    if (artifacts.scriptCount) warnings.push(`${artifacts.scriptCount} custom script/file artifact(s) are staged under /root/glinet-portable-restore by default. Direct overwrite requires explicit approval.`);
    if (artifacts.binaryCount && profile.source?.architecture !== target.architecture) warnings.push(`Binary restore is blocked: source architecture ${profile.source?.architecture || 'unknown'} does not match target architecture ${target.architecture}.`);
    response.json({ profile: { id: profile.id, label: profile.label, source: profile.source, selected: profile.selected, artifacts }, target, warnings, apply: Object.keys(profile.configs).filter((key) => !['network', 'system'].includes(key)) });
  } catch (error) { replyError(response, error); }
});
app.post('/api/backups/:backupId/restore', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const wanted = selected(request.body?.selected || profile.selected);
    const installPackages = Boolean(request.body?.installPackages);
    const directFileRestore = Boolean(request.body?.directFileRestore);
    const result = await withRouter(request.body?.target, async (client) => {
      const target = await routerFacts(client);
      const applied = [];
      const skipped = [];
      const staged = [];
      for (const [category, configs] of Object.entries(profile.configs || {})) {
        if (!wanted[category]) continue;
        if (category === 'network' || category === 'system') { skipped.push(`${category}: requires manual migration on the target.`); continue; }
        for (const [name, exportText] of Object.entries(configs)) {
          if (!(await exists(client, name))) { skipped.push(`${name}: not present on target.`); continue; }
          const encoded = Buffer.from(String(exportText), 'utf8').toString('base64');
          await run(client, `printf %s ${shell(encoded)} | base64 -d | uci import ${shell(name)}`);
          applied.push(name);
        }
      }
      const packageData = profile.artifacts?.packages;
      if (wanted.packages && packageData?.packages?.length) {
        if (!installPackages) skipped.push(`packages: ${packageData.packages.length} package manifest entries captured; select package install to resolve compatible packages from target feeds.`);
        else {
          const installed = new Set((await packageManifest(client)).packages.map((item) => item.name));
          const candidates = packageData.packages.map((item) => item.name).filter((name) => safePackage(name) && !installed.has(name) && !CORE_PACKAGE.test(name));
          const update = await run(client, 'opkg update', { timeout: 120_000, allowFailure: true });
          if (update.code !== 0) skipped.push(`packages: opkg update failed; no packages were installed. ${update.stderr.trim() || update.stdout.trim()}`);
          else {
            for (const packageName of candidates) {
              const install = await run(client, `opkg install ${shell(packageName)}`, { timeout: 120_000, allowFailure: true });
              if (install.code === 0) applied.push(`package:${packageName}`);
              else skipped.push(`package:${packageName}: unavailable or incompatible on target feeds.`);
            }
          }
        }
      }
      const stageRoot = `/root/glinet-portable-restore/${profile.id}`;
      for (const kind of ['scripts', 'binaries']) {
        const artifacts = profile.artifacts?.[kind] || [];
        if (!wanted[kind] || !artifacts.length) continue;
        if (kind === 'binaries' && profile.source?.architecture !== target.architecture) { skipped.push(`binaries: source ${profile.source?.architecture || 'unknown'} and target ${target.architecture} architectures do not match.`); continue; }
        for (const artifact of artifacts) {
          const destination = directFileRestore ? artifact.path : `${stageRoot}/${kind}${artifact.path}`;
          await writeArtifact(client, artifact, destination);
          (directFileRestore ? applied : staged).push(destination);
        }
      }
      if (applied.some((item) => !item.startsWith('package:'))) await run(client, 'uci commit; /etc/init.d/firewall restart 2>/dev/null || true', { allowFailure: true });
      return { applied, skipped, staged, target };
    });
    response.json({ ok: true, ...result });
  } catch (error) { replyError(response, error); }
});

app.listen(Number(process.env.PORT || 8787), '0.0.0.0', () => console.log('GL.iNet Cross-Model Backup / Restore listening'));
