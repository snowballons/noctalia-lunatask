-- tools/mock_panel.lua — headless driver for panel.luau.
-- Stubs ui.*/panel/noctalia, then clicks through the whole Tasks flow and
-- fails loudly on any Lua error (the class of bug invisible without logs).
-- Usage: lua tools/mock_panel.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local renders = {} -- panel.render trees, in order
local panel_open = false
local render_after_close = 0
local state_store = {
	registry = { schema = 1, items = {} },
}
local watchers = {}
local LOG = {}

local function node(ctype, props, children)
	return { type = ctype, props = props or {}, children = children or {} }
end

ui = {}
for _, c in ipairs({ "column", "row", "scroll", "label", "markdown", "glyph", "image", "box", "separator", "spacer", "progress", "button", "graph", "toggle", "slider", "select", "input", "dragSource", "dropZone" }) do
	local name = c
	ui[name] = function(props, children)
		return node(name, props, children)
	end
end

panel = {
	render = function(tree)
		if not panel_open then
			render_after_close = render_after_close + 1
		end
		renders[#renders + 1] = tree
	end,
	close = function() panel_open = false end,
}

noctalia = {
	getConfig = function(key)
		if key == "areas" then
			return { Work = "11111111-2222-3333-4444-555555555555" }
		end
		if key == "default_task_status" then
			return "later"
		end
		return nil
	end,
	tr = function(key, subst)
		if type(subst) == "table" then
			for k, v in pairs(subst) do
				key = key:gsub("{" .. k .. "}", tostring(v))
			end
		end
		return key
	end,
	log = function(m) LOG[#LOG + 1] = m end,
	openSettings = function() end,
	setUpdateInterval = function(_) end,
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

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then pass = pass + 1 print("PASS " .. name)
	else fail = fail + 1 print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or "")) end
end

local function walk(tree, out)
	if type(tree) ~= "table" or tree.type == nil then
		return
	end
	out[#out + 1] = tree
	for _, ch in ipairs(tree.children or {}) do
		walk(ch, out)
	end
end

local function nodes(tree)
	local out = {}
	walk(tree, out)
	return out
end

local function find_button(tree, text)
	for _, n in ipairs(nodes(tree)) do
		if n.type == "button" and n.props.text == text then
			return n
		end
	end
	return nil
end

local function find_input(tree, placeholder)
	for _, n in ipairs(nodes(tree)) do
		if n.type == "input" and n.props.placeholder == placeholder then
			return n
		end
	end
	return nil
end

local function find_selects(tree)
	local out = {}
	for _, n in ipairs(nodes(tree)) do
		if n.type == "select" then
			out[#out + 1] = n
		end
	end
	return out
end

local function has_text(tree, text)
	for _, n in ipairs(nodes(tree)) do
		if (n.type == "label" or n.type == "button") and n.props.text == text then
			return true
		end
	end
	return false
end

local function safe_call(name, fn, ...)
	local ok, err = pcall(fn, ...)
	check(name .. " (no error)", ok, err)
	return ok
end

-- ── load + open ──────────────────────────────────────────────────
assert(loadfile(PLUGIN_DIR .. "panel.luau"))()
panel_open = true
safe_call("onOpen", onOpen, "")
local tree = renders[#renders]
check("onOpen renders", tree ~= nil)
check("header + tabs present", has_text(tree, "ui.panel.title") and has_text(tree, "ui.tab.tasks"))
check("empty registry hint", has_text(tree, "ui.panel.registry.empty"))

-- ── reopen seeds existing registry (no watch needed) ───────────────
state_store["registry"] = { schema = 1, items = {
	{ kind = "task", source_id = "nct-0", state = "synced", title = "Old item" },
} }
local renders_before_reopen = #renders
safe_call("reopen", onOpen, "")
tree = renders[#renders]
check("reopen renders", #renders == renders_before_reopen + 1)
check("pre-existing item shown on open", has_text(tree, "● Old item"))

-- ── open form, fill, submit ──────────────────────────────────────
local newbtn = find_button(tree, "+ New task")
-- NOTE: text goes through tr stub which returns the KEY, not English.
newbtn = newbtn or find_button(tree, "ui.panel.new_task")
check("new task button found", newbtn ~= nil)
safe_call("click new task", newbtn.props.onClick)
tree = renders[#renders]
local title_in = find_input(tree, "ui.panel.form.title")
check("form title input present", title_in ~= nil)
safe_call("type title", title_in.props.onChange, "Buy milk")
local sels = find_selects(tree)
check("form has 3 selects + 1 diagnostic", #sels == 4)
safe_call("area select change", sels[1].props.onChange, "1")
local create = find_button(tree, "ui.panel.create")
check("create button found", create ~= nil)
safe_call("click create", create.props.onClick)
local cmd = state_store["cmd.panel"]
check("cmd.panel task.create", cmd ~= nil and cmd.op == "task.create")
check("create args", cmd.args.title == "Buy milk" and cmd.args.area == "Work" and cmd.args.priority == 0)

-- ── service ok -> form collapses ─────────────────────────────────
safe_call("evt ok", fire, "evt.panel", { seq = cmd.seq, op = "task.create", ok = true })
tree = renders[#renders]
check("form collapsed after ok", find_input(tree, "ui.panel.form.title") == nil)
check("created notice shown", has_text(tree, "notify.task_created"))

-- ── registry publishes item -> row appears ───────────────────────
safe_call("registry watch", fire, "registry", { schema = 1, items = {
	{ kind = "task", source_id = "nct-1", state = "synced", title = "Buy milk" },
} })
tree = renders[#renders]
check("synced row shown", has_text(tree, "● Buy milk"))

-- ── failed row -> retry + forget ─────────────────────────────────
safe_call("failed watch", fire, "registry", { schema = 1, items = {
	{ kind = "task", source_id = "nct-2", state = "failed", title = "Bad one", last_error = "validation" },
} })
tree = renders[#renders]
local retry = find_button(tree, "ui.panel.retry")
check("retry button on failed row", retry ~= nil)
safe_call("click retry", retry.props.onClick)
local cmd2 = state_store["cmd.panel"]
check("retry cmd keyed by source_id", cmd2.op == "task.retry" and cmd2.args.id == "nct-2")
safe_call("evt retry ok", fire, "evt.panel", { seq = cmd2.seq, op = "task.retry", ok = true })

-- ── stale evt ignored ────────────────────────────────────────────
local n_renders = #renders
safe_call("stale evt", fire, "evt.panel", { seq = 99999, op = "ping", ok = true })
check("stale evt ignored (no rerender)", #renders == n_renders)

-- ── tabs ─────────────────────────────────────────────────────────
safe_call("notes tab", find_button(renders[#renders], "ui.tab.notes").props.onClick)
check("notes stub", has_text(renders[#renders], "ui.panel.notes_stub"))
safe_call("journal tab", find_button(renders[#renders], "ui.tab.journal").props.onClick)
check("journal stub", has_text(renders[#renders], "ui.panel.journal_stub"))
safe_call("back to tasks", find_button(renders[#renders], "ui.tab.tasks").props.onClick)

-- ── M3: edit flow (diff-only submit) ───────────────────────────────
safe_call("synced for edit", fire, "registry", { schema = 1, items = {
	{ kind = "task", id = "rid-1", source_id = "nct-1", state = "synced",
		title = "Task one", status = "later", priority = 0, scheduled_on = nil, body = nil },
} })
tree = renders[#renders]
local editbtn = find_button(tree, "ui.panel.edit")
check("edit button on synced row", editbtn ~= nil)
safe_call("open edit", editbtn.props.onClick)
tree = renders[#renders]
local etitle = find_input(tree, "ui.panel.form.title")
check("edit title input present", etitle ~= nil)
safe_call("change title only", etitle.props.onChange, "Task uno")
local savebtn = find_button(tree, "ui.panel.save")
check("save button found", savebtn ~= nil)
safe_call("click save", savebtn.props.onClick)
local cmdu = state_store["cmd.panel"]
check("update cmd id", cmdu.op == "task.update" and cmdu.args.id == "rid-1")
local diffkeys = {}
for k, _ in pairs(cmdu.args.changes) do
	diffkeys[#diffkeys + 1] = k
end
check("diff-only changes (name)", #diffkeys == 1 and cmdu.args.changes.name == "Task uno")
safe_call("evt update ok", fire, "evt.panel", { seq = cmdu.seq, op = "task.update", ok = true })
tree = renders[#renders]
check("edit closed + saved notice", find_input(tree, "ui.panel.form.title") == nil and has_text(tree, "ui.panel.updated"))

-- ── M3: one-click complete ───────────────────────────────────────
local compbtn = find_button(tree, "ui.panel.complete")
check("complete button found", compbtn ~= nil)
safe_call("click complete", compbtn.props.onClick)
local cmdc = state_store["cmd.panel"]
check("complete sends status only", cmdc.op == "task.update" and cmdc.args.changes.status == "completed")
safe_call("evt complete ok", fire, "evt.panel", { seq = cmdc.seq, op = "task.update", ok = true })

-- ── M3: two-step delete ──────────────────────────────────────────
local delbtn = find_button(renders[#renders], "ui.panel.delete")
check("delete button found", delbtn ~= nil)
safe_call("first click arms", delbtn.props.onClick)
local cmd_armed = state_store["cmd.panel"]
check("first click sends nothing", cmd_armed.seq == cmdc.seq)
tree = renders[#renders]
local confirmbtn = find_button(tree, "ui.delete.confirm")
check("confirm delete shown", confirmbtn ~= nil)
safe_call("second click deletes", confirmbtn.props.onClick)
local cmdd = state_store["cmd.panel"]
check("delete cmd", cmdd.op == "task.delete" and cmdd.args.id == "rid-1")
safe_call("evt delete ok", fire, "evt.panel", { seq = cmdd.seq, op = "task.delete", ok = true })
check("deleted notice", has_text(renders[#renders], "ui.panel.deleted"))

-- ── M3: completed status visible, no Complete button ──────────────
safe_call("completed watch", fire, "registry", { schema = 1, items = {
	{ kind = "task", id = "rid-2", source_id = "nct-3", state = "synced",
		title = "Done thing", status = "completed", priority = 0 },
} })
tree = renders[#renders]
check("status shown in row meta", has_text(tree, "completed · synced"))
check("no Complete button when completed", find_button(tree, "ui.panel.complete") == nil)

-- ── M3: orphan forget + refresh display ──────────────────────────
safe_call("orphan watch", fire, "registry", { schema = 1, items = {
	{ kind = "task", id = "rid-9", source_id = "nct-9", state = "orphaned", title = "Gone" },
} })
tree = renders[#renders]
check("orphan hint shown", has_text(tree, "ui.panel.orphaned_hint"))
local refresher = find_button(tree, "ui.panel.refresh")
safe_call("click refresh", refresher.props.onClick)
local cmdr = state_store["cmd.panel"]
check("refresh cmd", cmdr.op == "registry.refresh")
safe_call("evt refresh ok/2 orphaned", fire, "evt.panel",
	{ seq = cmdr.seq, op = "registry.refresh", ok = true, orphaned = 2 })
check("refresh orphan count shown", has_text(renders[#renders], "ui.panel.refresh_ok ui.panel.refresh_orphaned"))

-- ── render-while-closed ──────────────────────────────────────────
panel_open = false
if type(onClose) == "function" then
	safe_call("onClose", onClose)
end
local rac_before = render_after_close
safe_call("watch while closed", fire, "registry", { schema = 1, items = {} })
check("NO render after close", render_after_close == rac_before,
	"rendered " .. tostring(render_after_close - rac_before) .. "x while closed")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
