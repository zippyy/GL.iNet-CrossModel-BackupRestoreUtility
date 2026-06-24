module("luci.controller.glinet_crossmodel", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"
local dispatcher = require "luci.dispatcher"

local APP = "/usr/libexec/glinet-crossmodel-backup"
local REMOTE_APP = "/usr/libexec/glinet-crossmodel-remote"
local PROFILE_DIR = "/root/glinet-crossmodel/profiles"
local TMP_DIR = "/tmp/glinet-crossmodel"
local categories = {
	"network", "wireless", "vpn", "firewall", "adguard",
	"ddns", "system", "packages", "scripts", "binaries"
}
local valid_category = {}
for _, name in ipairs(categories) do valid_category[name] = true end

local function quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\\"'\\\"'") .. "'"
end

local function command(commandline)
	local pipe = io.popen(commandline .. " 2>&1")
	local output = pipe:read("*a") or ""
	local ok, _, code = pipe:close()
	if ok == true or ok == 0 then return true, output end
	return false, output, code
end

local function ensure_directories()
	command("mkdir -p " .. quote(PROFILE_DIR) .. " " .. quote(TMP_DIR))
	fs.chmod(PROFILE_DIR, 448)
	fs.chmod(TMP_DIR, 448)
end

local function write_json(value, status)
	if status then http.status(status, status == 200 and "OK" or "Error") end
	http.prepare_content("application/json")
	http.write(jsonc.stringify(value))
end

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function profile_id()
	local value = trim(fs.readfile("/proc/sys/kernel/random/uuid") or "")
	if value:match("^[a-f0-9%-]+$") then return value end
	return string.format("%x-%x", os.time(), math.random(0, 0x7fffffff))
end

local function safe_profile_id(value)
	value = tostring(value or "")
	return value:match("^[a-f0-9%-]+$") and value or nil
end

local function valid_path(value)
	value = trim(value)
	if not value:match("^/[A-Za-z0-9%._/%-]+$") then return nil end
	if value:find("//", 1, true) or value:find("/../", 1, true) or value:find("/./", 1, true) or value:sub(-3) == "/.." then return nil end
	return value
end

local function parse_paths(value, max_count)
	local out, seen = {}, {}
	for line in (tostring(value or "") .. "\n"):gmatch("(.-)\n") do
		line = trim(line)
		if #line > 0 then
			local safe = valid_path(line)
			if not safe then return nil, "Invalid custom path: " .. line end
			if not seen[safe] then
				seen[safe] = true
				table.insert(out, safe)
			end
		end
	end
	if #out > max_count then return nil, "Too many paths selected (maximum " .. max_count .. ")." end
	return out
end

local function write_list(id, name, values)
	local path = TMP_DIR .. "/" .. id .. "-" .. name .. ".list"
	local file = io.open(path, "w")
	if not file then return nil, "Could not create temporary path list." end
	for _, value in ipairs(values) do file:write(value, "\n") end
	file:close()
	fs.chmod(path, 384)
	return path
end

local function selected_csv(input)
	local selected = {}
	for _, name in ipairs(categories) do
		if type(input) == "table" and (input[name] == true or input[name] == 1 or input[name] == "1") then
			table.insert(selected, name)
		end
	end
	return table.concat(selected, ",")
end

local function selected_from_csv(value)
	local selected, seen = {}, {}
	for name in tostring(value or ""):gmatch("[^,]+") do
		if valid_category[name] and not seen[name] then
			seen[name] = true
			table.insert(selected, name)
		end
	end
	return table.concat(selected, ",")
end

local function parse_profile_metadata(archive)
	local ok, output = command("tar -xOzf " .. quote(archive) .. " profile/meta.json 2>/dev/null")
	if not ok then return {} end
	return jsonc.parse(output) or {}
end

local function profiles()
	ensure_directories()
	local out = {}
	for item in fs.glob(PROFILE_DIR .. "/*.tar.gz") do
		local id = item:match("/([a-f0-9%-]+)%.tar%.gz$")
		if id then
			local stat = fs.stat(item) or {}
			table.insert(out, {
				id = id,
				size = stat.size or 0,
				mtime = stat.mtime or 0,
				metadata = parse_profile_metadata(item)
			})
		end
	end
	table.sort(out, function(a, b) return a.mtime > b.mtime end)
	return out
end

