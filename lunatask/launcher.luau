-- launcher.luau (M6): /lt quick capture + registry search.
-- onQuery never touches the network: it answers from settings + the registry
-- snapshot. Only onActivate sends a command to the service.

local ids = require("./lib/ids.luau")

local seq = 0
local pending = {} -- seq -> true while a command is in flight
local lastText = ""

local function regItems()
	local reg = noctalia.state.get("registry")
	if type(reg) == "table" and type(reg.items) == "table" then
		return reg.items
	end
	return {}
end

local function defaultArea()
	local areas = noctalia.getConfig("areas")
	if type(areas) ~= "table" then
		return nil
	end
	local dflt = noctalia.getConfig("default_area")
	if type(dflt) == "string" and dflt ~= "" and areas[dflt] ~= nil then
		return dflt
	end
	return nil
end

local function defaultNotebook()
	local books = noctalia.getConfig("notebooks")
	if type(books) ~= "table" then
		return nil
	end
	local dflt = noctalia.getConfig("default_notebook")
	if type(dflt) == "string" and dflt ~= "" and books[dflt] ~= nil then
		return dflt
	end
	return nil
end

local function defaultStatus()
	local s = noctalia.getConfig("default_task_status")
	if s == "later" or s == "next" or s == "started" or s == "waiting" then
		return s
	end
	return "later"
end

function onQuery(text)
	text = text or ""
	lastText = text
	local rows = {}
	if text == "" then
		rows[#rows + 1] = {
			id = "hint",
			title = "/lt <text> — create a task, note, or journal entry",
			glyph = "checklist",
		}
	else
		local area = defaultArea()
		if area ~= nil then
			rows[#rows + 1] = {
				id = "create-task",
				title = text,
				subtitle = "Create task → " .. area .. " · " .. defaultStatus(),
				glyph = "checkbox",
			}
		end
		local notebook = defaultNotebook()
		rows[#rows + 1] = {
			id = "create-note",
			title = text,
			subtitle = "Create note → " .. (notebook or noctalia.tr("ui.panel.unfiled")),
			glyph = "note",
		}
		rows[#rows + 1] = {
			id = "create-journal",
			title = "Add to today's journal",
			subtitle = text,
			glyph = "calendar",
		}
		local scored = {}
		for _, item in ipairs(regItems()) do
			if item.kind == "task" or item.kind == "note" then
				local score = noctalia.fuzzyScore(text, tostring(item.title or ""))
				if score ~= nil then
					scored[#scored + 1] = { score = score, item = item }
				end
			end
		end
		table.sort(scored, function(a, b)
			return a.score > b.score
		end)
		for i = 1, math.min(5, #scored) do
			local item = scored[i].item
			rows[#rows + 1] = {
				id = "open:" .. tostring(item.source_id or item.id),
				title = tostring(item.title or "?"),
				subtitle = tostring(item.kind) .. " · " .. tostring(item.status or item.state),
				glyph = item.kind == "task" and "checkbox" or "note",
			}
		end
	end
	-- query must echo the onQuery text, or late results are dropped.
	launcher.setResults(text, rows)
end

local function send(op, args)
	seq = seq + 1
	pending[seq] = true
	noctalia.state.set("cmd.launcher", { seq = seq, op = op, args = args, gen = noctalia.state.get("svc_boot") })
end

function onActivate(id)
	if id == "create-task" then
		local area = defaultArea()
		if area == nil then
			return
		end
		send("task.create", { title = lastText, area = area, status = defaultStatus(), priority = 0 })
	elseif id == "create-note" then
		send("note.create", { title = lastText, notebook = defaultNotebook() })
	elseif id == "create-journal" then
		send("journal.create", { date_on = ids.today(), content = lastText })
	elseif type(id) == "string" and id:sub(1, 5) == "open:" then
		local sid = id:sub(6)
		noctalia.state.set("open_item", { source_id = sid })
		noctalia.togglePanel("snowballons/lunatask:manager")
	end
end

noctalia.state.watch("evt.launcher", function(msg)
	if type(msg) ~= "table" or msg.seq == nil or not pending[msg.seq] then
		return
	end
	pending[msg.seq] = nil
	if msg.ok then
		if msg.op == "task.create" then
			noctalia.notify("Lunatask", noctalia.tr("notify.task_created"))
		elseif msg.op == "note.create" then
			noctalia.notify("Lunatask", noctalia.tr("notify.note_created"))
		elseif msg.op == "journal.create" then
			noctalia.notify("Lunatask", noctalia.tr("notify.journal_created"))
		end
	else
		local kind = (msg.err and msg.err.kind) or "error"
		noctalia.notifyError("Lunatask", kind)
	end
end)
