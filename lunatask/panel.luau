-- panel.luau (M5: Tasks + Notes + Journal tabs)
-- Protocol (§8): one outstanding command; submits stay disabled until the
-- matching evt.panel arrives.

local ids = require("./lib/ids.luau")

local STATUS_OPTS = { "later", "next", "started", "waiting", "completed" }
local PRIO_LABELS = { "Lowest (-2)", "Low (-1)", "Normal (0)", "High (1)", "Highest (2)" }
local PRIO_VALUES = { -2, -1, 0, 1, 2 }

noctalia.setUpdateInterval(1000)

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
local open = false -- true between onOpen and onClose; watchers skip render when closed
local editingSid = nil -- source_id of the task being edited (edit form open)
local eKey = 0 -- reseed key for edit inputs
local eTitle = ""
local eNote = ""
local eDate = ""
local eStatusIdx = 1
local ePrioIdx = 3
local delArmSid = nil -- source_id with armed delete confirm
local delArmLeft = 0 -- seconds left before the confirm reverts
local nshowForm = false
local nformKey = 0
local nTitle = ""
local nContent = ""
local nDate = ""
local nBookIdx = 1 -- 1 = Unfiled, else nbNames()[idx - 1]
local neditingSid = nil
local neKey = 0
local neTitle = ""
local neContent = ""
local neDate = ""
local neBookIdx = 1
local jKey = 0
local jDate = ids.today()
local jName = ""
local jContent = ""
local jErr = ""

-- Forward declaration: every onClick/onChange closure below calls render(),
-- but render() is defined at the bottom. Without this, those closures would
-- resolve a (nil) global instead of the local and crash on first click.
local render

-- Select index base (V-04, resolved live Oct 2026): ui.select is 0-BASED,
-- both for the selectedIndex prop and the onChange value. Internals stay
-- 1-based Lua; convert at the boundary (outgoing -1, incoming +1).
local function selIdx(raw, n)
	local i = tonumber(raw)
	if i == nil then
		return 1
	end
	i = math.floor(i)
	if i < 0 then
		return 1
	end
	if i < n then
		return i + 1
	end
	return n
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

