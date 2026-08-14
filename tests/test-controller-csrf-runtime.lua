local root = assert(arg[1], "repository root is required")
local controller_path = root .. "/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/controller/glinet_crossmodel.lua"

if not package.seeall then
	function package.seeall(target)
		local meta = getmetatable(target) or {}
		meta.__index = _G
		setmetatable(target, meta)
	end
end

if not module then
	function module(name, ...)
		local target = package.loaded[name] or {}
		package.loaded[name] = target
		target._M, target._NAME, target._PACKAGE = target, name, name:match("^(.*%.)") or ""
		for index = 1, select("#", ...) do
			local option = select(index, ...)
			if type(option) == "function" then option(target) end
		end
		local caller = debug.getinfo(2, "f").func
		local index = 1
		while true do
			local upvalue = debug.getupvalue(caller, index)
			if not upvalue then break end
			if upvalue == "_ENV" then debug.setupvalue(caller, index, target); break end
			index = index + 1
		end
	end
end

local request_method, request_json, response_status, committed, response_body, response_headers, response_content_type
local http = {
	getenv = function(name) if name == "REQUEST_METHOD" then return request_method end end,
	content = function() return "mock-json" end,
	status = function(status) response_status = status end,
	header = function(name, value) response_headers[name] = value end,
	prepare_content = function(content_type) response_content_type = content_type end,
	write = function(value) response_body = response_body .. tostring(value or "") end
}
local jsonc = {
	parse = function() return request_json end,
	stringify = function() return "{}" end
}
local fs = {
	readfile = function(path)
		if path == "/proc/sys/kernel/random/uuid" then return "11111111-1111-1111-1111-111111111111\n" end
	end,
	stat = function() return nil end,
	unlink = function() return true end,
	rename = function() return true end,
	access = function(path)
		return path == "/tmp/glinet-crossmodel/gcm.log"
			or path == "/root/glinet-crossmodel/profiles/11111111-1111-1111-1111-111111111111.tar.gz"
	end,
	writefile = function() return true end,
	chmod = function() return true end,
	glob = function() return function() return nil end end
}
local uci = {
	get = function(_, config, section, option)
		if config == "glinet_crossmodel" and section == "logging" and option == "level" then return "info" end
		if config == "glinet_crossmodel" and section == "logging" and option == "file_log" then return "0" end
		if config == "glinet_crossmodel" and section == "logging" and option == "syslog" then return "0" end
		if config == "glinet_crossmodel" and section == "logging" and option == nil then return "logging" end
	end,
	set = function() end,
	section = function() end,
	commit = function() committed = committed + 1; return true end
}

package.preload["luci.http"] = function() return http end
package.preload["luci.jsonc"] = function() return jsonc end
package.preload["nixio.fs"] = function() return fs end
package.preload["luci.dispatcher"] = function() return { context = { authtoken = "csrf-test-token" } } end
package.preload["luci.model.uci"] = function() return { cursor = function() return uci end } end

assert(loadfile(controller_path))()
local controller = assert(package.loaded["luci.controller.glinet_crossmodel"])

local function run(method, token)
	request_method = method
	request_json = { level = "debug", token = token }
	response_status = nil
	response_body, response_headers, response_content_type = "", {}, nil
	committed = 0
	controller.action_logging_save()
	return response_status, committed
end

local status, commits = run("POST", "csrf-test-token")
assert(status == 200 and commits == 1, "matching request-body token must permit the POST")

status, commits = run("POST", nil)
assert(status == 403 and commits == 0, "missing request-body token must reject the POST")

status, commits = run("POST", "login-session-id")
assert(status == 403 and commits == 0, "login session ID must not be accepted as a CSRF token")

status, commits = run("GET", "csrf-test-token")
assert(status == 405 and commits == 0, "state-changing endpoint must remain POST-only")

os.execute("mkdir -p /tmp/glinet-crossmodel")
local diagnostic_fixture = assert(io.open("/tmp/glinet-crossmodel/gcm.log", "w"))
diagnostic_fixture:write("diagnostic-download-fixture\n")
diagnostic_fixture:close()
response_body, response_headers, response_content_type = "", {}, nil
local download_ok, download_error = pcall(controller.action_diagnostics_download)
os.remove("/tmp/glinet-crossmodel/gcm.log")
assert(download_ok, "diagnostic download must stream through LuCI 21.02 without http.writefile: " .. tostring(download_error))
assert(response_body == "diagnostic-download-fixture\n", "diagnostic download must return the complete log")
assert(response_headers["Content-Disposition"] == "attachment; filename=glinet-crossmodel-diagnostics.log", "diagnostic download must retain its attachment filename")
assert(response_content_type == "text/plain", "diagnostic download must retain its text content type")

local profile_fixture_path = "/tmp/glinet-crossmodel/profile-download-fixture.tar.gz"
local profile_fixture = assert(io.open(profile_fixture_path, "w"))
profile_fixture:write("profile-download-fixture")
profile_fixture:close()
local real_io_open = io.open
io.open = function(path, mode)
	if path == "/root/glinet-crossmodel/profiles/11111111-1111-1111-1111-111111111111.tar.gz" then
		return real_io_open(profile_fixture_path, mode)
	end
	return real_io_open(path, mode)
end
response_body, response_headers, response_content_type = "", {}, nil
local profile_download_ok, profile_download_error = pcall(controller.action_download, "11111111-1111-1111-1111-111111111111")
io.open = real_io_open
os.remove(profile_fixture_path)
assert(profile_download_ok, "profile download must stream through LuCI 21.02 without http.writefile: " .. tostring(profile_download_error))
assert(response_body == "profile-download-fixture", "profile download must return the complete archive")
assert(response_headers["Content-Disposition"] == "attachment; filename=glinet-crossmodel-11111111-1111-1111-1111-111111111111.tar.gz", "profile download must retain its attachment filename")
assert(response_content_type == "application/gzip", "profile download must retain its archive content type")

print("controller CSRF runtime checks passed")
