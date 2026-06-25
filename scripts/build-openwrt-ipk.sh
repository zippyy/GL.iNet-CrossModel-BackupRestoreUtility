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
chmod 0755 \
  "$work/data/usr/libexec/glinet-crossmodel-backup" \
  "$work/data/usr/libexec/glinet-crossmodel-remote" \
  "$work/data/usr/libexec/glinet-crossmodel-validate"

python3 "$root/scripts/patch-ipk-payload.py" "$work/data"

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
# Do not restart web services: LuCI Package Manager installs through XHR.
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
EOF
chmod 0755 "$work/control/postinst"
printf '2.0\n' > "$work/debian-binary"

# GL.iNet firmware 4.0/OpenWrt 21.02 opkg uses a gzip-compressed tar wrapper.
(cd "$work/data" && tar --owner=0 --group=0 --numeric-owner -czf "$work/data.tar.gz" .)
(cd "$work/control" && tar --owner=0 --group=0 --numeric-owner -czf "$work/control.tar.gz" .)
ipk="$out/${name}_${version}-${release}_all.ipk"
rm -f "$ipk" "$ipk.sha256"
(cd "$work" && tar --owner=0 --group=0 --numeric-owner -czf "$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
sha256sum "$ipk" > "$ipk.sha256"

# Validate the exact package representation accepted by GL.iNet opkg.
tar -tzf "$ipk" > "$work/ipk-members"
grep -qx './debian-binary' "$work/ipk-members"
grep -qx './data.tar.gz' "$work/ipk-members"
grep -qx './control.tar.gz' "$work/ipk-members"
tar -xOzf "$ipk" ./debian-binary > "$work/debian-binary-check"
grep -qx '2.0' "$work/debian-binary-check"
tar -xOzf "$ipk" ./control.tar.gz > "$work/control-check.tar.gz"
tar -xOzf "$work/control-check.tar.gz" ./control > "$work/control-check"
grep -Fq 'Depends: luci-base, openssh-client, sshpass, jsonfilter' "$work/control-check"
tar -xOzf "$ipk" ./data.tar.gz > "$work/data-check.tar.gz"
tar -tzf "$work/data-check.tar.gz" > "$work/data-members"
grep -qx './usr/libexec/glinet-crossmodel-validate' "$work/data-members"
grep -qx './usr/lib/lua/luci/controller/glinet_crossmodel_validate.lua' "$work/data-members"
tar -xOzf "$work/data-check.tar.gz" ./usr/libexec/glinet-crossmodel-validate > "$work/validate-check.sh"
grep -Fq 'Read-only compatibility and safety preflight' "$work/validate-check.sh"
tar -xOzf "$work/data-check.tar.gz" ./usr/lib/lua/luci/view/glinet_crossmodel/index.htm > "$work/view-check.htm"
grep -Fq 'id="validate-profile"' "$work/view-check.htm"
grep -Fq 'id="validation-plan"' "$work/view-check.htm"

echo "Built $ipk"
