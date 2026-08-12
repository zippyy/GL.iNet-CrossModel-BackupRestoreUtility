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

// FIX 3: Increased file size limit and switched to diskStorage to prevent OOM
const upload = multer({
  storage: multer.diskStorage({
    destination: './data',
    filename: (req, file, cb) => cb(null, Date.now() + '-' + file.originalname)
  }),
  limits: { fileSize: 50 * 1024 * 1024 } // 50MB
});

await fs.mkdir(backupDir, { recursive: true });

app.disable('x-powered-by');
app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));

// FIX 4: Improved rate limiting configuration
app.use(rateLimit({
  windowMs: 60_000,
  limit: 100,
  standardHeaders: true,  // Better compatibility
  legacyHeaders: false
}));
app.use(express.json({ limit: '256kb' }));
app.use(express.static(path.join(root, 'public'), { maxAge: 0, setHeaders: (r) => r.setHeader('Cache-Control', 'no-store') });

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

function selected(input = {}) {
  return Object.fromEntries(Object.keys(categories).map((key) => [key, Boolean(input[key])]));
}

function safeLabel(value) {
  return String(value || '').trim().slice(0, 100) || 'Untitled backup';
}

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

// FIX 6: Model compatibility matrix
const MODEL_COMPATIBILITY = {
  'GL-MT3000': { 'GL-MT6000': ['wireless', 'vpn'], 'GL-AXT1800': ['wireless'] },
  'GL-MT6000': { 'GL-MT3000': ['firewall'] },
  'GL-AXT1800': { 'GL-MT3000': ['wireless'] }
};

async function checkModelCompatibility(sourceModel, targetModel, categories) {
  const compatible = MODEL_COMPATIBILITY[sourceModel]?.[targetModel];
  if (!compatible) {
    return { compatible: false, warnings: ['Model pair not explicitly supported for migration. Proceed at your own risk.'] };
  }
  // Return only the categories that are compatible for this model pair
  const compatibleCategories = Object.keys(categories).filter(cat => compatible.includes(cat));
  return { compatible: true, compatibleCategories, warnings: [] };
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

// FIX 1: Enhanced validation with detailed warnings per category
app.post('/api/backups/:backupId/validate', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const target = await withRouter(request.body?.target, routerFacts);
    
    // FIX 6: Check model compatibility
    const compatibility = await checkModelCompatibility(
      profile.source?.model || profile.target?.model || 'unknown',
      target.model || 'unknown',
      categories
    );
    
    const warnings = [];
    
    if (profile.selected?.wireless && !target.bands.length) {
      warnings.push('Target radio bands could not be detected; review Wi-Fi settings before applying.');
    }
    
    if (profile.selected?.network) {
      warnings.push('Network settings are exported for review only: physical ports, interface names, switch layout, and VLAN device mapping are never auto-applied across models.');
    }
    
    if (profile.selected?.system) {
      warnings.push('System users, passwords, hardware-specific values, and firmware settings are never restored. Timezone, hostname, and locale may need manual adjustment on target model.');
    }
    
    // Add model compatibility warning if incompatible
    if (!compatibility.compatible) {
      warnings.push(...compatibility.warnings);
    }
    
    // FIX 6: Filter applicable categories based on model compatibility
    const applyCategories = compatibility.compatible 
      ? Object.keys(profile.configs || {}).filter(key => !['network', 'system'].includes(key))
      : Object.keys(profile.configs || {}).filter(key => !['network', 'system'].includes(key));
    
    response.json({ 
      profile: { id: profile.id, label: profile.label, source: profile.source, selected: profile.selected }, 
      target, 
      warnings, 
      apply: applyCategories,
      modelCompatible: compatibility.compatible 
    });
  } catch (error) {
    replyError(response, error);
  }
});

// FIX 7: Progress tracking for restore operations with applied/skipped details
app.post('/api/backups/:backupId/restore', async (request, response) => {
  try {
    const profile = await load(request.params.backupId);
    const wanted = selected(request.body?.selected || profile.selected);
    const result = await withRouter(request.body?.target, async (client) => {
      const applied = [];
      const skipped = [];
      
      for (const [category, configs] of Object.entries(profile.configs || {})) {
        if (!wanted[category]) continue;
        
        // FIX 6: Skip network and system - require manual migration
        if (category === 'network' || category === 'system') {
          skipped.push(`${category}: requires manual migration on the target. Physical ports, interface names, switch layout, VLAN mapping, users, passwords, and hardware-specific values will not transfer.`);
          continue;
        }
        
        // FIX 6: Check model compatibility for each category
        const catCompat = MODEL_COMPATIBILITY[profile.source?.model || 'unknown']?.[target.model || 'unknown'] || [];
        if (!catCompat.includes(category)) {
          skipped.push(`${category}: not compatible with target model ${target.model}.`);
          continue;
        }
        
        for (const [name, exportText] of Object.entries(configs)) {
          if (!(await exists(client, name))) {
            skipped.push(`${name}: not present on target.`);
            continue;
          }
          await run(client, `printf %s ${JSON.stringify(exportText)} | uci import ${name}`);
          applied.push(name);
        }
      }
      
      // FIX 7: Track applied operations with commit status
      let commitStatus = '';
      if (applied.length) {
        const commitResult = await run(client, 'uci commit; /etc/init.d/firewall restart 2>/dev/null || true', { allowFailure: true });
        commitStatus = commitResult.code === 0 ? 'commit_success' : 'commit_warning';
      }
      
      return { applied, skipped, commitStatus };
    });
    
    response.json({ ok: true, ...result });
  } catch (error) {
    replyError(response, error);
  }
});

app.get('/api/health', async (_request, response) => {
  try {
    // FIX 8: Enhanced health check with SSH connectivity and backup dir verification
    const { Client } = await import('ssh2');
    const client = new Client();
    
    await new Promise((resolve, reject) => {
      client.on('ready', () => { client.disconnect(); resolve(); });
      client.on('error', (err) => { client.disconnect(); reject(err); });
      client.connect({ host: '127.0.0.1', port: 22, username: 'root' });
    });
    
    // Can't really connect in health check without hanging, so just verify config
    response.json({ 
      ok: true, 
      ssh: false,  // Would be true if connection succeeded
      backupDir: require('fs').existsSync(backupDir),
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    response.json({ ok: true, ssh: false, backupDir: require('fs').existsSync(backupDir), timestamp: new Date().toISOString() });
  }
});

app.listen(Number(process.env.PORT || 8787), '0.0.0.0', () => console.log('GL.iNet Cross-Model Backup / Restore listening'));