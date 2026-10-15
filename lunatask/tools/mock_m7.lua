-- tools/mock_m7.lua — M7 tests: watchdog, auto-retry, crash replay, chmod.
-- Usage: lua tools/mock_m7.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local files = {}
local state_store = {}
local watchers = {}
local fake_env = {}
local fake_config = {
	token = "valid-token",
	token_file = "",
	areas = { Work = "11111111-2222-3333-4444-555555555555" },
	default_task_status = "later",
	cache_bodies = false,
	source_tag = "noctalia",
	max_retries = 1,
}
local ms = 1000
local run_log = {}
local mode = "ok"
local hung = {}
local posts = {}
local server = {
	tasks = {
		{ id = "srv-adopt", status = "later", priority = 0, source = "noctalia", source_id = "nct-crash-1" },
		{ id = "srv-del", status = "later", priority = 0, source = "noctalia", source_id = "nct-crash-del" },
	},
	notes = {},
	nextId = 1,
}

local function enc(v)
	local t = type(v)
	if t == "string" then
		return string.format("%q", v)
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local is_arr, n = true, 0
		for k, _ in pairs(v) do
			if type(k) ~= "number" then
				is_arr = false
				break
			end
			n = n + 1
		end
		local parts = {}
		if is_arr then
			for i = 1, n do
				parts[#parts + 1] = enc(v[i])
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
		for k, val in pairs(v) do
			parts[#parts + 1] = "[" .. enc(k) .. "]=" .. enc(val)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

local function dec(s)
	if s == nil or s == "" then
		return nil
	end
	local f = loadstring and loadstring(s) or load(s)
	if not f then
		return nil
	end
	local ok, v = pcall(f)
	if not ok then
		return nil
	end
	return v
end

noctalia = {
	getenv = function(name) return fake_env[name] end,
	getConfig = function(key) return fake_config[key] end,
	readFile = function(p) return files[p] end,
	writeFile = function(p, c) files[p] = c return true end,
	renameFile = function(a, b) files[b] = files[a] files[a] = nil return true end,
	expandPath = function(p) return p end,
	pluginDataDir = function() return "/mockdata" end,
	string = {
		trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
		urlEncode = function(s) return s end,
	},
	json = {
		encode = function(v) return "return " .. enc(v) end,
		decode = dec,
	},
	runAsync = function(argv)
		run_log[#run_log + 1] = argv
		return true
	end,
	http = function(req, cb)
		local path = req.url:match("^https://api%.lunatask%.app/v1(.*)$")
		if mode == "hang" then
			hung[#hung + 1] = cb
			return true
		end
		if req.method == "GET" and path == "/ping" then
			cb({ ok = true, status = 200, body = "return {message=\"pong\"}" })
			return true
		end
		if req.method == "POST" and path == "/tasks" then
			local body = dec(req.body) or {}
			posts[#posts + 1] = body
			if mode == "err500" then
				cb({ ok = false, status = 500, body = "oops" })
				return true
			end
			local id = "task-" .. tostring(server.nextId)
			server.nextId = server.nextId + 1
			server.tasks[#server.tasks + 1] =
				{ id = id, status = body.status or "later", priority = body.priority or 0,
					source = body.source, source_id = body.source_id }
			cb({ ok = true, status = 201, body = "return {task={id=" .. string.format("%q", id) .. "}}" })
			return true
		end
		if req.method == "DELETE" and path and path:match("^/tasks/") then
			local id = path:match("^/tasks/(.+)$")
			for i, t in ipairs(server.tasks) do
				if t.id == id then
					table.remove(server.tasks, i)
					cb({ ok = true, status = 200, body = "return {task={id=\"x\"}}" })
					return true
				end
			end
			cb({ ok = false, status = 404, body = "nope" })
			return true
		end
		if req.method == "GET" and path and path:find("^/tasks") then
			local sid = path:match("source_id=(.*)")
			local out = {}
			for _, t in ipairs(server.tasks) do
				if sid == nil or t.source_id == sid then
					out[#out + 1] = { id = t.id, status = t.status }
				end
			end
			cb({ ok = true, status = 200, body = "return {tasks=" .. enc(out) .. "}" })
			return true
		end
		if req.method == "POST" and path == "/journal_entries" then
			posts[#posts + 1] = dec(req.body) or {}
			if mode == "err" then
				cb({ ok = false, status = 500, body = "oops" })
			else
				cb({ ok = true, status = 201, body = "return {journal_entry={id=\"j-9\"}}" })
			end
			return true
		end
		cb({ ok = false, status = 404, body = "?" })
		return true
	end,
	log = function(_) end,
	notify = function(_, _) end,
	notifyError = function(_, _) end,
	tr = function(k, _) return k end,
	setUpdateInterval = function(_) end,
	nowMs = function() ms = ms + 1 return ms end,
	state = {
		set = function(k, v) state_store[k] = v end,
		get = function(k) return state_store[k] end,
		watch = function(k, fn)
			watchers[k] = watchers[k] or {}
			table.insert(watchers[k], fn)
		end,
	},
}

local function fire(key, msg)
	for _, fn in ipairs(watchers[key] or {}) do
		fn(msg)
	end
end

local orig_require = require
require = function(path)
	local rel = path:match("^%./(.+)%.luau$")
	if rel then
		return assert(loadfile(PLUGIN_DIR .. rel .. ".luau"))()
	end
	return orig_require(path)
end

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then pass = pass + 1 print("PASS " .. name)
	else fail = fail + 1 print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or "")) end
end

-- ── seed a crashed registry, then boot ───────────────────────────
local crashed = { schema = 1, items = {
	{ kind = "task", id = nil, source_id = "nct-crash-1", state = "pending_create", title = "C1",
		area_id = "a", status = "later", priority = 0 },
	{ kind = "task", id = nil, source_id = "nct-crash-9", state = "pending_create", title = "C9",
		area_id = "a", status = "later", priority = 0 },
	{ kind = "note", id = nil, source_id = "nct-crash-n", state = "pending_create", title = "CN" },
	{ kind = "task", id = "srv-1", source_id = "nct-u", state = "pending_update", title = "U",
		area_id = "a", status = "next", priority = 0 },
	{ kind = "task", id = "srv-del", source_id = "nct-crash-del", state = "pending_delete", title = "D",
		area_id = "a", status = "later", priority = 0 },
	{ kind = "journal", id = nil, state = "pending_create", date_on = "2026-10-15" },
} }
files["/mockdata/registry.json"] = "return " .. enc(crashed)

local svc = assert(loadfile(PLUGIN_DIR .. "service.luau"))()

local by_sid = {}
for _, it in ipairs(svc._registry.items) do
	by_sid[it.source_id or ("id:" .. tostring(it.id))] = it
end

check("chmod argv at boot", run_log[1] ~= nil and run_log[1][1] == "chmod"
	and run_log[1][2] == "700" and run_log[1][3] == "/mockdata")
check("crashed create adopted, no POST", by_sid["nct-crash-1"].state == "synced"
	and by_sid["nct-crash-1"].id == "srv-adopt" and #posts == 0)
check("crashed create unknown -> failed", by_sid["nct-crash-9"].state == "failed")
check("crashed note unknown -> failed", by_sid["nct-crash-n"].state == "failed")
check("pending_update without payload -> failed", by_sid["nct-u"].state == "failed")
local del_gone = true
for _, t in ipairs(server.tasks) do
	if t.id == "srv-del" then
		del_gone = false
	end
end
check("pending_delete re-driven", del_gone and by_sid["nct-crash-del"] == nil)
local jfailed = false
for _, it in ipairs(svc._registry.items) do
	if it.kind == "journal" and it.state == "failed" then
		jfailed = true
	end
end
check("journal pending -> failed", jfailed)

-- ── watchdog ─────────────────────────────────────────────────────
svc._seam.setWatchdogMs(0)
mode = "hang"
local seq = 100
fire("cmd.panel", { seq = seq, op = "ping" })
check("request hung (busy)", #hung == 1)
update()
local e1 = state_store["evt.panel"]
check("watchdog times out", e1 ~= nil and e1.ok == false and e1.err.kind == "timeout")
hung[1]({ ok = true, status = 200, body = "return {message=\"pong\"}" })
local e1b = state_store["evt.panel"]
check("late callback ignored", e1b.seq == e1.seq and e1b.ok == false)
mode = "ok"

-- ── auto-retry: same key, exactly one remote ─────────────────────
svc._seam.setRetryDelayMs(0)
mode = "err500"
seq = seq + 1
local posts_before = #posts
fire("cmd.panel", { seq = seq, op = "task.create",
	args = { title = "Retry me", area = "Work", priority = 0 } })
local er = state_store["evt.panel"]
check("first attempt failed", er.ok == false)
local item = svc._registry.items[#svc._registry.items]
local sid = item.source_id
mode = "ok"
update()
check("retry synced, same source_id", item.state == "synced" and item.source_id == sid)
local with_sid = 0
for _, t in ipairs(server.tasks) do
	if t.source_id == sid then
		with_sid = with_sid + 1
	end
end
check("exactly one remote with the key", with_sid == 1)

-- ── max_retries = 0 disables ─────────────────────────────────────
fake_config.max_retries = 0
mode = "err500"
seq = seq + 1
local posts_b2 = #posts
fire("cmd.panel", { seq = seq, op = "task.create", args = { title = "No retry", area = "Work" } })
update()
update()
check("no retry when disabled", #posts == posts_b2 + 1)
fake_config.max_retries = 1

-- ── journal never auto-retries ───────────────────────────────────
mode = "err"
seq = seq + 1
local posts_b3 = #posts
fire("cmd.panel", { seq = seq, op = "journal.create",
	args = { date_on = "2026-10-15", content = "x" } })
update()
update()
check("journal failure stays single", #posts == posts_b3 + 1)
mode = "ok"

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
