import crypto from 'node:crypto';

// Input validation and normalization helpers.
// Never trust filenames, archive paths, router host input, remote paths, UUIDs,
// category names, or strategy names. These helpers are the single choke point.

const CATEGORIES = new Set([
  'wifi', 'lan', 'dhcp', 'dns', 'firewall', 'timezone', 'ddns', 'vpn',
  'packages', 'persistent', 'custom-files', 'custom-binaries'
]);

export const STRATEGIES = new Set(['portable', 'clone', 'remote-safe', 'snapshot']);
export const ALL_CATEGORIES = [...CATEGORIES].join(',');

export function validUuid(value) {
  return typeof value === 'string' && /^[a-f0-9-]{36}$/i.test(value);
}

export function assertUuid(value, label = 'ID') {
  if (!validUuid(value)) throw new HttpError(400, `Invalid ${label}.`);
  return String(value).toLowerCase();
}

export function validHost(value) {
  const host = String(value || '').trim();
  if (!host || host.length > 253) return false;
  // IPv6 literal, bracketed IPv6, hostname, or IPv4 — no whitespace/slashes.
  if (/[\s/\\]/.test(host)) return false;
  if (host.startsWith('[')) return /^\[[0-9a-fA-F:.]+\]$/.test(host);
  if (host.includes(':')) return /^[0-9a-fA-F:.]+$/.test(host);
  return /^[A-Za-z0-9._-]+$/.test(host);
}

export function validPort(value) {
  const port = Number(value);
  return Number.isInteger(port) && port >= 1 && port <= 65535;
}

export function validUsername(value) {
  const user = String(value || '').trim();
  return !!user && user.length <= 64 && !/[\s:]/.test(user);
}

export function validAuthType(value) {
  return ['password', 'key', 'agent'].includes(value);
}

export function validStrategy(value) {
  return STRATEGIES.has(value);
}

export function assertStrategy(value) {
  if (!validStrategy(value)) throw new HttpError(400, `Invalid strategy: ${String(value)}`);
  return value;
}

export function validCategoryList(value) {
  const input = Array.isArray(value) ? value : String(value || '').split(',');
  const seen = new Set();
  for (const raw of input) {
    const cat = String(raw).trim();
    if (!cat) continue;
    if (!CATEGORIES.has(cat)) throw new HttpError(400, `Unknown category: ${cat}`);
    seen.add(cat);
  }
  return [...seen].join(',');
}

export function validPackageName(value) {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9+._-]{0,127}$/.test(value);
}

export function normalizeRemotePath(value, { allowEmpty = false } = {}) {
  const raw = String(value ?? '').trim();
  if (!raw) {
    if (allowEmpty) return '';
    throw new HttpError(400, 'A path is required.');
  }
  if (raw.length > 512 || !raw.startsWith('/') || /[\x00-\x1f]/.test(raw)) {
    throw new HttpError(400, `Invalid path: ${raw || '(empty)'}`);
  }
  const normalized = raw.split('/').filter((part, i) => part !== '' || i === 0).join('/');
  if (normalized !== raw || normalized === '/' || raw.includes('/../') || raw.endsWith('/..')) {
    throw new HttpError(400, `Unsafe path: ${raw}`);
  }
  return normalized;
}

export function safeLabel(value, fallback = 'Untitled') {
  return String(value ?? '').trim().slice(0, 200) || fallback;
}

export function safeNotes(value) {
  return String(value ?? '').trim().slice(0, 4000);
}

export function bool(value, fallback = false) {
  if (value === undefined || value === null) return fallback;
  return value === true || value === 1 || String(value).toLowerCase() === 'true' || String(value) === '1';
}

export function httpJsonError(res, error, logger, op) {
  const status = error instanceof HttpError ? error.status : 500;
  const message = error instanceof HttpError ? error.message : 'Internal server error.';
  if (!(error instanceof HttpError)) {
    logger?.error(op, 'http', 'server', { error: String(error?.message || error).slice(0, 500) });
  }
  return res.status(status).json({ error: message });
}

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function sha256Hex(input) {
  return crypto.createHash('sha256').update(input).digest('hex');
}
