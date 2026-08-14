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
local LOG_FILE = TMP_DIR .. "/gcm.log"
local LOG_TAG = "glinet-crossmodel"
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

local log_rank = { error = 0, warn = 1, warning = 1, info = 2, debug = 3, trace = 4 }
local sensitive_log_name = {
	password = true, passwd = true, secret = true, token = true, authkey = true,
	private_key = true, privatekey = true, preshared_key = true, key = true,
	cert = true, ca = true, tls_auth = true, tls_crypt = true, csrf = true,
	session = true
}

local function log_clean(value)
	value = tostring(value == nil and "" or value):gsub("[%z\1-\31\127]", " "):gsub("\\", "\\\\"):gsub('"', '\\"')
	return value:sub(1, 1024)
end

local function log_name_sensitive(name)
	name = tostring(name or ""):lower()
	if sensitive_log_name[name] then return true end
	return name:find("password", 1, true) or name:find("passwd", 1, true) or name:find("secret", 1, true)
		or name:find("token", 1, true) or name:find("private_key", 1, true) or name:find("privatekey", 1, true)
		or name:find("preshared_key", 1, true) or name:find("authkey", 1, true)
		or name:find("csrf", 1, true) or name:find("session", 1, true)
		or name:match("^key_") or name:match("_key$") or name:match("^cert_") or name:match("_cert$")
		or name:find("certificate", 1, true) or name:match("^ca_") or name:match("_ca$")
end

local function configured_log_level()
	local level = tostring(uci:get("glinet_crossmodel", "logging", "level") or "info"):lower()
	return log_rank[level] and level or "info"
end

local function diagnostic_log(level, operation_id, component, fields, message)
	level = tostring(level or "INFO"):upper()
	if (log_rank[level:lower()] or 2) > (log_rank[configured_log_level()] or 2) then return end
	local log_scope = fields and fields.scope or "local"
	local parts = { os.date("!%Y-%m-%dT%H:%M:%SZ"), level, "op=" .. log_clean(operation_id or "none"), "component=" .. log_clean(component or "luci"), "scope=" .. log_clean(log_scope) }
	for name, value in pairs(fields or {}) do
		if name ~= "scope" then
		if log_name_sensitive(name) then value = "[REDACTED]" end
		table.insert(parts, tostring(name) .. '="' .. log_clean(value) .. '"')
		end
	end
	if message then table.insert(parts, 'msg="' .. log_clean(message) .. '"') end
	local line = table.concat(parts, " ")
	if uci:get("glinet_crossmodel", "logging", "file_log") ~= "0" then
		command("mkdir -p " .. quote(TMP_DIR) .. " && chmod 700 " .. quote(TMP_DIR))
		local max_kb = tonumber(uci:get("glinet_crossmodel", "logging", "max_log_kb")) or 512
		if max_kb < 64 then max_kb = 64 end
		local stat = fs.stat(LOG_FILE)
		if stat and (stat.size or 0) >= max_kb * 1024 then fs.unlink(LOG_FILE .. ".1"); fs.rename(LOG_FILE, LOG_FILE .. ".1") end
		local file = io.open(LOG_FILE, "a")
		if file then file:write(line, "\n"); file:close(); fs.chmod(LOG_FILE, "0600") end
	end
	if uci:get("glinet_crossmodel", "logging", "syslog") ~= "0" then
		local priority = level == "ERROR" and "daemon.err" or (level == "WARN" and "daemon.warning" or ((level == "DEBUG" or level == "TRACE") and "daemon.debug" or "daemon.info"))
		command("logger -t " .. quote(LOG_TAG) .. " -p " .. quote(priority) .. " -- " .. quote(line) .. " >/dev/null 2>&1")
	end
end

local current_request

local function operation_uuid()
	local value = trim(fs.readfile("/proc/sys/kernel/random/uuid") or "")
	if value:match("^[a-f0-9%-]+$") then return value end
	return string.format("%08x-%04x-%04x-%04x-%08x", os.time(), math.random(0, 65535), math.random(0, 65535), math.random(0, 65535), math.random(0, 0x7fffffff))
end

