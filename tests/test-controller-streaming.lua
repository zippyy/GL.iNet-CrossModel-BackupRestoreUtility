-- tests/test-controller-streaming.lua
--
-- Regression test for the OpenWrt 22 zero-byte download bug.
--
-- On legacy LuCI (OpenWrt 22), luci.http.write() yields per chunk
-- (coroutine.yield(4, content) in luci-lib-base/luasrc/http.lua) and the whole
-- dispatch runs inside a coroutine driven by uhttpd's resume loop. The old
-- stream_open_file() wrapped that yielding write loop in a plain Lua C pcall(),
-- which is illegal on Lua 5.1 ("attempt to yield across a C-call boundary").
-- The first http.write() therefore aborted, the response was already committed
-- with a 200, and the browser received a 0-byte archive. OpenWrt 25's runtime
-- writes at C level (no per-chunk yield), so the same code worked there.
--
-- This test exercises the REAL controller action_download() (nothing is mocked
-- except the LuCI/nixio module surface) under a coroutine whose http.write
-- yields exactly like LuCI 22.03. Under Lua 5.1 this fails against the old
-- pcall implementation and passes against the ltn12 + copcall fix.
--
-- Required interpreter: Lua 5.1 (or any 5.x for the modern-side assertions).

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

-- ---------------------------------------------------------------------------
-- Fixture files
-- ---------------------------------------------------------------------------
local TMP = "/tmp/glinet-crossmodel"
os.execute("mkdir -p " .. TMP)
local PROFILE_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
local PROFILE_PATH = "/root/glinet-crossmodel/profiles/" .. PROFILE_ID .. ".tar.gz"
local PROFILE_FIXTURE = TMP .. "/stream-profile-fixture.tar.gz"
local LOG_FILE = TMP .. "/gcm.log"
local LOG_FIXTURE = TMP .. "/gcm.log"

