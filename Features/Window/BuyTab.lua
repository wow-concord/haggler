--[[
	Buy tab: search the last scan (anywhere) by name, discount under the default rule and under
	the vendor price (Engine/Buy.lua); at the auction house, search one item live and buy.

	Buying is protected and runs from clicks only. A commodity buy takes two: the first starts
	the purchase (StartCommoditiesPurchase) and waits for the server's price
	(COMMODITY_PRICE_UPDATED); the second, on a button that now shows that total, confirms it.
	When the server's unit price is over what the live listings promised, the button says so
	before the second click. An item auction takes two clicks as well: the first arms its
	button, the second buys it outright (PlaceBid at its buyout). A price far over the rule
	price (WindowModel.FAR_ABOVE_RULE) is called out on the button before the confirming click.

	The search runs when the player asks (Search, Enter, a filter change), never when the tab
	is built: it reads the whole scan. Another tab hands an item over with
	ns.BuyTab.focusItem(itemId) (the Flips tab's Buy): it opens Buy, searches the item's name,
	selects it and, at the auction house, searches it live; buying still takes the Buy clicks. Names and vendor prices come only from what Haggler has
	seen already (PriceService:KnownName, :KnownVendorPrice), so a search never asks the client
	to load thousands of items.
]]
local _, ns = ...

local PAGE_SIZE = 10
local ROW_HEIGHT = 36
local LIST_WIDTH = 440
local LIVE_ROWS = 4
local DETAIL_LINES = 5
local DISCOUNTS = { 0, 10, 25, 50, 75 }
local QUANTITY_STEPS = { 1, 5, 10, 20, 50, 100, 200, 500, 1000 }

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildFilters, buildList, buildDetail, runSearch, refreshList, refreshDetail, selectedRow, searchLive
local onBuyClick, onLiveBuyClick, onEvent, itemName, cycle, money, resetPurchase, farAboveText, clearLive
local focusItem

-- The built tab, for focusItem (tabs are built on their first show).
local shown = {}

ns.BuyTab = {
	--- Opens the Buy tab on one item. Run from a click: the live search needs the hardware event.
	--- @param itemId number
	--- @return boolean found the item is in the last scan and selected
	focusItem = function(itemId)
		if not ns.window:Open('buy') or not shown.container then
			return false
		end
		return focusItem(shown.container, shown.ctx, itemId)
	end,
}

ns.window:AddTab({
	key = 'buy',
	label = 'Buy',
	order = 50,
	events = {
		'COMMODITY_SEARCH_RESULTS_UPDATED',
		'ITEM_SEARCH_RESULTS_UPDATED',
		'COMMODITY_PRICE_UPDATED',
		'COMMODITY_PURCHASE_SUCCEEDED',
		'COMMODITY_PURCHASE_FAILED',
		'AUCTION_HOUSE_CLOSED',
	},
	build = function(container, ctx)
		shown.container, shown.ctx = container, ctx
		container.state =
			{ discountIndex = 1, underVendor = false, page = 1, selected = 1, rows = {}, quantityIndex = 1 }
		buildFilters(container, ctx)
		buildList(container, ctx)
		buildDetail(container, ctx)
	end,
	refresh = function(container, ctx)
		refreshList(container, ctx)
		refreshDetail(container, ctx)
	end,
	onEvent = function(container, ctx, event, ...)
		onEvent(container, ctx, event, ...)
	end,
	-- A shift-clicked item while the search box has focus: search for its name.
	onItemLink = function(container, ctx, link)
		if not (container.input.HasFocus and container.input:HasFocus()) then
			return false
		end
		local name = type(link) == 'string' and link:match('%[(.-)%]')
		container.input:SetText(name or link)
		runSearch(container, ctx)
		return true
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function buildFilters(container, ctx)
	local ui = ctx.ui
	container.input = ui:Input(container, 220, function()
		runSearch(container, ctx)
	end)
	container.input:SetPoint('TOPLEFT', container, 'TOPLEFT', 4, 0)
	container.discountPicker = ui:Stepper(container, 200, function(delta)
		container.state.discountIndex = cycle(container.state.discountIndex, delta, #DISCOUNTS)
		runSearch(container, ctx)
	end)
	container.discountPicker:SetPoint('LEFT', container.input, 'RIGHT', 8, 0)
	container.vendorPicker = ui:Stepper(container, 200, function()
		container.state.underVendor = not container.state.underVendor
		runSearch(container, ctx)
	end)
	container.vendorPicker:SetPoint('LEFT', container.discountPicker, 'RIGHT', 8, 0)
	local searchButton = ui:Button(container, 'Search', 'primary')
	searchButton:SetPoint('LEFT', container.vendorPicker, 'RIGHT', 8, 0)
	searchButton:OnClick(function()
		runSearch(container, ctx)
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
			clearLive(container)
			resetPurchase(container)
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
	container.liveButton = ui:Button(detail, 'Search live', 'secondary')
	container.liveButton:SetPoint('TOPLEFT', container.lines.frame, 'BOTTOMLEFT', 0, -4)
	container.liveButton:OnClick(function()
		searchLive(container, ctx)
	end)
	container.liveButtons = {}
	for index = 1, LIVE_ROWS do
		local button = ui:Button(detail, '', 'secondary')
		button:SetSize(380, ROW_HEIGHT - 4)
		button:SetPoint('TOPLEFT', container.liveButton, 'BOTTOMLEFT', 0, -8 - (index - 1) * ROW_HEIGHT)
		button:OnClick(function()
			onLiveBuyClick(container, ctx, index)
		end)
		container.liveButtons[index] = button
	end
	container.quantityPicker = ui:Stepper(detail, 200, function(delta)
		container.state.quantityIndex = math.max(1, math.min(#QUANTITY_STEPS, container.state.quantityIndex + delta))
		resetPurchase(container)
		refreshDetail(container, ctx)
	end, { '-', '+' })
	container.quantityPicker:SetPoint('BOTTOMLEFT', detail, 'BOTTOMLEFT', 0, 48)
	container.buyButton = ui:Button(detail, 'Buy', 'primary')
	container.buyButton:SetPoint('BOTTOMLEFT', detail, 'BOTTOMLEFT')
	container.buyButton:OnClick(function()
		onBuyClick(container, ctx)
	end)
end

function runSearch(container, ctx)
	local prices = ns.prices
	if not prices then
		container.state.rows = {}
		return
	end
	-- Cached item info only: a search prices thousands of items and must not load them all.
	local rulePriceCtx = prices:Context({ isCacheOnly = true })
	container.state.hasSearched = true
	container.state.rows, container.state.isCapped = ns.Buy.fromSnapshot(prices:Snapshot(), {
		text = container.input:GetText(),
		underRulePercent = DISCOUNTS[container.state.discountIndex] > 0 and DISCOUNTS[container.state.discountIndex]
			or nil,
		underVendor = container.state.underVendor,
	}, {
		itemName = function(itemId)
			return prices:KnownName(itemId)
		end,
		vendorPrice = function(itemId)
			return prices:KnownVendorPrice(itemId)
		end,
		rulePrice = function(itemId)
			local price, reason = prices:Get(itemId, nil, rulePriceCtx)
			return price and price.copper, price and price.confidence, reason, price and price.usesPriceSource
		end,
	})
	if container.state.isCapped and DISCOUNTS[container.state.discountIndex] > 0 then
		ctx.setStatus(
			string.format(
				'Checked the %d cheapest matches only; narrow your search by name or price.',
				ns.Buy.MAX_FILTERED_CANDIDATES
			)
		)
	end
	container.state.page, container.state.selected = 1, 1
	clearLive(container)
	resetPurchase(container)
	ctx.window:Refresh()
end

function refreshList(container, ctx)
	local discount = DISCOUNTS[container.state.discountIndex]
	container.discountPicker:SetValue(discount > 0 and string.format('%d%% under rule', discount) or 'Any price')
	container.vendorPicker:SetValue(container.state.underVendor and 'Under vendor: on' or 'Under vendor: off')
	local rows = container.state.rows
	local page = ns.WindowModel.page(rows, container.state.page, PAGE_SIZE)
	container.state.page, container.state.pageFirst = page.page, page.first
	for index, button in ipairs(container.rowButtons) do
		local row = page.items[index]
		if row then
			button:Show()
			local discountText = row.discountPercent and string.format(' · %d%% under', row.discountPercent) or ''
			button:SetLabel(string.format('%s · %s%s', itemName(row.itemId), money(row.unitPrice), discountText))
			button:SetSelected(page.first + index - 1 == container.state.selected)
		else
			button:Hide()
		end
	end
	local snapshot = ns.prices and ns.prices:Snapshot()
	local pagerText
	if not snapshot then
		pagerText = 'No scan saved yet'
	elseif not container.state.hasSearched then
		pagerText = 'Search to list the last scan'
	elseif #rows == 0 then
		pagerText = 'Nothing matches (names: items seen this session)'
	else
		pagerText = string.format('Page %d of %d', page.page, page.pageCount)
	end
	container.pager:SetValue(pagerText)
	return ctx
end

function refreshDetail(container, ctx)
	local row = selectedRow(container)
	local isAtAuctionHouse = ctx.window:IsAtAuctionHouse()
	container.liveButton:SetEnabled(row ~= nil and isAtAuctionHouse)
	if not row then
		container.title:SetText('')
		container.lines:SetLines({})
		container.linesItemId = nil
	else
		container.title:SetText(itemName(row.itemId))
		container.lines:SetLines(ns.WindowModel.buyLines(row), row.itemId == container.linesItemId)
		container.linesItemId = row.itemId
	end
	ctx.setCredit(row and row.usesPriceSource and ctx.window:Credit() or nil)
	local live = container.state.live or {}
	local isCommodity = live[1] ~= nil and live[1].isCommodity
	for index, button in ipairs(container.liveButtons) do
		local listing = live[index]
		if listing and not isCommodity then
			button:Show()
			local price = money(listing.buyout or listing.unitPrice)
			local warning = farAboveText(listing.unitPrice, row and row.rulePrice)
			if container.state.liveArmed == listing.auctionId then
				button:SetLabel(string.format('Confirm: buy %d for %s%s', listing.units, price, warning))
			else
				button:SetLabel(string.format('Buy %d for %s%s', listing.units, price, warning))
			end
			button:SetEnabled(isAtAuctionHouse)
		elseif listing then
			button:Show()
			button:SetLabel(string.format('%d at %s', listing.units, money(listing.unitPrice)))
			button:SetEnabled(false)
		else
			button:Hide()
		end
	end
	local quantity = QUANTITY_STEPS[container.state.quantityIndex]
	container.quantityPicker:SetValue('Quantity: ' .. quantity)
	if isCommodity then
		container.quantityPicker:Show()
		container.buyButton:Show()
	else
		container.quantityPicker:Hide()
		container.buyButton:Hide()
	end
	local purchase = container.state.purchase
	if purchase and purchase.total then
		local warning = (purchase.isDearer and ' (dearer than listed!)' or '')
			.. farAboveText(purchase.unitPrice, row and row.rulePrice)
		container.buyButton:SetLabel(
			string.format('Confirm: %d for %s%s', purchase.quantity, money(purchase.total), warning)
		)
	elseif purchase then
		container.buyButton:SetLabel('Asking the auction house for the price...')
	else
		local units, total = ns.Buy.unitsWithin(container.state.liveResults or {}, math.huge, quantity)
		container.buyButton:SetLabel(string.format('Buy %d for about %s', units, money(total)))
	end
	container.buyButton:SetEnabled(isAtAuctionHouse and (purchase == nil or purchase.total ~= nil))
end

function selectedRow(container)
	return container.state.rows[container.state.selected]
end

function searchLive(container, ctx)
	local row = selectedRow(container)
	if not row or not ctx.window:IsAtAuctionHouse() then
		return
	end
	container.state.liveItemId = row.itemId
	if not ctx.wow:SearchItem(row.itemId) then
		ctx.setStatus('The auction house did not take the search; try again in a moment.')
	end
end

-- Runs on the Buy button's click (a hardware event): the first click starts the purchase, the
-- second, once the server sent the price, confirms it.
function onBuyClick(container, ctx)
	local row = selectedRow(container)
	if not row or not ctx.window:IsAtAuctionHouse() then
		return
	end
	local purchase = container.state.purchase
	if purchase and purchase.total then
		local isSent = ctx.wow:ConfirmCommodityPurchase(purchase.itemId, purchase.quantity)
		ctx.setStatus(isSent and 'Buying...' or 'The purchase did not go through.')
		container.state.purchase = isSent and { itemId = purchase.itemId, quantity = purchase.quantity, isSent = true }
			or nil
		return
	end
	local quantity = QUANTITY_STEPS[container.state.quantityIndex]
	local units, total = ns.Buy.unitsWithin(container.state.liveResults or {}, math.huge, quantity)
	if units == 0 then
		return
	end
	if ctx.wow:StartCommodityPurchase(row.itemId, units) then
		container.state.purchase = { itemId = row.itemId, quantity = units, expectedTotal = total }
	end
	refreshDetail(container, ctx)
end

-- The first click arms the listing's button; the second, on the same listing, buys it.
function onLiveBuyClick(container, ctx, index)
	local listing = container.state.live and container.state.live[index]
	if not listing or listing.isCommodity or type(listing.auctionId) ~= 'number' then
		return
	end
	if not ctx.window:IsAtAuctionHouse() then
		return
	end
	if container.state.liveArmed ~= listing.auctionId then
		container.state.liveArmed = listing.auctionId
		refreshDetail(container, ctx)
		return
	end
	container.state.liveArmed = nil
	local isSent = ctx.wow:BuyAuction(listing.auctionId, listing.buyout or listing.unitPrice * listing.units)
	ctx.setStatus(
		isSent and ('Bought for ' .. money(listing.buyout or listing.unitPrice)) or 'The purchase did not go through.'
	)
	if isSent then
		searchLive(container, ctx)
	end
end

function onEvent(container, ctx, event, ...)
	local itemId = container.state.liveItemId
	if event == 'AUCTION_HOUSE_CLOSED' then
		clearLive(container)
		container.state.liveItemId = nil
		resetPurchase(container)
		return
	end
	if event == 'COMMODITY_SEARCH_RESULTS_UPDATED' or event == 'ITEM_SEARCH_RESULTS_UPDATED' then
		if itemId then
			local row = selectedRow(container)
			container.state.liveResults = ctx.wow:SearchResults(itemId)
			container.state.live = ns.Buy.fromLive(container.state.liveResults, nil, row and row.rulePrice)
			container.state.liveArmed = nil
		end
	elseif event == 'COMMODITY_PRICE_UPDATED' then
		local purchase = container.state.purchase
		local unitPrice, totalPrice = ...
		-- Only for a purchase waiting on its price: one already confirmed takes no new total.
		if purchase and not purchase.isSent and type(totalPrice) == 'number' then
			purchase.unitPrice, purchase.total = unitPrice, totalPrice
			purchase.isDearer = purchase.expectedTotal ~= nil and totalPrice > purchase.expectedTotal
		end
	elseif event == 'COMMODITY_PURCHASE_SUCCEEDED' then
		ctx.setStatus('Bought.')
		resetPurchase(container)
		searchLive(container, ctx)
	elseif event == 'COMMODITY_PURCHASE_FAILED' then
		ctx.setStatus('The purchase failed.')
		resetPurchase(container)
	end
	if container:IsShown() and ctx.window:IsOpen() then
		refreshDetail(container, ctx)
	end
end

function itemName(itemId)
	local info = ns.prices and ns.prices:ItemInfo(itemId)
	return info and info.name or ('Item ' .. itemId)
end

-- ' · 2.0x the rule price!' when far over it, else ''.
function farAboveText(unitPrice, rulePrice)
	local ratio = ns.WindowModel.farAboveRule(unitPrice, rulePrice)
	return ratio and string.format(' · %.1fx the rule price!', ratio) or ''
end

function focusItem(container, ctx, itemId)
	container.state.discountIndex, container.state.underVendor = 1, false
	container.input:SetText(itemName(itemId))
	runSearch(container, ctx)
	for index, row in ipairs(container.state.rows) do
		if row.itemId == itemId then
			container.state.selected = index
			container.state.page = math.floor((index - 1) / PAGE_SIZE) + 1
			searchLive(container, ctx)
			ctx.window:Refresh()
			return true
		end
	end
	ctx.setStatus('That item is not in the last scan under its name; search it by hand.')
	return false
end

function clearLive(container)
	container.state.live, container.state.liveResults, container.state.liveArmed = nil, nil, nil
end

function cycle(index, delta, count)
	return ((index - 1 + delta) % count) + 1
end

function money(copper)
	return ns.TooltipLines.money(copper)
end

-- Drops a purchase in progress; one already started with the server is cancelled there too.
function resetPurchase(container)
	local purchase = container.state.purchase
	if purchase and not purchase.isSent then
		ns.wow:CancelCommodityPurchase()
	end
	container.state.purchase = nil
end
