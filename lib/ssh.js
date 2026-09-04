import { Client } from 'ssh2';
import crypto from 'node:crypto';
import { HttpError } from './util.js';

// Hardened SSH transport for the Docker controller.
//
// Host-key policy (accept-new -> persist -> hard fail):
//   - first connection: allowed only when acceptNewHostKey is explicitly set
//     (Test Connection / Add Router UI action) and the fingerprint is persisted;
//   - later connections: the server host key MUST match the persisted
//     fingerprint; a changed key is a HARD FAILURE and is never replaced
//     silently;
//   - re-trusting a changed key is a separate authenticated operation.
//
// Credentials are request/job scoped. Passwords are never persisted, never
// logged, and never placed on any command line (ssh2 passes them in the SSH
// protocol, not through a shell).

export class RouterConnectionError extends Error {
  constructor(message, { status = 422, code, cause } = {}) {
    super(message);
    this.name = 'RouterConnectionError';
    this.status = status;
    this.code = code || 'router-connection-error';
    this.cause = cause;
  }
}

const hostKeyFingerprint = (keyBytes) =>
  crypto.createHash('sha256').update(keyBytes).digest('hex');

function normalizePort(value) {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new RouterConnectionError('SSH port must be between 1 and 65535.', { status: 400 });
  }
  return port;
}

function normalizeHost(value) {
  const host = String(value || '').trim();
  if (!host || host.length > 253 || /[\s/\\]/.test(host)) {
    throw new RouterConnectionError('Enter a valid router hostname or IP address.', { status: 400 });
  }
  if (host.startsWith('[')) {
    if (!/^\[[0-9a-fA-F:.]+\]$/.test(host)) throw new RouterConnectionError('Invalid IPv6 literal.', { status: 400 });
    return host.slice(1, -1);
  }
  if (host.includes(':')) {
    if (!/^[0-9a-fA-F:.]+$/.test(host)) throw new RouterConnectionError('Invalid IPv6 address.', { status: 400 });
  } else if (!/^[A-Za-z0-9._-]+$/.test(host)) {
    throw new RouterConnectionError('Enter a valid router hostname or IP address.', { status: 400 });
  }
  return host;
}

function normalizeUsername(value) {
  const user = String(value || 'root').trim() || 'root';
  if (user.length > 64 || /[\s:]/.test(user)) {
    throw new RouterConnectionError('Enter a valid SSH username.', { status: 400 });
  }
  return user;
}

// key = "host:port" for IPv4/hostnames; "host:port" is also unambiguous for
// IPv6 because ssh2 receives host/port as structured fields (no shell).
export const hostKeyId = (host, port) => `${normalizeHost(host)}:${normalizePort(port)}`;

export function normalizeConnection(input = {}, { hostKeyProvider } = {}) {
  const host = normalizeHost(input.host);
  const port = normalizePort(input.port ?? 22);
  const username = normalizeUsername(input.username);
  const auth = input.authType || (input.password ? 'password' : input.privateKey ? 'key' : input.agent ? 'agent' : '');
  const connection = {
    host, port, username, auth,
    // hostKeyProvider may arrive via the options argument or inside the input
    // object (test/API convenience); never default to trusting everything.
    hostKeyProvider: hostKeyProvider || input.hostKeyProvider || (() => Promise.resolve(null))
  };

  switch (auth) {
    case 'password': {
      const password = String(input.password ?? '');
      if (!password) throw new RouterConnectionError('Enter the router SSH password.', { status: 400 });
      connection.password = password;
      break;
    }
    case 'key': {
      const privateKey = input.privateKey;
      if (!privateKey) throw new RouterConnectionError('A private key is required for key authentication.', { status: 400 });
      connection.privateKey = privateKey;
      break;
    }
    case 'agent': {
      const agent = input.agent || process.env.GCM_SSH_AUTH_SOCK;
      if (!agent) {
        throw new RouterConnectionError(
          'Agent authentication is unavailable: no SSH agent socket is configured (GCM_SSH_AUTH_SOCK).',
          { status: 400, code: 'agent-unavailable' }
        );
      }
      connection.agent = agent;
      break;
    }
    default:
      throw new RouterConnectionError('Choose an authentication method.', { status: 400 });
  }

  connection.acceptNewHostKey = input.acceptNewHostKey === true;
  return connection;
}

