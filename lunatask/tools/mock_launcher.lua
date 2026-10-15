-- tools/mock_launcher.lua — M6 tests: /lt rows, activation, notifications.
-- Usage: lua tools/mock_launcher.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local state_store = {
	registry = { schema = 1, items = {
		{ kind = "task", id = "r1", source_id = "nct-1", state = "synced", title = "Buy milk", status = "later" },
		{ kind = "note", id = "r2", source_id = "nct-2", state = "synced", title = "Meeting notes" },
		{ kind = "task", id = "r3", source_id = "nct-3", state = "synced", title = "Unrelated thing", status = "next" },
	} },
}
local watchers = {}
local fake_config = {
	areas = { Work = "11111111-2222-3333-4444-555555555555" },
	default_area = "Work",
	notebooks = {},
	default_notebook = "",
	default_task_status = "next",
}
local results = {} -- setResults calls: {query, rows}
local http_calls = 0
local notified = {}
local toggled = {}

noctalia = {
	getConfig = function(key) return fake_config[key] end,
	tr = function(k, _) return k end,
	fuzzyScore = function(pattern, text)
		if text:lower():find(pattern:lower(), 1, true) then
			return #pattern
		end
		return nil
	end,
	log = function(_) end,
	notify = function(t, b) notified[#notified + 1] = { kind = "info", title = t, body = b } end,
	notifyError = function(t, b) notified[#notified + 1] = { kind = "error", title = t, body = b } end,
	togglePanel = function(id) toggled[#toggled + 1] = id end,
	setUpdateInterval = function(_) end,
	nowMs = function() return 1000 end,
	string = {
		trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
		urlEncode = function(s) return s end,
	},
	json = {
		encode = function(_) return "{}" end,
		decode = function(_) return nil end,
	},
	http = function(_, _)
		http_calls = http_calls + 1
		return true
	end,
	state = {
		set = function(k, v) state_store[k] = v end,
		get = function(k) return state_store[k] end,
		watch = function(k, fn)
			watchers[k] = watchers[k] or {}
			table.insert(watchers[k], fn)
		end,
	},
}

launcher = {
	setResults = function(query, rows) results[#results + 1] = { query = query, rows = rows } end,
}

local os_date = os.date
os.date = function(_) return "2026-10-15" end

local orig_require = require
require = function(path)
	local rel = path:match("^%./(.+)%.luau$")
	if rel then
		return assert(loadfile(PLUGIN_DIR .. rel .. ".luau"))()
	end
	return orig_require(path)
end

os.date = os_date

local function fire(key, msg)
	for _, fn in ipairs(watchers[key] or {}) do
		fn(msg)
	end
end

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then pass = pass + 1 print("PASS " .. name)
	else fail = fail + 1 print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or "")) end
end

assert(loadfile(PLUGIN_DIR .. "launcher.luau"))()

local function row_ids(rows)
	local out = {}
	for _, r in ipairs(rows) do
		out[#out + 1] = r.id
	end
	return out
end

-- ── empty query: hint only ───────────────────────────────────────
onQuery("")
local r0 = results[#results]
check("empty query echoes", r0.query == "")
check("hint row", #r0.rows == 1 and r0.rows[1].id == "hint")

-- ── query: creates + matches, no network ─────────────────────────
onQuery("milk")
local r1 = results[#results]
check("echo exact text", r1.query == "milk")
check("no HTTP in onQuery", http_calls == 0)
local ids = row_ids(r1.rows)
check("create rows first", ids[1] == "create-task" and ids[2] == "create-note" and ids[3] == "create-journal")
check("task row subtitle", r1.rows[1].subtitle == "Create task → Work · next")
local has_match, has_other = false, false
for _, id in ipairs(ids) do
	if id == "open:nct-1" then
		has_match = true
	end
	if id == "open:nct-3" then
		has_other = true
	end
end
check("registry match ranked in", has_match)
check("non-match excluded", not has_other)

-- ── activation: create task ──────────────────────────────────────
onActivate("create-task")
local cmd = state_store["cmd.launcher"]
check("task cmd", cmd.op == "task.create" and cmd.args.title == "milk" and cmd.args.area == "Work")
fire("evt.launcher", { seq = cmd.seq, op = "task.create", ok = true })
check("created notification", notified[#notified].body == "notify.task_created")

-- ── activation: create note + journal ────────────────────────────
onActivate("create-note")
local cmdn = state_store["cmd.launcher"]
check("note cmd unfiled default", cmdn.op == "note.create" and cmdn.args.notebook == nil)
onActivate("create-journal")
local cmdj = state_store["cmd.launcher"]
check("journal cmd today", cmdj.op == "journal.create" and cmdj.args.date_on == "2026-10-15")
fire("evt.launcher", { seq = cmdj.seq, op = "journal.create", ok = false, err = { kind = "auth" } })
check("failure notification", notified[#notified].kind == "error")

-- ── activation: open match -> panel ──────────────────────────────
onActivate("open:nct-1")
check("open_item set", state_store["open_item"] ~= nil and state_store["open_item"].source_id == "nct-1")
check("panel toggled", toggled[#toggled] == "snowballons/lunatask:manager")

-- ── no areas: task row hidden ────────────────────────────────────
fake_config.areas = {}
fake_config.default_area = ""
onQuery("milk")
local r2 = results[#results]
local saw_task = false
for _, id in ipairs(row_ids(r2.rows)) do
	if id == "create-task" then
		saw_task = true
	end
end
check("task row hidden without areas", not saw_task)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
