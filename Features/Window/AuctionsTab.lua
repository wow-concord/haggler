--[[
	Auctions tab: the character's auctions Haggler tracks, each with relist advice when the
	market moved (Engine/Advice.lua: "Relist at X", or hold and why), and the "cancel untracked"
	action that takes out the auctions not posted from a venture.

	Cancelling is protected and loses the whole deposit, so it runs from clicks only, at the
	auction house, one auction per click, and the first click only arms the button. Relisting is
	cancel, then post again from the Sell tab at the advised price. Advice reads the last scan:
	its age lowers the confidence, and every reason that is not high shows. The floor is the
	auction's break-even (the cost-pool share it took when posted); the step comes from the rule
	price, else from the scan (copper seen, stacks seen), never a copper step on a silver item.

	Cancel untracked never touches a venture's auction: the venture records count in every state
	(the clock may have expired one that is still listed), and an owned auction with no record
	yet is spared when a pending venture post explains it. A cancelled auction is not offered
	again, and the button waits for the server (OWNED_AUCTIONS_UPDATED or AUCTION_CANCELED)
	between cancels.

	  ns.AuctionsTab.rows(records, deps) -> { { record, advice } }   (tested)
	      deps = { snapshot, now, scanAge?, rulePrice(itemId) -> Price|nil, vendorPrice(itemId) }
]]
local _, ns = ...