-- Notebook options for the create form: first entry is explicit Unfiled.
local function nbNames()
	local books = noctalia.getConfig("notebooks")
	local names = {}
	if type(books) == "table" then
		for name, _ in pairs(books) do
			names[#names + 1] = name
		end
		table.sort(names)
	end
	return names
end

local function nbOptions()
	local opts = { noctalia.tr("ui.panel.unfiled") }
	for _, n in ipairs(nbNames()) do
		opts[#opts + 1] = n
	end
	return opts
end

-- Outgoing value for a create-form notebook index: false = omit even when a
-- default_notebook is configured; otherwise the notebook name.
local function nbChoice(idx)
	local names = nbNames()
	if idx <= 1 then
		return false
	end
	return names[idx - 1]
end

local function statusIdxFor(value)
	for i, s in ipairs(STATUS_OPTS) do
		if s == value then
			return i
		end
	end
	return 1
end

local function prioIdxFor(value)
	for i, p in ipairs(PRIO_VALUES) do
		if p == value then
			return i
		end
	end
	return 3
end

local function statusDefaultIdx()
	local dflt = noctalia.getConfig("default_task_status")
	return statusIdxFor(dflt)
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
	pending = { seq = seq, op = op, since = noctalia.nowMs() }
	render()
	-- gen: the service generation seen by this panel (§8.3). Lets the service
	-- tell a restarted counter (seq back at 0) apart from a duplicate.
	noctalia.state.set("cmd.panel", { seq = seq, op = op, args = args, gen = noctalia.state.get("svc_boot") })
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
					selectedIndex = fAreaIdx - 1,
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
					selectedIndex = fStatusIdx - 1,
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
					selectedIndex = fPrioIdx - 1,
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

local function openEdit(item)
	editingSid = tostring(item.source_id or item.id)
	eKey = eKey + 1
	eTitle = tostring(item.title or "")
	eStatusIdx = statusIdxFor(item.status)
	ePrioIdx = prioIdxFor(item.priority)
	eDate = tostring(item.scheduled_on or "")
	-- Body only when cached (D6); otherwise start empty and never send it.
	eNote = tostring(item.body or "")
	render()
end

local function submitEdit()
	local item = nil
	for _, it in ipairs(regItems) do
		if tostring(it.source_id or it.id) == editingSid then
			item = it
			break
		end
	end
	if item == nil or item.id == nil then
		editingSid = nil
		render()
		return
	end
	-- Send only the fields that changed (partial PUT).
	local changes = {}
	if eTitle ~= tostring(item.title or "") then
		changes.name = eTitle
	end
	local status = STATUS_OPTS[eStatusIdx] or "later"
	if status ~= item.status then
		changes.status = status
	end
	local prio = PRIO_VALUES[ePrioIdx]
	if prio == nil then
		prio = 0
	end
	if prio ~= item.priority then
		changes.priority = prio
	end
	if eDate ~= tostring(item.scheduled_on or "") and eDate ~= "" then
		changes.scheduled_on = eDate
	end
	if item.body ~= nil then
		if eNote ~= tostring(item.body or "") then
			changes.note = eNote
		end
	elseif eNote ~= "" then
		changes.note = eNote
	end
	local empty = true
	for _, _ in pairs(changes) do
		empty = false
		break
	end
	if empty then
		editingSid = nil
		render()
		return
	end
	sendCmd("task.update", { id = item.id, changes = changes })
end

local function editTree()
	return ui.column({ gap = 8 }, {
		ui.input({
			key = "etitle" .. tostring(eKey),
			value = eTitle,
			placeholder = noctalia.tr("ui.panel.form.title"),
			onChange = function(v)
				eTitle = v
			end,
		}),
		ui.row({ gap = 8 }, {
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.status") }),
				ui.select({
					options = STATUS_OPTS,
					selectedIndex = eStatusIdx - 1,
					onChange = function(v)
						eStatusIdx = selIdx(v, #STATUS_OPTS)
						render()
					end,
				}),
			}),
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.priority") }),
				ui.select({
					options = PRIO_LABELS,
					selectedIndex = ePrioIdx - 1,
					onChange = function(v)
						ePrioIdx = selIdx(v, #PRIO_LABELS)
						render()
					end,
				}),
			}),
		}),
		ui.label({ text = noctalia.tr("ui.panel.form.scheduled") }),
		ui.input({
			key = "edate" .. tostring(eKey),
			value = eDate,
			placeholder = "YYYY-MM-DD",
			onChange = function(v)
				eDate = v
			end,
		}),
		ui.label({ text = noctalia.tr("ui.panel.edit_note_hint") }),
		ui.input({
			key = "enote" .. tostring(eKey),
			value = eNote,
			multiline = true,
			placeholder = "Markdown",
			onChange = function(v)
				eNote = v
			end,
		}),
		ui.row({ justify = "end", gap = 8 }, {
			ui.button({
				text = noctalia.tr("ui.panel.cancel"),
				enabled = pending == nil,
				onClick = function()
					editingSid = nil
					render()
				end,
			}),
			ui.button({
				text = noctalia.tr("ui.panel.save"),
				variant = "primary",
				enabled = pending == nil,
				onClick = function()
					submitEdit()
				end,
			}),
		}),
	})
end

local function taskRow(item)
	local key = tostring(item.source_id or item.id or "?")
	local title = tostring(item.title or item.date_on or "?")
	-- Show the Lunatask status (later/next/…/completed) alongside our sync
	-- state: without it, an app-side completion is invisible in the panel.
	local taskStatus = tostring(item.status or "-")
	local meta = taskStatus .. " · " .. tostring(item.state)
	local cells = {
		ui.label({ text = glyphFor(item.state) .. " " .. title, flexGrow = 1 }),
		ui.label({ text = meta }),
	}
	if item.state == "synced" then
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.edit"),
			enabled = pending == nil,
			onClick = function()
				openEdit(item)
			end,
		}))
		if taskStatus ~= "completed" then
			table.insert(cells, ui.button({
				text = noctalia.tr("ui.panel.complete"),
				enabled = pending == nil,
				onClick = function()
					sendCmd("task.update", { id = item.id, changes = { status = "completed" } })
				end,
			}))
		end
		local deleting = (delArmSid ~= nil and delArmSid == key)
		local confirm = noctalia.getConfig("confirm_delete")
		if confirm == false then
			confirm = false
		else
			confirm = true
		end
		table.insert(cells, ui.button({
			text = deleting and noctalia.tr("ui.delete.confirm") or noctalia.tr("ui.panel.delete"),
			variant = deleting and "destructive" or nil,
			enabled = pending == nil,
			onClick = function()
				if not confirm or (delArmSid ~= nil and delArmSid == key) then
					delArmSid = nil
					sendCmd("task.delete", { id = item.id })
				else
					delArmSid = key
					delArmLeft = 5
					render()
				end
			end,
		}))
	elseif item.state == "orphaned" then
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.forget"),
			enabled = pending == nil,
			onClick = function()
				sendCmd("registry.forget", { id = item.source_id })
			end,
		}))
	end
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
	if item.state == "orphaned" then
		table.insert(rows, ui.label({ text = noctalia.tr("ui.panel.orphaned_hint") }))
	end
	return ui.column({ gap = 2 }, rows)