local function begin_request(action, operation_id, fields)
	operation_id = tostring(operation_id or "")
	if #operation_id < 8 or #operation_id > 64 or not operation_id:match("^[A-Fa-f0-9%-]+$") then operation_id = nil end
	operation_id = operation_id or operation_uuid()
	current_request = { action = action, operation_id = operation_id, started = os.time(), finished = false }
	fields = fields or {}; fields.action = action; fields.stage = "request"
	diagnostic_log("INFO", operation_id, "luci", fields, "LuCI API request received")
	return operation_id
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
	status = status or 200
	if type(value) == "table" and current_request then value.operation_id = value.operation_id or current_request.operation_id end
	if current_request and not current_request.finished then
		current_request.finished = true
		diagnostic_log(status >= 500 and "ERROR" or (status >= 400 and "WARN" or "INFO"), current_request.operation_id, "luci", { action = current_request.action, stage = status >= 400 and "backend" or "response", status = status, duration_seconds = os.time() - current_request.started }, "LuCI API request completed")
	end
	if status then http.status(status, status == 200 and "OK" or "Error") end
	http.prepare_content("application/json")
	http.write(jsonc.stringify(value))
end

local function stream_open_file(file)
	local ok, stream_error = pcall(function()
		while true do
			local chunk = file:read(32 * 1024)
			if not chunk then break end
			http.write(chunk)
		end
	end)
	file:close()
	return ok, stream_error
end

local function read_json_request()
	if current_request and current_request.request_json_read then return current_request.request_json end
	local value = jsonc.parse(http.content() or "") or {}
	if current_request then current_request.request_json = value; current_request.request_json_read = true end
	return value
end

local function require_csrf(supplied)
	if http.getenv("REQUEST_METHOD") ~= "POST" then write_json({ error = "POST required." }, 405); return nil end
	if supplied == nil then
		local input = read_json_request()
		supplied = input.token
		input.token = nil
	end
	supplied = tostring(supplied or "")
	local expected = tostring(dispatcher.context.authtoken or "")
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

local function uuid() return operation_uuid() end

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
	diagnostic_log("INFO", operation_id, "luci", { action = action, stage = "remote-dispatch", scope = "remote", host = connection.host, port = connection.port, user = connection.user, auth = connection.auth }, "Remote backend dispatch started")
	if connection.saved and connection.saved.verified_fingerprint and connection.saved.verified_fingerprint ~= "" then
		local current = known_host_fingerprint(connection)
		if current == "" then diagnostic_log("ERROR", operation_id, "ssh", { action = action, stage = "known-hosts", scope = "remote", host = connection.host, reason = "known-hosts-record-missing" }, "Saved router trust check failed"); return false, "The saved router's known_hosts record is missing. Delete and deliberately re-add the router definition before operating on it." end
		if current ~= connection.saved.verified_fingerprint then diagnostic_log("ERROR", operation_id, "ssh", { action = action, stage = "fingerprint", scope = "remote", host = connection.host, reason = "changed-host-key" }, "Verified SSH host fingerprint differs from saved router"); return false, "Verified SSH host fingerprint differs from the saved router definition." end
		diagnostic_log("DEBUG", operation_id, "ssh", { action = action, stage = "fingerprint", scope = "remote", host = connection.host, result = "verified" }, "Saved SSH fingerprint verified")
	end
	local credential = credential_for(operation_id, connection)
	if not credential then return false, "Could not create a temporary SSH credential file." end
	for _, value in ipairs({ connection.host, connection.port, connection.user, connection.auth, credential }) do table.insert(arguments, value) end
	local environment = "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=remote GCM_LOG_LEVEL=" .. quote(configured_log_level())
	local ok, output, code = invoke(REMOTE, action, arguments, environment)
	cleanup_credential(connection, credential)
	diagnostic_log(ok and "INFO" or "ERROR", operation_id, "luci", { action = action, stage = "remote-backend", scope = "remote", host = connection.host, exit_code = code or 0, result = ok and "success" or "failed" }, "Remote backend dispatch completed")
	return ok, output, code
end

known_host_fingerprint = function(connection)
	local lookup = connection.port == "22" and connection.host or ("[" .. connection.host .. "]:" .. connection.port)
	local ok, output = command("ssh-keygen -F " .. quote(lookup) .. " -f " .. quote(KNOWN_HOSTS) .. " 2>/dev/null | sed '/^#/d' | ssh-keygen -lf - 2>/dev/null")
	if not ok then return "" end
	return trim(output:match("SHA256:[A-Za-z0-9+/=]+") or "")
