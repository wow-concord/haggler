--[[
	Lookup tab: any item, by name (of an item Haggler has seen this session), item id or link
	(shift-click an item while the box has focus). It shows every rule's price, confidence and
	reasons, sales a day, listings, the vendor price, and the item's own sales count for the
	last days when the market has daily summaries. Nothing is cut off: a list longer than the
	box pages. A name search reads only names already seen, never asks the client to load.
]]
local _, ns = ...

local MAX_LINES = 20
local LINES_WIDTH = 860
local MAX_NAME_MATCHES = 20

-- Helpers live at the bottom of the file; declared here so they stay local.
local lookUp, historyText, usesPriceSource

ns.window:AddTab({
	key = 'lookup',
	label = 'Lookup',
	order = 20,
	build = function(container, ctx)
		local input = ctx.ui:Input(container, 320, function(text)
			lookUp(container, ctx, text)
		end)
		input:SetPoint('TOPLEFT', container, 'TOPLEFT', 4, 0)
		container.input = input
		local button = ctx.ui:Button(container, 'Look up', 'primary')
		button:SetPoint('LEFT', input, 'RIGHT', 8, 0)
		button:OnClick(function()
			lookUp(container, ctx, input:GetText())
		end)
		container.title = ctx.ui:Text(container, 17, 'color.text.title', ns.Widgets.HEADING_FACE)
		container.title:SetPoint('TOPLEFT', input, 'BOTTOMLEFT', -4, -16)
		container.lines = ctx.ui:PagedLines(container, MAX_LINES, 13, LINES_WIDTH)
		container.lines.frame:SetPoint('TOPLEFT', container.title, 'BOTTOMLEFT', 0, -8)
	end,
	refresh = function(container, ctx)
		if container.itemId then
			lookUp(container, ctx, tostring(container.itemId))
		end
	end,
	-- A shift-clicked item while the box has focus is looked up at once.
	onItemLink = function(container, ctx, link)
		if not (container.input.HasFocus and container.input:HasFocus()) then
			return false
		end
		container.input:SetText(link)
		lookUp(container, ctx, link)
		return true
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function lookUp(container, ctx, text)
	local prices = ns.prices
	if not prices then
		ctx.setStatus('Prices are not ready yet.')
		return
	end
	local itemId, reason = ns.WindowModel.itemIdFromText(text, {
		itemIdFromLink = function(link)
			return ctx.wow:ItemIdFromLink(link)
		end,
		itemIdsByName = function(lowerText)
			return prices:ItemIdsByName(lowerText, MAX_NAME_MATCHES)
		end,
	})
	if not itemId then
		-- A failed search leaves nothing of the item shown before.
		container.itemId = nil
		container.title:SetText('')
		container.lines:SetLines({})
		ctx.setCredit(nil)
		ctx.setStatus(reason)
		return
	end
	local isNewItem = itemId ~= container.itemId
	container.itemId = itemId
	local ruleIds = {}
	for _, rule in ipairs(prices:Rules()) do
		ruleIds[#ruleIds + 1] = rule.id
	end
	local quote = prices:Quote(itemId, ruleIds)
	local info = prices:ItemInfo(itemId)
	container.title:SetText(info and info.name or ('Item ' .. itemId))
	local lines = ns.WindowModel.lookupLines(quote)
	local key = prices:MarketKey()
	local market = key and ns.store:Market(key)
	local history = ns.WindowModel.historyLines(market and market.scanDays, itemId, ctx.wow:Now())
	if #history > 0 then
		lines[#lines + 1] = { text = 'Your scans, units sold: ' .. historyText(history) }
	end
	container.lines:SetLines(lines, not isNewItem)
	ctx.setCredit(usesPriceSource(quote) and ctx.window:Credit() or nil)
	ctx.setStatus('')
end

function historyText(history)
	local parts = {}
	for _, day in ipairs(history) do
		parts[#parts + 1] = (day.daysAgo == 0 and 'today' or (day.daysAgo .. 'd ago')) .. ' ' .. day.sold
	end
	return table.concat(parts, ' · ')
end

function usesPriceSource(quote)
	for _, entry in ipairs(quote.prices or {}) do
		if entry.price and entry.price.usesPriceSource then
			return true
		end
	end
	return false
end