end

local function submitNote()
	sendCmd("note.create", {
		title = nTitle,
		notebook = nbChoice(nBookIdx),
		date_on = (nDate ~= "" and nDate or nil),
		content = (nContent ~= "" and nContent or nil),
	})
end

local function nFormTree()
	local opts = nbOptions()
	if nBookIdx < 1 or nBookIdx > #opts then
		nBookIdx = 1
	end
	return ui.column({ gap = 8 }, {
		ui.input({
			key = "ntitle" .. tostring(nformKey),
			placeholder = noctalia.tr("ui.panel.form.title"),
			onChange = function(v)
				nTitle = v
			end,
		}),
		ui.row({ gap = 8 }, {
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.notebook") }),
				ui.select({
					options = opts,
					selectedIndex = nBookIdx - 1,
					onChange = function(v)
						nBookIdx = selIdx(v, #opts)
						render()
					end,
				}),
			}),
			ui.column({ flexGrow = 1 }, {
				ui.label({ text = noctalia.tr("ui.panel.form.date") }),
				ui.input({
					key = "ndate" .. tostring(nformKey),
					placeholder = "YYYY-MM-DD",
					onChange = function(v)
						nDate = v
					end,
				}),
			}),
		}),
		ui.label({ text = noctalia.tr("ui.panel.form.content") }),
		ui.input({
			key = "ncontent" .. tostring(nformKey),
			multiline = true,
			placeholder = "Markdown",
			onChange = function(v)
				nContent = v
			end,
		}),
		ui.row({ justify = "end", gap = 8 }, {
			ui.button({
				text = noctalia.tr("ui.panel.cancel"),
				enabled = pending == nil,
				onClick = function()
					nshowForm = false
					render()
				end,
			}),
			ui.button({
				text = noctalia.tr("ui.panel.create"),
				variant = "primary",
				enabled = pending == nil,
				onClick = function()
					submitNote()
				end,
			}),
		}),
	})
end

local function openNEdit(item)
	neditingSid = tostring(item.source_id or item.id)
	neKey = neKey + 1
	neTitle = tostring(item.title or "")
	neDate = tostring(item.date_on or "")
	neContent = tostring(item.body or "")
	neBookIdx = 1
	local names = nbNames()
	for i, n in ipairs(names) do
		if n == item.notebook_name then
			neBookIdx = i
			break
		end
	end
	render()
end

local function submitNEdit()
	local item = nil
	for _, it in ipairs(regItems) do
		if tostring(it.source_id or it.id) == neditingSid then
			item = it
			break
		end
	end
	if item == nil or item.id == nil then
		neditingSid = nil
		render()
		return
	end
	local changes = {}
	if neTitle ~= tostring(item.title or "") then
		changes.name = neTitle
	end
	local names = nbNames()
	local selName = names[neBookIdx]
	if selName ~= nil and selName ~= item.notebook_name then
		changes.notebook = selName
	end
	if neDate ~= tostring(item.date_on or "") and neDate ~= "" then
		changes.date_on = neDate
	end
	-- Content replaces the whole note (C3): send only when the user typed
	-- something new. Renaming / moving / re-dating never touches the body.
	if item.body ~= nil then
		if neContent ~= tostring(item.body or "") then
			changes.content = neContent
		end
	elseif neContent ~= "" then
		changes.content = neContent
	end
	local empty = true
	for _, _ in pairs(changes) do
		empty = false
		break
	end
	if empty then
		neditingSid = nil
		render()
		return
	end
	sendCmd("note.update", { id = item.id, changes = changes })
