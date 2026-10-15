-- tools/mock_m2.lua — M2 tests: ids + task.create/task.retry incl. 204 recovery.
-- Usage: lua tools/mock_m2.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local files = {}
local state_store = {}
local watchers = {}
local fake_env = {}
local fake_config = {
	token = "valid-token",
	token_file = "",
	areas = { Work = "11111111-2222-3333-4444-555555555555", Bad = "not-a-uuid" },
	default_task_status = "later",
	cache_bodies = false,
	source_tag = "noctalia",
}
local ms = 1000

-- Fake Lunatask server.
local server = { mode = "ok", tasks = {}, nextId = 1, posts = {}, gets = 0 }

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
	if s:find("pong") and not s:find("^return") then
		return { message = "pong" }
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
	http = function(req, cb)
		local path = req.url:match("^https://api%.lunatask%.app/v1(.*)$")
		if req.method == "GET" and path == "/ping" then
			cb({ ok = true, status = 200, body = '{"message":"pong"}' })
			return true
		end
		if req.method == "POST" and path == "/tasks" then
			local body = dec(req.body) or {}
			server.posts[#server.posts + 1] = body
			if server.mode == "ok" then
				local id = "task-" .. tostring(server.nextId)
				server.nextId = server.nextId + 1
				server.tasks[#server.tasks + 1] =
					{ id = id, source = body.source, source_id = body.source_id }
				cb({ ok = true, status = 201, body = "return {task={id=" .. string.format("%q", id) .. "}}" })
			elseif server.mode == "dup-adopt" then
				cb({ ok = true, status = 204, body = "" })
			elseif server.mode == "dup-miss" then
				cb({ ok = true, status = 204, body = "" })
			elseif server.mode == "err422" then
				cb({ ok = false, status = 422, body = "bad" })
			elseif server.mode == "err500" then
				cb({ ok = false, status = 500, body = "oops" })
			elseif server.mode == "netfail" then
				cb({ ok = false, status = 0, body = "" })
			end
			return true
		end
		if req.method == "GET" and path and path:find("/tasks%?") then
			server.gets = server.gets + 1
			local src, sid = path:match("source=([^&]*)&source_id=(.*)")
			if server.forceHit then
				cb({ ok = true, status = 200, body = "return {tasks={{id=\"server-task-9\"}}}" })
				return true
			end
			if server.mode == "dup-adopt" then
				cb({ ok = true, status = 200, body = "return {tasks={{id=\"server-task-1\"}}}" })
				return true
			end
			local out = {}
			for _, t in ipairs(server.tasks) do
				if t.source == src and t.source_id == sid then
					out[#out + 1] = { id = t.id }
				end
			end
			local parts = {}
			for _, t in ipairs(out) do
				parts[#parts + 1] = "{id=" .. string.format("%q", t.id) .. "}"
			end
			cb({ ok = true, status = 200, body = "return {tasks={" .. table.concat(parts, ",") .. "}}" })
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

-- ── ids ──────────────────────────────────────────────────────────
local ids = require("./lib/ids.luau")
local seen = {}
local fmt_ok = true
for _ = 1, 100 do
	local s = ids.newSourceId()
	if not s:match("^nct%-%d+%-%x%x%x%x%-%d+$") then
		fmt_ok = false
	end
	if seen[s] then
		fmt_ok = false
	end
	seen[s] = true
end
check("source_id format + unique x100", fmt_ok)
check("isDate ok", ids.isDate("2026-10-15") and not ids.isDate("15-10-2026") and not ids.isDate(""))
check("isUuid ok", ids.isUuid("11111111-2222-3333-4444-555555555555") and not ids.isUuid("not-a-uuid"))

-- ── service ──────────────────────────────────────────────────────
local svc = assert(loadfile(PLUGIN_DIR .. "service.luau"))()
local seq = 0
local function cmd(op, args)
	seq = seq + 1
	fire("cmd.panel", { seq = seq, op = op, args = args })
	return state_store["evt.panel"]
end

local BASE_ARGS = { title = "Buy milk", area = "Work", status = "next", priority = 0 }

local e = cmd("task.create", BASE_ARGS)
check("create ok", e.ok == true)
local item = svc._registry.items[1]
check("item synced with id", item.state == "synced" and item.id == "task-1")
check("post body has idempotency pair", server.posts[1].source == "noctalia" and server.posts[1].source_id == item.source_id)
check("post body fields", server.posts[1].area_id == "11111111-2222-3333-4444-555555555555" and server.posts[1].name == "Buy milk")
check("no note cached by default", item.body == nil and item.has_note == false)

-- validation (no HTTP side effects beyond count)
local posts_before = #server.posts
check("empty title rejected", cmd("task.create", { title = "  ", area = "Work" }).ok == false)
check("unknown area rejected", cmd("task.create", { title = "x", area = "Nope" }).ok == false)
check("bad uuid area rejected", cmd("task.create", { title = "x", area = "Bad" }).ok == false)
check("bad date rejected", cmd("task.create", { title = "x", area = "Work", scheduled_on = "tomorrow" }).ok == false)
check("bad priority rejected", cmd("task.create", { title = "x", area = "Work", priority = 5 }).ok == false)
check("no posts on validation failure", #server.posts == posts_before)

-- 204 -> lookup adopts
server.mode = "dup-adopt"
local e204 = cmd("task.create", BASE_ARGS)
local item204 = svc._registry.items[#svc._registry.items]
check("204 adopted via lookup", e204.ok == true and item204.state == "synced" and item204.id == "server-task-1")

-- 204 -> lookup miss -> failed
server.mode = "dup-miss"
local e204m = cmd("task.create", BASE_ARGS)
local item204m = svc._registry.items[#svc._registry.items]
check("204 miss -> failed", e204m.ok == false and item204m.state == "failed")

-- 500 -> lookup hit -> adopted (server actually stored it before failing)
server.mode = "err500"
server.forceHit = true
local e500h = cmd("task.create", BASE_ARGS)
local item500h = svc._registry.items[#svc._registry.items]
check("500 + lookup hit -> adopted", e500h.ok == true and item500h.state == "synced" and item500h.id == "server-task-9")
server.forceHit = false

-- 500 -> lookup miss -> failed
server.mode = "err500"
local gets_before = server.gets
local e500 = cmd("task.create", BASE_ARGS)
local item500 = svc._registry.items[#svc._registry.items]
check("500 miss -> failed + lookup ran", e500.ok == false and item500.state == "failed" and server.gets == gets_before + 1)
check("last_error recorded", item500.last_error == "server")
local sid500 = item500.source_id

-- 422 -> failed, NO lookup
server.mode = "err422"
gets_before = server.gets
local e422 = cmd("task.create", BASE_ARGS)
check("422 -> failed validation, no lookup", e422.ok == false and server.gets == gets_before)

-- retry reuses source_id, succeeds (failed creates have no remote id yet,
-- so retry keys on source_id)
server.mode = "ok"
local posts2 = #server.posts
local er = cmd("task.retry", { id = item500.source_id })
check("retry ok", er.ok == true and item500.state == "synced")
check("retry same source_id (idempotent)", item500.source_id == sid500 and server.posts[#server.posts].source_id == sid500)
check("retry posted again", #server.posts == posts2 + 1)
check("retry unknown id -> not_found", cmd("task.retry", { id = "ghost" }).ok == false)
check("retry synced item rejected", cmd("task.retry", { id = item500.id }).ok == false)

-- cache_bodies stores note; retry without cache flags note_dropped
fake_config.cache_bodies = true
server.mode = "ok"
cmd("task.create", { title = "with note", area = "Work", note = "hello" })
local noted = svc._registry.items[#svc._registry.items]
check("cache on stores body", noted.body == "hello" and noted.has_note == true)
fake_config.cache_bodies = false
server.mode = "netfail"
cmd("task.create", { title = "note nocache", area = "Work", note = "secret" })
local nc = svc._registry.items[#svc._registry.items]
check("cache off drops body, keeps flag", nc.body == nil and nc.has_note == true and nc.state == "failed")
server.mode = "ok"
cmd("task.retry", { id = nc.source_id })
check("retry without cached note flags drop", nc.note_dropped == true and nc.state == "synced")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
