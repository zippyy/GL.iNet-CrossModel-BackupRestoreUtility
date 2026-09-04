// In-process fake OpenWrt router for transport tests.
//
// A real ssh2 Server that:
//   - accepts password or public-key (ed25519) authentication;
//   - executes every incoming command through /bin/sh on the host, so the
//     streamed canonical runtime genuinely runs;
//   - provides a minimal SFTP handler (OPEN/READ/WRITE/FSTAT/STAT/CLOSE)
//     sufficient for ssh2 fastPut/fastGet round trips.
//
// This is a transport fixture: it proves the Docker controller's SSH trust,
// streaming, and transfer code paths against a real SSH handshake.

import ssh2 from 'ssh2';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

const { Server } = ssh2;

export function generateKeys(dir, label) {
  // Generate an ed25519 keypair with ssh-keygen (deterministic, OpenSSH format
  // that both ssh2 (client + server) and our comparison code understand).
  fs.mkdirSync(dir, { recursive: true });
  const privateFile = path.join(dir, `${label}_ed25519`);
  const publicFile = `${privateFile}.pub`;
  fs.rmSync(privateFile, { force: true });
  fs.rmSync(publicFile, { force: true });
  const result = spawnSync('ssh-keygen', ['-t', 'ed25519', '-N', '', '-f', privateFile, '-q'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`ssh-keygen failed: ${result.stderr}`);
  return {
    privateFile,
    publicFile,
    privatePem: fs.readFileSync(privateFile, 'utf8'),
    publicKeyRaw: parseSshPublicKey(fs.readFileSync(publicFile, 'utf8'))
  };
}

export function parseSshPublicKey(publicLine) {
  // "ssh-ed25519 AAAAC3... comment" -> raw 32-byte key data
  const parts = String(publicLine).trim().split(/\s+/);
  if (parts.length < 2) throw new Error('Malformed public key line.');
  return Buffer.from(parts[1], 'base64').subarray(-32); // last 32 bytes = raw ed25519 key
}

export async function startFakeRouter({
  password = 'router-secret-pw',
  hostKey, // from generateKeys()
  clientKeyRaw = null, // raw 32-byte ed25519 public key (accept publickey auth)
  execHook = null, // async (command, inputStream) => { stdout, stderr, code }
  sftpRoot = os.tmpdir(),
  port = 0 // fixed port for same-address host-key-change tests
}) {
  if (!hostKey) throw new Error('hostKey is required (generateKeys()).');

  const connections = new Set();
  const server = new Server({ hostKeys: [hostKey.privatePem] }, (client) => {
    connections.add(client);
    client.on('close', () => connections.delete(client));
    client.on('error', () => { /* per-connection errors are expected (e.g. a
                                  client rejecting our host key mid-KEX) */ });

    client.on('authentication', (ctx) => {
      if (ctx.username !== 'root') return ctx.reject();
      switch (ctx.method) {
        case 'password':
          if (ctx.password === password) return ctx.accept();
          return ctx.reject();
        case 'publickey': {
          if (!clientKeyRaw) return ctx.reject();
          const offered = Buffer.isBuffer(ctx.key?.data) ? ctx.key.data : Buffer.from(ctx.key?.data || []);
          // ssh2 key.data for ed25519 is the wire blob; last 32 bytes are raw.
          const raw = offered.subarray(-32);
          const match = raw.length === clientKeyRaw.length && Buffer.compare(raw, clientKeyRaw) === 0;
          if (!match) return ctx.reject();
          // First (unsigned) query: accept so ssh2 requests the signature.
          if (!ctx.signature) return ctx.accept();
          return ctx.accept();
        }
        default:
          return ctx.reject();
      }
    });

    client.on('ready', () => {
      client.on('session', (accept) => {
        const session = accept();

        session.on('exec', (acceptExec, rejectExec, info) => {
          const stream = acceptExec();
          const command = String(info.command || '');

          const finish = (stdout, stderr, code) => {
            try {
              if (stdout) stream.stdout.write(stdout);
              if (stderr) stream.stderr.write(stderr);
            } catch { /* stream closed */ }
            stream.exit(code);
            stream.end();
          };

          (async () => {
            try {
              if (execHook) {
                // execHook receives the command and a stdin source (the
                // client's stream) so streamed-runtime commands can be fed
                // into /bin/sh -s like a real router would.
                const out = await execHook(command, stream);
                finish(out.stdout || '', out.stderr || '', out.code ?? 0);
              } else {
                const result = await runShell(command, stream);
                finish(result.stdout, result.stderr, result.code);
              }
            } catch (error) {
              finish('', `fixture exec error: ${String(error?.message || error).slice(0, 300)}`, 1);
            }
          })();
        });

        session.on('sftp', (acceptSftp) => {
          const sftp = acceptSftp();
          attachSftpHandler(sftp, sftpRoot);
        });
      });
    });
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });

  const boundPort = server.address().port;
  return {
    host: '127.0.0.1',
    port: boundPort,
    async close() {
      for (const client of connections) { try { client.end(); } catch { /* closed */ } }
      connections.clear();
      await new Promise((resolve) => {
        server.close(resolve);
        server.closeAllConnections?.();
      });
    }
  };
}

function runShell(command, inputStream) {
  return new Promise((resolve) => {
    const child = spawn('/bin/sh', ['-c', command], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => { stdout += c.toString('utf8'); });
    child.stderr.on('data', (c) => { stderr += c.toString('utf8'); });
    // The streamed runtime (core.sh + CLI) arrives on the client's stdin and
    // must be fed into `sh -s --` exactly like a real router shell would.
    if (inputStream) {
      inputStream.pipe(child.stdin);
      inputStream.on('error', () => { try { child.stdin.end(); } catch { /* closed */ } });
    } else {
      child.stdin.end();
    }
    child.on('close', (code) => resolve({ stdout, stderr, code: code ?? 0 }));
  });
}

// Exported so test execHooks can delegate to the same host shell runner after
// injecting sandbox environment (the pipeline test drives the canonical
// runtime over SSH with GCM_* sandbox roots, mirroring the native harness).
export { runShell };

// ssh2 sftp OPEN_MODE flags (ssh2-streams).
const OPEN_MODE = { READ: 0x00000001, WRITE: 0x00000002, CREAT: 0x00000008, TRUNC: 0x00000010 };

function attachSftpHandler(sftp, root) {
  const handles = new Map();
  let nextHandle = 1;
  const resolvePath = (filename) => {
    // The client sends router-absolute paths (/tmp/...). The fixture serves a
    // chroot-like view: map them under the sftp root. A root of "/" makes the
    // fixture a genuine host-backed router: SFTP and exec commands then see
    // the same real files (used by pipeline tests whose canonical runtime
    // streams archives over SFTP and verifies them with sha256sum over exec).
    const relative = String(filename).replace(/^\/+/, '');
    const full = path.join(root, relative);
    const base = path.resolve(root);
    if (full !== base && !full.startsWith(base.endsWith(path.sep) ? base : base + path.sep)) throw new Error('path escape');
    return full;
  };

  sftp.on('OPEN', (reqid, filename, flags) => {
    const write = (flags & OPEN_MODE.WRITE) !== 0;
    const read = (flags & OPEN_MODE.READ) !== 0 && !write;
    const creat = (flags & OPEN_MODE.CREAT) !== 0;
    const trunc = (flags & OPEN_MODE.TRUNC) !== 0;
    try {
      const full = resolvePath(filename);
      let openFlags = read ? 'r' : 'w';
      if (write && creat && trunc) openFlags = 'w';
      else if (write && creat) openFlags = 'a';
      else if (write) openFlags = 'w';
      if (!write && !fs.existsSync(full)) {
        return sftp.status(reqid, 2 /* NO_SUCH_FILE */);
      }
      if (write) fs.mkdirSync(path.dirname(full), { recursive: true });
      const fd = fs.openSync(full, openFlags);
      const handle = nextHandle++;
      handles.set(handle, { fd, read });
      sftp.handle(reqid, Buffer.from(String(handle)));
    } catch (error) {
      sftp.status(reqid, 4 /* FAILURE */, String(error?.message || error).slice(0, 300));
    }
  });

  sftp.on('READ', (reqid, handle, offset, length) => {
    const entry = handles.get(Number(handle.toString('utf8')));
    if (!entry) return sftp.status(reqid, 4, 'bad handle');
    const buf = Buffer.alloc(length);
    fs.read(entry.fd, buf, 0, length, offset, (error, bytesRead) => {
      if (error) return sftp.status(reqid, 4, String(error.message));
      sftp.data(reqid, buf.subarray(0, bytesRead));
    });
  });

  sftp.on('WRITE', (reqid, handle, offset, data) => {
    const entry = handles.get(Number(handle.toString('utf8')));
    if (!entry) return sftp.status(reqid, 4, 'bad handle');
    fs.write(entry.fd, data, 0, data.length, offset, (error) => {
      if (error) return sftp.status(reqid, 4, String(error.message));
      sftp.status(reqid, 0 /* OK */);
    });
  });

  sftp.on('FSTAT', (reqid, handle) => {
    const entry = handles.get(Number(handle.toString('utf8')));
    if (!entry) return sftp.status(reqid, 4, 'bad handle');
    const stat = fs.fstatSync(entry.fd);
    sftp.attrs(reqid, {
      size: stat.size,
      mode: stat.mode,
      uid: stat.uid,
      gid: stat.gid,
      atime: Math.floor(stat.atimeMs / 1000),
      mtime: Math.floor(stat.mtimeMs / 1000)
    });
  });

  sftp.on('STAT', (reqid, filename) => {
    try {
      const stat = fs.statSync(resolvePath(filename));
      sftp.attrs(reqid, { size: stat.size, mode: stat.mode, atime: Math.floor(stat.atimeMs / 1000), mtime: Math.floor(stat.mtimeMs / 1000) });
    } catch {
      sftp.status(reqid, 2, 'no such file');
    }
  });

  sftp.on('CLOSE', (reqid, handle) => {
    const key = Number(handle.toString('utf8'));
    const entry = handles.get(key);
    if (entry) {
      try { fs.closeSync(entry.fd); } catch { /* ignore */ }
      handles.delete(key);
    }
    sftp.status(reqid, 0);
  });
}
