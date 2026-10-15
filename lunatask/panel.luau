-- panel.luau (M1 stub: connection status + registry + ping roundtrip)
-- M2+ adds task/note/journal tabs and forms onto this skeleton.
-- Protocol (§8): one outstanding command; submit stays disabled until the
-- matching evt.panel arrives (V-02).

local seq = 0
local pending = nil -- { seq, op } while a command is in flight
local connText = noctalia.tr("ui.panel.status.unknown")
local regItems = {}
local regSchema = 0
local selectIdx = 1
local selectEcho = "-"

local function render()
	local rows = {}

	table.insert(rows, ui.row({ align = "center", justify = "space_between" }, {
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
	}))

	table.insert(rows, ui.label({ text = noctalia.tr("ui.banner.visibility"), maxLines = 3 }))

	table.insert(rows, ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = connText, flexGrow = 1 }),
		ui.button({
			text = noctalia.tr("ui.panel.ping"),
			variant = "primary",
			enabled = pending == nil,
			onClick = function()
				sendCmd("ping")
			end,
		}),
	}))

	table.insert(rows, ui.separator({}))

	if #regItems == 0 then
		table.insert(rows, ui.label({ text = noctalia.tr("ui.panel.registry.empty") }))
	else
		local itemRows = {}
		for _, item in ipairs(regItems) do
			local title = item.title or item.date_on or item.id or "?"
			table.insert(itemRows, ui.label({
				key = "reg-" .. tostring(item.id or title),
				text = "● " .. tostring(title) .. " (" .. tostring(item.kind) .. " · " .. tostring(item.state) .. ")",
			}))
		end
		table.insert(rows, ui.scroll({ flexGrow = 1 }, itemRows))
	end

	table.insert(rows, ui.separator({}))
	table.insert(rows, ui.label({ text = noctalia.tr("ui.panel.diag.select_hint") }))
	table.insert(rows, ui.select({
		options = { "alpha", "beta", "gamma" },
		selectedIndex = selectIdx,
		onChange = function(v)
			selectEcho = tostring(v)
			local n = tonumber(v)
			if n ~= nil then
				selectIdx = n
			end
			render()
		end,
	}))
	table.insert(rows, ui.label({ text = "select raw=" .. selectEcho }))

	panel.render(ui.column({ gap = 10, padding = 12 }, rows))
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

noctalia.state.watch("registry", function(msg)
	if type(msg) == "table" then
		regSchema = msg.schema or 0
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
	end
	if msg.ok ~= true and msg.err ~= nil and msg.err.kind ~= nil then
		noctalia.log("panel cmd " .. tostring(op) .. " failed kind=" .. tostring(msg.err.kind))
	end
	render()
end)

function onOpen(_context)
	render()
end

function onClose()
	pending = nil
end
