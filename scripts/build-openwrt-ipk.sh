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

# GL.iNet 4.0 can have no visible Services parent menu. Make it an alias to this app.
mkdir -p "$work/data/usr/lib/lua/luci/controller"
printf '%s' 'bW9kdWxlKCJsdWNpLmNvbnRyb2xsZXIuZ2xpbmV0X2Nyb3NzbW9kZWxfbWVudSIsIHBhY2thZ2Uuc2VlYWxsKQoKZnVuY3Rpb24gaW5kZXgoKQoJbG9jYWwgc2VydmljZXMgPSBlbnRyeSh7ImFkbWluIiwgInNlcnZpY2VzIn0sIGFsaWFzKCJhZG1pbiIsICJzZXJ2aWNlcyIsICJnbGluZXQtY3Jvc3Ntb2RlbCIpLCBfKCJTZXJ2aWNlcyIpLCA2MCkKCXNlcnZpY2VzLmRlcGVuZGVudCA9IGZhbHNlCmVuZAo=' | base64 -d > "$work/data/usr/lib/lua/luci/controller/glinet_crossmodel_menu.lua"

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
# Do not restart nginx or uhttpd here. Package Manager installs over an XHR
# request, so restarting its web server aborts the browser request.
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
EOF
chmod 0755 "$work/control/postinst"
printf '2.0\n' > "$work/debian-binary"

# GL.iNet firmware 4.0 / OpenWrt 21.02 expects a gzip-compressed tar wrapper.
(cd "$work/data" && tar --owner=0 --group=0 --numeric-owner -czf "$work/data.tar.gz" .)
(cd "$work/control" && tar --owner=0 --group=0 --numeric-owner -czf "$work/control.tar.gz" .)
ipk="$out/${name}_${version}-${release}_all.ipk"
rm -f "$ipk" "$ipk.sha256"
(cd "$work" && tar --owner=0 --group=0 --numeric-owner -czf "$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
sha256sum "$ipk" > "$ipk.sha256"

# Validate the exact GL.iNet tar-format package before publishing it.
tar -tzf "$ipk" | grep -qx './debian-binary'
tar -tzf "$ipk" | grep -qx './data.tar.gz'
tar -tzf "$ipk" | grep -qx './control.tar.gz'
tar -xOzf "$ipk" ./debian-binary | grep -qx '2.0'
tar -xOzf "$ipk" ./data.tar.gz > "$work/data-check.tar.gz"
tar -tzf "$work/data-check.tar.gz" | grep -qx './usr/lib/lua/luci/controller/glinet_crossmodel_menu.lua'

echo "Built $ipk"