local function remote_connection(input)
	input = input or {}
	local host = trim(input.host)
	local user = trim(input.user)
	local password = tostring(input.password or "")
	local port = tonumber(input.port)
	if #host < 1 or #host > 253 or not host:match("^[A-Za-z0-9][A-Za-z0-9%._:%-]*$") then
		return nil, "Enter a valid LAN router hostname or IP address."
	end
	if not port or port % 1 ~= 0 or port < 1 or port > 65535 then
		return nil, "SSH port must be between 1 and 65535."
	end
	if #user < 1 or #user > 64 or not user:match("^[A-Za-z0-9][A-Za-z0-9%._%-]*$") then
		return nil, "Enter a valid SSH username."
	end
	if #password < 1 or #password > 512 or password:find("[%c]") then
		return nil, "Enter a valid SSH password."
	end
	return { host = host, port = tostring(port), user = user, password = password }
end

local function write_secret(id, password)
	local path = TMP_DIR .. "/sshpass-" .. id
	local file = io.open(path, "w")
	if not file then return nil, "Could not create temporary SSH credential file." end
	file:write(password, "\n")
	file:close()
	fs.chmod(path, 384)
	return path
end

local function remote_command(action, arguments)
	local parts = { quote(REMOTE_APP), action }
	for _, argument in ipairs(arguments) do table.insert(parts, quote(argument)) end
	return command(table.concat(parts, " "))
end

local function make_backup_inputs(input)
	local selected = selected_csv(input.categories)
	if selected == "" then return nil, "Select at least one backup category." end
	local scripts, script_error = parse_paths(input.scripts, 20)
	if not scripts then return nil, script_error end
	local binaries, binary_error = parse_paths(input.binaries, 10)
	if not binaries then return nil, binary_error end
	local id = profile_id()
	local scripts_file, scripts_error = write_list(id, "scripts", scripts)
	if not scripts_file then return nil, scripts_error end
	local binaries_file, binaries_error = write_list(id, "binaries", binaries)
	if not binaries_file then fs.unlink(scripts_file); return nil, binaries_error end
	return { id = id, selected = selected, scripts_file = scripts_file, binaries_file = binaries_file }
end

local function cleanup_backup_inputs(input)
	if input then
		if input.scripts_file then fs.unlink(input.scripts_file) end
		if input.binaries_file then fs.unlink(input.binaries_file) end
	end
end

function index()
	entry({"admin", "services", "glinet-crossmodel"}, call("action_index"), _("GL.iNet Cross-Model Backup"), 92).dependent = false
	entry({"admin", "services", "glinet-crossmodel", "api", "facts"}, call("action_facts")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "api", "remote-facts"}, call("action_remote_facts")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "api", "profiles"}, call("action_profiles")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "api", "create"}, call("action_create")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "api", "remote-create"}, call("action_remote_create")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "api", "restore"}, call("action_restore")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "download"}, call("action_download")).leaf = true
end

function action_index()
	luci.template.render("glinet_crossmodel/index")
end

function action_facts()
	local ok, output = command(quote(APP) .. " facts")
	if not ok then return write_json({ error = trim(output) }, 500) end
	write_json(jsonc.parse(output) or { raw = output }, 200)
end

function action_remote_facts()
	ensure_directories()
	local input = jsonc.parse(http.content() or "") or {}
	local connection, connection_error = remote_connection(input.connection)
	if not connection then return write_json({ error = connection_error }, 400) end
	local id = profile_id()
	local passfile, password_error = write_secret(id, connection.password)
	if not passfile then return write_json({ error = password_error }, 500) end
	local ok, output = remote_command("facts", { connection.host, connection.port, connection.user, passfile })
	fs.unlink(passfile)
	if not ok then return write_json({ error = trim(output) ~= "" and trim(output) or "Could not connect to the LAN router over SSH." }, 422) end
	write_json(jsonc.parse(output) or { raw = output }, 200)
end

function action_profiles()
	write_json({ profiles = profiles() }, 200)
end

function action_create()
	ensure_directories()
	local input = jsonc.parse(http.content() or "") or {}
	local backup, input_error = make_backup_inputs(input)
	if not backup then return write_json({ error = input_error }, 400) end
	local output = PROFILE_DIR .. "/" .. backup.id .. ".tar.gz"
	local ok, log = command(quote(APP) .. " create " .. quote(output) .. " " .. quote(backup.id) .. " " .. quote(backup.selected) .. " " .. quote(backup.scripts_file) .. " " .. quote(backup.binaries_file))
	cleanup_backup_inputs(backup)
	if not ok or not fs.access(output) then
		fs.unlink(output)
		return write_json({ error = trim(log) ~= "" and trim(log) or "Could not create portable profile." }, 500)
	end
	fs.chmod(output, 384)
	write_json({ ok = true, id = backup.id, log = log, download = dispatcher.build_url("admin", "services", "glinet-crossmodel", "download", backup.id) }, 200)
