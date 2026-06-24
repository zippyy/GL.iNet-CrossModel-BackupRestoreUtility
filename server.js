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
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 8 * 1024 * 1024 } });
await fs.mkdir(backupDir, { recursive: true });

app.disable('x-powered-by');
app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));
app.use(rateLimit({ windowMs: 60_000, limit: 40, standardHeaders: 'draft-8', legacyHeaders: false }));
app.use(express.json({ limit: '256kb' }));
app.use(express.static(path.join(root, 'public'), { maxAge: 0, setHeaders: (r) => r.setHeader('Cache-Control', 'no-store') }));

const categories = {
  network: ['network', 'dhcp'],
  wireless: ['wireless'],
  vpn: ['wireguard', 'openvpn'],
  firewall: ['firewall'],
  adguard: ['adguardhome'],
  ddns: ['ddns'],
  system: ['system']
};

function id(value) {
  if (!/^[a-f0-9-]{36}$/i.test(String(value || ''))) throw new Error('Invalid backup ID.');
  return String(value).toLowerCase();
}
function fileFor(value) { return path.join(backupDir, `${id(value)}.json`); }
function selected(input = {}) { return Object.fromEntries(Object.keys(categories).map((key) => [key, Boolean(input[key])])); }
function safeLabel(value) { return String(value || '').trim().slice(0, 100) || 'Untitled backup'; }
function replyError(response, error) {
  const status = error instanceof RouterConnectionError ? 422 : 400;
  response.status(status).json({ error: error?.message || 'Request failed.' });
}
async function exists(client, config) {
  const result = await run(client, `uci -q show ${config}`, { allowFailure: true });
  return result.code === 0 && Boolean(result.stdout.trim());
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
  return {
    model: raw?.model?.name || raw?.model || 'GL.iNet / OpenWrt router',
    boardName: raw?.board_name || raw?.boardName || 'unknown',
    firmware: raw?.release?.version || raw?.distribution?.version || 'unknown',
    bands: [...new Set(bands)],
    detectedAt: new Date().toISOString()
  };
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
      output.push({ id: profile.id, label: profile.label, createdAt: profile.createdAt, source: profile.source, selected: profile.selected });
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
    const profile = await withRouter(request.body?.connection, async (client) => {
      const configs = {};
      for (const [category, names] of Object.entries(categories)) {
        if (!wanted[category]) continue;
        configs[category] = {};
        for (const name of names) {
          if (await exists(client, name)) configs[category][name] = (await run(client, `uci -q export ${name}`)).stdout;
        }
      }
      return { format: 'glinet-portable-profile/v1', id: crypto.randomUUID(), label: safeLabel(request.body?.label), createdAt: new Date().toISOString(), source: await routerFacts(client), selected: wanted, configs };
    });
    await save(profile);
    response.status(201).json({ backup: { id: profile.id, label: profile.label, createdAt: profile.createdAt, source: profile.source, selected: profile.selected } });
  } catch (error) { replyError(response, error); }
});
app.post('/api/backups/import', upload.single('backup'), async (request, response) => {
  try {
    if (!request.file) throw new Error('Choose a JSON backup file.');
    const profile = JSON.parse(request.file.buffer.toString('utf8'));
    if (profile.format !== 'glinet-portable-profile/v1' || typeof profile.configs !== 'object') throw new Error('That is not a supported portable backup.');
    profile.id = crypto.randomUUID();
    profile.label = safeLabel(request.body?.label || profile.label);
    await save(profile);
    response.status(201).json({ backup: { id: profile.id, label: profile.label, createdAt: profile.createdAt, source: profile.source, selected: profile.selected } });
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
    const warnings = [];
    if (profile.selected?.wireless && !target.bands.length) warnings.push('Target radio bands could not be detected; review Wi-Fi settings before applying.');
    if (profile.selected?.network) warnings.push('Network settings are exported for review only: physical ports, interface names, switch layout, and VLAN device mapping are never auto-applied across models.');
    if (profile.selected?.system) warnings.push('System users, passwords, hardware-specific values, and firmware settings are never restored.');
    response.json({ profile: { id: profile.id, label: profile.label, source: profile.source, selected: profile.selected }, target, warnings, apply: Object.keys(profile.configs).filter((key) => !['network', 'system'].includes(key)) });
  } catch (error) { replyError(response, error); }
});
app.post('/api/backups/:backupId/restore', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const wanted = selected(request.body?.selected || profile.selected);
    const result = await withRouter(request.body?.target, async (client) => {
      const applied = [];
      const skipped = [];
      for (const [category, configs] of Object.entries(profile.configs || {})) {
        if (!wanted[category]) continue;
        if (category === 'network' || category === 'system') { skipped.push(`${category}: requires manual migration on the target.`); continue; }
        for (const [name, exportText] of Object.entries(configs)) {
          if (!(await exists(client, name))) { skipped.push(`${name}: not present on target.`); continue; }
          await run(client, `printf %s ${JSON.stringify(exportText)} | uci import ${name}`);
          applied.push(name);
        }
      }
      if (applied.length) await run(client, 'uci commit; /etc/init.d/firewall restart 2>/dev/null || true', { allowFailure: true });
      return { applied, skipped };
    });
    response.json({ ok: true, ...result });
  } catch (error) { replyError(response, error); }
});

app.listen(Number(process.env.PORT || 8787), '0.0.0.0', () => console.log('GL.iNet Cross-Model Backup / Restore listening'));