end

local function nEditTree()
	local names = nbNames()
	local parts = {
		ui.input({
			key = "netitle" .. tostring(neKey),
			value = neTitle,
			placeholder = noctalia.tr("ui.panel.form.title"),
			onChange = function(v)
				neTitle = v
			end,
		}),
	}
	if #names > 0 then
		if neBookIdx < 1 or neBookIdx > #names then
			neBookIdx = 1
		end
		table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.form.notebook") }))
		table.insert(parts, ui.select({
			options = names,
			selectedIndex = neBookIdx - 1,
			onChange = function(v)
				neBookIdx = selIdx(v, #names)
				render()
			end,
		}))
	end
	table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.form.date") }))
	table.insert(parts, ui.input({
		key = "nedate" .. tostring(neKey),
		value = neDate,
		placeholder = "YYYY-MM-DD",
		onChange = function(v)
			neDate = v
		end,
	}))
	table.insert(parts, ui.label({ text = noctalia.tr("ui.note.replace_warning") }))
	table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.edit_note_hint") }))
	table.insert(parts, ui.input({
		key = "necontent" .. tostring(neKey),
		value = neContent,
		multiline = true,
		placeholder = "Markdown",
		onChange = function(v)
			neContent = v
		end,
	}))
	table.insert(parts, ui.row({ justify = "end", gap = 8 }, {
		ui.button({
			text = noctalia.tr("ui.panel.cancel"),
			enabled = pending == nil,
			onClick = function()
				neditingSid = nil
				render()
			end,
		}),
		ui.button({
			text = noctalia.tr("ui.panel.save"),
			variant = "primary",
			enabled = pending == nil,
			onClick = function()
				submitNEdit()
			end,
		}),
	}))
	return ui.column({ gap = 8 }, parts)
end

local function noteRow(item)
	local key = tostring(item.source_id or item.id or "?")
	local title = tostring(item.title or "?")
	local where = tostring(item.notebook_name or noctalia.tr("ui.panel.unfiled"))
	local meta = where .. " · " .. tostring(item.state)
	local cells = {
		ui.label({ text = glyphFor(item.state) .. " " .. title, flexGrow = 1 }),
		ui.label({ text = meta }),
	}
	if item.state == "synced" then
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.edit"),
			enabled = pending == nil,
			onClick = function()
				openNEdit(item)
			end,
		}))
		local deleting = (delArmSid ~= nil and delArmSid == key)
		table.insert(cells, ui.button({
			text = deleting and noctalia.tr("ui.delete.confirm") or noctalia.tr("ui.panel.delete"),
			variant = deleting and "destructive" or nil,
			enabled = pending == nil,
			onClick = function()
				local confirm = noctalia.getConfig("confirm_delete")
				if confirm == false then
					confirm = false
				else
					confirm = true
				end
				if not confirm or (delArmSid ~= nil and delArmSid == key) then
					delArmSid = nil
					sendCmd("note.delete", { id = item.id })
				else
					delArmSid = key
					delArmLeft = 5
					render()
				end
			end,
		}))
	elseif item.state == "failed" then
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.retry"),
			enabled = pending == nil,
			onClick = function()
				sendCmd("note.retry", { id = item.source_id })
			end,
		}))
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.forget"),
			enabled = pending == nil,
			onClick = function()
				sendCmd("registry.forget", { id = item.source_id })
			end,
		}))
	elseif item.state == "orphaned" then
		table.insert(cells, ui.button({
			text = noctalia.tr("ui.panel.forget"),
			enabled = pending == nil,
			onClick = function()
				sendCmd("registry.forget", { id = item.source_id })
			end,
		}))
	end
	local rows = { ui.row({ key = "nreg-" .. key, gap = 8, align = "center" }, cells) }
	if item.last_error ~= nil then
		table.insert(rows, ui.label({ text = tostring(item.last_error) }))
	end
	if item.state == "orphaned" then
		table.insert(rows, ui.label({ text = noctalia.tr("ui.panel.orphaned_hint") }))
	end
	return ui.column({ gap = 2 }, rows)
