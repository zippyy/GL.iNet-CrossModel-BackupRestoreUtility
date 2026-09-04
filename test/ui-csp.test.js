// UI / CSP proof (Blocker 4).
//
// The UI must work under a STRICT Content-Security-Policy served by Helmet:
//   - no inline <script> or <style> in the served HTML (external app.js/app.css);
//   - CSP header present with script-src/style-src 'self' and NO unsafe-inline;
//   - login page (index.html) and static assets load with correct MIME types;
//   - the real API auth contract the JS depends on works: unauthenticated
//     requests are rejected, wrong password is rejected, valid login returns
//     a session cookie + CSRF token, state-changing requests without CSRF are
//     rejected, with CSRF they succeed.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gcm-ui-csp-'));
const dataDir = path.join(work, 'data');
const secretFile = path.join(work, 'admin-secret');
fs.writeFileSync(secretFile, 'ui-csp-admin-secret-123\n');
process.env.DATA_DIR = dataDir;
process.env.GCM_ADMIN_PASSWORD_FILE = secretFile;
process.env.PORT = '0';
process.env.GCM_LOG_LEVEL = 'ERROR';
process.env.GCM_FILE_LOG = '0';
process.env.GCM_SYSLOG = '0';

const { server: httpServer } = await import('../server.js');
if (!httpServer.address()) {
  await new Promise((resolve) => httpServer.once('listening', resolve));
}
const baseUrl = `http://127.0.0.1:${httpServer.address().port}`;
const ADMIN_PASSWORD = 'ui-csp-admin-secret-123';

after(async () => {
  try { await new Promise((resolve) => httpServer.close(resolve)); } catch { /* closed */ }
  fs.rmSync(work, { recursive: true, force: true });
});

test('index.html carries no inline script or style and references external assets', async () => {
  const res = await fetch(`${baseUrl}/`);
  assert.equal(res.status, 200);
  const html = await res.text();
  // External assets only.
  assert.match(html, /<link rel="stylesheet" href="\/app\.css">/);
  assert.match(html, /<script src="\/app\.js" defer><\/script>/);
  // No inline executable or style content anywhere in the document.
  assert.doesNotMatch(html, /<script(?![^>]*src=)[^>]*>/i, 'no inline <script> block');
  assert.doesNotMatch(html, /<style[^>]*>/i, 'no inline <style> block');
  assert.doesNotMatch(html, /\son\w+\s*=/i, 'no inline event handler attributes');
  assert.doesNotMatch(html, /\sstyle\s*=/i, 'no inline style attributes');
  // CSP header is present and strict.
  const csp = res.headers.get('content-security-policy');
  assert.ok(csp, 'CSP header must be present');
  assert.match(csp, /script-src 'self'/, 'script-src self');
  assert.doesNotMatch(csp, /unsafe-inline/, 'no unsafe-inline anywhere in CSP');
  assert.doesNotMatch(csp, /unsafe-eval/, 'no unsafe-eval anywhere in CSP');
  assert.match(csp, /style-src 'self'/, 'style-src self');
  assert.match(csp, /frame-ancestors 'none'/, 'frame-ancestors none');
  // No other security headers disabled.
  assert.ok(res.headers.get('x-content-type-options'), 'nosniff header present');
});

test('external app.css and app.js are served first-party with correct MIME types', async () => {
  const css = await fetch(`${baseUrl}/app.css`);
  assert.equal(css.status, 200);
  assert.match(css.headers.get('content-type') || '', /text\/css/);
  const cssText = await css.text();
  assert.ok(cssText.length > 500, 'app.css is non-trivial');
  assert.match(cssText, /:root/, 'css contains the theme variables');

  const js = await fetch(`${baseUrl}/app.js`);
  assert.equal(js.status, 200);
  const jsType = js.headers.get('content-type') || '';
  assert.match(jsType, /javascript|ecmascript/, `app.js MIME is a JS type (got ${jsType})`);
  const jsText = await js.text();
  assert.ok(jsText.length > 1000, 'app.js is non-trivial');
  assert.match(jsText, /'use strict'/, 'app.js retains its strict-mode prologue');
  assert.doesNotMatch(jsText, /<script/i, 'no embedded html in app.js');
});

test('the login page renders for an anonymous client', async () => {
  const res = await fetch(`${baseUrl}/`);
  const html = await res.text();
  assert.match(html, /GL\.iNet Cross-Model Backup/);
  assert.match(html, /id="login"/);
  assert.match(html, /id="login-pw"/);
});

test('unauthenticated API access is rejected; wrong password is rejected; valid login issues session + CSRF', async () => {
  // No cookie -> 401.
  const anon = await fetch(`${baseUrl}/api/routers`, { headers: { Accept: 'application/json' } });
  assert.equal(anon.status, 401, 'unauthenticated API request must be rejected');

  // Wrong password -> 401.
  const bad = await fetch(`${baseUrl}/api/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: 'definitely-wrong-password' })
  });
  assert.equal(bad.status, 401, 'wrong password must be rejected');

  // Valid login -> session cookie + CSRF token.
  const login = await fetch(`${baseUrl}/api/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: ADMIN_PASSWORD })
  });
  assert.equal(login.status, 200);
  const data = await login.json();
  assert.ok(data.csrf, 'login returns a CSRF token');
  const setCookies = login.headers.getSetCookie();
  assert.ok(setCookies.length >= 1);
  const cookie = setCookies[0].split(';')[0];

  // Authenticated GET works with the cookie.
  const authed = await fetch(`${baseUrl}/api/routers`, { headers: { Accept: 'application/json', Cookie: cookie } });
  assert.equal(authed.status, 200);

  // State-changing request WITHOUT CSRF is rejected (403).
  const noCsrf = await fetch(`${baseUrl}/api/jobs`, {
    method: 'POST',
    headers: { Accept: 'application/json', Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ type: 'facts' })
  });
  assert.equal(noCsrf.status, 403, 'state-changing request without CSRF must be rejected');

  // With the session-bound CSRF token the same request reaches validation
  // (a 4xx here means it passed the CSRF gate — no router/connection yet).
  const withCsrf = await fetch(`${baseUrl}/api/jobs`, {
    method: 'POST',
    headers: { Accept: 'application/json', Cookie: cookie, 'Content-Type': 'application/json', 'X-CSRF-Token': data.csrf },
    body: JSON.stringify({ type: 'facts', connection: { host: '', port: 22 } })
  });
  assert.notEqual(withCsrf.status, 403, 'valid CSRF must pass the CSRF gate');
});

test('no first-party asset is served with inline-executable content', async () => {
  const html = await (await fetch(`${baseUrl}/`)).text();
  assert.doesNotMatch(html, /javascript:/i, 'no javascript: URLs in the document');
  assert.doesNotMatch(html, /<iframe/i, 'no iframes (frame-ancestors none)');
});