-- Deterministic pseudo-random archive body: 200 KiB, larger than one 32 KiB
-- stream chunk, so multi-chunk streaming (and byte-exactness) is exercised.
math.randomseed(20260901)
local block = {}
for i = 1, 1024 do block[i] = string.char(math.random(0, 255)) end
block = table.concat(block)
local FIXTURE_BYTES = 200 * 1024
local expected_archive = string.rep(block, math.ceil(FIXTURE_BYTES / #block)):sub(1, FIXTURE_BYTES)

local fixture_out = assert(io.open(PROFILE_FIXTURE, "wb"))
fixture_out:write(expected_archive)
fixture_out:close()

local function fixture_size(path)
	local f = io.open(path, "rb")
	if not f then return 0 end
	local size = f:seek("end")
	f:close()
	return size
end

-- ---------------------------------------------------------------------------
-- Mocked LuCI module surface
-- ---------------------------------------------------------------------------
local request_method = "GET"
local response_status, response_content_type, response_headers
local received_chunks = {}
local fail_after_chunks      -- inject a mid-stream failure after N chunks
local fail_open_path         -- inject an io.open() failure for this path

local http = {
	getenv = function(name) if name == "REQUEST_METHOD" then return request_method end end,
	content = function() return "" end,
	status = function(status) response_status = status end,
	header = function(name, value) response_headers[name] = value end,
	prepare_content = function(content_type) response_content_type = content_type end,
	-- Legacy LuCI (22.03) behavior: http.write() yields to the uhttpd resume
	-- loop for every chunk written, and implicitly commits status 200 when no
	-- status was set yet (http.lua: "if not context.status then status() end").
	write = function(value)
		if value == nil then return true end
		if not response_status then response_status = 200 end
		if fail_after_chunks and #received_chunks >= fail_after_chunks then
			error("injected stream failure")
		end
		table.insert(received_chunks, value)
		coroutine.yield("chunk")
	end
}
local jsonc = {
	parse = function() return {} end,
	stringify = function() return "{}" end
}
local fs = {
	readfile = function(path)
		if path == "/proc/sys/kernel/random/uuid" then return "11111111-1111-1111-1111-111111111111\n" end
	end,
	stat = function(path)
		if path == PROFILE_PATH then return { type = "reg", size = fixture_size(PROFILE_FIXTURE) } end
		if path == LOG_FILE then return { type = "reg", size = fixture_size(LOG_FILE) } end
		return nil
	end,
	unlink = function(path) return os.remove(path) end,
	rename = function() return true end,
	access = function(path)
		return path == PROFILE_PATH or path == LOG_FILE
	end,
	writefile = function() return true end,
	chmod = function() return true end,
	glob = function() return function() return nil end end
}
local uci = {
	get = function(_, config, section, option)
		if config == "glinet_crossmodel" and section == "logging" then
			if option == "level" then return "info" end
			if option == "file_log" then return "1" end
			if option == "syslog" then return "0" end
			if option == "max_log_kb" then return "512" end
		end
	end,
	set = function() end,
	section = function() end,
	commit = function() return true end
}

-- Serve the real fixture for the (virtual) profile path.
local real_io_open = io.open
io.open = function(path, mode)
	if path == PROFILE_PATH and fail_open_path ~= path then
		return real_io_open(PROFILE_FIXTURE, mode)
	end
	if path == PROFILE_PATH and fail_open_path == path then return nil end
	return real_io_open(path, mode)
end

package.preload["luci.http"] = function() return http end
package.preload["luci.jsonc"] = function() return jsonc end
package.preload["nixio.fs"] = function() return fs end
package.preload["luci.dispatcher"] = function()
	return { context = { authtoken = "stream-test-token" }, build_url = function() return "/" end }
end
package.preload["luci.model.uci"] = function() return { cursor = function() return uci end } end
package.preload["luci.ltn12"] = function()
	assert(loadfile(root .. "/tests/fixtures/luci/ltn12.lua"))()
	return package.loaded["luci.ltn12"]
end
package.preload["luci.util"] = function()
	return assert(dofile(root .. "/tests/fixtures/luci/util-copcall.lua"))
end

assert(loadfile(controller_path))()
local controller = assert(package.loaded["luci.controller.glinet_crossmodel"])

-- ---------------------------------------------------------------------------
-- Coroutine driver, mirroring luci-base sgi/uhttpd.lua: resume the dispatch
-- coroutine until dead; every http.write() yield comes back as a "chunk" tag.
-- ---------------------------------------------------------------------------
local function drive(fn, ...)
	-- Lua 5.1 does not inherit ... into nested functions; capture explicitly.
	-- unpack is a global in 5.1 but table.unpack in 5.2+; support both so the
	-- same test runs under the legacy (5.1) and modern (5.2+) interpreters.
	local unpack_fn = table.unpack or unpack
	local args = { n = select("#", ...), ... }
	received_chunks = {}
	local co = coroutine.create(function()
		fn(unpack_fn(args, 1, args.n))
	end)
	while coroutine.status(co) ~= "dead" do
		local ok, tag = coroutine.resume(co)
		assert(ok, "controller coroutine failed: " .. tostring(tag))
	end
end

local function reset()
	response_status, response_content_type, response_headers = nil, nil, {}
	received_chunks = {}
	fail_after_chunks, fail_open_path = nil, nil
end

local function body()
	return table.concat(received_chunks, "")
end

-- ---------------------------------------------------------------------------
-- 1. Non-empty archive is streamed completely and byte-exact
-- ---------------------------------------------------------------------------
reset()
drive(controller.action_download, PROFILE_ID)
assert(#body() == #expected_archive,
	"downloaded byte count " .. #body() .. " != source " .. #expected_archive .. " (zero-byte bug)")
assert(body() == expected_archive, "downloaded bytes differ from source archive")
assert(#received_chunks >= 2, "archive must be streamed in multiple chunks, not buffered whole")

-- 2. Headers: attachment filename, gzip content type, Content-Length
assert(response_headers["Content-Disposition"] == "attachment; filename=glinet-crossmodel-" .. PROFILE_ID .. ".tar.gz",
	"unexpected Content-Disposition: " .. tostring(response_headers["Content-Disposition"]))
assert(response_content_type == "application/gzip", "unexpected Content-Type: " .. tostring(response_content_type))
assert(response_headers["Content-Length"] == tostring(#expected_archive),
	"Content-Length " .. tostring(response_headers["Content-Length"]) .. " != " .. #expected_archive)

-- 3. Source archive is not truncated or modified
local reread = assert(real_io_open(PROFILE_FIXTURE, "rb")):read("*a")
assert(reread == expected_archive, "source archive was modified or truncated during download")

-- 4. Missing profile -> clean 404 before any body commit
reset()
drive(controller.action_download, "bbbbbbbb-0000-0000-0000-000000000000")
assert(response_status == 404, "missing profile must yield 404, got " .. tostring(response_status))
assert(body() == "Profile not found", "404 body mismatch: " .. body())

-- 5. Open failure -> clean 500 before any body commit, no attachment headers
reset()
fail_open_path = PROFILE_PATH
drive(controller.action_download, PROFILE_ID)
assert(response_status == 500, "open failure must yield 500, got " .. tostring(response_status))
assert(body() == "Profile download could not be opened", "500 body mismatch: " .. body())
assert(response_headers["Content-Disposition"] == nil, "open failure must not emit attachment headers")
assert(response_content_type == "text/plain", "open failure must be text/plain, got " .. tostring(response_content_type))

-- 6. Mid-stream failure: response is already committed (200), no fake 500,
--    and the failure is logged with a sanitized error and byte accounting.
reset()
fail_after_chunks = 2
drive(controller.action_download, PROFILE_ID)
assert(response_status == 200, "post-commit failure must not rewrite status, got " .. tostring(response_status))
assert(#body() == 2 * (32 * 1024), "expected two 32 KiB chunks streamed before failure, got " .. #body())

local log_text = assert(real_io_open(LOG_FILE, "rb")):read("*a")
local log_marker = 'stage="stream"'
assert(log_text:find(log_marker, 1, true), "stream failure must be logged with stage=stream")
assert(log_text:find('result="failed"', 1, true), "stream failure must be logged as failed")
-- The sanitized error is quoted by the log formatter and carries the Lua
-- position prefix (file:line: message); assert on the message substring.
assert(log_text:find('injected stream failure', 1, true), "stream failure must include the sanitized error")
assert(log_text:find('bytes_streamed="65536"', 1, true), "stream failure must report bytes streamed before failure")
assert(log_text:find('expected="' .. tostring(#expected_archive) .. '"', 1, true), "stream failure must report expected size")

-- 7. Diagnostics download streams completely with its own headers.
--    Note: the controller logs its own request lines to LOG_FILE while
--    streaming it, so the body is the fixture plus appended log entries
--    (expected self-referential behavior on-device). Assert the fixture
--    prefix and that the full fixture is present at the start.
reset()
local log_fixture = assert(real_io_open(LOG_FILE, "wb"))
log_fixture:write("diagnostic-log-fixture\nsecond line\n")
log_fixture:close()
local fixture_text = "diagnostic-log-fixture\nsecond line\n"
drive(controller.action_diagnostics_download)
assert(body():sub(1, #fixture_text) == fixture_text, "diagnostics download body must begin with the log fixture")
assert(body():find("diagnostic-log-fixture", 1, true), "diagnostics download must contain the fixture")
assert(response_headers["Content-Disposition"] == "attachment; filename=glinet-crossmodel-diagnostics.log",
	"diagnostics download must retain its attachment filename")
assert(response_content_type == "text/plain", "diagnostics download must retain its text content type")

-- 8. move_file EXDEV fallback: rename fails, streaming copy must succeed
--    and remove the source.
local src = TMP .. "/move-src.bin"
local dst = TMP .. "/move-dst.bin"
local mv_out = assert(real_io_open(src, "wb"))
mv_out:write(expected_archive)
mv_out:close()
local real_rename = fs.rename
fs.rename = function() return nil end -- force EXDEV fallback
assert(controller.move_file(src, dst), "move_file EXDEV fallback must succeed")
fs.rename = real_rename
local dst_text = assert(real_io_open(dst, "rb")):read("*a")
assert(dst_text == expected_archive, "move_file copy must preserve bytes exactly")
assert(not fs.access(src), "move_file must remove the source after copy")
assert(real_io_open(src, "rb") == nil, "source must be gone after move_file copy")
os.remove(src); os.remove(dst)

os.remove(PROFILE_FIXTURE)
os.remove(LOG_FILE)

print("controller streaming regression checks passed (byte-exact, legacy-yield boundary)")