end

local function notesTab()
	local parts = {}
	if lastResult ~= "" then
		table.insert(parts, ui.label({ text = lastResult }))
	end
	if nshowForm then
		table.insert(parts, nFormTree())
	else
		table.insert(parts, ui.button({
			text = noctalia.tr("ui.panel.new_note"),
			enabled = pending == nil,
			onClick = function()
				nshowForm = true
				render()
			end,
		}))
	end
	table.insert(parts, ui.separator({}))
	if neditingSid ~= nil then
		table.insert(parts, nEditTree())
		table.insert(parts, ui.separator({}))
	end
	local found = false
	local itemRows = {}
	for i = #regItems, 1, -1 do
		if regItems[i].kind == "note" then
			found = true
			table.insert(itemRows, noteRow(regItems[i]))
		end
	end
	if not found then
		table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.registry.empty") }))
	else
		table.insert(parts, ui.scroll({ flexGrow = 1 }, itemRows))
	end
	return ui.column({ gap = 10 }, parts)
end

local function submitJournal()
	-- Local pre-check (M5 acceptance): malformed dates never hit the network.
	if not ids.isDate(jDate) then
		jErr = noctalia.tr("ui.panel.bad_date")
		render()
		return
	end
	local content = noctalia.string.trim(jContent)
	if content == "" then
		jErr = ""
		render()
		return
	end
	jErr = ""
	sendCmd("journal.create", {
		date_on = jDate,
		content = jContent,
		name = (jName ~= "" and jName or nil),
	})
end

local function journalTab()
	local parts = {}
	if lastResult ~= "" then
		table.insert(parts, ui.label({ text = lastResult }))
	end
	table.insert(parts, ui.row({ gap = 8 }, {
		ui.column({ flexGrow = 1 }, {
			ui.label({ text = noctalia.tr("ui.panel.form.scheduled") }),
			ui.input({
				key = "jdate" .. tostring(jKey),
				value = jDate,
				placeholder = "YYYY-MM-DD",
				onChange = function(v)
					jDate = v
				end,
			}),
		}),
		ui.column({ flexGrow = 2 }, {
			ui.label({ text = noctalia.tr("ui.panel.form.jname") }),
			ui.input({
				key = "jname" .. tostring(jKey),
				value = jName,
				onChange = function(v)
					jName = v
				end,
			}),
		}),
	}))
	if jErr ~= "" then
		table.insert(parts, ui.label({ text = jErr }))
	end
	table.insert(parts, ui.input({
		key = "jcontent" .. tostring(jKey),
		value = jContent,
		multiline = true,
		placeholder = "Markdown",
		onChange = function(v)
			jContent = v
		end,
	}))
	table.insert(parts, ui.row({ justify = "end", gap = 8 }, {
		ui.button({
			text = noctalia.tr("ui.panel.create"),
			variant = "primary",
			enabled = pending == nil,
			onClick = function()
				submitJournal()
			end,
		}),
	}))
	table.insert(parts, ui.separator({}))
	table.insert(parts, ui.label({ text = noctalia.tr("ui.journal.no_edit") }))
	local found = false
	local itemRows = {}
	for i = #regItems, 1, -1 do
		local item = regItems[i]
		if item.kind == "journal" then
			found = true
			local key = tostring(item.id or item.date_on or "?") .. "-" .. tostring(i)
			local line = glyphFor(item.state) .. " " .. tostring(item.date_on or "?")
			if item.excerpt ~= nil then
				line = line .. " — " .. tostring(item.excerpt):sub(1, 80)
			end
			local rows = { ui.label({ key = "jreg-" .. key, text = line }) }
			if item.last_error ~= nil then
				table.insert(rows, ui.label({ text = tostring(item.last_error) }))
			end
			table.insert(itemRows, ui.column({ gap = 2 }, rows))
		end
	end
	if not found then
		table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.registry.empty") }))
	else
		table.insert(parts, ui.scroll({ flexGrow = 1 }, itemRows))
	end
	return ui.column({ gap = 10 }, parts)
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
	if editingSid ~= nil then
		table.insert(parts, editTree())
		table.insert(parts, ui.separator({}))
	end
	if #regItems == 0 then
		table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.registry.empty") }))
	else
		local itemRows = {}
		local found = false
		for i = #regItems, 1, -1 do
			if regItems[i].kind == "task" then
				found = true
				table.insert(itemRows, taskRow(regItems[i]))
			end
		end
		if not found then
			table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.registry.empty") }))
		else
			table.insert(parts, ui.scroll({ flexGrow = 1 }, itemRows))
		end
	end
	table.insert(parts, ui.separator({}))
	table.insert(parts, ui.label({ text = noctalia.tr("ui.panel.diag.select_hint") }))
	table.insert(parts, ui.select({
		options = { "alpha", "beta", "gamma" },
		selectedIndex = 0,
		onChange = function(v)
			selectEcho = tostring(v)
			render()
		end,
	}))
	table.insert(parts, ui.label({ text = "select raw=" .. selectEcho }))
	return ui.column({ gap = 10 }, parts)
