--[[
	Flips tab (V2, left out of the release package; it adds the top bar's Flips shortcut):
	listings in the last scan worth buying to sell again (Engine/Flips.lua): under
	what a vendor pays, or under the default rule's value (a relist). The list runs when the
	player asks (Find, a filter change), never when the tab is built: it reads the whole scan.

	Buy hands the item to the Buy tab (ns.BuyTab.focusItem), which searches it live at the
	auction house; buying stays on the Buy tab's own two-click buttons. Relist opens the Sell
	tab. Every row shows its confidence, and every reason that is not high, which cannot be
	switched off; the footer credits AHledger when a rule price used its figures.

	  ns.FlipsTab.lines(row) -> { { text, level? }... }   the detail lines (tested)
]]
local _, ns = ...

local PAGE_SIZE = 10
local ROW_HEIGHT = 36
local LIST_WIDTH = 440
local DETAIL_LINES = 9
local KINDS = {
	{ label = 'Vendor and relist', kinds = { vendor = true, relist = true } },
	{ label = 'Vendor flips', kinds = { vendor = true } },
	{ label = 'Relist flips', kinds = { relist = true } },
}
local MIN_PERCENTS = { 0, 10, 25, 50 }
local CONFIDENCE_TEXT = { high = 'Confidence: high', medium = 'Confidence: medium', low = 'Confidence: low' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildFilters, buildList, buildDetail, runFind, refreshList, refreshDetail, selectedRow, itemName
local money, cycle, rowLabel, flipDeps, ownListingsByItem

local FlipsTab = {}
ns.FlipsTab = FlipsTab

ns.window:AddTab({
	key = 'flips',
	label = 'Flips',
	order = 45,
	build = function(container, ctx)
		container.state = { kindIndex = 1, minPercentIndex = 1, page = 1, selected = 1, rows = {} }
		buildFilters(container, ctx)
		buildList(container, ctx)
		buildDetail(container, ctx)
	end,
	refresh = function(container, ctx)
		refreshList(container, ctx)
		refreshDetail(container, ctx)
	end,
})

-- The top bar's Flips shortcut, before Settings; without this V2 tab the bar has none.
do
	local shortcuts = ns.TopBarModel.SHORTCUTS
	local position = #shortcuts + 1
	for index, shortcut in ipairs(shortcuts) do
		if shortcut.key == 'settings' then
			position = index
		end
	end
	table.insert(shortcuts, position, { key = 'flips', label = 'Flips', tab = 'flips' })
end

--- The detail lines for a flip: what to buy, what it sells for, the expected profit and its
--- confidence with every reason that is not high.
--- @param row table FlipRow
--- @return table { { text, level? }... }
function FlipsTab.lines(row)
	local lines = {
		{ text = string.format('Buy %d for %s (from %s each)', row.units, money(row.cost), money(row.buyPrice)) },
	}
	if row.kind == 'vendor' then
		lines[#lines + 1] = { text = 'Sell to a vendor at ' .. money(row.sellPrice) .. ' each' }
	else
		lines[#lines + 1] = { text = 'Relist at ' .. money(row.sellPrice) .. " each (on the item's step)" }
		if row.sellChance then
			lines[#lines + 1] =
				{ text = string.format('Sells within the listing: %d%%', math.floor(row.sellChance * 100)) }
		end
		if row.depositLoss and row.depositLoss > 0 then
			lines[#lines + 1] = { text = 'Deposit expected lost: ' .. money(row.depositLoss) }
		end
		if row.isCappedBySales then
			lines[#lines + 1] = { text = 'Capped at one listing period of sales' }
		end
	end
	lines[#lines + 1] = { text = string.format('Expected profit: %s (%d%%)', money(row.profit), row.percent or 0) }
	local confidence = row.confidence or {}
	lines[#lines + 1] =
		{ text = CONFIDENCE_TEXT[confidence.level] or CONFIDENCE_TEXT.low, level = confidence.level or 'low' }
	for _, reason in ipairs(confidence.reasons or {}) do
		if reason.level ~= 'high' then
			lines[#lines + 1] = { text = '    ' .. tostring(reason.text), level = reason.level }
		end
	end
	return lines
end

-- Helpers ---------------------------------------------------------------------------------

function buildFilters(container, ctx)
	local ui = ctx.ui
	container.kindPicker = ui:Stepper(container, 220, function(delta)
		container.state.kindIndex = cycle(container.state.kindIndex, delta, #KINDS)
		runFind(container, ctx)
	end)
	container.kindPicker:SetPoint('TOPLEFT', container, 'TOPLEFT', 4, 0)
	container.percentPicker = ui:Stepper(container, 200, function(delta)
		container.state.minPercentIndex = cycle(container.state.minPercentIndex, delta, #MIN_PERCENTS)
		runFind(container, ctx)
	end)
	container.percentPicker:SetPoint('LEFT', container.kindPicker, 'RIGHT', 8, 0)
	container.findButton = ui:Button(container, 'Find flips', 'primary')
	container.findButton:SetPoint('LEFT', container.percentPicker, 'RIGHT', 8, 0)
	container.findButton:OnClick(function()
		runFind(container, ctx)
	end)
end

function buildList(container, ctx)
	local ui = ctx.ui
	container.rowButtons = {}
	for index = 1, PAGE_SIZE do
		local button = ui:Button(container, '', 'secondary')
		button:SetSize(LIST_WIDTH, ROW_HEIGHT - 4)
		button:SetPoint('TOPLEFT', container, 'TOPLEFT', 0, -48 - (index - 1) * ROW_HEIGHT)
		button.label:ClearAllPoints()
		button.label:SetPoint('LEFT', button, 'LEFT', 12, 0)
		button:OnClick(function()
			container.state.selected = (container.state.pageFirst or 1) + index - 1
			ctx.window:Refresh()
		end)
		container.rowButtons[index] = button
	end
	container.pager = ui:Stepper(container, LIST_WIDTH, function(delta)
		container.state.page = container.state.page + delta
		refreshList(container, ctx)
	end)
	container.pager:SetPoint('TOPLEFT', container, 'TOPLEFT', 0, -48 - PAGE_SIZE * ROW_HEIGHT - 8)
end

function buildDetail(container, ctx)
	local ui = ctx.ui
	local detail = ctx.wow:CreateFrame('Frame', container)
	detail:SetPoint('TOPLEFT', container, 'TOPLEFT', LIST_WIDTH + 24, -48)
	detail:SetPoint('BOTTOMRIGHT', container, 'BOTTOMRIGHT')
	container.title = ui:Text(detail, 17, 'color.text.title', ns.Widgets.HEADING_FACE)
	container.title:SetPoint('TOPLEFT', detail, 'TOPLEFT')
	container.lines = ui:PagedLines(detail, DETAIL_LINES, 13, 400)
	container.lines.frame:SetPoint('TOPLEFT', container.title, 'BOTTOMLEFT', 0, -8)
	-- Buy runs the Buy tab's live search, which needs this click's hardware event.
	container.buyButton = ui:Button(detail, 'Buy on the Buy tab', 'primary')
	container.buyButton:SetPoint('BOTTOMLEFT', detail, 'BOTTOMLEFT')
	container.buyButton:OnClick(function()
		local row = selectedRow(container)
		if row and ns.BuyTab then
			ns.BuyTab.focusItem(row.itemId)
		end
	end)
	container.relistButton = ui:Button(detail, 'Open the Sell tab', 'secondary')
	container.relistButton:SetPoint('LEFT', container.buyButton, 'RIGHT', 8, 0)
	container.relistButton:OnClick(function()
		ctx.window:Open('sell')
	end)
end

function runFind(container, ctx)
	local prices = ns.prices
	if not prices then
		container.state.rows = {}
		return
	end
	container.state.hasSearched = true
	container.state.rows, container.state.isCapped = ns.Flips.find(prices:Snapshot(), flipDeps(prices, ctx), {
		kinds = KINDS[container.state.kindIndex].kinds,
		minPercent = MIN_PERCENTS[container.state.minPercentIndex],
	})
	if container.state.isCapped then
		ctx.setStatus(string.format('Relist flips: checked the %d most listed items only.', ns.Flips.MAX_PRICED))
	end
	container.state.page, container.state.selected = 1, 1
	ctx.window:Refresh()
end

function refreshList(container, ctx)
	container.kindPicker:SetValue(KINDS[container.state.kindIndex].label)
	local minPercent = MIN_PERCENTS[container.state.minPercentIndex]
	container.percentPicker:SetValue(minPercent > 0 and string.format('At least %d%%', minPercent) or 'Any margin')
	local rows = container.state.rows
	local page = ns.WindowModel.page(rows, container.state.page, PAGE_SIZE)
	container.state.page, container.state.pageFirst = page.page, page.first
	for index, button in ipairs(container.rowButtons) do
		local row = page.items[index]
		if row then
			button:Show()
			button:SetLabel(rowLabel(row))
			button:SetSelected(page.first + index - 1 == container.state.selected)
		else
			button:Hide()
		end
	end
	local pagerText
	if not (ns.prices and ns.prices:Snapshot()) then
		pagerText = 'No scan saved yet'
	elseif not container.state.hasSearched then
		pagerText = 'Find flips to list the last scan'
	elseif #rows == 0 then
		pagerText = 'No flips (names: items seen this session)'
	else
		pagerText = string.format('Page %d of %d', page.page, page.pageCount)
	end
	container.pager:SetValue(pagerText)
	return ctx
end

function refreshDetail(container, ctx)
	local row = selectedRow(container)
	container.buyButton:SetEnabled(row ~= nil)
	container.relistButton:SetEnabled(row ~= nil and row.kind == 'relist')
	if not row then
		container.title:SetText('')
		container.lines:SetLines({})
		container.linesItemId = nil
		ctx.setCredit(nil)
		return
	end
	container.title:SetText(itemName(row.itemId))
	container.lines:SetLines(FlipsTab.lines(row), row.itemId == container.linesItemId)
	container.linesItemId = row.itemId
	ctx.setCredit(row.usesPriceSource and ctx.window:Credit() or nil)
end

function selectedRow(container)
	return container.state.rows[container.state.selected]
end

-- ' ? ' marks a flip that is not high confidence, so the list shows it before the detail does.
function rowLabel(row)
	local level = row.confidence and row.confidence.level
	local mark = level == 'high' and '' or '? '
	local kind = row.kind == 'vendor' and 'vendor' or 'relist'
	return string.format('%s%s · +%s · %s', mark, itemName(row.itemId), money(row.profit), kind)
end

-- Cached item info only: the find reads the whole scan and must not load thousands of items.
function flipDeps(prices, ctx)
	local priceCtx = prices:Context({ isCacheOnly = true })
	local ownListings = ownListingsByItem(prices)
	return {
		now = ctx.wow:Now(),
		vendorPrice = function(itemId)
			return prices:KnownVendorPrice(itemId)
		end,
		rulePrice = function(itemId)
			return (prices:Get(itemId, nil, priceCtx))
		end,
		salesPerDay = function(itemId)
			return ns.PriceContext.facts(priceCtx, itemId).salesPerDay
		end,
		ownListings = function(itemId)
			return ownListings[itemId]
		end,
	}
end

-- Every character's active auctions on this market, by item: built once per search.
function ownListingsByItem(prices)
	local byItem = {}
	local market = ns.store and ns.store:Market(prices:MarketKey())
	for _, record in ipairs(market and ns.AuctionTracker.list(market, { state = 'active' }) or {}) do
		byItem[record.itemId] = byItem[record.itemId] or {}
		table.insert(byItem[record.itemId], {
			unitPrice = record.unitPrice,
			listed = record.listed,
			postedAt = record.postedAt,
		})
	end
	return byItem
end

function itemName(itemId)
	local name = ns.prices and ns.prices:KnownName(itemId)
	return name or ('Item ' .. itemId)
end

function money(copper)
	return ns.TooltipLines.money(copper or 0)
end

function cycle(index, delta, count)
	return ((index - 1 + delta) % count) + 1
end