export async function connectRouter(input, { logger, trustHostKey } = {}) {
  const connection = normalizeConnection(input);
  // trustHostKey may arrive via the options argument (withRouter style) or
  // inside the input object; either way it must be wired before the handshake
  // so an accepted new host key can be persisted.
  connection.trustHostKey = connection.trustHostKey || trustHostKey || null;
  const expectedFingerprint = await connection.hostKeyProvider(hostKeyId(connection.host, connection.port));
  const acceptNew = connection.acceptNewHostKey;

  if (!expectedFingerprint && !acceptNew) {
    throw new RouterConnectionError(
      'Unknown router host key. Test the connection first to accept and store its fingerprint.',
      { status: 409, code: 'unknown-host-key' }
    );
  }

  return new Promise((resolve, reject) => {
    const client = new Client();
    let settled = false;
    let verified = false;
    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        client.end();
        reject(new RouterConnectionError(`Timed out connecting to ${connection.host}:${connection.port}.`, { code: 'connect-timeout' }));
      }
    }, 15000);

    const fail = (message, code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      reject(new RouterConnectionError(message, { code }));
    };

    client.on('ready', () => {
      if (settled) return;
      clearTimeout(timeout);
      if (expectedFingerprint && !verified) {
        // The hostVerifier normally runs during handshake; if it did not fire,
        // do not proceed without a verified key.
        settled = true;
        client.end();
        return reject(new RouterConnectionError('Router host key was not verified.', { code: 'host-key-unverified' }));
      }
      settled = true;
      resolve(client);
    });

    client.on('error', (error) => {
      if (settled) return;
      const text = String(error?.message || error || '').toLowerCase();
      // ssh2 reports hostVerifier=false as "Host denied (verification failed)".
      if (text.includes('host denied') || text.includes('hostkey') || text.includes('host key')) {
        return fail('Router host key verification failed. The key changed or is untrusted.', 'host-key-mismatch');
      }
      if (text.includes('authentication') || text.includes('permission denied')) {
        return fail('SSH authentication failed. Check the username and credentials.', 'authentication-failure');
      }
      if (text.includes('timed out') || text.includes('timeout')) {
        return fail(`Timed out connecting to ${connection.host}:${connection.port}.`, 'connect-timeout');
      }
      if (text.includes('refused')) return fail('SSH connection refused by the router.', 'connection-refused');
      if (text.includes('no route') || text.includes('unreachable')) return fail('Router is unreachable.', 'host-unreachable');
      if (text.includes('resolve')) return fail('Could not resolve the router hostname.', 'dns-failure');
      fail(`SSH connection failed: ${String(error?.message || error).slice(0, 300)}`, 'connection-failed');
    });

    const connectOptions = {
      host: connection.host,
      port: connection.port,
      username: connection.username,
      readyTimeout: 12000,
      keepaliveInterval: 10000,
      keepaliveCountMax: 2,
      algorithms: { serverHostKey: ['ssh-ed25519', 'ecdsa-sha2-nistp256', 'rsa-sha2-512', 'rsa-sha2-256'] }
    };
    if (connection.password) connectOptions.password = connection.password;
    if (connection.privateKey) { connectOptions.privateKey = connection.privateKey; connectOptions.identitiesOnly = true; }
    if (connection.agent) connectOptions.agent = connection.agent;

    if (expectedFingerprint || acceptNew) {
      connectOptions.hostVerifier = (keyBytes) => {
        const fingerprint = hostKeyFingerprint(keyBytes);
        if (expectedFingerprint) {
          const ok = fingerprint === expectedFingerprint;
          if (!ok) {
            logger?.error('ssh', 'transport', 'connect', {
              host: connection.host, port: connection.port,
              host_key: 'mismatch', expected: expectedFingerprint.slice(0, 12), actual: fingerprint.slice(0, 12),
              msg: 'Host key mismatch; connection refused'
            });
          }
          verified = ok;
          return ok;
        }
        if (acceptNew) {
          verified = true;
          // Store via the provider after connect completes so the persist
          // operation is explicit and atomic with acceptance.
          connection.pendingTrust = { hostKeyId: hostKeyId(connection.host, connection.port), fingerprint, host: connection.host, port: connection.port };
          return true;
        }
        verified = false;
        return false;
      };
    }

    try {
      client.connect(connectOptions);
    } catch (error) {
      fail(`SSH connection failed: ${String(error?.message || error).slice(0, 300)}`, 'connection-failed');
    }
  }).then(async (client) => {
    if (connection.pendingTrust && connection.trustHostKey) {
      await connection.trustHostKey(connection.pendingTrust.hostKeyId, connection.pendingTrust);
    }
    return { client, connection };
  });
}

export class CommandResult {
  constructor({ stdout, stderr, code, signal }) {
    this.stdout = stdout || '';
    this.stderr = stderr || '';
    this.code = code;
    this.signal = signal;
  }
}

