#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD_DIR="$ROOT_DIR/openwrt/luci-app-glinet-crossmodel-backup/root"
MAKEFILE="$ROOT_DIR/openwrt/luci-app-glinet-crossmodel-backup/Makefile"
OUTPUT_DIR="$ROOT_DIR/dist"

export PAYLOAD_DIR MAKEFILE OUTPUT_DIR

python3 - <<'PY'
from __future__ import annotations

import gzip
import io
import os
import re
import stat
import tarfile
from pathlib import Path

payload = Path(os.environ['PAYLOAD_DIR'])
makefile = Path(os.environ['MAKEFILE'])
outdir = Path(os.environ['OUTPUT_DIR'])

if not payload.is_dir():
    raise SystemExit(f'Missing payload directory: {payload}')

text = makefile.read_text(encoding='utf-8')
def value(name: str) -> str:
    match = re.search(rf'^{re.escape(name)}:=(.+)$', text, re.MULTILINE)
    if not match:
        raise SystemExit(f'Missing {name} in {makefile}')
    return match.group(1).strip()

name = value('PKG_NAME')
version = value('PKG_VERSION')
release = value('PKG_RELEASE')
outdir.mkdir(parents=True, exist_ok=True)
ipk = outdir / f'{name}_{version}-{release}_all.ipk'

control = f'''Package: {name}
Version: {version}-{release}
Architecture: all
Installed-Size: 0
Section: utils
Priority: optional
Maintainer: zippyy
Description: GL.iNet Cross-Model Backup and Restore
 Native LuCI utility for portable GL.iNet and OpenWrt configuration profiles.
'''.encode('utf-8')
postinst = b'''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
mkdir -p /root/glinet-crossmodel/profiles /tmp/glinet-crossmodel /root/.ssh
chmod 700 /root/.ssh
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
[ -x /etc/init.d/nginx ] && /etc/init.d/nginx restart >/dev/null 2>&1 || true
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
exit 0
'''

def tar_gz(entries: list[tuple[str, bytes, int]]) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz', format=tarfile.GNU_FORMAT) as archive:
        for name, content, mode in entries:
            info = tarfile.TarInfo(name=name)
            info.size = len(content)
            info.mode = mode
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            info.mtime = 0
            archive.addfile(info, io.BytesIO(content))
    return output.getvalue()

# Critical for GL.iNet's legacy opkg: tar members must be named `control` and
# `usr/...`, not `./control` / `./usr/...`.
control_tar = tar_gz([
    ('control', control, 0o644),
    ('postinst', postinst, 0o755),
])

data_entries: list[tuple[str, bytes, int]] = []
for path in sorted(payload.rglob('*')):
    if not path.is_file():
        continue
    rel = path.relative_to(payload).as_posix()
    mode = stat.S_IMODE(path.stat().st_mode)
    data_entries.append((rel, path.read_bytes(), mode))
if not data_entries:
    raise SystemExit('Package payload is empty')
data_tar = tar_gz(data_entries)

# Write a classic ar archive manually. GNU ar appends `/` to member names;
# GL.iNet's older opkg package reader rejects that variant. These headers use
# plain fixed-width names exactly: debian-binary, control.tar.gz, data.tar.gz.
def ar_member(member_name: str, content: bytes) -> bytes:
    if len(member_name.encode('ascii')) > 16:
        raise ValueError(member_name)
    header = (
        member_name.encode('ascii').ljust(16, b' ') +
        b'0'.ljust(12, b' ') +
        b'0'.ljust(6, b' ') +
        b'0'.ljust(6, b' ') +
        b'100644'.ljust(8, b' ') +
        str(len(content)).encode('ascii').ljust(10, b' ') +
        b'`\n'
    )
    if len(header) != 60:
        raise ValueError('bad ar header')
    return header + content + (b'\n' if len(content) % 2 else b'')

archive = b'!<arch>\n' + b''.join([
    ar_member('debian-binary', b'2.0\n'),
    ar_member('control.tar.gz', control_tar),
    ar_member('data.tar.gz', data_tar),
])
ipk.write_bytes(archive)

# Verify the exact layout that legacy opkg expects before publishing.
assert archive.startswith(b'!<arch>\n')
offset = 8
members: list[tuple[str, bytes]] = []
while offset + 60 <= len(archive):
    header = archive[offset:offset + 60]
    member_name = header[:16].decode('ascii').rstrip(' ')
    member_size = int(header[48:58].decode('ascii').strip())
    offset += 60
    member = archive[offset:offset + member_size]
    members.append((member_name, member))
    offset += member_size + (member_size % 2)
assert [entry[0] for entry in members] == ['debian-binary', 'control.tar.gz', 'data.tar.gz']
assert members[0][1] == b'2.0\n'
with tarfile.open(fileobj=io.BytesIO(members[1][1]), mode='r:gz') as archive_file:
    assert archive_file.getnames() == ['control', 'postinst']
with tarfile.open(fileobj=io.BytesIO(members[2][1]), mode='r:gz') as archive_file:
    names = archive_file.getnames()
    assert 'usr/libexec/glinet-crossmodel-backup' in names
    assert 'usr/libexec/glinet-crossmodel-remote' in names
    assert all(not item.startswith('./') for item in names)

print(f'Built {ipk}')
PY
