-- panel.luau (M2: Tasks tab functional; Notes/Journal stubs for M4/M5)
-- Protocol (§8): one outstanding command; submits stay disabled until the
-- matching evt.panel arrives (V-02).

local STATUS_OPTS = { "later", "next", "started", "waiting", "completed" }
local PRIO_LABELS = { "Lowest (-2)", "Low (-1)", "Normal (0)", "High (1)", "Highest (2)" }
local PRIO_VALUES = { -2, -1, 0, 1, 2 }

local seq = 0
local pending = nil -- { seq, op } while a command is in flight
local connText = noctalia.tr("ui.panel.status.unknown")
local lastResult = ""
local tab = "tasks"
local regItems = {}
local showForm = false
local formKey = 0
local fTitle = ""
local fNote = ""
local fDate = ""
local fAreaIdx = 1
local fStatusIdx = 1
local fPrioIdx = 3
local selectEcho = "-"

-- Defensive select index: works whether onChange passes a 0- or 1-based
-- index string (V-04 still open; this helper is correct under either).
local function selIdx(raw, n)
	local i = tonumber(raw)
	if i == nil then
		return 1
	end
	if i >= 1 and i <= n then
		return i
	end
	if i >= 0 and i < n then
		return i + 1
	end
	return 1
end

local function areaNames()
	local areas = noctalia.getConfig("areas")
	local names = {}
	if type(areas) == "table" then
		for name, _ in pairs(areas) do
			names[#names + 1] = name
		end
		table.sort(names)
	end
	return names
end

local function statusDefaultIdx()
	local dflt = noctalia.getConfig("default_task_status")
	for i, s in ipairs(STATUS_OPTS) do
		if s == dflt then
			return i
		end
	end
	return 1
end

local function glyphFor(state)
	if state == "synced" then
		return "●"
	elseif state == "failed" then
		return "⚠"
	elseif state == "orphaned" then
		return "✕"
	else
		return "◐"
	end
end

function sendCmd(op, args)
	if pending ~= nil then
		return
	end
	seq = seq + 1
	pending = { seq = seq, op = op }
	render()
	noctalia.state.set("cmd.panel", { seq = seq, op = op, args = args })
end

local function submitTask()
	local names = areaNames()
	if #names == 0 then
		return
	end
	local area = names[fAreaIdx] or names[1]
	sendCmd("task.create", {
		title = fTitle,
		area = area,
		status = STATUS_OPTS[fStatusIdx] or "later",
		priority = PRIO_VALUES[fPrioIdx] or 0,
		scheduled_on = (fDate ~= "" and fDate or nil),
		note = (fNote ~= "" and fNote or nil),
	})
end

local function formTree()
	local names = areaNames()
	if #names == 0 then
		return ui.label({ text = noctalia.tr("ui.panel.no_areas") })
	end
	if fAreaIdx < 1 or fAreaIdx > #names then
		fAreaIdx = 1
	end
	return ui.column({ gap = 8 }, {
		ui.input({
			key = "ftitle" .. tostring(formKey),
			placeholder = noctalia.tr("ui.panel.form.title"),
			onChange = function(v)
				fTitle = v
			end,
		}),
		ui.row({ gap = 8 }, {
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.area") }),
				ui.select({
					options = names,
					selectedIndex = fAreaIdx,
					onChange = function(v)
						fAreaIdx = selIdx(v, #names)
						render()
					end,
				}),
			}),
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.status") }),
				ui.select({
					options = STATUS_OPTS,
					selectedIndex = fStatusIdx,
					onChange = function(v)
						fStatusIdx = selIdx(v, #STATUS_OPTS)
						render()
					end,
				}),
			}),
		}),
		ui.row({ gap = 8 }, {
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.priority") }),
				ui.select({
					options = PRIO_LABELS,
					selectedIndex = fPrioIdx,
					onChange = function(v)
						fPrioIdx = selIdx(v, #PRIO_LABELS)
						render()
					end,
				}),
			}),
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.scheduled") }),
				ui.input({
					key = "fdate" .. tostring(formKey),
					placeholder = "YYYY-MM-DD",
					onChange = function(v)
						fDate = v
					end,
				}),
			}),
		}),
		ui.label({ text = noctalia.tr("ui.panel.form.note") }),
		ui.input({
			key = "fnote" .. tostring(formKey),
			multiline = true,
			placeholder = "Markdown",
			onChange = function(v)
				fNote = v
			end,
		}),
		ui.row({ justify = "end", gap = 8 }, {
			ui.button({
				text = noctalia.tr("ui.panel.cancel"),
				enabled = pending == nil,
				onClick = function()
					showForm = false
					render()
				end,
			}),
			ui.button({
				text = noctalia.tr("ui.panel.create"),
				variant = "primary",
				enabled = pending == nil,
				onClick = function()
					submitTask()
				end,
			}),
		}),
	})
end

