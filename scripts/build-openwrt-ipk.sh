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

controller="$work/data/usr/lib/lua/luci/controller/glinet_crossmodel.lua"
python3 - "$controller" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
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
path.write_text(text, encoding="utf-8")
PY

size="$(du -sk "$work/data" | awk '{print $1}')"
cat > "$work/control/control" <<EOF
Package: $name
Version: $version-$release
Section: luci
Priority: optional
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

echo "Built $ipk"
