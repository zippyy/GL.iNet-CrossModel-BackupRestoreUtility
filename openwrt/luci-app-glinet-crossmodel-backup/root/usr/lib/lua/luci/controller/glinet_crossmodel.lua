module("luci.controller.glinet_crossmodel", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"
local dispatcher = require "luci.dispatcher"
local uci = require("luci.model.uci").cursor()

local CLI = "/usr/bin/glinet-crossmodel"
local REMOTE = "/usr/libexec/glinet-crossmodel-remote"
local PROFILE_DIR = "/root/glinet-crossmodel/profiles"
local TMP_DIR = "/tmp/glinet-crossmodel"
local ROUTERS_FILE = "/root/glinet-crossmodel/routers.json"
local KNOWN_HOSTS = "/root/.ssh/known_hosts"
local MAX_UPLOAD = 128 * 1024 * 1024
local categories = {
	"wifi", "lan", "dhcp", "dns", "firewall", "timezone", "ddns", "vpn",
	"packages", "persistent", "custom-files", "custom-binaries"
}
local valid_category, valid_strategy = {}, { portable = true, clone = true, ["remote-safe"] = true, snapshot = true }
for _, name in ipairs(categories) do valid_category[name] = true end

local function quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\"'\"'") .. "'"
end

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function command(commandline)
	local marker = "__GCM_EXIT__"
	local shell = "(" .. commandline .. ") 2>&1; rc=$?; echo; echo " .. marker .. "$rc"
	local pipe = io.popen(shell)
	local output = pipe:read("*a") or ""
	pipe:close()
	local status = tonumber(output:match("\n" .. marker .. "(%d+)%s*$"))
	output = output:gsub("\n" .. marker .. "%d+%s*$", "")
	if status == 0 then return true, output end
	return false, output, status
end

local function invoke(program, action, arguments, environment)
	local parts = {}
	if environment then table.insert(parts, environment) end
	table.insert(parts, quote(program))
	if action then table.insert(parts, quote(action)) end
	for _, argument in ipairs(arguments or {}) do table.insert(parts, quote(argument)) end
	return command(table.concat(parts, " "))
end

local function write_json(value, status)
	if status then http.status(status, status == 200 and "OK" or "Error") end
	http.prepare_content("application/json")
	http.write(jsonc.stringify(value))
end

local function read_json_request()
	return jsonc.parse(http.content() or "") or {}
end

local function require_csrf()
	if http.getenv("REQUEST_METHOD") ~= "POST" then write_json({ error = "POST required." }, 405); return nil end
	local supplied = tostring(http.getenv("HTTP_X_CSRF_TOKEN") or "")
	local expected = tostring(dispatcher.context.authsession or "")
	if supplied == "" or expected == "" or supplied ~= expected then write_json({ error = "Invalid or expired LuCI request token. Reload the page." }, 403); return nil end
	return true
end

local function ensure_directories()
	command("mkdir -p " .. quote(PROFILE_DIR) .. " " .. quote(TMP_DIR) .. " /root/.ssh /root/glinet-crossmodel/rollback")
	fs.chmod("/root/glinet-crossmodel", "0700")
	fs.chmod(PROFILE_DIR, "0700")
	fs.chmod(TMP_DIR, "0700")
	fs.chmod("/root/.ssh", "0700")
	if not fs.access(KNOWN_HOSTS) then fs.writefile(KNOWN_HOSTS, "") end
	fs.chmod(KNOWN_HOSTS, "0600")
end

local function uuid()
	local value = trim(fs.readfile("/proc/sys/kernel/random/uuid") or "")
	if value:match("^[a-f0-9%-]+$") then return value end
	return string.format("%08x-%04x-%04x-%04x-%08x", os.time(), math.random(0, 65535), math.random(0, 65535), math.random(0, 65535), math.random(0, 0x7fffffff))
end

local function safe_id(value)
	value = tostring(value or "")
	return #value >= 8 and #value <= 64 and value:match("^[A-Fa-f0-9%-]+$") and value or nil
end

