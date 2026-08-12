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

  if (!host || host.length > 253) {
    throw new RouterConnectionError(
      'Invalid router host address',
      new Error(`Host: ${host}`)
    );
  }
}

export function connectRouter(input) {
  const credentials = normalizeCredentials(input);
  return new Promise((resolve, reject) => {
    const client = new Client();
    const timeout = setTimeout(() => {
      if (client.connected) {
        client.end();
      }
      reject(
        new RouterConnectionError(
          `Router connection timed out after 10 seconds.`,
          new Error('Timeout')
        )
      );
    }, 10000);

    client.on('ready', () => {
      clearTimeout(timeout);
      resolve(client);
    });

    client.on('error', (error) => {
      clearTimeout(timeout);
      reject(
        new RouterConnectionError(
          `SSH connection failed: ${error.message}`,
          error
        )
      );
    });

    client.connect({
      ...credentials,
      readyTimeout: 10000,
      keepaliveInterval: 10000,
      keepaliveCountMax: 2,
    });
  });
}

/**
 * Run a command on the router with proper error handling and retry logic.
 * @param {import('ssh2').Client} client - SSH client connection
 * @param {string} command - UCI command to execute
 * @param {Object} options - Additional options
 * @param {number} options.timeout - Command timeout in ms (default: 30000)
 * @param {boolean} options.allowFailure - If true, don't throw on non-zero exit (default: false)
 * @param {number} options.retryCount - Number of retries for transient failures (default: 0)
 * @returns {Promise<{stdout: string, stderr: string, code: number, signal: string | null}>}
 */
export async function run(client, command, { 
  timeout = 30000, 
  allowFailure = false, 
  retryCount = 0 
} = {}) {
  let lastError;

  for (let attempt = 0; attempt <= retryCount; attempt++) {
    try {
      return await _runAttempt(client, command, timeout, allowFailure);
    } catch (error) {
      lastError = error;

      // Don't retry on authentication or connection errors
      if (error.cause && error.cause.message.includes('auth')) {
        throw error;
      }

      // Don't retry if this was the last attempt
      if (attempt >= retryCount) break;

      // Wait before retry (2 seconds)
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
  }

  // All retries exhausted, throw the last error
  if (!allowFailure) {
    throw lastError;
  }

  // If allowFailure, return a failed result
  return { stdout: '', stderr: lastError.message || 'Unknown error', code: 1, signal: null };
}

async function _runAttempt(client, command, timeout, allowFailure) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(
          new RouterConnectionError(
            `Router command timed out after ${Math.round(timeout / 1000)} seconds.`,
            new Error('Timeout')
          )
        );
      }
    }, timeout);

    client.exec(command, (error, stream) => {
      if (error) {
        clearTimeout(timer);
        return reject(
          new RouterConnectionError(
            `Could not execute a router command: ${error.message}`,
            error
          )
        );
      }

      stream.on('data', (chunk) => {
        stdout += chunk.toString('utf8');
      });

      stream.stderr.on('data', (chunk) => {
        stderr += chunk.toString('utf8');
      });

      stream.on('close', (code, signal) => {
        clearTimeout(timer);

        if (settled) return;
        settled = true;

        const result = {
          stdout,
          stderr,
          code: Number(code ?? 0),
          signal,
        };

        if (result.code !== 0 && !allowFailure) {
          return reject(
            new RouterConnectionError(
              `Router command failed (${result.code}): ${stderr.trim() || stdout.trim() || command}`,
              new Error(`Code ${result.code}`)
            )
          );
        }

        resolve(result);
      });
    });
  });
}