end

render = function()
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
		body = notesTab()
	else
		body = journalTab()
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
		if open then
			render()
		end
	end
end)

-- Service restarted (or reloaded): our in-flight command died with its old VM.
-- Un-stick the submit buttons instead of staying disabled forever.
noctalia.state.watch("svc_boot", function(_msg)
	if pending ~= nil then
		pending = nil
		lastResult = noctalia.tr("err.timeout")
		if open then
			render()
		end
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
	elseif msg.op == "task.update" then
		if msg.ok then
			editingSid = nil
			lastResult = noctalia.tr("ui.panel.updated")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			lastResult = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.op == "task.delete" then
		if msg.ok then
			delArmSid = nil
			lastResult = noctalia.tr("ui.panel.deleted")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			lastResult = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.op == "note.create" then
		if msg.ok then
			nshowForm = false
			nformKey = nformKey + 1
			nTitle = ""
			nContent = ""
			nDate = ""
			lastResult = noctalia.tr("notify.note_created")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			lastResult = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.op == "note.update" then
		if msg.ok then
			neditingSid = nil
			lastResult = noctalia.tr("ui.panel.updated")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			lastResult = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.op == "note.delete" then
		if msg.ok then
			delArmSid = nil
			lastResult = noctalia.tr("ui.panel.deleted")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			lastResult = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.op == "journal.create" then
		if msg.ok then
			jKey = jKey + 1
			jContent = ""
			jName = ""
			jDate = ids.today()
			lastResult = noctalia.tr("notify.journal_created")
		else
			local kind = (msg.err and msg.err.kind) or "?"
			lastResult = noctalia.tr("ui.panel.status.fail", { kind = kind })
		end
	elseif msg.op == "registry.refresh" then
		if msg.ok then
			if msg.warning ~= nil then
				lastResult = tostring(msg.warning)
			elseif (msg.orphaned or 0) > 0 then
				lastResult = noctalia.tr("ui.panel.refresh_ok") .. " "
					.. noctalia.tr("ui.panel.refresh_orphaned", { n = tostring(msg.orphaned) })
			else
				lastResult = noctalia.tr("ui.panel.refresh_ok")
			end
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
	if open then
		render()
	end
end)

function onOpen(_context)
	open = true
	-- Seed from current state: the service publishes the registry long before
	-- the panel first opens, and watch() only fires on *changes*.
	local current = noctalia.state.get("registry")
	if type(current) == "table" then
		regItems = current.items or {}
	end
	fStatusIdx = statusDefaultIdx()
	render()
end

function onClose()
	open = false
	pending = nil
	delArmSid = nil
end

-- Delete-confirm countdown: an armed "Confirm delete" reverts after ~5 s.
-- Pending watchdog: an answer that never arrives (service reloaded mid-flight
-- and the boot watch missed it) must not disable submits forever.
function update()
	if not open then
		return
	end
	if delArmSid ~= nil then
		delArmLeft = delArmLeft - 1
		if delArmLeft <= 0 then
			delArmSid = nil
			render()
		end
	end
	if pending ~= nil and (noctalia.nowMs() - (pending.since or 0)) > 30000 then
		pending = nil
		lastResult = noctalia.tr("err.timeout")
		render()
	end
end
