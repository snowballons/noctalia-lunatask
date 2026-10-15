-- tools/mock_ping.lua (M0 mock test, runs with stock lua, no Noctalia needed)
-- Usage: lua tools/mock_ping.lua   (run from lunatask/ dir)
-- Verifies: token resolution order (D3), lowercase bearer header,
-- status-based response handling (V-01), classify matrix (§11.1).

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

-- ── stub noctalia ──────────────────────────────────────────────
local state_store = {}
local fake_env = {}
local fake_config = { token = "", token_file = "" }
local fake_files = {}
local log_lines = {}

noctalia = {
	getenv = function(name) return fake_env[name] end,
	getConfig = function(key) return fake_config[key] end,
	readFile = function(_path)
		-- token_file test uses expandPath output as key into fake_files
		return fake_files._last_path_content
	end,
	expandPath = function(p)
		fake_files._last_path = p
		return p
	end,
	string = {
		trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
		urlEncode = function(s) return s end,
	},
	json = {
		encode = function(_v) return "{}" end,
		decode = function(s)
			if s == nil or s == "" then return nil end
			if s:find("pong") then return { message = "pong" } end
			if s:find('"tasks"') then return { tasks = {} } end
			return nil -- malformed -> "bad json" path
		end,
	},
	http = function(req, cb)
		-- Find Authorization header; must be lowercase "bearer".
		local auth
		for _, h in ipairs(req.headers or {}) do
			if h:sub(1, 14) == "Authorization:" then auth = h end
		end
		assert(auth ~= nil, "missing Authorization header")
		assert(auth:find("bearer ", 1, true) ~= nil, "auth scheme must be lowercase 'bearer', got: " .. auth)
		local token = auth:match("bearer%s+(.*)%s*$")
		-- Simulate V-01 ambiguity: transport ok=false but HTTP status present.
		if token == "valid-token" then
			cb({ ok = true, status = 200, body = '{"message":"pong"}' })
		elseif token == "bad-token" then
			cb({ ok = false, status = 401, body = "unauthorized" })
		elseif token == "rate-token" then
			cb({ ok = false, status = 0, body = "" })
		else
			cb({ ok = false, status = 401, body = "unauthorized" })
		end
		return true
	end,
	log = function(m) table.insert(log_lines, m) end,
	notify = function(t, b) print("NOTIFY " .. t .. ": " .. tostring(b)) end,
	notifyError = function(t, b) print("NOTIFY-ERROR " .. t .. ": " .. tostring(b)) end,
	tr = function(k) return k end,
	setUpdateInterval = function(_) end,
	runAsync = function(_) return true end,
	nowMs = function() return 1792029000000 end,
	pluginDataDir = function() return "/tmp/lunatask-mock-data" end,
	writeFile = function(_, _) return true end,
	renameFile = function(_, _) return true end,
	state = {
		set = function(k, v) state_store[k] = v end,
		get = function(k) return state_store[k] end,
		watch = function(_, _) end,
	},
}

-- ── require shim for Noctalia-style relative requires ──────────
local orig_require = require
require = function(path)
	local rel = path:match("^%./(.+)%.luau$")
	if rel then
		local chunk = assert(loadfile(PLUGIN_DIR .. rel .. ".luau"))
		return chunk()
	end
	return orig_require(path)
end

local function load_service()
	local chunk = assert(loadfile(PLUGIN_DIR .. "service.luau"))
	return chunk() -- returns { resolveToken, ping }
end

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then
		pass = pass + 1
		print("PASS " .. name)
	else
		fail = fail + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

-- 1. classify matrix (§11.1)
local svc = load_service()
local api = require("./lib/api.luau")
check("classify 401=auth", api.classify(401) == "auth")
check("classify 402=plan", api.classify(402) == "plan")
check("classify 404=not_found", api.classify(404) == "not_found")
check("classify 400=validation", api.classify(400) == "validation")
check("classify 422=validation", api.classify(422) == "validation")
check("classify 500=server", api.classify(500) == "server")
check("classify 503=server", api.classify(503) == "server")
check("classify 524=server", api.classify(524) == "server")
check("auth header lowercase bearer", api.authHeader("x") == "Authorization: bearer x")

-- 2. no token anywhere -> config error, no HTTP call
fake_env = {}
fake_config = { token = "", token_file = "" }
local made_http = false
local real_http = noctalia.http
noctalia.http = function(...) made_http = true return true end
local r1 = nil
svc.ping(function(r) r1 = r end)
check("no token -> ok=false", r1 ~= nil and r1.ok == false)
check("no token -> kind=config", r1 ~= nil and r1.err ~= nil and r1.err.kind == "config")
check("no token -> no HTTP", made_http == false)
noctalia.http = real_http

-- 3. resolution order: env wins over file/setting
fake_env = { LUNATASK_ACCESS_TOKEN = "  valid-token  " } -- whitespace trimmed
fake_config = { token = "bad-token", token_file = "" }
local r2 = nil
svc.ping(function(r) r2 = r end)
check("env token trimmed + accepted", r2 ~= nil and r2.ok == true and r2.status == 200)
check("env pong body decoded", r2 ~= nil and r2.data ~= nil and r2.data.message == "pong")

-- 4. bad token -> auth (even when res.ok=false, decide by status: V-01)
fake_env = {}
fake_config = { token = "bad-token", token_file = "" }
local r3 = nil
svc.ping(function(r) r3 = r end)
check("bad token -> ok=false", r3 ~= nil and r3.ok == false)
check("bad token -> kind=auth", r3 ~= nil and r3.err ~= nil and r3.err.kind == "auth")
check("bad token -> status=401", r3 ~= nil and r3.status == 401)

-- 5. file token path (token_file set, file content wins over setting)
fake_env = {}
fake_config = { token = "bad-token", token_file = "~/secrets/lunatask" }
fake_files._last_path_content = "valid-token\n"
local r4 = nil
svc.ping(function(r) r4 = r end)
check("file token -> ok", r4 ~= nil and r4.ok == true)

-- 6. onConfigChanged invalidates token_checked; onIpc ping logs without secret
svc = load_service() -- fresh to get onIpc globals
assert(type(onIpc) == "function", "service must define global onIpc")
assert(type(onConfigChanged) == "function", "service must define global onConfigChanged")
onConfigChanged()
check("onConfigChanged clears token_checked", noctalia.state.get("token_checked") == false)
fake_config = { token = "bad-token", token_file = "" }
log_lines = {}
onIpc("ping", "")
local leaked = false
for _, line in ipairs(log_lines) do
	if line:find("bad%-token") or line:find("valid%-token") then leaked = true end
end
check("ping log has no token", leaked == false)
local has_ping_log = false
for _, line in ipairs(log_lines) do
	if line:find("ping ok=") then has_ping_log = true end
end
check("ping writes one log line", has_ping_log)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