local function safe_text(value, maximum)
	value = trim(value)
	if #value > maximum or value:find("[%z\1-\8\11\12\14-\31]") then return nil end
	return value
end

local function valid_path(value)
	value = trim(value)
	if not value:match("^/[A-Za-z0-9_%.%/+@%%:,=%-]+$") then return nil end
	if value == "/" or value:find("//", 1, true) or value:find("/../", 1, true) or value:find("/./", 1, true) or value:sub(-3) == "/.." then return nil end
	return value
end

local function parse_paths(value, maximum)
	local out, seen = {}, {}
	for line in (tostring(value or "") .. "\n"):gmatch("(.-)\n") do
		local cleaned = trim(line)
		if #cleaned > 0 then
			local path = valid_path(cleaned)
			if not path then return nil, "Invalid custom path: " .. cleaned end
			if not seen[path] then seen[path] = true; table.insert(out, path) end
		end
	end
	if #out > maximum then return nil, "Too many custom paths (maximum " .. maximum .. ")." end
	return out
end

local function write_list(operation_id, name, values)
	local path = TMP_DIR .. "/" .. operation_id .. "-" .. name .. ".list"
	local file = io.open(path, "w")
	if not file then return nil end
	for _, value in ipairs(values) do file:write(value, "\n") end
	file:close()
	fs.chmod(path, "0600")
	return path
end

local function selected_csv(value)
	local selected, seen = {}, {}
	if type(value) == "table" then
		for _, name in ipairs(categories) do
			if value[name] == true or value[name] == 1 or value[name] == "1" then table.insert(selected, name) end
		end
	else
		for name in tostring(value or ""):gmatch("[^,]+") do
			if valid_category[name] and not seen[name] then seen[name] = true; table.insert(selected, name) end
		end
	end
	return table.concat(selected, ",")
end

local function load_routers()
	local parsed = jsonc.parse(fs.readfile(ROUTERS_FILE) or "")
	return type(parsed) == "table" and parsed or {}
end

local function save_routers(routers)
	local temporary = ROUTERS_FILE .. ".tmp"
	if not fs.writefile(temporary, jsonc.stringify(routers)) then return nil end
	fs.chmod(temporary, "0600")
	if not fs.rename(temporary, ROUTERS_FILE) then fs.unlink(temporary); return nil end
	fs.chmod(ROUTERS_FILE, "0600")
	return true
end

local function router_by_id(router_id)
	for _, router in ipairs(load_routers()) do if router.id == router_id then return router end end
	return nil
end

local function normalize_connection(input)
	input = input or {}
	local saved = safe_id(input.saved_id) and router_by_id(input.saved_id) or nil
	local host = trim(input.host or (saved and saved.host))
	local user = trim(input.user or (saved and saved.user) or "root")
	local port = tonumber(input.port or (saved and saved.port) or 22)
	local password = tostring(input.password or "")
	local auth = trim(input.auth or (saved and saved.auth) or (password ~= "" and "password" or "key"))
	local key_path = trim(input.key_path or (saved and saved.key_path) or "")
	if #host < 1 or #host > 253 or not host:match("^[A-Za-z0-9][A-Za-z0-9%._:%-]*$") then return nil, "Enter a valid router hostname or IP address." end
	if not port or port % 1 ~= 0 or port < 1 or port > 65535 then return nil, "SSH port must be between 1 and 65535." end
	if #user < 1 or #user > 64 or not user:match("^[A-Za-z0-9][A-Za-z0-9%._%-]*$") then return nil, "Enter a valid SSH username." end
	if auth == "password" then
		if #password < 1 or #password > 512 or password:find("[%c]") then return nil, "Enter the SSH password for this request." end
	elseif auth == "key" then
		if not valid_path(key_path) or not fs.access(key_path) then return nil, "Choose an existing absolute SSH private-key path on this controller." end
	elseif auth ~= "agent" then return nil, "Authentication must be password, SSH key, or agent." end
	return { host = host, port = tostring(port), user = user, auth = auth, password = password, key_path = key_path, saved = saved }
end

