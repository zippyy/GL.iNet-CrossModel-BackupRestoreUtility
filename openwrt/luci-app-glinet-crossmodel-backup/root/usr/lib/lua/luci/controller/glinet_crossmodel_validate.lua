module("luci.controller.glinet_crossmodel_validate", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"

local VALIDATE_APP = "/usr/libexec/glinet-crossmodel-validate"
local TMP_DIR = "/tmp/glinet-crossmodel"
local KNOWN_HOSTS = "/root/.ssh/known_hosts"
local categories = {
	"network", "wireless", "vpn", "firewall", "adguard",
	"ddns", "system", "packages", "scripts", "binaries"
}
local valid_category = {}
for _, name in ipairs(categories) do valid_category[name] = true end

local function quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\\"'\\\"'") .. "'"
end

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function command(commandline)
	local marker = "__GCM_VALIDATE_EXIT__"
	local shell = "(" .. commandline .. ") 2>&1; rc=$?; echo; echo " .. marker .. "$rc"
	local pipe = io.popen(shell)
	local output = pipe:read("*a") or ""
	pipe:close()
	local status = tonumber(output:match("\n" .. marker .. "(%d+)%s*$"))
	output = output:gsub("\n" .. marker .. "%d+%s*$", "")
	if status == 0 then return true, output end
	return false, output, status
end

local function write_json(value, status)
	if status then http.status(status, status == 200 and "OK" or "Error") end
	http.prepare_content("application/json")
	http.write(jsonc.stringify(value))
end

local function profile_id()
	local value = trim(fs.readfile("/proc/sys/kernel/random/uuid") or "")
	if value:match("^[a-f0-9%-]+$") then return value end
	return string.format("%x-%x", os.time(), math.random(0, 0x7fffffff))
end

local function ensure_directories()
	command("mkdir -p " .. quote(TMP_DIR) .. " /root/.ssh")
	fs.chmod(TMP_DIR, "0700")
	fs.chmod("/root/.ssh", "0700")
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

local function valid_connection(input)
	input = input or {}
	local host = trim(input.host)
	local user = trim(input.user)
	local password = tostring(input.password or "")
	local port = tonumber(input.port)
	if #host < 1 or #host > 253 or not host:match("^[A-Za-z0-9][A-Za-z0-9%._:%-]*$") then return nil, "Enter a valid LAN router hostname or IP address." end
	if not port or port % 1 ~= 0 or port < 1 or port > 65535 then return nil, "SSH port must be between 1 and 65535." end
	if #user < 1 or #user > 64 or not user:match("^[A-Za-z0-9][A-Za-z0-9%._%-]*$") then return nil, "Enter a valid SSH username." end
	if #password < 1 or #password > 512 or password:find("[%c]") then return nil, "Enter a valid SSH password." end
	return { host = host, port = tostring(port), user = user, password = password }
end

local function remote_target(connection)
	if connection.host:find(":", 1, true) then return connection.user .. "@[" .. connection.host .. "]" end
	return connection.user .. "@" .. connection.host
end

local function write_secret(id, password)
	local path = TMP_DIR .. "/validate-sshpass-" .. id
	local file = io.open(path, "w")
	if not file then return nil, "Could not create temporary SSH credential file." end
	file:write(password, "\n")
	file:close()
	fs.chmod(path, "0600")
	return path
end

local function receive_archive(temporary)
	local bytes, upload_seen, collecting, stream = 0, false, false, nil
	http.setfilehandler(function(meta, chunk, eof)
		if meta then
			if meta.name == "archive" then
				upload_seen = true
				if not collecting then
					stream = io.open(temporary, "wb")
					collecting = stream ~= nil
				end
			else
				if collecting and stream then stream:close(); stream = nil end
				collecting = false
			end
		end
		if collecting and stream and chunk and #chunk > 0 then
			bytes = bytes + #chunk
			if bytes <= 64 * 1024 * 1024 then stream:write(chunk) end
		end
		if collecting and eof then
			if stream then stream:close(); stream = nil end
			collecting = false
		end
	end)
	http.formvalue("archive")
	if stream then stream:close() end
	if not upload_seen or bytes == 0 or bytes > 64 * 1024 * 1024 or not fs.access(temporary) then
		fs.unlink(temporary)
		return nil, "Upload a portable profile archive smaller than 64 MB."
	end
	fs.chmod(temporary, "0600")
	local ok = command("tar -tzf " .. quote(temporary) .. " >/dev/null")
	if not ok then
		fs.unlink(temporary)
		return nil, "Uploaded profile archive could not be read on the control router."
	end
	return true
