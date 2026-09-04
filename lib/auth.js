import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { HttpError } from './util.js';

// Built-in admin authentication. Fail-closed:
//   - ADMIN_PASSWORD_HASH (scrypt, format "salt:hash") or ADMIN_PASSWORD is
//     required at startup; without it the server refuses to start.
//   - Server-side sessions under /data/sessions (HttpOnly cookie carries only
//     a random session id).
//   - CSRF protection for state-changing browser requests (double-submit
//     cookie + server-side token bound to the session).
//   - Rate-limited login.
//   - Credentials never touch localStorage or logs.

const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 32 };
const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // 12h
const COOKIE_NAME = 'gcm_session';

export function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(String(password), salt, SCRYPT.keylen, SCRYPT).toString('hex');
  return `${salt}:${hash}`;
}

export function verifyPassword(password, stored) {
  const [salt, hash] = String(stored || '').split(':');
  if (!salt || !hash) return false;
  const candidate = crypto.scryptSync(String(password), salt, SCRYPT.keylen, SCRYPT);
  const expected = Buffer.from(hash, 'hex');
  return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected);
}

export function authConfigFromEnv(env = process.env) {
  // Docker-secret style configuration is preferred: a file whose content is
  // the admin password (GCM_ADMIN_PASSWORD_FILE or ADMIN_PASSWORD_FILE). The
  // file is read at startup only; the secret is never logged or persisted.
  const secretFile = env.GCM_ADMIN_PASSWORD_FILE || env.ADMIN_PASSWORD_FILE;
  if (secretFile) {
    let secret;
    try {
      secret = readFileSync(path.resolve(secretFile), 'utf8').replace(/\r?\n$/, '');
    } catch (error) {
      throw new Error(`Could not read admin password file ${secretFile}: ${error.message}`);
    }
    if (secret.length < 8) throw new Error('ADMIN_PASSWORD_FILE must contain at least 8 characters.');
    const expected = Buffer.from(secret);
    return {
      verify: (pw) => {
        const candidate = Buffer.from(String(pw ?? ''));
        return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected);
      }
    };
  }
  const configuredHash = env.ADMIN_PASSWORD_HASH || env.GCM_ADMIN_PASSWORD_HASH;
  if (configuredHash) {
    const [salt, hash] = configuredHash.split(':');
    if (!salt || !hash || !/^[a-f0-9]+$/.test(salt) || !/^[a-f0-9]+$/.test(hash)) {
      throw new Error('ADMIN_PASSWORD_HASH must be in "salt:hash" scrypt format (run `node lib/auth.js --hash` to generate).');
    }
    return { verify: (pw) => verifyPassword(pw, configuredHash) };
  }
  const plain = env.ADMIN_PASSWORD || env.GCM_ADMIN_PASSWORD;
  if (plain) {
    if (String(plain).length < 8) throw new Error('ADMIN_PASSWORD must be at least 8 characters.');
    const expected = Buffer.from(String(plain));
    return {
      verify: (pw) => {
        const candidate = Buffer.from(String(pw ?? ''));
        return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected);
      }
    };
  }
  throw new Error(
    'No admin credential configured. Set GCM_ADMIN_PASSWORD_FILE (Docker secret), ADMIN_PASSWORD_HASH (scrypt salt:hash) ' +
    'or ADMIN_PASSWORD (min 8 chars) via environment. The server refuses to start unauthenticated.'
  );
}

export class Auth {
  constructor({ store, logger, verify, cookieSecure = false, trustProxy = false }) {
    this.store = store;
    this.logger = logger;
    this.verify = verify;
    this.cookieSecure = cookieSecure;
    this.trustProxy = trustProxy;
  }

  sessionPath(id) {
    const safe = String(id || '').replace(/[^a-f0-9-]/gi, '');
    return path.join(this.store.sessionDir, `${safe}.json`);
  }

  async createSession() {
    const id = crypto.randomUUID();
    const session = { id, createdAt: new Date().toISOString(), expiresAt: Date.now() + SESSION_TTL_MS, csrf: crypto.randomBytes(24).toString('hex') };
    await fs.writeFile(this.sessionPath(id), JSON.stringify(session), { mode: 0o600 });
    return session;
  }

  async loadSession(id) {
    if (!/^[a-f0-9-]{36}$/i.test(String(id || ''))) return null;
    try {
      const session = JSON.parse(await fs.readFile(this.sessionPath(id), 'utf8'));
      if (!session || session.expiresAt < Date.now()) return null;
      return session;
    } catch {
      return null;
    }
  }

  async destroySession(id) {
    await fs.rm(this.sessionPath(id), { force: true }).catch(() => {});
  }

  // Cookie options: HttpOnly, SameSite=Strict; Secure when configured.
  cookieOptions() {
    return {
      httpOnly: true,
      sameSite: 'strict',
      secure: this.cookieSecure,
      path: '/',
      maxAge: SESSION_TTL_MS
    };
  }

  setSessionCookie(res, session) {
    res.cookie(COOKIE_NAME, session.id, this.cookieOptions());
  }

  clearSessionCookie(res) {
    res.clearCookie(COOKIE_NAME, { ...this.cookieOptions(), maxAge: 0 });
  }

  async requireAuth(req, res, next) {
    const id = req.cookies?.[COOKIE_NAME];
    const session = await this.loadSession(id);
    if (!session) {
      return res.status(401).json({ error: 'Authentication required.' });
    }
    req.session = session;
    next();
  }

  async requireCsrf(req, res, next) {
    // State-changing browser actions must carry the session-bound CSRF token.
    if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
    const supplied = req.get('x-csrf-token') || req.body?.csrf;
    if (!supplied || !req.session || supplied !== req.session.csrf) {
      this.logger?.warn('auth', 'http', 'csrf', { ip: req.ip, msg: 'CSRF validation failed' });
      return res.status(403).json({ error: 'CSRF validation failed. Refresh the page and try again.' });
    }
    next();
  }

  // Alternative: bearer-token auth for API clients (optional).
  async requireApiToken(req, res, next) {
    const token = req.get('authorization')?.replace(/^Bearer\s+/i, '') || req.get('x-api-token');
    if (!this.bearerTokens?.length) return res.status(401).json({ error: 'API tokens are not configured.' });
    if (!this.bearerTokens.includes(token)) return res.status(401).json({ error: 'Invalid API token.' });
    req.session = { id: 'api', csrf: null };
    next();
  }
}

// Standalone: generate a password hash.
const isMain = process.argv[1] && path.basename(process.argv[1]) === 'auth.js';
if (isMain && process.argv[2] === '--hash') {
  const password = process.argv[3] || process.env.ADMIN_PASSWORD;
  if (!password) {
    console.error('usage: node lib/auth.js --hash <password>');
    process.exit(2);
  }
  console.log(hashPassword(password));
}
