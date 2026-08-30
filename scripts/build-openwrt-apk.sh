#!/bin/sh
# Build a signed OpenWrt 25+ (apk-tools 3.x, v3/ADB) package of the LuCI app.
#
# Requires:
#   - apk-tools 3.x (apk mkpkg / apk verify)  -> run inside alpine:edge container
#   - openssl (to derive the public key)
#   - APK_SIGN_KEY: path to the RSA (PKCS#1 PEM) signing private key
#
# Emits:
#   dist/luci-app-glinet-crossmodel-backup-<version>-r<release>-noarch.apk
#   dist/<apk>.sha256
#   dist/glinet-crossmodel.pub   (public key to install on the router, one-time)
set -eu

# Inside alpine:edge the default toolbox needs the openssl applet for pubkey
# derivation; on hosts with system openssl this is a no-op.
apk add --no-cache openssl >/dev/null 2>&1 || true
command -v openssl >/dev/null 2>&1 || {
  echo "error: openssl is required" >&2
  exit 1
}

root="$(cd "$(dirname "$0")/.." && pwd)"
pkg="$root/openwrt/luci-app-glinet-crossmodel-backup"
payload="$pkg/root"
makefile="$pkg/Makefile"
out="$root/dist"
name="$(sed -n 's/^PKG_NAME:=//p' "$makefile" | head -n1)"
version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile" | head -n1)"
release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile" | head -n1)"
license="$(sed -n 's/^PKG_LICENSE:=//p' "$makefile" | head -n1)"

key="${APK_SIGN_KEY:-}"
[ -n "$key" ] && [ -f "$key" ] || {
  echo "error: APK_SIGN_KEY must name an RSA (PKCS#1 PEM) private key file" >&2
  exit 1
}
[ -n "$name" ] && [ -n "$version" ] && [ -n "$release" ] && [ -n "$license" ]
[ -d "$payload" ]

apk --version 2>/dev/null | grep -q 'apk-tools 3\.' || {
  echo "error: apk-tools 3.x required (run inside alpine:edge)" >&2
  apk --version 2>/dev/null || true
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/data" "$work/scripts" "$work/keys" "$out"

cp -a "$payload/." "$work/data/"
chmod 0755 \
  "$work/data/usr/bin/glinet-crossmodel" \
  "$work/data/usr/libexec/glinet-crossmodel-backup" \
  "$work/data/usr/libexec/glinet-crossmodel-remote" \
  "$work/data/usr/libexec/glinet-crossmodel-validate" \
  "$work/data/usr/libexec/gcm-glui-integrate" \
  "$work/data/etc/init.d/gcm-glui-integration"
chmod 0644 "$work/data/usr/lib/glinet-crossmodel/core.sh"

# Runtime content packaged exactly as checked in (mirror of the ipk builder).
diff -qr "$payload" "$work/data" >/dev/null

cat > "$work/scripts/post-install" <<'EOF'
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
chmod 0755 "$work/scripts/post-install"

cat > "$work/scripts/pre-deinstall" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/gcm-glui-integration stop >/dev/null 2>&1 || true
/etc/init.d/gcm-glui-integration disable >/dev/null 2>&1 || true
/usr/libexec/gcm-glui-integrate --remove >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$work/scripts/pre-deinstall"

openssl rsa -in "$key" -pubout -out "$work/keys/signing.pub" 2>/dev/null

apk_version="$version-r$release"
apk_file="$out/${name}-${apk_version}-noarch.apk"
rm -f "$apk_file" "$apk_file.sha256" "$out/glinet-crossmodel.pub"

apk mkpkg \
  --sign-key "$key" \
  --xattrs=no \
  --files "$work/data" \
  --output "$apk_file" \
  --info "name:$name" \
  --info "version:$apk_version" \
  --info "arch:noarch" \
  --info "description:GL.iNet Cross-Model Backup, Migration and Recovery" \
  --info "maintainer:zippyy" \
  --info "license:$license" \
  --info "origin:$name" \
  --info "depends:luci-base openssh-client sshpass jsonfilter" \
  --script post-install:"$work/scripts/post-install" \
  --script pre-deinstall:"$work/scripts/pre-deinstall"

# The signature must verify against the public key we ship.
mkdir -p "$work/vkeys"
cp "$work/keys/signing.pub" "$work/vkeys/glinet-crossmodel.pub"
verify_out="$(apk verify --keys-dir "$work/vkeys" "$apk_file" 2>&1 || true)"
printf '%s\n' "$verify_out" | grep -q "OK" || {
  echo "error: signature verification failed: $verify_out" >&2
  exit 1
}

(cd "$out" && sha256sum "$(basename "$apk_file")" > "$(basename "$apk_file").sha256")
cp "$work/keys/signing.pub" "$out/glinet-crossmodel.pub"

echo "Built $apk_file (signed, apk-tools 3.x / OpenWrt 25+ format)"