export function execCommand(client, command, {
  stdin = null,
  timeout = 30000,
  allowFailure = false,
  maxStdout = 64 * 1024 * 1024,
  maxStderr = 8 * 1024 * 1024,
  logger,
  op,
  component = 'ssh',
  scope = 'router'
} = {}) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    let settled = false;
    let stdoutCapped = false;
    let stderrCapped = false;

    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) return reject(error);
      if (result.code !== 0 && !allowFailure) {
        return reject(new RouterConnectionError(
          `Router command failed (${result.code}): ${(result.stderr || result.stdout || command).trim().slice(0, 500)}`,
          { code: 'remote-command-failed' }
        ));
      }
      resolve(result);
    };

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        try { client.end(); } catch { /* already closed */ }
        reject(new RouterConnectionError(`Router command timed out after ${Math.round(timeout / 1000)} seconds.`, { code: 'command-timeout' }));
      }
    }, timeout);

    client.exec(command, (error, stream) => {
      if (error) return finish(new RouterConnectionError(`Could not execute a router command: ${String(error.message || error).slice(0, 300)}`, { code: 'exec-failed' }));
      stream.on('data', (chunk) => {
        if (stdout.length < maxStdout) {
          stdout += chunk.toString('utf8');
          if (stdout.length > maxStdout) { stdout = stdout.slice(0, maxStdout); stdoutCapped = true; }
        } else stdoutCapped = true;
      });
      stream.stderr.on('data', (chunk) => {
        if (stderr.length < maxStderr) {
          stderr += chunk.toString('utf8');
          if (stderr.length > maxStderr) { stderr = stderr.slice(0, maxStderr); stderrCapped = true; }
        } else stderrCapped = true;
      });
      stream.on('close', (code, signal) => {
        const result = new CommandResult({ stdout, stderr, code: code ?? 0, signal });
        if (stdoutCapped) logger?.warn(op, component, scope, { msg: 'remote stdout capped', bytes: maxStdout });
        finish(null, result);
      });
    });
  });
}

// Streaming variant: execute a command whose stdin is a source stream
// (used to stream the concatenated native runtime to the router, mirroring
// the native controller's `cat core.sh cli | ssh sh -s -- args`).
export function execWithStdin(client, command, stdinSource, {
  timeout = 120000,
  maxStdout = 64 * 1024 * 1024,
  maxStderr = 8 * 1024 * 1024,
  logger,
  op = 'exec',
  component = 'ssh',
  scope = 'router',
  onStdout = null
} = {}) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        try { client.end(); } catch { /* noop */ }
        reject(new RouterConnectionError(`Router command timed out after ${Math.round(timeout / 1000)} seconds.`, { code: 'command-timeout' }));
      }
    }, timeout);

    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) return reject(error);
      resolve(result);
    };

    client.exec(command, (error, stream) => {
      if (error) return finish(new RouterConnectionError(`Could not execute a router command: ${String(error.message || error).slice(0, 300)}`, { code: 'exec-failed' }));
      stream.on('data', (chunk) => {
        const text = chunk.toString('utf8');
        if (stdout.length < maxStdout) { stdout += text; if (stdout.length > maxStdout) stdout = stdout.slice(0, maxStdout); }
        onStdout?.(text);
      });
      stream.stderr.on('data', (chunk) => {
        if (stderr.length < maxStderr) { stderr += chunk.toString('utf8'); if (stderr.length > maxStderr) stderr = stderr.slice(0, maxStderr); }
      });
      stream.on('close', (code, signal) => {
        finish(null, new CommandResult({ stdout, stderr, code: code ?? 0, signal }));
      });
      if (stdinSource) {
        // stdinSource may be a Buffer or an async iterable/stream of buffers.
        if (Buffer.isBuffer(stdinSource) || typeof stdinSource === 'string') {
          stream.stdin.end(stdinSource);
        } else if (typeof stdinSource[Symbol.asyncIterator] === 'function') {
          (async () => {
            try {
              for await (const chunk of stdinSource) stream.stdin.write(chunk);
              stream.stdin.end();
            } catch (error) {
              stream.stdin.destroy();
              finish(new RouterConnectionError(`Failed writing to router stdin: ${String(error?.message || error).slice(0, 300)}`, { code: 'stdin-failed' }));
            }
          })();
        } else if (typeof stdinSource.pipe === 'function') {
          stdinSource.pipe(stream.stdin);
        }
      }
    });
  });
}

export async function sftpPut(client, localPath, remotePath, { logger, op = 'upload' } = {}) {
  return new Promise((resolve, reject) => {
    client.sftp((error, sftp) => {
      if (error) return reject(new RouterConnectionError(`SFTP failed: ${String(error.message || error).slice(0, 300)}`, { code: 'sftp-failed' }));
      sftp.fastPut(localPath, remotePath, (putError) => {
        if (putError) return reject(new RouterConnectionError(`Upload failed: ${String(putError.message || putError).slice(0, 300)}`, { code: 'upload-failed' }));
        resolve();
      });
    });
  });
}

export async function sftpGet(client, remotePath, localPath, { logger, op = 'download' } = {}) {
  return new Promise((resolve, reject) => {
    client.sftp((error, sftp) => {
      if (error) return reject(new RouterConnectionError(`SFTP failed: ${String(error.message || error).slice(0, 300)}`, { code: 'sftp-failed' }));
      sftp.fastGet(remotePath, localPath, (getError) => {
        if (getError) return reject(new RouterConnectionError(`Download failed: ${String(getError.message || getError).slice(0, 300)}`, { code: 'download-failed' }));
        resolve();
      });
    });
  });
}

export async function withRouter(connectionInput, task, { hostKeyProvider, trustHostKey, logger } = {}) {
  const connection = normalizeConnection(connectionInput, { hostKeyProvider });
  connection.trustHostKey = trustHostKey;
  const { client, connection: resolved } = await connectRouter(connection, { logger });
  try {
    return await task({ client, connection: resolved });
  } finally {
    try { client.end(); } catch { /* noop */ }
  }
}