end

local function detect_connection(connection, operation_id)
	operation_id = operation_id or uuid()
	local ok, output = remote_call("facts", {}, connection, operation_id)
	if not ok then return nil, trim(output) ~= "" and trim(output) or "SSH connection failed." end
	local facts = jsonc.parse(output)
	if not facts then return nil, "Remote facts response was invalid." end
	local fingerprint = known_host_fingerprint(connection)
	diagnostic_log(fingerprint ~= "" and "INFO" or "WARN", operation_id, "ssh", { action = "facts", stage = "fingerprint", scope = "remote", host = connection.host, fingerprint = fingerprint ~= "" and fingerprint or "unavailable", result = fingerprint ~= "" and "verified" or "unavailable" }, "SSH host fingerprint inspection completed")
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

local function inspect_archive(path, operation_id)
	operation_id = operation_id or uuid()
	local environment = "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=local GCM_COMPONENT=archive GCM_LOG_LEVEL=" .. quote(configured_log_level())
	local ok, output = invoke(CLI, "inspect", { path }, environment)
	if not ok then return nil, trim(output) end
	return jsonc.parse(output), nil
end

local function profile_list()
	ensure_directories()
	local result = {}
	for path in fs.glob(PROFILE_DIR .. "/*.tar.gz") do
		local profile_id = path:match("/([A-Fa-f0-9%-]+)%.tar%.gz$")
		if profile_id then
			local manifest = inspect_archive(path, current_request and current_request.operation_id or nil)
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
	diagnostic_log("DEBUG", current_request and current_request.operation_id or "none", "storage", { action = "prune", stage = "evaluate", profiles = #profiles, total_bytes = total, max_profiles = maximum_count, max_bytes = maximum_bytes, auto_prune = auto_prune }, "Profile storage limits evaluated")
	while (#profiles > maximum_count or total > maximum_bytes) and auto_prune and #profiles > 1 do
		local prune_index = #profiles
		while prune_index > 0 and profiles[prune_index].id == new_id do prune_index = prune_index - 1 end
		if prune_index == 0 then break end
		local oldest = table.remove(profiles, prune_index)
		fs.unlink(profile_archive(oldest.id)); fs.unlink(profile_sidecar(oldest.id)); total = total - oldest.size
		diagnostic_log("INFO", current_request and current_request.operation_id or "none", "storage", { action = "prune", stage = "remove", profile_uuid = oldest.id, profile_size = oldest.size, result = "removed" }, "Oldest profile pruned")
	end
	if #profiles > maximum_count or total > maximum_bytes then
		fs.unlink(profile_archive(new_id)); fs.unlink(profile_sidecar(new_id))
		diagnostic_log("ERROR", current_request and current_request.operation_id or "none", "storage", { action = "retain", stage = "limit", profile_uuid = new_id, result = "failed", reason = "storage-limit-reached" }, "New profile removed because bounded storage limit was exceeded")
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
	local supplied = http.formvalue("token", true)
	if stream then stream:close() end
	if not upload_seen or bytes == 0 or bytes > MAX_UPLOAD or not fs.access(destination) then diagnostic_log("WARN", current_request and current_request.operation_id or "none", "archive", { action = "import", stage = "upload", bytes = bytes, result = "failed", reason = "missing-empty-or-too-large" }, "Archive upload rejected"); fs.unlink(destination); return nil, "Upload an archive smaller than 128 MB.", supplied end
	fs.chmod(destination, "0600")
	return true, nil, supplied, bytes
end

local function validate_received_archive(destination, bytes)
	local ok = command("tar -tzf " .. quote(destination) .. " >/dev/null")
	if not ok then diagnostic_log("ERROR", current_request and current_request.operation_id or "none", "archive", { action = "import", stage = "archive-format", bytes = bytes, result = "failed", reason = "unreadable-tar" }, "Uploaded archive is unreadable"); fs.unlink(destination); return nil, "Uploaded archive is unreadable." end
	diagnostic_log("INFO", current_request and current_request.operation_id or "none", "archive", { action = "import", stage = "upload", bytes = bytes, result = "success" }, "Archive upload completed")
	return true
end

function index()
	local system = entry({ "admin", "system" }, firstchild(), _("System"), 60)
	system.dependent = false
	entry({ "admin", "system", "glinet-crossmodel" }, call("action_index"), _("Backup & Recovery"), 92).dependent = false
	for _, route in ipairs({ "facts", "routers", "router-save", "router-delete", "test", "profiles", "settings", "settings-save", "create", "import", "inspect", "validate", "packages", "restore", "profile-update", "profile-delete", "diagnostics", "logging-save", "logs-clear" }) do
		entry({ "admin", "system", "glinet-crossmodel", "api", route }, call("action_" .. route:gsub("%-", "_"))).leaf = true
	end
	entry({ "admin", "system", "glinet-crossmodel", "download" }, call("action_download")).leaf = true
	entry({ "admin", "system", "glinet-crossmodel", "diagnostics-download" }, call("action_diagnostics_download")).leaf = true
end

function action_index() luci.template.render("glinet_crossmodel/index") end

function action_facts()
	local operation_id = begin_request("facts")
	local ok, output = invoke(CLI, "facts", {}, "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=local GCM_COMPONENT=facts GCM_LOG_LEVEL=" .. quote(configured_log_level()))
	if not ok then return write_json({ error = trim(output) }, 500) end
	write_json(jsonc.parse(output) or { error = "Invalid local facts." }, 200)
end

function action_routers() begin_request("routers"); write_json({ routers = load_routers() }, 200) end

function action_router_save()
	local operation_id = begin_request("router-save")
	if not require_csrf() then return end
	ensure_directories()
	local input = read_json_request()
	local friendly_name = safe_text(input.friendly_name, 80)
	if not friendly_name or friendly_name == "" then return write_json({ error = "Enter a friendly router name." }, 400) end
	local connection, connection_error = normalize_connection(input.connection)
	if not connection then return write_json({ error = connection_error }, 400) end
	diagnostic_log("INFO", operation_id, "luci", { action = "router-save", stage = "validate", scope = "remote", host = connection.host, port = connection.port, user = connection.user, auth = connection.auth }, "Router definition validated; secret-bearing request fields omitted")
	local facts, detect_error = detect_connection(connection, operation_id)
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
	local operation_id = begin_request("router-delete")
	if not require_csrf() then return end
	local input, out = read_json_request(), {}
	local router_id = safe_id(input.id)
	if not router_id then return write_json({ error = "Invalid router ID." }, 400) end
	diagnostic_log("INFO", operation_id, "luci", { action = "router-delete", stage = "delete", router_id = router_id }, "Saved router deletion started")
	for _, router in ipairs(load_routers()) do if router.id ~= router_id then table.insert(out, router) end end
	if not save_routers(out) then return write_json({ error = "Could not update router inventory." }, 500) end
	write_json({ ok = true }, 200)
end

function action_test()
	local operation_id = begin_request("test")
	if not require_csrf() then return end
	ensure_directories()
	local input = read_json_request()
	if input.scope ~= "remote" then
		local ok, output = invoke(CLI, "facts", {}, "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=local GCM_COMPONENT=facts GCM_LOG_LEVEL=" .. quote(configured_log_level()))
		if not ok then return write_json({ error = trim(output) }, 500) end
		return write_json(jsonc.parse(output) or { error = "Invalid local facts." }, 200)
	end
	local connection, connection_error = normalize_connection(input.connection)
	if not connection then return write_json({ error = connection_error }, 400) end
	local facts, detect_error = detect_connection(connection, operation_id)
	if not facts then return write_json({ error = detect_error }, 422) end
	if not update_saved_detection(connection, facts) then return write_json({ error = "Router was detected, but its inventory metadata could not be updated." }, 500) end
	write_json(facts, 200)
end

function action_profiles() begin_request("profiles"); write_json({ profiles = profile_list() }, 200) end

function action_settings()
	begin_request("settings")
	write_json({ max_profiles = tonumber(uci:get("glinet_crossmodel", "storage", "max_profiles")) or 20, max_storage_mb = tonumber(uci:get("glinet_crossmodel", "storage", "max_storage_mb")) or 128, max_rollbacks = tonumber(uci:get("glinet_crossmodel", "storage", "max_rollbacks")) or 5, auto_prune = uci:get("glinet_crossmodel", "storage", "auto_prune") == "1" }, 200)
end

function action_settings_save()
	begin_request("settings-save")
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
	local operation_id = begin_request("create")
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
	local category_count = 0; for _ in selected:gmatch("[^,]+") do category_count = category_count + 1 end
	diagnostic_log("INFO", operation_id, "luci", { action = "create", stage = "dispatch", scope = input.scope == "remote" and "remote" or "local", strategy = strategy, selected_category_count = category_count }, "Backup request validated")
	local scripts, scripts_error = parse_paths(input.scripts, 40)
	if not scripts then return write_json({ error = scripts_error }, 400) end
	local binaries, binaries_error = parse_paths(input.binaries, 20)
	if not binaries then return write_json({ error = binaries_error }, 400) end
	local scripts_file, binaries_file = write_list(operation_id, "scripts", scripts), write_list(operation_id, "binaries", binaries)
	if not scripts_file or not binaries_file then fs.unlink(scripts_file); fs.unlink(binaries_file); return write_json({ error = "Could not create temporary custom-file lists." }, 500) end
	local output = profile_archive(operation_id)
	local ok, log
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then fs.unlink(scripts_file); fs.unlink(binaries_file); return write_json({ error = connection_error }, 400) end
		ok, log = remote_call("create", { output, strategy, operation_id, name, notes, selected, scripts_file, binaries_file }, connection, operation_id)
	else
		ok, log = invoke(CLI, "create", { "--output", output, "--strategy", strategy, "--id", operation_id, "--name", name, "--notes", notes, "--categories", selected, "--scripts-list", scripts_file, "--binaries-list", binaries_file }, "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=local GCM_LOG_LEVEL=" .. quote(configured_log_level()))
	end
	fs.unlink(scripts_file); fs.unlink(binaries_file)
	if not ok or not fs.access(output) then fs.unlink(output); return write_json({ error = trim(log) ~= "" and trim(log) or "Backup failed." }, input.scope == "remote" and 422 or 500) end
	fs.chmod(output, "0600")
	local retained, retention_error = enforce_storage(operation_id)
	if not retained then return write_json({ error = retention_error }, 507) end
	write_json({ ok = true, id = operation_id, log = log, download = dispatcher.build_url("admin", "system", "glinet-crossmodel", "download", operation_id) }, 200)
end

function action_import()
	local operation_id = begin_request("import")
	if http.getenv("REQUEST_METHOD") ~= "POST" then return write_json({ error = "POST required." }, 405) end
	ensure_directories()
	local temporary = TMP_DIR .. "/import-" .. operation_id .. ".tar.gz"
	diagnostic_log("INFO", operation_id, "luci", { action = "import", stage = "upload", destination = temporary }, "Profile import started")
	local received, receive_error, supplied, bytes = receive_archive(temporary)
	if not require_csrf(supplied) then fs.unlink(temporary); return end
	if not received then return write_json({ error = receive_error }, 400) end
	local archive_valid, archive_error = validate_received_archive(temporary, bytes)
	if not archive_valid then return write_json({ error = archive_error }, 400) end
	local manifest, inspect_error = inspect_archive(temporary, operation_id)
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
	local operation_id = begin_request("inspect")
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	local manifest, inspect_error = inspect_archive(path, operation_id)
	if not manifest then return write_json({ error = inspect_error }, 400) end
	write_json({ manifest = manifest }, 200)
end

local function target_call(action, path, input, extra, operation_id)
	local selected = selected_csv(input.categories)
	if selected == "" then return false, "Select at least one category.", 400 end
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then return false, connection_error, 400 end
		local arguments = { path, operation_id, selected }
		for _, value in ipairs(extra or {}) do table.insert(arguments, value) end
		local ok, output = remote_call(action, arguments, connection, operation_id)
		return ok, output, ok and 200 or 422
	end
	local arguments = { path }
	if action == "validate" then table.insert(arguments, "--categories"); table.insert(arguments, selected); if extra and extra[1] == "1" then table.insert(arguments, "--dangerous-device-override") end end
	local ok, output = invoke(CLI, action, arguments, "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=local GCM_LOG_LEVEL=" .. quote(configured_log_level()))
	return ok, output, ok and 200 or 500
end

function action_validate()
	local operation_id = begin_request("validate")
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	local override = input.dangerous_override == true and "1" or "0"
	diagnostic_log("INFO", operation_id, "luci", { action = "validate", stage = "dispatch", scope = input.scope == "remote" and "remote" or "local", profile_id = input.id, dangerous_override = override }, "Validation backend dispatch started")
	local ok, output, status = target_call("validate", path, input, { override }, operation_id)
	if not ok then return write_json({ error = trim(output) }, status or 500) end
	local plan = jsonc.parse(output)
	if not plan then return write_json({ error = "Validation returned invalid data." }, 500) end
	write_json(plan, 200)
end

function action_packages()
	local operation_id = begin_request("packages")
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	diagnostic_log("INFO", operation_id, "luci", { action = "packages", stage = "dispatch", scope = input.scope == "remote" and "remote" or "local", profile_id = input.id }, "Package Review backend dispatch started")
	local ok, output, status
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then return write_json({ error = connection_error }, 400) end
		ok, output = remote_call("packages", { path, operation_id }, connection, operation_id); status = ok and 200 or 422
	else ok, output = invoke(CLI, "packages", { path }, "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=local GCM_LOG_LEVEL=" .. quote(configured_log_level())); status = ok and 200 or 500 end
	if not ok then return write_json({ error = trim(output) }, status) end
	write_json(jsonc.parse(output) or { error = "Package Review returned invalid data." }, 200)
end

function action_restore()
	local operation_id = begin_request("restore")
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
	local category_count = 0; for _ in selected:gmatch("[^,]+") do category_count = category_count + 1 end
	diagnostic_log("INFO", operation_id, "luci", { action = "restore", stage = "dispatch", scope = input.scope == "remote" and "remote" or "local", profile_id = input.id, selected_category_count = category_count, selected_package_count = packages == "" and 0 or select(2, packages:gsub(",", ",")) + 1, direct_custom_files = direct, dangerous_override = override, allow_legacy = allow_legacy }, "Restore request validated; request body and secret-bearing fields omitted")
	local ok, output, status
	if input.scope == "remote" then
		local connection, connection_error = normalize_connection(input.connection)
		if not connection then return write_json({ error = connection_error }, 400) end
		ok, output = remote_call("restore", { path, operation_id, selected, packages, direct, override, allow_legacy }, connection, operation_id); status = ok and 200 or 422
	else
		local arguments = { path, "--categories", selected }
		if packages ~= "" then table.insert(arguments, "--packages"); table.insert(arguments, packages) end
		if direct == "1" then table.insert(arguments, "--direct-custom-files") end
		if override == "1" then table.insert(arguments, "--dangerous-device-override") end
		if allow_legacy == "1" then table.insert(arguments, "--allow-legacy") end
		ok, output = invoke(CLI, "restore", arguments, "GCM_OP_ID=" .. quote(operation_id) .. " GCM_SCOPE=local GCM_LOG_LEVEL=" .. quote(configured_log_level())); status = ok and 200 or 500
	end
	if not ok then return write_json({ error = trim(output) ~= "" and trim(output) or "Restore failed." }, status) end
	write_json({ ok = true, log = output }, 200)
end

function action_profile_update()
	begin_request("profile-update")
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
	begin_request("profile-delete")
	if not require_csrf() then return end
	local input = read_json_request()
	local path, profile_error = require_profile(input)
	if not path then return write_json({ error = profile_error }, 404) end
	if not fs.unlink(path) then return write_json({ error = "Could not delete the profile archive." }, 500) end
	local sidecar = profile_sidecar(input.id)
	if fs.access(sidecar) and not fs.unlink(sidecar) then return write_json({ error = "Profile archive was deleted, but its metadata sidecar could not be removed." }, 500) end
	diagnostic_log("INFO", current_request.operation_id, "storage", { action = "profile-delete", stage = "delete", profile_uuid = input.id, result = "success" }, "Profile archive and sidecar deleted")
	write_json({ ok = true }, 200)
end

function action_diagnostics()
	begin_request("diagnostics")
	local ok, entries = command("tail -n 250 " .. quote(LOG_FILE) .. " 2>/dev/null")
	if not ok then entries = "" end
	write_json({ level = configured_log_level(), syslog = uci:get("glinet_crossmodel", "logging", "syslog") ~= "0", file_log = uci:get("glinet_crossmodel", "logging", "file_log") ~= "0", max_log_kb = tonumber(uci:get("glinet_crossmodel", "logging", "max_log_kb")) or 512, entries = entries }, 200)
end

function action_logging_save()
	local operation_id = begin_request("logging-save")
	if not require_csrf() then return end
	local input = read_json_request()
	local level = tostring(input.level or ""):lower()
	if level ~= "info" and level ~= "debug" and level ~= "trace" then return write_json({ error = "Logging level must be INFO, DEBUG, or TRACE." }, 400) end
	if not uci:get("glinet_crossmodel", "logging") then uci:section("glinet_crossmodel", "logging", "logging", {}) end
	uci:set("glinet_crossmodel", "logging", "level", level)
	if not uci:commit("glinet_crossmodel") then return write_json({ error = "Could not save logging settings." }, 500) end
	diagnostic_log("INFO", operation_id, "luci", { action = "logging-save", stage = "commit", level = level, result = "success" }, "Diagnostic log level changed")
	write_json({ ok = true, level = level }, 200)
end

function action_logs_clear()
	local operation_id = begin_request("logs-clear")
	if not require_csrf() then return end
	fs.unlink(LOG_FILE .. ".1")
	if not fs.writefile(LOG_FILE, "") then return write_json({ error = "Could not clear the diagnostic log." }, 500) end
	fs.chmod(LOG_FILE, "0600")
	diagnostic_log("INFO", operation_id, "luci", { action = "logs-clear", stage = "complete", result = "success" }, "Diagnostic log cleared")
	write_json({ ok = true }, 200)
end

function action_download(profile_id)
	local operation_id = begin_request("profile-download")
	local path = profile_archive(profile_id)
	if not path or not fs.access(path) then diagnostic_log("WARN", operation_id, "luci", { action = "profile-download", stage = "locate", status = 404, profile_uuid = profile_id, result = "failed" }, "Profile download not found"); http.status(404, "Not Found"); return http.write("Profile not found") end
	local file = io.open(path, "rb")
	if not file then diagnostic_log("ERROR", operation_id, "luci", { action = "profile-download", stage = "open", status = 500, profile_uuid = profile_id, result = "failed" }, "Profile archive could not be opened"); http.status(500, "Internal Server Error"); return http.write("Profile download could not be opened") end
	http.header("Content-Disposition", "attachment; filename=glinet-crossmodel-" .. profile_id .. ".tar.gz")
	http.prepare_content("application/gzip")
	diagnostic_log("INFO", operation_id, "luci", { action = "profile-download", stage = "stream-start", status = 200, profile_uuid = profile_id, result = "started" }, "Profile archive download started")
	local ok = stream_open_file(file)
	if not ok then diagnostic_log("ERROR", operation_id, "luci", { action = "profile-download", stage = "stream", status = 500, profile_uuid = profile_id, result = "failed" }, "Profile archive download stream failed"); return end
	diagnostic_log("INFO", operation_id, "luci", { action = "profile-download", stage = "complete", status = 200, profile_uuid = profile_id, result = "success" }, "Profile archive download completed")
end

function action_diagnostics_download()
	local operation_id = begin_request("diagnostics-download")
	if not fs.access(LOG_FILE) then http.status(404, "Not Found"); diagnostic_log("WARN", operation_id, "luci", { action = "diagnostics-download", stage = "locate", status = 404, result = "failed" }, "Diagnostic log not found"); return http.write("Diagnostic log not found") end
	local file = io.open(LOG_FILE, "rb")
	if not file then diagnostic_log("ERROR", operation_id, "luci", { action = "diagnostics-download", stage = "open", status = 500, result = "failed" }, "Diagnostic log could not be opened"); http.status(500, "Internal Server Error"); return http.write("Diagnostic log could not be opened") end
	http.header("Content-Disposition", "attachment; filename=glinet-crossmodel-diagnostics.log")
	http.prepare_content("text/plain")
	diagnostic_log("INFO", operation_id, "luci", { action = "diagnostics-download", stage = "stream-start", status = 200, result = "started" }, "Diagnostic log download started")
	local ok = stream_open_file(file)
	if not ok then diagnostic_log("ERROR", operation_id, "luci", { action = "diagnostics-download", stage = "stream", status = 500, result = "failed" }, "Diagnostic log download stream failed"); return end
	diagnostic_log("INFO", operation_id, "luci", { action = "diagnostics-download", stage = "complete", status = 200, result = "success" }, "Diagnostic log download completed")
end