local PAGE_SIZE = 10
local ROW_HEIGHT = 36
local LIST_WIDTH = 440
local DETAIL_LINES = 8
-- A cancel the server never answers (refused, or the answer lost) frees the button after this.
local SERVER_WAIT_SECONDS = 5
local CONFIDENCE_TEXT = { high = 'Confidence: high', medium = 'Confidence: medium', low = 'Confidence: low' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildList, buildDetail, reloadRows, refreshList, refreshDetail, selectedRow, untrackedNow
local onCancelClick, onCancelUntrackedClick, itemName, money, rowLabel, detailLines, marketNow, charKey
local stepFor, breakEvenFor, signed, pendingVenturePosts

local AuctionsTab = {}
ns.AuctionsTab = AuctionsTab

ns.window:AddTab({
	key = 'auctions',
	label = 'Auctions',
	order = 42,
	events = { 'OWNED_AUCTIONS_UPDATED', 'AUCTION_CANCELED', 'AUCTION_HOUSE_SHOW', 'AUCTION_HOUSE_CLOSED' },
	build = function(container, ctx)
		container.state = { page = 1, selected = 1, rows = {}, cancelledIds = {} }
		buildList(container, ctx)
		buildDetail(container, ctx)
	end,
	refresh = function(container, ctx)
		reloadRows(container, ctx)
		refreshList(container, ctx)
		refreshDetail(container, ctx)
	end,
	onEvent = function(container, ctx, event)
		container.state.armed = nil
		container.state.isAwaitingServer, container.state.serverWait = nil, nil
		if event == 'AUCTION_HOUSE_SHOW' or event == 'AUCTION_HOUSE_CLOSED' then
			container.state.cancelledIds = {}
		end
		ctx.window:Refresh()
	end,
})

--- Advice for each tracked auction, cheapest-moved first (relists before holds).
--- @param records table { Tracked + auctionId } active auctions
--- @param deps table see the file header
--- @return table { { record, advice }... }
function AuctionsTab.rows(records, deps)
	-- Our units in the scan's levels: a listing posted after the scan is not in them.
	local scanAt = deps.snapshot and deps.snapshot.at
	local own = {}
	for _, record in ipairs(records) do
		local isInScan = not (
			type(scanAt) == 'number'
			and type(record.postedAt) == 'number'
			and record.postedAt > scanAt
		)
		if isInScan then
			own[record.itemId] = own[record.itemId] or {}
			table.insert(own[record.itemId], { unitPrice = record.unitPrice, listed = record.listed })
		end
	end
	local rows = {}
	for _, record in ipairs(records) do
		local scanItem = deps.snapshot
			and type(record.itemId) == 'number'
			and ns.ScanStore.item(deps.snapshot, record.itemId)
		local price = deps.rulePrice(record.itemId)
		local vendor = deps.vendorPrice(record.itemId)
		local step = price and price.step or stepFor(record, scanItem or nil)
		local advice = ns.Advice.forAuction(record, {
			cheapestOther = scanItem and ns.Advice.cheapestOther(scanItem.levels, own[record.itemId]) or nil,
			rulePrice = price and price.copper or nil,
			step = step,
			vendor = vendor,
			breakEven = breakEvenFor(record, step, vendor),
			scanAgeSeconds = deps.scanAge,
			confidence = price and price.confidence or nil,
		})
		local usesPriceSource = advice.usesRulePrice == true and price ~= nil and price.usesPriceSource == true
		rows[#rows + 1] = { record = record, advice = advice, usesPriceSource = usesPriceSource }
	end
	table.sort(rows, function(a, b)
		if (a.advice.action == 'relist') ~= (b.advice.action == 'relist') then
			return a.advice.action == 'relist'
		end
		return (a.record.postedAt or 0) > (b.record.postedAt or 0)
	end)
	return rows
end

-- Helpers ---------------------------------------------------------------------------------

function buildList(container, ctx)
	local ui = ctx.ui
	container.rowButtons = {}
	for index = 1, PAGE_SIZE do
		local button = ui:Button(container, '', 'secondary')
		button:SetSize(LIST_WIDTH, ROW_HEIGHT - 4)
		button:SetPoint('TOPLEFT', container, 'TOPLEFT', 0, -(index - 1) * ROW_HEIGHT)
		button.label:ClearAllPoints()
		button.label:SetPoint('LEFT', button, 'LEFT', 12, 0)
		button:OnClick(function()
			container.state.selected = (container.state.pageFirst or 1) + index - 1
			container.state.armed = nil
			ctx.window:Refresh()
		end)
		container.rowButtons[index] = button
	end
	container.pager = ui:Stepper(container, LIST_WIDTH, function(delta)
		container.state.page = container.state.page + delta
		refreshList(container, ctx)
	end)
	container.pager:SetPoint('TOPLEFT', container, 'TOPLEFT', 0, -PAGE_SIZE * ROW_HEIGHT - 8)
end

function buildDetail(container, ctx)
	local ui = ctx.ui
	local detail = ctx.wow:CreateFrame('Frame', container)
	detail:SetPoint('TOPLEFT', container, 'TOPLEFT', LIST_WIDTH + 24, 0)
	detail:SetPoint('BOTTOMRIGHT', container, 'BOTTOMRIGHT')
	container.title = ui:Text(detail, 17, 'color.text.title', ns.Widgets.HEADING_FACE)
	container.title:SetPoint('TOPLEFT', detail, 'TOPLEFT')
	container.lines = ui:PagedLines(detail, DETAIL_LINES, 13, 400)
	container.lines.frame:SetPoint('TOPLEFT', container.title, 'BOTTOMLEFT', 0, -8)
	container.cancelButton = ui:Button(detail, 'Cancel to relist', 'secondary')
	container.cancelButton:SetPoint('BOTTOMLEFT', detail, 'BOTTOMLEFT', 0, 40)
	container.cancelButton:OnClick(function()
		onCancelClick(container, ctx)
	end)
	container.untrackedButton = ui:Button(detail, 'Cancel untracked', 'secondary')
	container.untrackedButton:SetPoint('BOTTOMLEFT', detail, 'BOTTOMLEFT')
	container.untrackedButton:OnClick(function()
		onCancelUntrackedClick(container, ctx)
	end)
end

function reloadRows(container, ctx)
	local prices, market = ns.prices, marketNow()
	if not prices or not market then
		container.state.rows = {}
		return
	end
	local records = ns.AuctionTracker.list(market, { state = 'active', char = charKey() })
	local priceCtx = prices:Context({ isCacheOnly = true })
	container.state.rows = AuctionsTab.rows(records, {
		snapshot = prices:Snapshot(),
		scanAge = prices:Ages(ctx.wow:Now()).scanAge,
		rulePrice = function(itemId)
			return (prices:Get(itemId, nil, priceCtx))
		end,
		vendorPrice = function(itemId)
			return prices:KnownVendorPrice(itemId)
		end,
	})
end

function refreshList(container, ctx)
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
	container.pager:SetValue(
		#rows == 0 and 'No tracked auctions on this character'
			or string.format('Page %d of %d', page.page, page.pageCount)
	)
	return ctx
end

function refreshDetail(container, ctx)
	local row = selectedRow(container)
	local isAtAuctionHouse = ctx.window:IsAtAuctionHouse()
	local armed = container.state.armed
	if row then
		container.title:SetText(itemName(row.record.itemId))
		container.lines:SetLines(detailLines(row), row.record.auctionId == container.linesAuctionId)
		container.linesAuctionId = row.record.auctionId
	else
		container.title:SetText('')
		container.lines:SetLines({})
		container.linesAuctionId = nil
	end
	ctx.setCredit(row and row.usesPriceSource and ctx.window:Credit() or nil)
	local isCancelArmed = row ~= nil and armed == row.record.auctionId
	container.cancelButton:SetLabel(isCancelArmed and 'Confirm: cancel (the deposit is lost)' or 'Cancel to relist')
	container.cancelButton:SetEnabled(row ~= nil and isAtAuctionHouse)
	local untracked = isAtAuctionHouse and untrackedNow(container, ctx) or {}
	if armed == 'untracked' then
		container.untrackedButton:SetLabel(string.format('Confirm: cancel %d untracked, one per click', #untracked))
	else
		container.untrackedButton:SetLabel(string.format('Cancel untracked (%d)', #untracked))
	end
	container.untrackedButton:SetEnabled(#untracked > 0 and not container.state.isAwaitingServer)
end

function selectedRow(container)
	return container.state.rows[container.state.selected]
end

-- The owned auctions not posted from a venture, as the server last listed them, less the ones
-- cancelled this visit.
function untrackedNow(container, ctx)
	local market = marketNow()
	local tracked = {}
	for _, record in ipairs(market and ns.AuctionTracker.list(market) or {}) do
		tracked[record.auctionId] = record
	end
	return ns.Advice.untracked(ctx.wow:OwnedAuctions(), tracked, {
		pendingVenturePosts = pendingVenturePosts(),
		skip = container.state.cancelledIds,
	})
end

-- Runs on the click (a hardware event): the first arms it, the second cancels.
function onCancelClick(container, ctx)
	local row = selectedRow(container)
	if not row or not ctx.window:IsAtAuctionHouse() then
		return
	end
	if container.state.armed ~= row.record.auctionId then
		container.state.armed = row.record.auctionId
		refreshDetail(container, ctx)
		return
	end
	container.state.armed = nil
	if ctx.wow:CancelAuction(row.record.auctionId) then
		local price = row.advice.price
		ctx.setStatus(
			price and ('Cancelled; post it again at ' .. money(price) .. ' from the Sell tab.') or 'Cancelled.'
		)
	else
		ctx.setStatus('The auction house did not take the cancel; try again in a moment.')
	end
	refreshDetail(container, ctx)
end

-- The first click arms; each later click cancels one more until none is left.
function onCancelUntrackedClick(container, ctx)
	if not ctx.window:IsAtAuctionHouse() or container.state.isAwaitingServer then
		return
	end
	local untracked = untrackedNow(container, ctx)
	if container.state.armed ~= 'untracked' then
		container.state.armed = #untracked > 0 and 'untracked' or nil
		refreshDetail(container, ctx)
		return
	end
	local entry = untracked[1]
	if not entry then
		container.state.armed = nil
	elseif ctx.wow:CancelAuction(entry.auctionId) then
		ctx.setStatus(string.format('Cancelled %s; %d untracked left.', itemName(entry.itemId), #untracked - 1))
		-- Never offered again this visit, and the button waits for the server's answer
		-- (OWNED_AUCTIONS_UPDATED or AUCTION_CANCELED), which disarms it.
		container.state.cancelledIds[entry.auctionId] = true
		container.state.isAwaitingServer = true
		container.state.armed = nil
		local wait = {}
		container.state.serverWait = wait
		ctx.wow:After(SERVER_WAIT_SECONDS, function()
			if container.state.serverWait == wait then
				container.state.isAwaitingServer, container.state.serverWait = nil, nil
				refreshDetail(container, ctx)
			end
		end)
	else
		ctx.setStatus('The auction house did not take the cancel; try again in a moment.')
	end
	refreshDetail(container, ctx)
end

function rowLabel(row)
	local record, advice = row.record, row.advice
	local level = advice.confidence and advice.confidence.level
	local mark = level == 'high' and '' or '? '
	local action = advice.action == 'relist' and ('relist at ' .. money(advice.price)) or 'hold'
	return string.format(
		'%s%s · %d at %s · %s',
		mark,
		itemName(record.itemId),
		record.listed or 0,
		money(record.unitPrice),
		action
	)
end

function detailLines(row)
	local record, advice = row.record, row.advice
	local lines = {
		{ text = string.format('%d listed at %s each', record.listed or 0, money(record.unitPrice)) },
	}
	if advice.action == 'relist' then
		lines[#lines + 1] = { text = 'Relist at ' .. money(advice.price) }
		lines[#lines + 1] = { text = 'Nets after the lost deposit: ' .. money(advice.net) }
		lines[#lines + 1] = { text = 'Against the listing as it stands: ' .. signed(advice.gain) }
		if advice.overVendor then
			lines[#lines + 1] = { text = 'Against selling to a vendor: ' .. signed(advice.overVendor) }
		end
	else
		lines[#lines + 1] = { text = 'Hold' }
	end
	lines[#lines + 1] = { text = advice.text }
	local confidence = advice.confidence or {}
	lines[#lines + 1] =
		{ text = CONFIDENCE_TEXT[confidence.level] or CONFIDENCE_TEXT.low, level = confidence.level or 'low' }
	for _, reason in ipairs(confidence.reasons or {}) do
		if reason.level ~= 'high' then
			lines[#lines + 1] = { text = '    ' .. tostring(reason.text), level = reason.level }
		end
	end
	return lines
end

-- The item's step when no rule price gives one: from the scan (copper seen in any listing,
-- ours included; a stack over one seen), else whole silver, as ItemMarket infers it.
function stepFor(record, scanItem)
	local maxStackSeen = scanItem and scanItem.maxStackSeen
	local hasOwnCopper = type(record.unitPrice) == 'number' and record.unitPrice % 100 ~= 0
	return ns.ItemMarket.forItem({
		maxStack = type(maxStackSeen) == 'number' and maxStackSeen > 1 and maxStackSeen or nil,
		copperSeen = hasOwnCopper or (scanItem ~= nil and scanItem.copperSeen == true),
	}).step
end

-- The unit price at which relisting the auction's units still covers what they cost (their
-- cost-pool share when posted); nil when their cost is unknown.
function breakEvenFor(record, step, vendor)
	local knownUnits, knownCopper = record.knownUnits, record.knownCopper
	if type(knownUnits) ~= 'number' or knownUnits <= 0 or type(knownCopper) ~= 'number' then
		return nil
	end
	if type(record.listed) ~= 'number' or record.listed <= 0 then
		return nil
	end
	return ns.Guardrail.breakEven({
		units = record.listed,
		cost = knownCopper / knownUnits,
		deposit = type(record.deposit) == 'number' and record.deposit or 0,
		step = step,
		vendor = vendor,
	})
end

-- Venture posts the client has not confirmed with an auction id yet.
function pendingVenturePosts()
	local posts = {}
	for _, post in ipairs(ns.books and ns.books.pendingPosts or {}) do
		if type(post) == 'table' and post.ventureId ~= nil then
			posts[#posts + 1] = post
		end
	end
	return posts
end

function signed(copper)
	if type(copper) ~= 'number' then
		return '?'
	end
	return (copper < 0 and '-' or '+') .. money(math.abs(copper))
end

function itemName(itemId)
	local name = ns.prices and type(itemId) == 'number' and ns.prices:KnownName(itemId)
	return name or ('Item ' .. tostring(itemId))
end

function money(copper)
	return ns.TooltipLines.money(copper or 0)
end

function marketNow()
	local marketKey = ns.prices and ns.prices:MarketKey()
	return marketKey and ns.store:Market(marketKey) or nil
end

function charKey()
	return ns.store and ns.store:CharacterKey(ns.wow:Player()) or nil
end
