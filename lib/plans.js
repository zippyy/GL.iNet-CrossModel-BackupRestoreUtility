import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { HttpError } from './util.js';

// One-use restore plan tokens.
//
// A restore must never be a single click from profile selection. The API flow
// is: validate (against a live target) -> server issues a short-lived token
// bound to the authenticated session, router identity, profile SHA-256, target
// facts hash, strategy, selected categories/packages and override flags ->
// restore consumes that exact token. Any drift between validation and restore
// invalidates the token.

const TOKEN_TTL_MS = 15 * 60 * 1000; // 15 minutes

export class PlanStore {
  constructor({ dir, logger }) {
    this.dir = dir;
    this.logger = logger;
  }

  async init() {
    await fs.mkdir(this.dir, { recursive: true, mode: 0o700 });
  }

  tokenPath(id) {
    const safe = String(id || '').replace(/[^a-f0-9-]/gi, '');
    return path.join(this.dir, `${safe}.json`);
  }

  async issue(binding) {
    const id = crypto.randomUUID();
    const token = {
      id,
      createdAt: new Date().toISOString(),
      expiresAt: Date.now() + TOKEN_TTL_MS,
      used: false,
      sessionId: binding.sessionId,
      binding: {
        routerId: binding.routerId || null,
        hostKeyId: binding.hostKeyId || null,
        profileSha256: binding.profileSha256,
        targetFactsHash: binding.targetFactsHash,
        strategy: binding.strategy,
        categories: binding.categories,
        packages: binding.packages || '',
        directCustomFiles: !!binding.directCustomFiles,
        dangerousOverride: !!binding.dangerousOverride,
        allowLegacy: !!binding.allowLegacy,
        preserveLanIp: !!binding.preserveLanIp
      }
    };
    await fs.writeFile(this.tokenPath(id), JSON.stringify(token), { mode: 0o600 });
    return token;
  }

  async consume(id, expectedBinding) {
    if (!/^[a-f0-9-]{36}$/i.test(String(id || ''))) throw new HttpError(400, 'Invalid plan token.');
    let token;
    try {
      token = JSON.parse(await fs.readFile(this.tokenPath(id), 'utf8'));
    } catch {
      throw new HttpError(404, 'Plan token not found. Run validation again.');
    }
    if (token.used) throw new HttpError(409, 'Plan token was already used. Run validation again.');
    if (token.expiresAt < Date.now()) throw new HttpError(409, 'Plan token expired. Run validation again.');
    if (token.sessionId && token.sessionId !== expectedBinding.sessionId) {
      throw new HttpError(403, 'Plan token belongs to another session.');
    }
    const b = token.binding;
    const e = expectedBinding;
    const mismatches = [];
    if (b.routerId !== e.routerId) mismatches.push('router');
    if (b.profileSha256 !== e.profileSha256) mismatches.push('profile');
    if (b.targetFactsHash !== e.targetFactsHash) mismatches.push('target state');
    if (b.strategy !== e.strategy) mismatches.push('strategy');
    if (b.categories !== e.categories) mismatches.push('categories');
    if (b.packages !== (e.packages || '')) mismatches.push('package selection');
    if (b.directCustomFiles !== !!e.directCustomFiles) mismatches.push('custom-file mode');
    if (b.dangerousOverride !== !!e.dangerousOverride) mismatches.push('dangerous override');
    if (b.allowLegacy !== !!e.allowLegacy) mismatches.push('legacy approval');
    if (b.preserveLanIp !== !!e.preserveLanIp) mismatches.push('LAN IP preservation');
    if (mismatches.length) {
      this.logger?.warn('restore', 'plan', 'consume', { reason: `binding-drift:${mismatches.join(',')}`, msg: 'Restore plan token binding mismatch' });
      throw new HttpError(409, `Restore plan no longer matches: ${mismatches.join(', ')}. Run validation again.`);
    }
    token.used = true;
    await fs.writeFile(this.tokenPath(id), JSON.stringify(token), { mode: 0o600 });
    return token;
  }

  async revokeAllForSession(sessionId) {
    const entries = await fs.readdir(this.dir).catch(() => []);
    for (const name of entries) {
      if (!name.endsWith('.json')) continue;
      try {
        const token = JSON.parse(await fs.readFile(path.join(this.dir, name), 'utf8'));
        if (token.sessionId === sessionId) {
          token.used = true;
          await fs.writeFile(path.join(this.dir, name), JSON.stringify(token), { mode: 0o600 });
        }
      } catch { /* ignore */ }
    }
  }
}

export function factsHash(facts) {
  if (!facts) return '';
  const stable = JSON.stringify({
    model: facts.source_model ?? facts.model,
    board_name: facts.board_name ?? facts.boardName,
    firmware: facts.firmware_version ?? facts.firmware,
    openwrt: facts.openwrt_version ?? facts.openwrt,
    architecture: facts.architecture,
    kernel: facts.kernel_version ?? facts.kernel,
    fingerprint: facts.device_fingerprint ?? facts.fingerprint
  });
  return crypto.createHash('sha256').update(stable).digest('hex');
}
