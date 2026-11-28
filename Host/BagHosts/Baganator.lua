--[[
	Baganator (846): the plugin API. Three corner widgets (a corner shows one widget at a time,
	so the player picks the corners in Baganator's own settings) and one region for the total:

	  Haggler: value          bottom left    the item's value, when the Bags value setting is on;
	                                         a guessed value carries the low marker in its text
	  Haggler: decision       top left       post, sell, wait or undecided
	  Haggler: item type      top right      quest or junk

	A badge widget is a frame of Haggler's own holding the glyph and its outline, so hiding the
	widget hides both. Quest comes from the item class and junk from the quality Baganator gives
	(a grey the vendor pays for): Baganator's details carry no bag slot to ask.

	A widget's onUpdate answers true (show), false (hide) or nil (item data not ready; Baganator
	asks again). The total is a frame of Haggler's own placed with RegisterRegion in the
	backpack's bottom-left; its width follows the text and Baganator lays it out again.
]]
local _, ns = ...

local REGION_ID = 'haggler_total'
local WIDGETS = {
	{
		label = 'Haggler: value',
		id = 'haggler_value',
		corner = 'bottom_left',
		region = 'text',
	},
	{
		label = 'Haggler: decision',
		id = 'haggler_decision',
		corner = 'top_left',
		region = 'badge',
		slot = 'decision',
	},
	{
		label = 'Haggler: item type',
		id = 'haggler_type',
		corner = 'top_right',
		region = 'badge',
		slot = 'type',
	},
}
-- Baganator appends a widget whose priority is past the corner's list and inserts it at that
-- position otherwise: a high number keeps the user's own widgets ahead of Haggler's.
local WIDGET_PRIORITY = 1000
local TOTAL_HEIGHT = 16
local TOTAL_PADDING = 4

-- Helpers live at the bottom of the file; declared here so they stay local.
local apiOf, registerWidget, registerTotal, findBadge

local Baganator = ns.BagHosts.register({
	name = 'Baganator',
	targets = 'Baganator 846: API.RegisterCornerWidget, API.RegisterRegion',
	detect = function(wow)
		return apiOf(wow) ~= nil
	end,
	attach = function(wow, view)
		local api = apiOf(wow)
		for _, widget in ipairs(WIDGETS) do
			registerWidget(wow, api, widget, view)
		end
		registerTotal(wow, api, view)
		return true
	end,
	refresh = function(wow)
		local api = apiOf(wow)
		if api and type(api.RequestItemButtonsRefresh) == 'function' then
			api.RequestItemButtonsRefresh()
		end
	end,
})
ns.BagHostBaganator = Baganator

--- What one widget shows for Baganator's item details: true, false or nil (not ready).
function Baganator.update(widget, region, details, view)
	if not view:IsActive() then
		return false
	end
	local itemId = type(details) == 'table' and details.itemID or nil
	if type(itemId) ~= 'number' then
		return nil
	end
	if widget.region == 'text' then
		local decision = view:DecideItem(itemId, details.itemCount, { isBound = details.isBound == true })
		if not decision.valueText then
			return false
		end
		region:SetText(view:ValueLabel(decision))
		return true
	end
	local item = view:ItemFlags(itemId, details.quality, details.isBound == true)
	local decision = view:DecideItem(itemId, details.itemCount, item)
	return view:PaintBadgeFrame(region, findBadge(decision, widget.slot))
end

-- Helpers ---------------------------------------------------------------------------------

function apiOf(wow)
	local baganator = wow:Global('Baganator')
	local api = type(baganator) == 'table' and baganator.API or nil
	if type(api) ~= 'table' or type(api.RegisterCornerWidget) ~= 'function' then
		return nil
	end
	return api
end

function registerWidget(wow, api, widget, view)
	api.RegisterCornerWidget(widget.label, widget.id, function(region, details)
		return Baganator.update(widget, region, details, view)
	end, function(itemButton)
		if widget.region == 'text' then
			return itemButton:CreateFontString(nil, 'OVERLAY', ns.Badges.VALUE_FONT)
		end
		return view:NewBadgeFrame(wow:CreateFrame('Frame', itemButton))
	end, { corner = widget.corner, priority = WIDGET_PRIORITY }, false)
end

function registerTotal(wow, api, view)
	if type(api.RegisterRegion) ~= 'function' then
		return
	end
	local frame = wow:CreateFrame('Frame')
	frame:SetSize(1, TOTAL_HEIGHT)
	local text = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
	text:SetPoint('LEFT', frame, 'LEFT', 0, 0)
	view:TrackTotal(text, function(width)
		frame:SetWidth(width + TOTAL_PADDING)
		if type(api.RequestLayoutUpdate) == 'function' then
			api.RequestLayoutUpdate()
		end
	end)
	api.RegisterRegion('Haggler: bag value', REGION_ID, 'backpack', 'bottom_left', frame)
end

function findBadge(decision, slot)
	for _, badge in ipairs(decision.badges) do
		if badge.slot == slot then
			return badge
		end
	end
	return nil
end

return Baganator
