--!nonstrict
-- widget.luau (M6): bar glyph that opens the manager panel.
-- The bar never takes keyboard focus, so this only toggles the panel.
barWidget.setGlyph("checklist")

function onClick()
	noctalia.togglePanel("snowballons/lunatask:manager")
end