end

local function remote_validate(archive, id, categories_csv, connection)
	local passfile, secret_error = write_secret(id, connection.password)
	if not passfile then return nil, secret_error end
	local remote_archive = "/tmp/glinet-crossmodel-validate-" .. id .. ".tar.gz"
	local target = remote_target(connection)
	local common = "-o BatchMode=no -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=" .. quote(KNOWN_HOSTS)
	local scp = "sshpass -f " .. quote(passfile) .. " scp -O " .. common .. " -P " .. quote(connection.port) .. " " .. quote(archive) .. " " .. quote(target .. ":" .. remote_archive)
	local ok, output = command(scp)
	if not ok then fs.unlink(passfile); return nil, trim(output) ~= "" and trim(output) or "Could not upload profile archive to target router." end
	local md5 = "sshpass -f " .. quote(passfile) .. " ssh " .. common .. " -p " .. quote(connection.port) .. " " .. quote(target) .. " " .. quote("tar -tzf " .. remote_archive .. " >/dev/null 2>&1")
	ok, output = command(md5)
	if not ok then
		command("sshpass -f " .. quote(passfile) .. " ssh " .. common .. " -p " .. quote(connection.port) .. " " .. quote(target) .. " " .. quote("rm -f " .. remote_archive))
		fs.unlink(passfile)
		return nil, "Target router cannot read the transferred profile archive."
	end
	local run = "cat " .. quote(VALIDATE_APP) .. " | sshpass -f " .. quote(passfile) .. " ssh " .. common .. " -p " .. quote(connection.port) .. " " .. quote(target) .. " sh -s -- " .. quote(remote_archive) .. " " .. quote(categories_csv)
	ok, output = command(run)
	command("sshpass -f " .. quote(passfile) .. " ssh " .. common .. " -p " .. quote(connection.port) .. " " .. quote(target) .. " " .. quote("rm -f " .. remote_archive))
	fs.unlink(passfile)
	if not ok then return nil, trim(output) ~= "" and trim(output) or "Target validation failed." end
	return jsonc.parse(output) or nil, "Target validation returned invalid data."
end

function index()
	entry({"admin", "services", "glinet-crossmodel", "api", "validate"}, call("action_validate")).leaf = true
end

function action_validate()
	ensure_directories()
	local id = profile_id()
	local temporary = TMP_DIR .. "/validate-upload-" .. id .. ".tar.gz"
	local received, receive_error = receive_archive(temporary)
	if not received then return write_json({ error = receive_error }, 400) end
	local selected = selected_from_csv(http.formvalue("categories"))
	if selected == "" then fs.unlink(temporary); return write_json({ error = "Select at least one restore category." }, 400) end
	local remote = http.formvalue("remote_enabled") == "1"
	local plan, plan_error
	if remote then
		local connection, connection_error = valid_connection({ host = http.formvalue("remote_host"), port = http.formvalue("remote_port"), user = http.formvalue("remote_user"), password = http.formvalue("remote_password") })
		if not connection then fs.unlink(temporary); return write_json({ error = connection_error }, 400) end
		plan, plan_error = remote_validate(temporary, id, selected, connection)
	else
		local ok, output = command(quote(VALIDATE_APP) .. " " .. quote(temporary) .. " " .. quote(selected))
		if ok then plan = jsonc.parse(output) else plan_error = trim(output) end
		if not plan and not plan_error then plan_error = "Validation backend returned invalid data." end
	end
	fs.unlink(temporary)
	if not plan then return write_json({ error = plan_error ~= "" and plan_error or "Validation failed." }, remote and 422 or 500) end
	write_json(plan, 200)
end
