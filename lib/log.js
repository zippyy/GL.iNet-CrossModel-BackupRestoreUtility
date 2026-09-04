import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

// Correlation-aware diagnostic logging with credential redaction.
//
// Mirrors the native runtime's logging principles: every significant operation
// carries a correlation ID (GCM_OP_ID) and fields whose names imply secrets
// are redacted before they reach any log sink.

const SENSITIVE_NAME = /password|passwd|secret|token|auth|private[_-]?key|preshared|csrf|session|certificate|\bcert\b|_ca\b|credential|keyfile/i;

export function isSensitiveName(name) {
  return SENSITIVE_NAME.test(String(name || ''));
}

export function redact(value) {
  return String(value ?? '').replace(/[A-Za-z0-9+/=._-]{6,}/g, '[REDACTED]');
}

export function cleanField(value) {
  return String(value ?? '')
    .replace(/[\r\n\t]/g, ' ')
    .replace(/[\x00-\x1f]/g, '')
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .slice(0, 1024);
}

export function formatEntry(entry) {
  const fields = [];
  for (const [name, value] of Object.entries(entry.fields || {})) {
    const out = isSensitiveName(name) ? '[REDACTED]' : cleanField(value);
    fields.push(`${name}="${out}"`);
  }
  return `${entry.timestamp} ${entry.severity} op=${cleanField(entry.op || 'none')} component=${cleanField(entry.component)} scope=${cleanField(entry.scope)} ${fields.join(' ')}`.trimEnd();
}

const LEVEL_RANK = { ERROR: 0, WARN: 1, INFO: 2, DEBUG: 3, TRACE: 4 };

export class Logger {
  constructor({ dir, level = process.env.GCM_LOG_LEVEL || 'INFO' } = {}) {
    this.dir = dir;
    this.buffer = [];
    this.setLevel(level);
    this.listeners = new Set();
  }

  setLevel(level) {
    const normalized = String(level || 'INFO').toUpperCase();
    this.level = LEVEL_RANK[normalized] === undefined ? 'INFO' : normalized;
  }

  levelName() { return this.level; }

  // Rotate at 512 KB like the native runtime.
  async append(line) {
    if (!this.dir) return;
    await fs.mkdir(this.dir, { recursive: true, mode: 0o700 });
    const file = path.join(this.dir, 'docker.log');
    try {
      const stat = await fs.stat(file).catch(() => null);
      if (stat && stat.size >= 512 * 1024) {
        await fs.rename(file, path.join(this.dir, 'docker.log.1')).catch(() => {});
      }
      await fs.appendFile(file, `${line}\n`, { mode: 0o600 });
    } catch { /* logging never breaks an operation */ }
  }

  log(severity, op, component, scope, fields = {}) {
    const rank = LEVEL_RANK[severity] ?? LEVEL_RANK.INFO;
    if (rank > LEVEL_RANK[this.level]) return null;
    // Redact at entry creation so the in-memory buffer, subscribers (SSE/
    // diagnostics UI), and the file sink all carry only redacted values.
    const redactedFields = {};
    for (const [name, value] of Object.entries(fields || {})) {
      redactedFields[name] = isSensitiveName(name) ? '[REDACTED]' : value;
    }
    const entry = {
      severity, op: op || 'none', component, scope: scope || 'server',
      timestamp: new Date().toISOString(), fields: redactedFields
    };
    const line = formatEntry(entry);
    this.append(line);
    this.buffer.push({ ...entry, line });
    if (this.buffer.length > 2000) this.buffer.splice(0, this.buffer.length - 2000);
    const out = this.buffer[this.buffer.length - 1];
    for (const listener of this.listeners) listener(out);
    return out;
  }

  error(op, component, scope, fields) { return this.log('ERROR', op, component, scope, fields); }
  warn(op, component, scope, fields) { return this.log('WARN', op, component, scope, fields); }
  info(op, component, scope, fields) { return this.log('INFO', op, component, scope, fields); }
  debug(op, component, scope, fields) { return this.log('DEBUG', op, component, scope, fields); }
  trace(op, component, scope, fields) { return this.log('TRACE', op, component, scope, fields); }

  subscribe(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }

  recent(limit = 200) {
    // Read the current log file tail; fall back to in-memory buffer of last entries.
    return this.memoryTail(limit);
  }

  memoryTail(limit) {
    return [...this.buffer || []].slice(-limit);
  }
}

export function newCorrelationId() { return crypto.randomUUID(); }

export function correlationFromJob(jobId) { return jobId; }
