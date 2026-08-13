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
  "$work/data/usr/bin/glinet-crossmodel" \
  "$work/data/usr/libexec/glinet-crossmodel-backup" \
  "$work/data/usr/libexec/glinet-crossmodel-remote" \
  "$work/data/usr/libexec/glinet-crossmodel-validate" \
  "$work/data/usr/libexec/gcm-glui-integrate" \
  "$work/data/etc/init.d/gcm-glui-integration"
chmod 0644 "$work/data/usr/lib/glinet-crossmodel/core.sh"

# Runtime content is packaged exactly as checked in. Permissions may be
# normalized, but application source must never be rewritten during a build.
diff -qr "$payload" "$work/data" >/dev/null
sh "$root/tests/run.sh"

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
Description: GL.iNet Cross-Model Backup, Migration and Recovery
 Native local and agentless-controller utility for GL.iNet and OpenWrt routers.
EOF

cat > "$work/control/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
mkdir -p /root/glinet-crossmodel/profiles /root/glinet-crossmodel/rollback /tmp/glinet-crossmodel /root/.ssh
chmod 700 /root/glinet-crossmodel /root/glinet-crossmodel/profiles /root/glinet-crossmodel/rollback /tmp/glinet-crossmodel /root/.ssh
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
/etc/init.d/gcm-glui-integration enable >/dev/null 2>&1 || true
/etc/init.d/gcm-glui-integration start >/dev/null 2>&1 || true
# Do not restart web services: LuCI Package Manager installs through XHR.
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
EOF
chmod 0755 "$work/control/postinst"
cat > "$work/control/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/gcm-glui-integration stop >/dev/null 2>&1 || true
/etc/init.d/gcm-glui-integration disable >/dev/null 2>&1 || true
/usr/libexec/gcm-glui-integrate --remove >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$work/control/prerm"
printf '/etc/config/glinet_crossmodel\n' > "$work/control/conffiles"
printf '2.0\n' > "$work/debian-binary"

# GL.iNet firmware 4.0/OpenWrt 21.02 opkg uses a gzip-compressed tar wrapper.
(cd "$work/data" && tar --owner=0 --group=0 --numeric-owner -czf "$work/data.tar.gz" .)
(cd "$work/control" && tar --owner=0 --group=0 --numeric-owner -czf "$work/control.tar.gz" .)
ipk="$out/${name}_${version}-${release}_all.ipk"
rm -f "$ipk" "$ipk.sha256"
(cd "$work" && tar --owner=0 --group=0 --numeric-owner -czf "$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
(cd "$out" && sha256sum "$(basename "$ipk")" > "$(basename "$ipk").sha256")

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
tar -xOzf "$work/control-check.tar.gz" ./conffiles > "$work/conffiles-check"
grep -qx '/etc/config/glinet_crossmodel' "$work/conffiles-check"
tar -xOzf "$ipk" ./data.tar.gz > "$work/data-check.tar.gz"
tar -tzf "$work/data-check.tar.gz" > "$work/data-members"
grep -qx './usr/libexec/glinet-crossmodel-validate' "$work/data-members"
grep -qx './usr/bin/glinet-crossmodel' "$work/data-members"
grep -qx './usr/lib/glinet-crossmodel/core.sh' "$work/data-members"
grep -qx './usr/libexec/gcm-glui-integrate' "$work/data-members"
grep -qx './www/js/gcm-glui-hook.js' "$work/data-members"
tar -xOzf "$work/data-check.tar.gz" ./usr/lib/glinet-crossmodel/core.sh > "$work/core-check.sh"
grep -Fq "GCM_FORMAT_NAME='glinet-crossmodel/v2'" "$work/core-check.sh"
grep -Fq 'gcm_verify_checksums()' "$work/core-check.sh"
tar -xOzf "$work/data-check.tar.gz" ./usr/lib/lua/luci/view/glinet_crossmodel/index.htm > "$work/view-check.htm"
grep -Fq 'name="scope" value="local"' "$work/view-check.htm"
grep -Fq 'name="scope" value="remote"' "$work/view-check.htm"
grep -Fq 'id="validation-modal"' "$work/view-check.htm"
grep -Fq 'id="restore-approved"' "$work/view-check.htm"

echo "Built $ipk"
