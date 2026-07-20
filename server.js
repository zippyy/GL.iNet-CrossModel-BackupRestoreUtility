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
  vpn: ['wireguard', 'wireguard_server', 'openvpn', 'ovpnclient', 'ovpnserver'],
  firewall: ['firewall'],
  adguard: ['adguardhome'],
  ddns: ['ddns', 'gl_ddns'],
  system: ['system']
};

const backupModes = new Set(['profile', 'remote-safe', 'clone']);
const remoteSafeExcludedConfigs = new Set(['zerotier', 'tailscale', 'gl-cloud', 'rtty', 'dropbear', 'wan-access']);
const secretOrIdentityOptions = [
  'macaddr',
  'private_key',
  'public_key',
  'preshared_key',
  'presharedkey',
  'username',
  'password',
  'param_enc',
  'lookup_host'
];

function id(value) {
  if (!/^[a-f0-9-]{36}$/i.test(String(value || ''))) throw new Error('Invalid backup ID.');
  return String(value).toLowerCase();
}
function fileFor(value) { return path.join(backupDir, `${id(value)}.json`); }
function selected(input = {}) { return Object.fromEntries(Object.keys(categories).map((key) => [key, Boolean(input[key])])); }
function safeLabel(value) { return String(value || '').trim().slice(0, 100) || 'Untitled backup'; }
function backupMode(value) {
  const mode = String(value || 'profile').toLowerCase();
  if (!backupModes.has(mode)) throw new Error('Unsupported backup mode.');
  return mode;
}
function replyError(response, error) {
  const status = error instanceof RouterConnectionError ? 422 : 400;
  response.status(status).json({ error: error?.message || 'Request failed.' });
}
function quoteShell(value) {
  return `'${String(value ?? '').replaceAll("'", "'\"'\"'")}'`;
}
async function exists(client, config) {
  const result = await run(client, `uci -q show ${quoteShell(config)}`, { allowFailure: true });
  return result.code === 0 && Boolean(result.stdout.trim());
}
function stripUciOptions(exportText, optionNames) {
  const wanted = new Set(optionNames);
  return String(exportText || '')
    .split(/\r?\n/)
    .filter((line) => {
      const match = line.match(/^\s*option\s+([A-Za-z0-9_]+)\s+/);
      return !match || !wanted.has(match[1]);
    })
    .join('\n')
    .trimEnd() + '\n';
}
function sanitizeConfigExport(name, exportText, mode) {
  if (mode === 'profile') return { text: exportText, sanitized: [] };

  const options = [];
  if (name === 'network' || name === 'wireless') options.push('macaddr');
  if (['network', 'wireguard', 'wireguard_server'].includes(name)) options.push('private_key', 'public_key', 'preshared_key', 'presharedkey');
  if (['gl_ddns', 'ddns'].includes(name)) options.push('username', 'password', 'domain', 'param_enc', 'lookup_host');
  if (['ovpnclient', 'openvpn'].includes(name)) options.push('username', 'password');

  const unique = [...new Set(options.length ? options : secretOrIdentityOptions.filter((option) => option !== 'domain'))];
  const text = stripUciOptions(exportText, unique);
  return { text, sanitized: unique };
}
async function routerFacts(client) {
  const board = await run(client, 'cat /etc/board.json 2>/dev/null || ubus call system board', { allowFailure: true });
  let raw = {};
  try { raw = JSON.parse(board.stdout); } catch { raw = {}; }
  const wireless = await run(client, 'uci -q show wireless', { allowFailure: true });
  const release = await run(client, '. /etc/openwrt_release 2>/dev/null; printf "%s\\n%s\\n" "${DISTRIB_RELEASE:-unknown}" "${DISTRIB_ARCH:-unknown}"', { allowFailure: true });
  const kernel = await run(client, "awk '/^Package: kernel$/{found=1} found && /^Version:/{print $2; exit}' /usr/lib/opkg/status 2>/dev/null || uname -r", { allowFailure: true });
  const text = wireless.stdout.toLowerCase();
  const bands = [];
  if (/6g|6ghz|11ax6/.test(text)) bands.push('6 GHz');
  if (/5g|11a|11ac|11ax/.test(text)) bands.push('5 GHz');
  if (/2g|11g|11b/.test(text)) bands.push('2.4 GHz');
  const [openwrtVersion = 'unknown', architecture = 'unknown'] = release.stdout.trim().split(/\r?\n/);
  return {
    model: raw?.model?.name || raw?.model || 'GL.iNet / OpenWrt router',
    boardName: raw?.model?.id || raw?.board_name || raw?.boardName || 'unknown',
    firmware: raw?.release?.version || raw?.distribution?.version || 'unknown',
    openwrtVersion,
    architecture,
    kernel: kernel.stdout.trim() || 'unknown',
    bands: [...new Set(bands)],
    detectedAt: new Date().toISOString()
  };
}
async function capturePackages(client) {
  const script = String.raw`awk '
    BEGIN { first = 1; printf "[" }
    /^Package:/ { pkg = $2 }
    /^Version:/ { ver = $2 }
    /^Architecture:/ { arch = $2 }
    /^Section:/ { section = $2 }
    /^Status:.*user installed/ { user = 1 }
    /^$/ {
      if (pkg != "" && user) {
        if (!first) printf ","
        first = 0
        printf "{\"name\":\"%s\",\"version\":\"%s\",\"architecture\":\"%s\",\"section\":\"%s\",\"isKernelModule\":%s}", pkg, ver, arch, section, (section == "kernel" || substr(pkg, 1, 5) == "kmod-" ? "true" : "false")
      }
      pkg = ""; ver = ""; arch = ""; section = ""; user = 0
    }
    END {
      if (pkg != "" && user) {
        if (!first) printf ","
        printf "{\"name\":\"%s\",\"version\":\"%s\",\"architecture\":\"%s\",\"section\":\"%s\",\"isKernelModule\":%s}", pkg, ver, arch, section, (section == "kernel" || substr(pkg, 1, 5) == "kmod-" ? "true" : "false")
      }
      printf "]\n"
    }
  ' /usr/lib/opkg/status 2>/dev/null`;
  const result = await run(client, script, { allowFailure: true });
  try {
    const packages = JSON.parse(result.stdout || '[]');
    return Array.isArray(packages) ? packages : [];
  } catch {
    return [];
  }
}
async function targetInstalledPackages(client) {
  const script = String.raw`awk '
    /^Package:/ { pkg = $2 }
    /^Version:/ { ver = $2 }
    /^Status:.*installed/ { installed = 1 }
    /^$/ {
      if (pkg != "" && installed) print pkg "\t" ver
      pkg = ""; ver = ""; installed = 0
    }
    END {
      if (pkg != "" && installed) print pkg "\t" ver
    }
  ' /usr/lib/opkg/status 2>/dev/null`;
  const result = await run(client, script, { allowFailure: true });
  return new Map(result.stdout.split(/\r?\n/).filter(Boolean).map((line) => {
    const [name, version = ''] = line.split('\t');
    return [name, version];
  }));
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
      output.push({ id: profile.id, label: profile.label, mode: profile.mode || 'profile', createdAt: profile.createdAt, source: profile.source, selected: profile.selected });
    } catch {}
  }
  return output.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}
