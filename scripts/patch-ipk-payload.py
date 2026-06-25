#!/usr/bin/env python3
"""Apply GL.iNet 4.0 / LuCI 21.02 compatibility and UI additions to an IPK payload."""
from pathlib import Path
import sys

payload = Path(sys.argv[1])
controller = payload / "usr/lib/lua/luci/controller/glinet_crossmodel.lua"
backend = payload / "usr/libexec/glinet-crossmodel-backup"
view = payload / "usr/lib/lua/luci/view/glinet_crossmodel/index.htm"

# Main LuCI controller: GL.iNet's nixio uses octal strings; collect command exit
# status explicitly, because io.popen():close() differs across LuCI builds.
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
    raise SystemExit('main controller command helper not found')

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
if old_upload in text:
    text = text.replace(old_upload, new_upload, 1)
elif 'upload_seen, collecting, stream' not in text:
    raise SystemExit('main controller upload handler not found')
controller.write_text(text, encoding="utf-8")

# Remote restores should report a result before a target firewall or Wi-Fi reload
# can sever their SSH channel. Local restores retain immediate reload behavior.
text = backend.read_text(encoding="utf-8")
old_reload = '''\tif has_category "$categories" firewall; then /etc/init.d/firewall restart 2>/dev/null || true; fi
\tif has_category "$categories" wireless; then wifi reload 2>/dev/null || true; fi
'''
new_reload = '''\tif has_category "$categories" firewall; then
\t\tcase "${GCM_DEFER_RELOAD:-0}" in
\t\t\t1) log 'DEFERRED=firewall-restart:reboot-target-to-activate' ;;
\t\t\t*) /etc/init.d/firewall restart 2>/dev/null || true ;;
\t\tesac
\tfi
\tif has_category "$categories" wireless; then
\t\tcase "${GCM_DEFER_RELOAD:-0}" in
\t\t\t1) log 'DEFERRED=wireless-reload:reboot-target-to-activate' ;;
\t\t\t*) wifi reload 2>/dev/null || true ;;
\t\tesac
\tfi
'''
if old_reload in text:
    text = text.replace(old_reload, new_reload, 1)
elif 'DEFERRED=firewall-restart:reboot-target-to-activate' not in text:
    raise SystemExit('backend reload section not found')
backend.write_text(text, encoding="utf-8")

# Add the Docker-style preflight plan to the native LuCI page.
text = view.read_text(encoding="utf-8")
css = '''\n#gcm-app .gcm-validation{display:none;grid-template-columns:1fr 1fr 1fr;gap:12px;margin-top:14px}#gcm-app .gcm-validation.show{display:grid}#gcm-app .gcm-validation-card{padding:13px;border:1px solid #e0e8f1;border-radius:12px;background:#fafcff}#gcm-app .gcm-validation-card.good{background:#effbf4;border-color:#d8f2e2}#gcm-app .gcm-validation-card.warn{background:#fffaf0;border-color:#f5e8c8}#gcm-app .gcm-validation-card.skip{background:#f8fafc;border-color:#e5eaf0}#gcm-app .gcm-validation-card b{display:block;font-size:12px;letter-spacing:.04em;text-transform:uppercase;margin-bottom:7px}#gcm-app .gcm-validation-card ul{margin:0;padding-left:18px;color:#526581}#gcm-app .gcm-validation-card li{margin:5px 0}@media(max-width:780px){#gcm-app .gcm-validation{grid-template-columns:1fr}}\n'''
if 'gcm-validation-card' not in text:
    text = text.replace('</style>', css + '</style>', 1)

old_actions = '<div class="gcm-actions"><button id="restore-profile" class="gcm-primary">⇧ Restore selected items</button></div><div id="restore-status" class="gcm-status">Choose a profile and restore only what is appropriate for the selected target router.</div>'
new_actions = '<div class="gcm-actions"><button id="validate-profile" class="gcm-secondary">▦ Validate selected items</button><button id="restore-profile" class="gcm-primary">⇧ Restore selected items</button></div><div id="restore-status" class="gcm-status">Validate first to review what will be applied, adapted, or skipped.</div><div id="validation-plan" class="gcm-validation" aria-live="polite"></div>'
if old_actions in text:
    text = text.replace(old_actions, new_actions, 1)
elif 'id="validate-profile"' not in text:
    raise SystemExit('restore action markup not found')

anchor = "  $('#refresh-profiles').addEventListener('click',profiles);toggle('source');toggle('target');facts();profiles();"
validation_js = '''  function planCard(title,items,kind){var rows=(items&&items.length)?items.map(function(item){return '<li>'+esc(item)+'</li>';}).join(''):'<li>None.</li>';return '<div class="gcm-validation-card '+kind+'"><b>'+esc(title)+'</b><ul>'+rows+'</ul></div>';}
  function renderValidation(plan){var box=$('#validation-plan');var source=(plan.source||{}).model||'Portable profile source';var target=(plan.target||{}).model||'Target router';box.innerHTML=planCard('Will apply',plan.will_apply,'good')+planCard('Warnings / adaptation',plan.warnings,'warn')+planCard('Skipped safely',plan.skipped,'skip');box.classList.add('show');setStatus('#restore-status','Validation complete. Source: '+source+' · Target: '+target);}
  $('#validate-profile').addEventListener('click',async function(){var file=$('#restore-file').files[0];var remote=$('#target-remote').checked;var choices=csv('#restore-categories');if(!file){setStatus('#restore-status','Choose a portable .tar.gz profile archive first.',true);return;}if(!choices){setStatus('#restore-status','Select at least one restore category.',true);return;}var button=$('#validate-profile');button.disabled=true;button.textContent='Validating…';setStatus('#restore-status',remote?'Uploading profile and validating the remote target…':'Validating profile against this router…');try{var form=new FormData();form.append('archive',file);form.append('categories',choices);form.append('remote_enabled',remote?'1':'0');if(remote){var target=connection('target');form.append('remote_host',target.host);form.append('remote_port',target.port);form.append('remote_user',target.user);form.append('remote_password',target.password);}var data=await request(base+'/api/validate',{method:'POST',body:form});renderValidation(data);}catch(error){setStatus('#restore-status',error.message,true);$('#validation-plan').classList.remove('show');}finally{button.disabled=false;button.textContent='▦ Validate selected items';}});
'''
if validation_js not in text:
    if anchor not in text:
        raise SystemExit('view initialization anchor not found')
    text = text.replace(anchor, validation_js + anchor, 1)
view.write_text(text, encoding="utf-8")