end

function action_remote_create()
	ensure_directories()
	local input = jsonc.parse(http.content() or "") or {}
	local connection, connection_error = remote_connection(input.connection)
	if not connection then return write_json({ error = connection_error }, 400) end
	local backup, input_error = make_backup_inputs(input)
	if not backup then return write_json({ error = input_error }, 400) end
	local passfile, password_error = write_secret(backup.id, connection.password)
	if not passfile then cleanup_backup_inputs(backup); return write_json({ error = password_error }, 500) end
	local output = PROFILE_DIR .. "/" .. backup.id .. ".tar.gz"
	local ok, log = remote_command("create", { output, backup.id, backup.selected, backup.scripts_file, backup.binaries_file, connection.host, connection.port, connection.user, passfile })
	fs.unlink(passfile)
	cleanup_backup_inputs(backup)
	if not ok or not fs.access(output) then
		fs.unlink(output)
		return write_json({ error = trim(log) ~= "" and trim(log) or "Could not create a portable profile from the LAN router." }, 422)
	end
	fs.chmod(output, 384)
	write_json({ ok = true, id = backup.id, log = log, download = dispatcher.build_url("admin", "services", "glinet-crossmodel", "download", backup.id) }, 200)
end

function action_restore()
	ensure_directories()
	local id = profile_id()
	local temporary = TMP_DIR .. "/upload-" .. id .. ".tar.gz"
	local bytes, upload, stream = 0, false, nil
	http.setfilehandler(function(meta, chunk, eof)
		if meta and meta.name == "archive" then
			upload = true
			stream = io.open(temporary, "wb")
		end
		if upload and stream and chunk and #chunk > 0 then
			bytes = bytes + #chunk
			if bytes <= 64 * 1024 * 1024 then stream:write(chunk) end
		end
		if upload and eof and stream then stream:close(); stream = nil end
	end)
	http.formvalue("archive")
	if stream then stream:close() end
	if not upload or bytes == 0 or bytes > 64 * 1024 * 1024 or not fs.access(temporary) then
		fs.unlink(temporary)
		return write_json({ error = "Upload a portable profile archive smaller than 64 MB." }, 400)
	end
	fs.chmod(temporary, 384)
	local selected = selected_from_csv(http.formvalue("categories"))
	if selected == "" then fs.unlink(temporary); return write_json({ error = "Select at least one restore category." }, 400) end
	local install_packages = http.formvalue("install_packages") == "1" and "1" or "0"
	local direct_files = http.formvalue("direct_files") == "1" and "1" or "0"
	local remote_enabled = http.formvalue("remote_enabled") == "1"
	local ok, log
	if remote_enabled then
		local connection, connection_error = remote_connection({
			host = http.formvalue("remote_host"), port = http.formvalue("remote_port"),
			user = http.formvalue("remote_user"), password = http.formvalue("remote_password")
		})
		if not connection then fs.unlink(temporary); return write_json({ error = connection_error }, 400) end
		local passfile, password_error = write_secret(id, connection.password)
		if not passfile then fs.unlink(temporary); return write_json({ error = password_error }, 500) end
		ok, log = remote_command("restore", { temporary, id, selected, install_packages, direct_files, connection.host, connection.port, connection.user, passfile })
		fs.unlink(passfile)
	else
		ok, log = command(quote(APP) .. " restore " .. quote(temporary) .. " " .. quote(selected) .. " " .. quote(install_packages) .. " " .. quote(direct_files))
	end
	fs.unlink(temporary)
	if not ok then return write_json({ error = trim(log) ~= "" and trim(log) or "Restore failed." }, remote_enabled and 422 or 500) end
	write_json({ ok = true, log = log }, 200)
end

function action_download(id)
	id = safe_profile_id(id)
	local archive = id and (PROFILE_DIR .. "/" .. id .. ".tar.gz") or nil
	if not archive or not fs.access(archive) then
		http.status(404, "Not Found")
		return http.write("Profile not found")
	end
	http.header("Content-Disposition", "attachment; filename=glinet-portable-" .. id .. ".tar.gz")
	http.prepare_content("application/gzip")
	http.write(fs.readfile(archive) or "")
end