local function taskRow(item)
	local key = tostring(item.source_id or item.id or "?")
	local title = tostring(item.title or item.date_on or "?")
	local meta = tostring(item.kind) .. " · " .. tostring(item.state)
	local cells = {
		ui.label({ text = glyphFor(item.state) .. " " .. title, flexGrow = 1 }),
		ui.label({ text = meta }),
	}
	if item.state == "failed" then
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.retry"),
			enabled = pending == nil,
			onClick = function()
				sendCmd("task.retry", { id = item.source_id })
			end,
		}))
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.forget"),
			enabled = pending == nil,
			onClick = function()
				sendCmd("registry.forget", { id = item.source_id })
			end,
		}))
	end
	local rows = { ui.row({ key = "reg-" .. key, gap = 8, align = "center" }, cells) }
	if item.last_error ~= nil then
		table.insert(rows, ui.label({ text = tostring(item.last_error) }))
	end
	if item.note_dropped then
		table.insert(rows, ui.label({ text = noctalia.tr("ui.panel.note_dropped") }))
	end
	return ui.column({ gap = 2 }, rows)
end

local function tasksTab()
	local parts = {}
	table.insert(parts, ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = connText, flexGrow = 1 }),
		ui.button({
			text = noctalia.tr("ui.panel.ping"),
			enabled = pending == nil,
			onClick = function()
				sendCmd("ping")
			end,
		}),
	}))
	if lastResult ~= "" then
		table.insert(parts, ui.label({ text = lastResult }))
	end
	if showForm then
		table.insert(parts, formTree())
	else
		table.insert(parts, ui.button({
			text = noctalia.tr("ui.panel.new_task"),
			enabled = pending == nil,
			onClick = function()
				showForm = true
				render()
			end,
		}))
	end
	table.insert(parts, ui.separator({}))
	if #regItems == 0 then
		table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.registry.empty") }))
	else
		local itemRows = {}
		for i = #regItems, 1, -1 do
			table.insert(itemRows, taskRow(regItems[i]))
		end
		table.insert(parts, ui.scroll({ flexGrow = 1 }, itemRows))
	end
	table.insert(parts, ui.separator({}))
	table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.diag.select_hint") }))
	table.insert(parts, ui.select({
		options = { "alpha", "beta", "gamma" },
		selectedIndex = 1,
		onChange = function(v)
			selectEcho = tostring(v)
			render()
		end,
	}))
	table.insert(parts, ui.label({ text = "select raw=" .. selectEcho }))
	return ui.column({ gap = 10 }, parts)
end

local function render()
	local tabs = ui.row({ gap = 8 }, {
		ui.button({
			text = noctalia.tr("ui.tab.tasks"),
			selected = tab == "tasks",
			onClick = function()
				tab = "tasks"
				render()
			end,
		}),
		ui.button({
			text = noctalia.tr("ui.tab.notes"),
			selected = tab == "notes",
			onClick = function()
				tab = "notes"
				render()
			end,
		}),
		ui.button({
			text = noctalia.tr("ui.tab.journal"),
			selected = tab == "journal",
			onClick = function()
				tab = "journal"
				render()
			end,
		}),
	})
	local body = nil
	if tab == "tasks" then
		body = tasksTab()
	elseif tab == "notes" then
		body = ui.label({ text = noctalia.tr("ui.panel.notes_stub") })
	else
		body = ui.label({ text = noctalia.tr("ui.panel.journal_stub") })
	end
	panel.render(ui.column({ gap = 10, padding = 12 }, {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({ text = noctalia.tr("ui.panel.title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
			ui.button({ text = noctalia.tr("ui.panel.refresh"), onClick = function()
				sendCmd("registry.refresh")
			end, enabled = pending == nil }),
			ui.button({ text = noctalia.tr("ui.panel.settings"), onClick = function()
				noctalia.openSettings()
			end }),
			ui.button({ text = noctalia.tr("ui.panel.close"), onClick = function()
				panel.close()
			end }),
		}),
		ui.label({ text = noctalia.tr("ui.banner.visibility"), maxLines = 3 }),
		tabs,
		body,
	}))
end

noctalia.state.watch("registry", function(msg)
	if type(msg) == "table" then
		regItems = msg.items or {}
		render()
	end
end)

noctalia.state.watch("evt.panel", function(msg)
	if type(msg) ~= "table" or pending == nil then
		return
	end
	if msg.seq ~= pending.seq then
		return
	end
	local op = pending.op
	pending = nil
	if msg.op == "ping" then
		if msg.ok then
			connText = noctalia.tr("ui.panel.status.ok")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			connText = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.op == "task.create" then
		if msg.ok then
			showForm = false
			formKey = formKey + 1
			fTitle = ""
			fNote = ""
			fDate = ""
			fStatusIdx = statusDefaultIdx()
			lastResult = noctalia.tr("notify.task_created")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			lastResult = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.ok ~= true and msg.err ~= nil and msg.err.kind ~= nil then
		lastResult = noctalia.tr("ui.panel.status.fail", { kind = tostring(msg.err.kind) })
	end
	if msg.ok ~= true and msg.err ~= nil and msg.err.kind ~= nil then
		noctalia.log("panel cmd " .. tostring(op) .. " failed kind=" .. tostring(msg.err.kind))
	end
	render()
end)

function onOpen(_context)
	fStatusIdx = statusDefaultIdx()
	render()
end

function onClose()
	pending = nil
end
