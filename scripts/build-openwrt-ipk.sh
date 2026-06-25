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

# GL.iNet LuCI expects string chmod modes. Add a real Services parent without
# using an alias, because aliases intercept the nested API routes used by the app.
python3 - "$work/data/usr/lib/lua/luci/controller/glinet_crossmodel.lua" <<'PY'
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

old_upload = '''\tlocal bytes, upload, stream = 0, false, nil
\thttp.setfilehandler(function(meta, chunk, eof)
\t\tif meta and meta.name == "archive" then
\t\t\tupload = true
\t\t\tstream = io.open(temporary, "wb")
\t\tend
\t\tif upload and stream and chunk and #chunk > 0 then
\t\t\tbytes = bytes + #chunk
\t\t\tif bytes <= 64 * 1024 * 1024 then stream:write(chunk) end
\t\tend
\t\tif upload and eof and stream then stream:close(); stream = nil end
\tend)
\thttp.formvalue("archive")
\tif stream then stream:close() end
\tif not upload or bytes == 0 or bytes > 64 * 1024 * 1024 or not fs.access(temporary) then
\t\tfs.unlink(temporary)
\t\treturn write_json({ error = "Upload a portable profile archive smaller than 64 MB." }, 400)
\tend
\tfs.chmod(temporary, "0600")
'''
new_upload = '''\tlocal bytes, upload_seen, collecting, stream = 0, false, false, nil
\thttp.setfilehandler(function(meta, chunk, eof)
\t\tif meta then
\t\t\tif meta.name == "archive" then
\t\t\t\tupload_seen = true
\t\t\t\tif not collecting then
\t\t\t\t\tstream = io.open(temporary, "wb")
\t\t\t\t\tcollecting = stream ~= nil
\t\t\t\tend
\t\t\telse
\t\t\t\tif collecting and stream then stream:close(); stream = nil end
\t\t\t\tcollecting = false
\t\t\tend
\t\tend
\t\tif collecting and stream and chunk and #chunk > 0 then
\t\t\tbytes = bytes + #chunk
\t\t\tif bytes <= 64 * 1024 * 1024 then stream:write(chunk) end
\t\tend
\t\tif collecting and eof then
\t\t\tif stream then stream:close(); stream = nil end
\t\t\tcollecting = false
\t\tend
\tend)
\thttp.formvalue("archive")
\tif stream then stream:close() end
\tif not upload_seen or bytes == 0 or bytes > 64 * 1024 * 1024 or not fs.access(temporary) then
\t\tfs.unlink(temporary)
\t\treturn write_json({ error = "Upload a portable profile archive smaller than 64 MB." }, 400)
\tend
\tfs.chmod(temporary, "0600")
\tlocal readable = command("tar -tzf " .. quote(temporary) .. " >/dev/null")
\tif not readable then
\t\tfs.unlink(temporary)
\t\treturn write_json({ error = "Uploaded profile archive could not be read on the control router." }, 400)
\tend
'''
if old_upload not in text:
    raise SystemExit('LuCI restore upload handler was not found')
text = text.replace(old_upload, new_upload, 1)

old_command = '''local function command(commandline)
\tlocal pipe = io.popen(commandline .. " 2>&1")
\tlocal output = pipe:read("*a") or ""
\tlocal ok, _, code = pipe:close()
\tif ok == true or ok == 0 then return true, output end
\treturn false, output, code
end
'''
new_command = '''local function command(commandline)
\tlocal marker = "__GCM_EXIT__"
\tlocal shell = "(" .. commandline .. ") 2>&1; rc=$?; echo; echo " .. marker .. "$rc"
\tlocal pipe = io.popen(shell)
\tlocal output = pipe:read("*a") or ""
\tpipe:close()
\tlocal status = tonumber(output:match("\\n" .. marker .. "(%d+)%s*$"))
\toutput = output:gsub("\\n" .. marker .. "%d+%s*$", "")
\tif status == 0 then return true, output end
\treturn false, output, status
end
'''
if old_command in text:
    text = text.replace(old_command, new_command, 1)
elif '__GCM_EXIT__' not in text:
    raise SystemExit('LuCI command helper was not found')
path.write_text(text, encoding="utf-8")
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
# Do not restart web services here: LuCI Package Manager uses XHR.
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
EOF
chmod 0755 "$work/control/postinst"
printf '2.0\n' > "$work/debian-binary"

# GL.iNet firmware 4.0 / OpenWrt 21.02 uses a gzip-compressed tar wrapper.
(cd "$work/data" && tar --owner=0 --group=0 --numeric-owner -czf "$work/data.tar.gz" .)
(cd "$work/control" && tar --owner=0 --group=0 --numeric-owner -czf "$work/control.tar.gz" .)
ipk="$out/${name}_${version}-${release}_all.ipk"
rm -f "$ipk" "$ipk.sha256"
(cd "$work" && tar --owner=0 --group=0 --numeric-owner -czf "$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)
sha256sum "$ipk" > "$ipk.sha256"

# Validate without piping tar into grep. With pipefail, grep -q exits early
# and can make tar fail with a false Broken pipe error.
tar -tzf "$ipk" | grep -qx './debian-binary'
tar -tzf "$ipk" | grep -qx './data.tar.gz'
tar -tzf "$ipk" | grep -qx './control.tar.gz'
tar -xOzf "$ipk" ./debian-binary > "$work/debian-binary-check"
grep -qx '2.0' "$work/debian-binary-check"
tar -xOzf "$ipk" ./control.tar.gz > "$work/control-check.tar.gz"
tar -xOzf "$work/control-check.tar.gz" ./control > "$work/control-check"
grep -Fq 'Depends: luci-base, openssh-client, sshpass, jsonfilter' "$work/control-check"
tar -xOzf "$ipk" ./data.tar.gz > "$work/data-check.tar.gz"
tar -xOzf "$work/data-check.tar.gz" ./usr/libexec/glinet-crossmodel-remote > "$work/remote-check.sh"
grep -Fq 'verify_remote_copy' "$work/remote-check.sh"
grep -Fq 'scp -O' "$work/remote-check.sh"
tar -xOzf "$work/data-check.tar.gz" ./usr/lib/lua/luci/controller/glinet_crossmodel.lua > "$work/controller-check.lua"
grep -Fq '__GCM_EXIT__' "$work/controller-check.lua"
grep -Fq 'upload_seen, collecting, stream' "$work/controller-check.lua"
grep -Fq 'Uploaded profile archive could not be read on the control router.' "$work/controller-check.lua"
grep -Fq 'fs.chmod(PROFILE_DIR, "0700")' "$work/controller-check.lua"
grep -Fq 'local services = entry({"admin", "services"}, firstchild(), _("Services"), 60)' "$work/controller-check.lua"

echo "Built $ipk"