function comparePackages(sourcePackages = [], installed = new Map()) {
  const rows = { missingKernelModules: [], missing: [], installed: [] };
  for (const source of sourcePackages) {
    if (!source?.name) continue;
    const targetVersion = installed.get(source.name);
    if (targetVersion) rows.installed.push({ ...source, targetVersion, versionMatch: source.version === targetVersion });
    else if (source.isKernelModule) rows.missingKernelModules.push(source);
    else rows.missing.push(source);
  }
  return rows;
}
function validationPlan(profile, target, packageComparison) {
  const warnings = [];
  const apply = [];
  const skipped = [];

  if ((profile.mode === 'clone' || profile.mode === 'remote-safe') && profile.source?.boardName !== target.boardName) {
    skipped.push(`Mode ${profile.mode} requires the same model. Source ${profile.source?.boardName || 'unknown'}, target ${target.boardName || 'unknown'}.`);
  }
  if (profile.mode !== 'profile' && profile.source?.firmware !== target.firmware) {
    warnings.push(`Firmware differs. Source ${profile.source?.firmware || 'unknown'}, target ${target.firmware || 'unknown'}.`);
  }
  if (profile.mode === 'remote-safe') warnings.push('Remote-Safe mode preserves Tailscale, ZeroTier, GoodCloud, Dropbear, WAN access, and tunnel-facing firewall/network sections.');
  if (profile.selected?.wireless && !target.bands.length) warnings.push('Target radio bands could not be detected; review Wi-Fi settings before applying.');
  if (profile.selected?.network) warnings.push('Network settings are applied last and service reload is deferred; reconnect or reboot after restore.');
  if (profile.selected?.system) skipped.push('System users, passwords, hardware-specific values, and firmware settings are never restored.');

  for (const key of Object.keys(profile.configs || {})) {
    if (key === 'system') continue;
    if (profile.mode === 'profile' && key === 'network') warnings.push('Profile mode keeps network changes conservative; physical ports, device names, and switch/VLAN mapping are not portable.');
    apply.push(key);
  }

  if (packageComparison?.missingKernelModules?.length) warnings.push(`${packageComparison.missingKernelModules.length} kernel module package(s) are missing; install firmware-matched IPKs manually.`);
  if (packageComparison?.missing?.length) warnings.push(`${packageComparison.missing.length} user package(s) from the source are not installed on the target.`);

  return { warnings, apply, skipped };
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
    const mode = backupMode(request.body?.mode);
    const profile = await withRouter(request.body?.connection, async (client) => {
      const configs = {};
      const sanitized = {};
      for (const [category, names] of Object.entries(categories)) {
        if (!wanted[category]) continue;
        configs[category] = {};
        sanitized[category] = {};
        for (const name of names) {
          if (mode === 'remote-safe' && remoteSafeExcludedConfigs.has(name)) continue;
          if (await exists(client, name)) {
            const raw = (await run(client, `uci -q export ${quoteShell(name)}`)).stdout;
            const clean = sanitizeConfigExport(name, raw, mode);
            configs[category][name] = clean.text;
            sanitized[category][name] = clean.sanitized;
          }
        }
      }
      const source = await routerFacts(client);
      const packages = await capturePackages(client);
      return {
        format: 'glinet-portable-profile/v2',
        compatibleFormats: ['glinet-portable-profile/v1'],
        id: crypto.randomUUID(),
        label: safeLabel(request.body?.label),
        mode,
        createdAt: new Date().toISOString(),
        source,
        selected: wanted,
        configs,
        sanitized,
        packages,
        safety: {
          archivePrefix: 'glinet-portable-profile',
          remoteSafeExcludedConfigs: [...remoteSafeExcludedConfigs],
          identityOptionsStripped: mode === 'profile' ? [] : secretOrIdentityOptions
        }
      };
    });
    await save(profile);
    response.status(201).json({ backup: { id: profile.id, label: profile.label, mode: profile.mode, createdAt: profile.createdAt, source: profile.source, selected: profile.selected } });
  } catch (error) { replyError(response, error); }
});
app.post('/api/backups/import', upload.single('backup'), async (request, response) => {
  try {
    if (!request.file) throw new Error('Choose a JSON backup file.');
    const profile = JSON.parse(request.file.buffer.toString('utf8'));
    if (!['glinet-portable-profile/v1', 'glinet-portable-profile/v2'].includes(profile.format) || typeof profile.configs !== 'object') throw new Error('That is not a supported portable backup.');
    profile.id = crypto.randomUUID();
    profile.label = safeLabel(request.body?.label || profile.label);
    profile.mode = backupMode(profile.mode);
    await save(profile);
    response.status(201).json({ backup: { id: profile.id, label: profile.label, mode: profile.mode, createdAt: profile.createdAt, source: profile.source, selected: profile.selected } });
  } catch (error) { replyError(response, error); }
});
app.get('/api/backups/:backupId/download', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    response.setHeader('Content-Disposition', `attachment; filename="glinet-portable-${profile.mode || 'profile'}-${profile.id}.json"`);
    response.type('application/json').send(JSON.stringify(profile, null, 2));
  } catch (error) { replyError(response, error); }
});
app.delete('/api/backups/:backupId', async (request, response) => {
  try { await fs.rm(fileFor(request.params.backupId)); response.status(204).end(); }
  catch (error) { replyError(response, error); }
});
app.post('/api/backups/:backupId/packages', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const result = await withRouter(request.body?.target, async (client) => comparePackages(profile.packages || [], await targetInstalledPackages(client)));
    response.json({ ok: true, ...result });
  } catch (error) { replyError(response, error); }
});
app.post('/api/backups/:backupId/validate', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const result = await withRouter(request.body?.target, async (client) => {
      const target = await routerFacts(client);
      const packageComparison = comparePackages(profile.packages || [], await targetInstalledPackages(client));
      const plan = validationPlan(profile, target, packageComparison);
      return { target, packageComparison, plan };
    });
    response.json({ profile: { id: profile.id, label: profile.label, mode: profile.mode || 'profile', source: profile.source, selected: profile.selected }, ...result });
  } catch (error) { replyError(response, error); }
});
app.post('/api/backups/:backupId/restore', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const mode = backupMode(profile.mode);
    const wanted = selected(request.body?.selected || profile.selected);
    const result = await withRouter(request.body?.target, async (client) => {
      const target = await routerFacts(client);
      if ((mode === 'clone' || mode === 'remote-safe') && profile.source?.boardName !== target.boardName) {
        throw new Error(`Mode ${mode} requires matching models. Source ${profile.source?.boardName || 'unknown'}, target ${target.boardName || 'unknown'}.`);
      }

      const applied = [];
      const skipped = [];
      let serviceReloadDeferred = false;

      for (const [category, configs] of Object.entries(profile.configs || {})) {
        if (!wanted[category]) continue;
        if (category === 'system') { skipped.push(`${category}: requires manual migration on the target.`); continue; }

        for (const [name, exportText] of Object.entries(configs)) {
          if (mode === 'remote-safe' && remoteSafeExcludedConfigs.has(name)) { skipped.push(`${name}: preserved by remote-safe mode.`); continue; }
          if (!(await exists(client, name))) { skipped.push(`${name}: not present on target.`); continue; }

          await run(client, `printf %s ${JSON.stringify(exportText)} | uci import ${quoteShell(name)}`);
          applied.push(name);
          if (['network', 'dhcp', 'wireless', 'firewall'].includes(name)) serviceReloadDeferred = true;
        }
      }

      if (applied.length) await run(client, 'uci commit', { allowFailure: true });
      return { applied, skipped, serviceReloadDeferred };
    });
    response.json({ ok: true, ...result });
  } catch (error) { replyError(response, error); }
});

app.listen(Number(process.env.PORT || 8787), '0.0.0.0', () => console.log('GL.iNet Cross-Model Backup / Restore listening'));
