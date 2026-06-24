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

[ -n "$version" ] && [ -n "$release" ] && [ -d "$payload" ]
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/control" "$work/data" "$out"
cp -a "$payload/." "$work/data/"
chmod 0755 "$work/data/usr/libexec/glinet-crossmodel-backup"
chmod 0755 "$work/data/usr/libexec/glinet-crossmodel-remote"

# Do not register admin/services as an alias. An alias intercepts nested
# /api/* routes on LuCI 21.02, which breaks profile listing and creation.
# Add a regular firstchild parent in the main controller instead.
controller="$work/data/usr/lib/lua/luci/controller/glinet_crossmodel.lua"
python3 - "$controller" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = 'function index()\n'
new = '''function index()
\tlocal services = entry({"admin", "services"}, firstchild(), _("Services"), 60)
\tservices.dependent = false
'''
if new not in text:
    if old not in text:
        raise SystemExit("LuCI controller index() function was not found")
    text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")

# Remove menu files left by older package builds.
for name in ("glinet_crossmodel_menu.lua",):
    stale = path.parent / name
    if stale.exists():
        stale.unlink()
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
# Do not restart nginx or uhttpd here. LuCI Package Manager runs this through
# an XHR request, and a restart aborts the browser response.
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
EOF
chmod 0755 "$work/control/postinst"
printf '2.0\n' > "$work/debian-binary"

# GL.iNet firmware 4.0 / OpenWrt 21.02 opkg expects this gzip tar wrapper.
(cd "$work/data" && tar --owner=0 --group=0 --numeric-owner -czf "$work/data.tar.gz" .)
(cd "$work/control" && tar --owner=0 --group=0 --numeric-owner -czf "$work/control.tar.gz" .)
ipk="$out/${name}_${version}-${release}_all.ipk"
rm -f "$ipk" "$ipk.sha256"
(cd "$work" && tar --owner=0 --group=0 --numeric-owner -czf "$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
sha256sum "$ipk" > "$ipk.sha256"

# Validate package layout and, critically, the non-alias menu registration.
tar -tzf "$ipk" | grep -qx './debian-binary'
tar -tzf "$ipk" | grep -qx './data.tar.gz'
tar -tzf "$ipk" | grep -qx './control.tar.gz'
tar -xOzf "$ipk" ./debian-binary | grep -qx '2.0'
tar -xOzf "$ipk" ./data.tar.gz > "$work/data-check.tar.gz"
tar -tzf "$work/data-check.tar.gz" | grep -qx './usr/lib/lua/luci/controller/glinet_crossmodel.lua'
! tar -tzf "$work/data-check.tar.gz" | grep -q 'glinet_crossmodel_menu.lua'
tar -xOzf "$work/data-check.tar.gz" ./usr/lib/lua/luci/controller/glinet_crossmodel.lua | grep -Fqx $'\tlocal services = entry({"admin", "services"}, firstchild(), _("Services"), 60)'

echo "Built $ipk"
