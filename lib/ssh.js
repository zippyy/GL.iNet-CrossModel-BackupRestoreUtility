import { Client } from 'ssh2';

export class RouterConnectionError extends Error {
  constructor(message, cause) {
    super(message);
    this.name = 'RouterConnectionError';
    this.cause = cause;
  }
}

function normalizeCredentials(input = {}) {
  const host = String(input.host || '').trim();
  const username = String(input.username || 'root').trim() || 'root';
  const password = String(input.password || '');
  const port = Number(input.port || 22);

  if (!host || host.length > 253 || /[\s/\\]/.test(host)) {
    throw new RouterConnectionError('Enter a valid router hostname or IP address.');
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new RouterConnectionError('SSH port must be between 1 and 65535.');
  }
  if (!username || username.length > 64 || /[\s:]/.test(username)) {
    throw new RouterConnectionError('Enter a valid SSH username.');
  }
  if (!password) throw new RouterConnectionError('Enter the router SSH password.');
  return { host, username, password, port };
}

export function connectRouter(input) {
  const credentials = normalizeCredentials(input);
  return new Promise((resolve, reject) => {
    const client = new Client();
    const timeout = setTimeout(() => {
      client.end();
      reject(new RouterConnectionError(`Timed out connecting to ${credentials.host}:${credentials.port}.`));
    }, 12000);
    client.on('ready', () => { clearTimeout(timeout); resolve(client); });
    client.on('error', (error) => {
      clearTimeout(timeout);
      reject(new RouterConnectionError(`SSH connection failed: ${error.message}`, error));
    });
    client.connect({ ...credentials, readyTimeout: 10000, keepaliveInterval: 10000, keepaliveCountMax: 2 });
  });
}

export function run(client, command, { timeout = 30000, allowFailure = false } = {}) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(new RouterConnectionError(`Router command timed out after ${Math.round(timeout / 1000)} seconds.`));
      }
    }, timeout);
    client.exec(command, (error, stream) => {
      if (error) {
        clearTimeout(timer);
        return reject(new RouterConnectionError(`Could not execute a router command: ${error.message}`, error));
      }
      stream.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
      stream.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
      stream.on('close', (code, signal) => {
        clearTimeout(timer);
        if (settled) return;
        settled = true;
        const result = { stdout, stderr, code: Number(code ?? 0), signal };
        if (result.code !== 0 && !allowFailure) {
          return reject(new RouterConnectionError(`Router command failed (${result.code}): ${stderr.trim() || stdout.trim() || command}`));
        }
        resolve(result);
      });
    });
  });
}

export async function withRouter(input, task) {
  const client = await connectRouter(input);
  try { return await task(client); } finally { client.end(); }
}
