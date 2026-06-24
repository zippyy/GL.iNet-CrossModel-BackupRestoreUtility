#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
payload="$root/openwrt/luci-app-glinet-crossmodel-backup/root"
makefile="$root/openwrt/luci-app-glinet-crossmodel-backup/Makefile"
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
size="$(du -sk "$work/data" | awk '{print $1}')"
cat > "$work/control/control" <<EOF
Package: $name
Version: $version-$release
Architecture: all
Installed-Size: $size
Section: utils
Priority: optional
Maintainer: zippyy
Description: GL.iNet Cross-Model Backup and Restore
 Native LuCI utility for portable GL.iNet and OpenWrt configuration profiles.
EOF
printf '2.0\n' > "$work/debian-binary"
(cd "$work/control" && tar --owner=0 --group=0 --numeric-owner -czf "$work/control.tar.gz" .)
(cd "$work/data" && tar --owner=0 --group=0 --numeric-owner -czf "$work/data.tar.gz" .)
ipk="$out/${name}_${version}-${release}_all.ipk"
rm -f "$ipk"
(cd "$work" && ar r "$ipk" debian-binary control.tar.gz data.tar.gz)
echo "Built $ipk"
