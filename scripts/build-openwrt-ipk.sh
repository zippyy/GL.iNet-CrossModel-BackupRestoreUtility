#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pkg="$root/openwrt/luci-app-glinet-crossmodel-backup"
payload="$pkg/root"
makefile="$pkg/Makefile"
out="$root/dist"
name="luci-app-glinet-crossmodel-backup"
version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile" | head -n1)"
release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile" | head -n1)"

[ -n "$version" ]
[ -n "$release" ]
[ -d "$payload" ]

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/control" "$work/data" "$out"
cp -a "$payload/." "$work/data/"
chmod 0755 "$work/data/usr/libexec/glinet-crossmodel-backup"
chmod 0755 "$work/data/usr/libexec/glinet-crossmodel-remote"

python3 - "$work/data/usr/lib/lua/luci/controller/glinet_crossmodel.lua" "$work/data/usr/libexec/glinet-crossmodel-remote" <<'PY'
from pathlib import Path
import sys

controller = Path(sys.argv[1])
remote = Path(sys.argv[2])

text = controller.read_text(encoding="utf-8")
parent = 'function index()\n\tlocal services = entry({"admin", "services"}, firstchild(), _("Services"), 60)\n\tservices.dependent = false\n'
if parent not in text:
    text = text.replace('function index()\n', parent, 1)
for old, new in {
    'fs.chmod(PROFILE_DIR, 448)': 'fs.chmod(PROFILE_DIR, "0700")',
    'fs.chmod(TMP_DIR, 448)': 'fs.chmod(TMP_DIR, "0700")',
    'fs.chmod(path, 384)': 'fs.chmod(path, "0600")',
    'fs.chmod(output, 384)': 'fs.chmod(output, "0600")',
    'fs.chmod(temporary, 384)': 'fs.chmod(temporary, "0600")',
}.items():
    text = text.replace(old, new)
controller.write_text(text, encoding="utf-8")

text = remote.read_text(encoding="utf-8")
text = text.replace(
    "\tcommand -v ssh >/dev/null 2>&1 || die 'OpenSSH client is not installed.'\n"
    "\tcommand -v sshpass >/dev/null 2>&1 || die 'sshpass is not installed.'\n"
    "\tcommand -v base64 >/dev/null 2>&1 || die 'base64 is not available on the control router.'\n",
    "\tcommand -v ssh >/dev/null 2>&1 || die 'OpenSSH client is not installed.'\n"
    "\tcommand -v scp >/dev/null 2>&1 || die 'OpenSSH SCP client is not installed.'\n"
    "\tcommand -v sshpass >/dev/null 2>&1 || die 'sshpass is not installed.'\n"
)
start = text.index('copy_to_remote() {')
end = text.index('\nstream_backend() {', start)
replacement = '''copy_to_remote() {
	# local-file host port user passfile remote-path
	local local_file host port user passfile remote_path target
	local_file="$1"; host="$2"; port="$3"; user="$4"; passfile="$5"; remote_path="$6"
	[ -f "$local_file" ] || die "Local input is missing: $local_file"
	target="$(remote_target "$host" "$user")"
	sshpass -f "$passfile" scp \
		-o BatchMode=no \
		-o ConnectTimeout=12 \
		-o StrictHostKeyChecking=accept-new \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-P "$port" "$local_file" "${target}:${remote_path}"
}

copy_from_remote() {
	# host port user passfile remote-path local-file
	local host port user passfile remote_path local_file target
	host="$1"; port="$2"; user="$3"; passfile="$4"; remote_path="$5"; local_file="$6"
	target="$(remote_target "$host" "$user")"
	if ! sshpass -f "$passfile" scp \
		-o BatchMode=no \
		-o ConnectTimeout=12 \
		-o StrictHostKeyChecking=accept-new \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-P "$port" "${target}:${remote_path}" "$local_file"; then
		rm -f "$local_file"
		die 'Could not download the remote profile archive.'
	fi
	[ -s "$local_file" ] || die 'Remote router created an empty profile archive.'
}
'''
text = text[:start] + replacement + text[end:]
if 'base64' in text:
    raise SystemExit('base64 remains in remote coordinator')
remote.write_text(text, encoding="utf-8")
PY

size="$(du -sk "$work/data" | awk '{print $1}')"
cat > "$work/control/control" <<EOF
Package: $name
Version: $version-$release
Section: luci
Priority: optional
Depends: luci-base, openssh-client, sshpass, jsonfilter
Maintainer: zippyy
Architecture: all
Installed-Size: $size
Description: GL.iNet Cross-Model Backup and Restore
 Native LuCI utility for portable GL.iNet and OpenWrt configuration profiles.
EOF

cat > "$work/control/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
mkdir -p /root/glinet-crossmodel/profiles /tmp/glinet-crossmodel /root/.ssh
chmod 700 /root/.ssh
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
EOF
chmod 0755 "$work/control/postinst"
printf '2.0\n' > "$work/debian-binary"

(cd "$work/data" && tar --owner=0 --group=0 --numeric-owner -czf "$work/data.tar.gz" .)
(cd "$work/control" && tar --owner=0 --group=0 --numeric-owner -czf "$work/control.tar.gz" .)
ipk="$out/${name}_${version}-${release}_all.ipk"
rm -f "$ipk" "$ipk.sha256"
(cd "$work" && tar --owner=0 --group=0 --numeric-owner -czf "$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
sha256sum "$ipk" > "$ipk.sha256"

tar -tzf "$ipk" | grep -qx './debian-binary'
tar -tzf "$ipk" | grep -qx './data.tar.gz'
tar -tzf "$ipk" | grep -qx './control.tar.gz'
tar -xOzf "$ipk" ./debian-binary | grep -qx '2.0'
tar -xOzf "$ipk" ./control.tar.gz > "$work/control-check.tar.gz"
tar -xOzf "$work/control-check.tar.gz" ./control | grep -Fq 'Depends: luci-base, openssh-client, sshpass, jsonfilter'
tar -xOzf "$ipk" ./data.tar.gz > "$work/data-check.tar.gz"
tar -xOzf "$work/data-check.tar.gz" ./usr/libexec/glinet-crossmodel-remote | grep -Fq 'OpenSSH SCP client is not installed.'

echo "Built $ipk"
