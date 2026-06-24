module("luci.controller.glinet_crossmodel", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"

local APP = "/usr/libexec/glinet-crossmodel-backup"
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

local function command(command)
	local pipe = io.popen(command .. " 2>&1")
	local output = pipe:read("*a") or ""
	local ok, _, code = pipe:close()
	if ok == true or ok == 0 then return true, output end
	return false, output, code
end

local function ensure_directories()
	command("mkdir -p " .. quote(PROFILE_DIR) .. " " .. quote(TMP_DIR))
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
	local selected = {}
	for name in tostring(value or ""):gmatch("[^,]+") do
		if valid_category[name] then table.insert(selected, name) end
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
			local metadata = parse_profile_metadata(item)
			table.insert(out, {
				id = id,
				size = stat.size or 0,
				mtime = stat.mtime or 0,
				metadata = metadata
			})
		end
	end
	table.sort(out, function(a, b) return a.mtime > b.mtime end)
	return out
end

function index()
	entry({"admin", "services", "glinet-crossmodel"}, call("action_index"), _("GL.iNet Cross-Model Backup"), 92).dependent = false
	entry({"admin", "services", "glinet-crossmodel", "api", "facts"}, call("action_facts")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "api", "profiles"}, call("action_profiles")).leaf = true
	entry({"admin", "services", "glinet-crossmodel", "api", "create"}, call("action_create")).leaf = true
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

function action_profiles()
	write_json({ profiles = profiles() }, 200)
end

function action_create()
	ensure_directories()
	local input = jsonc.parse(http.content() or "") or {}
	local selected = selected_csv(input.categories)
	if selected == "" then return write_json({ error = "Select at least one backup category." }, 400) end
	local scripts, script_error = parse_paths(input.scripts, 20)
	if not scripts then return write_json({ error = script_error }, 400) end
	local binaries, binary_error = parse_paths(input.binaries, 10)
	if not binaries then return write_json({ error = binary_error }, 400) end
	local id = profile_id()
	local scripts_file, scripts_error = write_list(id, "scripts", scripts)
	if not scripts_file then return write_json({ error = scripts_error }, 500) end
	local binaries_file, binaries_error = write_list(id, "binaries", binaries)
	if not binaries_file then fs.unlink(scripts_file); return write_json({ error = binaries_error }, 500) end
	local output = PROFILE_DIR .. "/" .. id .. ".tar.gz"
	local ok, log = command(quote(APP) .. " create " .. quote(output) .. " " .. quote(id) .. " " .. quote(selected) .. " " .. quote(scripts_file) .. " " .. quote(binaries_file))
	fs.unlink(scripts_file)
	fs.unlink(binaries_file)
	if not ok or not fs.access(output) then return write_json({ error = trim(log) ~= "" and trim(log) or "Could not create portable profile." }, 500) end
	write_json({ ok = true, id = id, log = log, download = luci.dispatcher.build_url("admin", "services", "glinet-crossmodel", "download", id) }, 200)
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
	local selected = selected_from_csv(http.formvalue("categories"))
	if selected == "" then fs.unlink(temporary); return write_json({ error = "Select at least one restore category." }, 400) end
	local install_packages = http.formvalue("install_packages") == "1" and "1" or "0"
	local direct_files = http.formvalue("direct_files") == "1" and "1" or "0"
	local ok, log = command(quote(APP) .. " restore " .. quote(temporary) .. " " .. quote(selected) .. " " .. quote(install_packages) .. " " .. quote(direct_files))
	fs.unlink(temporary)
	if not ok then return write_json({ error = trim(log) ~= "" and trim(log) or "Restore failed." }, 500) end
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