local function credential_for(operation_id, connection)
	if connection.auth == "agent" then return "-" end
	if connection.auth == "key" then return connection.key_path end
	local path = TMP_DIR .. "/sshpass-" .. operation_id
	local file = io.open(path, "w")
	if not file then return nil end
	file:write(connection.password, "\n")
	file:close()
	fs.chmod(path, "0600")
	return path
end

local function cleanup_credential(connection, credential)
	if connection and connection.auth == "password" and credential then fs.unlink(credential) end
end

local known_host_fingerprint

local function remote_call(action, arguments, connection, operation_id)
	if connection.saved and connection.saved.verified_fingerprint and connection.saved.verified_fingerprint ~= "" then
		local current = known_host_fingerprint(connection)
		if current == "" then return false, "The saved router's known_hosts record is missing. Delete and deliberately re-add the router definition before operating on it." end
		if current ~= connection.saved.verified_fingerprint then return false, "Verified SSH host fingerprint differs from the saved router definition." end
	end
	local credential = credential_for(operation_id, connection)
	if not credential then return false, "Could not create a temporary SSH credential file." end
	for _, value in ipairs({ connection.host, connection.port, connection.user, connection.auth, credential }) do table.insert(arguments, value) end
	local ok, output, code = invoke(REMOTE, action, arguments)
	cleanup_credential(connection, credential)
	return ok, output, code
end

known_host_fingerprint = function(connection)
	local lookup = connection.port == "22" and connection.host or ("[" .. connection.host .. "]:" .. connection.port)
	local ok, output = command("ssh-keygen -F " .. quote(lookup) .. " -f " .. quote(KNOWN_HOSTS) .. " 2>/dev/null | sed '/^#/d' | ssh-keygen -lf - 2>/dev/null")
	if not ok then return "" end
	return trim(output:match("SHA256:[A-Za-z0-9+/=]+") or "")
end

local function detect_connection(connection)
	local operation_id = uuid()
	local ok, output = remote_call("facts", {}, connection, operation_id)
	if not ok then return nil, trim(output) ~= "" and trim(output) or "SSH connection failed." end
	local facts = jsonc.parse(output)
	if not facts then return nil, "Remote facts response was invalid." end
	local fingerprint = known_host_fingerprint(connection)
	if connection.saved and connection.saved.verified_fingerprint and connection.saved.verified_fingerprint ~= "" and fingerprint ~= connection.saved.verified_fingerprint then
		return nil, "Verified SSH host fingerprint differs from the saved router definition."
	end
	facts.verified_fingerprint = fingerprint
	return facts
end

local function update_saved_detection(connection, facts)
	if not connection.saved then return true end
	local routers = load_routers()
	for _, router in ipairs(routers) do
		if router.id == connection.saved.id then
			router.last_model = facts.model or router.last_model or ""
			router.last_firmware = facts.firmware or router.last_firmware or ""
			router.verified_fingerprint = facts.verified_fingerprint or router.verified_fingerprint or ""
			router.detected_at = os.time()
			return save_routers(routers)
		end
	end
	return nil
end

local function profile_archive(profile_id)
	profile_id = safe_id(profile_id)
	return profile_id and (PROFILE_DIR .. "/" .. profile_id .. ".tar.gz") or nil
end

local function profile_sidecar(profile_id)
	return PROFILE_DIR .. "/" .. profile_id .. ".meta.json"
end

local function inspect_archive(path)
	local ok, output = invoke(CLI, "inspect", { path })
	if not ok then return nil, trim(output) end
	return jsonc.parse(output), nil
end

local function profile_list()
	ensure_directories()
	local result = {}
	for path in fs.glob(PROFILE_DIR .. "/*.tar.gz") do
		local profile_id = path:match("/([A-Fa-f0-9%-]+)%.tar%.gz$")
		if profile_id then
			local manifest = inspect_archive(path)
			local sidecar = jsonc.parse(fs.readfile(profile_sidecar(profile_id)) or "") or {}
			local stat = fs.stat(path) or {}
			if manifest then
				table.insert(result, { id = profile_id, uuid = manifest.profile_uuid or "", name = sidecar.name or manifest.profile_name or "Backup", notes = sidecar.notes or manifest.notes or "", strategy = manifest.backup_strategy or "legacy-portable", source = manifest.source_hostname or manifest.source_model or "Unknown", model = manifest.source_model or manifest.model or "Unknown", firmware = manifest.firmware_version or manifest.firmware or "Unknown", created_at = manifest.created_at or "", size = stat.size or 0, mtime = stat.mtime or 0, legacy = manifest.legacy == true })
			end
		end
	end
	table.sort(result, function(a, b) return a.mtime > b.mtime end)
	return result
end

local function storage_limits()
	return tonumber(uci:get("glinet_crossmodel", "storage", "max_profiles")) or 20,
		(tonumber(uci:get("glinet_crossmodel", "storage", "max_storage_mb")) or 128) * 1024 * 1024,
		uci:get("glinet_crossmodel", "storage", "auto_prune") == "1"
end

local function enforce_storage(new_id)
	local maximum_count, maximum_bytes, auto_prune = storage_limits()
	local profiles = profile_list()
	local total = 0
	for _, profile in ipairs(profiles) do total = total + profile.size end
	while (#profiles > maximum_count or total > maximum_bytes) and auto_prune and #profiles > 1 do
		local prune_index = #profiles
		while prune_index > 0 and profiles[prune_index].id == new_id do prune_index = prune_index - 1 end
		if prune_index == 0 then break end
		local oldest = table.remove(profiles, prune_index)
		fs.unlink(profile_archive(oldest.id)); fs.unlink(profile_sidecar(oldest.id)); total = total - oldest.size
	end
	if #profiles > maximum_count or total > maximum_bytes then
		fs.unlink(profile_archive(new_id)); fs.unlink(profile_sidecar(new_id))
		return nil, "Storage limit reached. Increase retention limits, enable auto-prune, or delete an older profile."
	end
	return true
end

local function receive_archive(destination)
	local bytes, upload_seen, collecting, stream = 0, false, false, nil
	http.setfilehandler(function(meta, chunk, eof)
		if meta then
			if meta.name == "archive" then upload_seen = true; if not collecting then stream = io.open(destination, "wb"); collecting = stream ~= nil end
			elseif collecting and stream then stream:close(); stream = nil; collecting = false
			else collecting = false
			end
		end
		if collecting and stream and chunk and #chunk > 0 then bytes = bytes + #chunk; if bytes <= MAX_UPLOAD then stream:write(chunk) end end
		if collecting and eof then if stream then stream:close(); stream = nil end; collecting = false end
	end)
	http.formvalue("archive")
	if stream then stream:close() end
	if not upload_seen or bytes == 0 or bytes > MAX_UPLOAD or not fs.access(destination) then fs.unlink(destination); return nil, "Upload an archive smaller than 128 MB." end
	fs.chmod(destination, "0600")
	local ok = command("tar -tzf " .. quote(destination) .. " >/dev/null")
	if not ok then fs.unlink(destination); return nil, "Uploaded archive is unreadable." end
	return true
end

function index()
	local system = entry({ "admin", "system" }, firstchild(), _("System"), 60)
	system.dependent = false
	entry({ "admin", "system", "glinet-crossmodel" }, call("action_index"), _("Backup & Recovery"), 92).dependent = false
	for _, route in ipairs({ "facts", "routers", "router-save", "router-delete", "test", "profiles", "settings", "settings-save", "create", "import", "inspect", "validate", "packages", "restore", "profile-update", "profile-delete" }) do
		entry({ "admin", "system", "glinet-crossmodel", "api", route }, call("action_" .. route:gsub("%-", "_"))).leaf = true
	end
	entry({ "admin", "system", "glinet-crossmodel", "download" }, call("action_download")).leaf = true
end

function action_index() luci.template.render("glinet_crossmodel/index") end

function action_facts()
	local ok, output = invoke(CLI, "facts", {})
	if not ok then return write_json({ error = trim(output) }, 500) end
	write_json(jsonc.parse(output) or { error = "Invalid local facts." }, 200)
end

function action_routers() write_json({ routers = load_routers() }, 200) end

function action_router_save()
	if not require_csrf() then return end
	ensure_directories()
	local input = read_json_request()
	local friendly_name = safe_text(input.friendly_name, 80)
	if not friendly_name or friendly_name == "" then return write_json({ error = "Enter a friendly router name." }, 400) end
	local connection, connection_error = normalize_connection(input.connection)
	if not connection then return write_json({ error = connection_error }, 400) end
	local facts, detect_error = detect_connection(connection)
	if not facts then return write_json({ error = detect_error }, 422) end
	local router_id = safe_id(input.id) or uuid()
	local routers, replacement = load_routers(), { id = router_id, friendly_name = friendly_name, host = connection.host, port = tonumber(connection.port), user = connection.user, auth = connection.auth, key_path = connection.auth == "key" and connection.key_path or "", verified_fingerprint = facts.verified_fingerprint or "", last_model = facts.model or "", last_firmware = facts.firmware or "", detected_at = os.time() }
	local found = false
	for index, router in ipairs(routers) do if router.id == router_id then routers[index] = replacement; found = true; break end end
	if not found then table.insert(routers, replacement) end
	if not save_routers(routers) then return write_json({ error = "Could not save router inventory." }, 500) end
	write_json({ router = replacement, facts = facts }, 200)
end

function action_router_delete()
	if not require_csrf() then return end
	local input, out = read_json_request(), {}
	local router_id = safe_id(input.id)
	if not router_id then return write_json({ error = "Invalid router ID." }, 400) end
	for _, router in ipairs(load_routers()) do if router.id ~= router_id then table.insert(out, router) end end
	if not save_routers(out) then return write_json({ error = "Could not update router inventory." }, 500) end
	write_json({ ok = true }, 200)
end

function action_test()
	if not require_csrf() then return end
	ensure_directories()
	local input = read_json_request()
	if input.scope ~= "remote" then return action_facts() end
	local connection, connection_error = normalize_connection(input.connection)
	if not connection then return write_json({ error = connection_error }, 400) end
	local facts, detect_error = detect_connection(connection)
	if not facts then return write_json({ error = detect_error }, 422) end
	if not update_saved_detection(connection, facts) then return write_json({ error = "Router was detected, but its inventory metadata could not be updated." }, 500) end
	write_json(facts, 200)
end

function action_profiles() write_json({ profiles = profile_list() }, 200) end

function action_settings()
	write_json({ max_profiles = tonumber(uci:get("glinet_crossmodel", "storage", "max_profiles")) or 20, max_storage_mb = tonumber(uci:get("glinet_crossmodel", "storage", "max_storage_mb")) or 128, max_rollbacks = tonumber(uci:get("glinet_crossmodel", "storage", "max_rollbacks")) or 5, auto_prune = uci:get("glinet_crossmodel", "storage", "auto_prune") == "1" }, 200)
end

function action_settings_save()
	if not require_csrf() then return end
	local input = read_json_request()
	local max_profiles, max_storage_mb, max_rollbacks = tonumber(input.max_profiles), tonumber(input.max_storage_mb), tonumber(input.max_rollbacks)
	if not max_profiles or max_profiles % 1 ~= 0 or max_profiles < 1 or max_profiles > 100 then return write_json({ error = "Profile retention must be between 1 and 100." }, 400) end
	if not max_storage_mb or max_storage_mb % 1 ~= 0 or max_storage_mb < 16 or max_storage_mb > 2048 then return write_json({ error = "Storage limit must be between 16 and 2048 MB." }, 400) end
	if not max_rollbacks or max_rollbacks % 1 ~= 0 or max_rollbacks < 1 or max_rollbacks > 20 then return write_json({ error = "Rollback retention must be between 1 and 20." }, 400) end
	uci:set("glinet_crossmodel", "storage", "max_profiles", tostring(max_profiles))
	uci:set("glinet_crossmodel", "storage", "max_storage_mb", tostring(max_storage_mb))
	uci:set("glinet_crossmodel", "storage", "max_rollbacks", tostring(max_rollbacks))
	uci:set("glinet_crossmodel", "storage", "auto_prune", input.auto_prune == true and "1" or "0")
	if not uci:commit("glinet_crossmodel") then return write_json({ error = "Could not save storage settings." }, 500) end
	write_json({ ok = true }, 200)
end

function action_create()
	if not require_csrf() then return end
	ensure_directories()
	local input = read_json_request()
	local strategy = valid_strategy[input.strategy] and input.strategy or nil
	local name = safe_text(input.name, 100)
	local notes = safe_text(input.notes, 1000)
	local selected = selected_csv(input.categories)
	if not strategy then return write_json({ error = "Choose a valid backup strategy." }, 400) end
	if not name or name == "" or not notes then return write_json({ error = "Profile name or notes are invalid." }, 400) end
	if selected == "" then return write_json({ error = "Select at least one category." }, 400) end
	local scripts, scripts_error = parse_paths(input.scripts, 40)
	if not scripts then return write_json({ error = scripts_error }, 400) end
	local binaries, binaries_error = parse_paths(input.binaries, 20)
	if not binaries then return write_json({ error = binaries_error }, 400) end
	local operation_id = uuid()
	local scripts_file, binaries_file = write_list(operation_id, "scripts", scripts), write_list(operation_id, "binaries", binaries)
	if not scripts_file or not binaries_file then fs.unlink(scripts_file); fs.unlink(binaries_file); return write_json({ error = "Could not create temporary custom-file lists." }, 500) end
	local output = profile_archive(operation_id)
	local ok, log
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then fs.unlink(scripts_file); fs.unlink(binaries_file); return write_json({ error = connection_error }, 400) end
		ok, log = remote_call("create", { output, strategy, operation_id, name, notes, selected, scripts_file, binaries_file }, connection, operation_id)
	else
		ok, log = invoke(CLI, "create", { "--output", output, "--strategy", strategy, "--id", operation_id, "--name", name, "--notes", notes, "--categories", selected, "--scripts-list", scripts_file, "--binaries-list", binaries_file })
	end
	fs.unlink(scripts_file); fs.unlink(binaries_file)
	if not ok or not fs.access(output) then fs.unlink(output); return write_json({ error = trim(log) ~= "" and trim(log) or "Backup failed." }, input.scope == "remote" and 422 or 500) end
	fs.chmod(output, "0600")
	local retained, retention_error = enforce_storage(operation_id)
	if not retained then return write_json({ error = retention_error }, 507) end
	write_json({ ok = true, id = operation_id, log = log, download = dispatcher.build_url("admin", "system", "glinet-crossmodel", "download", operation_id) }, 200)
end

function action_import()
	if not require_csrf() then return end
	ensure_directories()
	local operation_id = uuid()
	local temporary = TMP_DIR .. "/import-" .. operation_id .. ".tar.gz"
	local received, receive_error = receive_archive(temporary)
	if not received then return write_json({ error = receive_error }, 400) end
	local manifest, inspect_error = inspect_archive(temporary)
	if not manifest then fs.unlink(temporary); return write_json({ error = inspect_error }, 400) end
	local destination = profile_archive(operation_id)
	if not fs.rename(temporary, destination) then fs.unlink(temporary); return write_json({ error = "Could not store the imported archive." }, 500) end
	fs.chmod(destination, "0600")
	if not fs.writefile(profile_sidecar(operation_id), jsonc.stringify({ name = manifest.profile_name or "Imported backup", notes = manifest.notes or "" })) then fs.unlink(destination); return write_json({ error = "Could not store imported profile metadata." }, 500) end
	fs.chmod(profile_sidecar(operation_id), "0600")
	local retained, retention_error = enforce_storage(operation_id)
	if not retained then return write_json({ error = retention_error }, 507) end
	write_json({ ok = true, id = operation_id, manifest = manifest }, 200)
end

local function require_profile(input)
	local path = profile_archive(input.id)
	if not path or not fs.access(path) then return nil, "Profile not found." end
	return path
end

function action_inspect()
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	local manifest, inspect_error = inspect_archive(path)
	if not manifest then return write_json({ error = inspect_error }, 400) end
	write_json({ manifest = manifest }, 200)
end

local function target_call(action, path, input, extra)
	local selected = selected_csv(input.categories)
	if selected == "" then return false, "Select at least one category.", 400 end
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then return false, connection_error, 400 end
		local operation_id = uuid()
		local arguments = { path, operation_id, selected }
		for _, value in ipairs(extra or {}) do table.insert(arguments, value) end
		local ok, output = remote_call(action, arguments, connection, operation_id)
		return ok, output, ok and 200 or 422
	end
	local arguments = { path }
	if action == "validate" then table.insert(arguments, "--categories"); table.insert(arguments, selected); if extra and extra[1] == "1" then table.insert(arguments, "--dangerous-device-override") end end
	local ok, output = invoke(CLI, action, arguments)
	return ok, output, ok and 200 or 500
end

function action_validate()
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	local override = input.dangerous_override == true and "1" or "0"
	local ok, output, status = target_call("validate", path, input, { override })
	if not ok then return write_json({ error = trim(output) }, status or 500) end
	local plan = jsonc.parse(output)
	if not plan then return write_json({ error = "Validation returned invalid data." }, 500) end
	write_json(plan, 200)
end

function action_packages()
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	local ok, output, status
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then return write_json({ error = connection_error }, 400) end
		local operation_id = uuid()
		ok, output = remote_call("packages", { path, operation_id }, connection, operation_id); status = ok and 200 or 422
	else ok, output = invoke(CLI, "packages", { path }); status = ok and 200 or 500 end
	if not ok then return write_json({ error = trim(output) }, status) end
	write_json(jsonc.parse(output) or { error = "Package Review returned invalid data." }, 200)
end

function action_restore()
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	local selected = selected_csv(input.categories)
	if selected == "" then return write_json({ error = "Select at least one category." }, 400) end
	local packages = tostring(input.packages or "")
	if packages:find("[^A-Za-z0-9%+%._,%-%s]") then return write_json({ error = "Invalid package selection." }, 400) end
	packages = packages:gsub("%s+", "")
	local direct = input.direct_custom == true and "1" or "0"
	local override = input.dangerous_override == true and "1" or "0"
	local allow_legacy = input.allow_legacy == true and "1" or "0"
	local ok, output, status
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then return write_json({ error = connection_error }, 400) end
		local operation_id = uuid()
		ok, output = remote_call("restore", { path, operation_id, selected, packages, direct, override, allow_legacy }, connection, operation_id); status = ok and 200 or 422
	else
		local arguments = { path, "--categories", selected }
		if packages ~= "" then table.insert(arguments, "--packages"); table.insert(arguments, packages) end
		if direct == "1" then table.insert(arguments, "--direct-custom-files") end
		if override == "1" then table.insert(arguments, "--dangerous-device-override") end
		if allow_legacy == "1" then table.insert(arguments, "--allow-legacy") end
		ok, output = invoke(CLI, "restore", arguments); status = ok and 200 or 500
	end
	if not ok then return write_json({ error = trim(output) ~= "" and trim(output) or "Restore failed." }, status) end
	write_json({ ok = true, log = output }, 200)
end

function action_profile_update()
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	local name, notes = safe_text(input.name, 100), safe_text(input.notes, 1000)
	if not name or name == "" or not notes then return write_json({ error = "Invalid profile name or notes." }, 400) end
	local sidecar = profile_sidecar(input.id)
	if not fs.writefile(sidecar, jsonc.stringify({ name = name, notes = notes })) then return write_json({ error = "Could not update profile metadata." }, 500) end
	fs.chmod(sidecar, "0600")
	write_json({ ok = true }, 200)
end

function action_profile_delete()
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	fs.unlink(path); fs.unlink(profile_sidecar(input.id))
	write_json({ ok = true }, 200)
end

function action_download(profile_id)
	local path = profile_archive(profile_id)
	if not path or not fs.access(path) then http.status(404, "Not Found"); return http.write("Profile not found") end
	http.header("Content-Disposition", "attachment; filename=glinet-crossmodel-" .. profile_id .. ".tar.gz")
	http.prepare_content("application/gzip")
	http.writefile(path)
end
