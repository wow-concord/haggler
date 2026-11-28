--[[
	Sell tab: the items in the bags with the default rule's suggested price, the deposit and the
	loss guardrail's verdict (Engine/Sell.lua), post first. Pick a row, step the price, pick a
	rule or a duration, and post it at the auction house.

	Posting is protected, so it runs straight from the Post button's click: no timer, no event
	in between. The guardrail asks for a second click before a listing expected to lose money
	(behaviour 'confirm'); when the client itself warns about the price (PostItem answers
	true), the next click posts through ConfirmPost*. A commodity posts every unit carried in
	one listing; anything else posts its first slot, one click a listing.

	Away from the auction house it shows the same numbers on saved data, with Post greyed out
	and the deposit estimated from the vendor price.

	The selection follows the item, not the row: a re-sort (bags changed, a new scan) keeps the
	same item selected. A price set with the stepper and an armed Post (a loss to confirm, the
	client's warning) belong to one item at one price; they are dropped when another item is
	selected, and an armed Post when the auction house opens or closes.
]]
local _, ns = ...

local PAGE_SIZE = 10
local ROW_HEIGHT = 36
local LIST_WIDTH = 440
local DETAIL_LINES = 15

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildList, buildDetail, reloadRows, refreshList, refreshDetail, selectedRow, currentVerdict
local onPostClick, depositFor, ruleChoices, itemName, actionLabel, settingsOf, disarm, selectIndex
local currentRule, armedKey, armedState

ns.window:AddTab({
	key = 'sell',
	label = 'Sell',
	order = 40,
	events = { 'BAG_UPDATE_DELAYED', 'AUCTION_HOUSE_SHOW', 'AUCTION_HOUSE_CLOSED' },
	build = function(container, ctx)
		-- ruleId nil is the default rule, whichever that is now.
		container.state = { page = 1, selected = 1, rows = {} }
		buildList(container, ctx)
		buildDetail(container, ctx)
	end,
	refresh = function(container, ctx)
		reloadRows(container, ctx)
		refreshList(container, ctx)
		refreshDetail(container, ctx)
	end,
	onEvent = function(container, ctx, event)
		if event == 'AUCTION_HOUSE_SHOW' or event == 'AUCTION_HOUSE_CLOSED' then
			disarm(container)
		end
		if container:IsShown() and ctx.window:IsOpen() then
			reloadRows(container, ctx)
			refreshList(container, ctx)
			refreshDetail(container, ctx)
		end
	end,
})

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
			selectIndex(container, (container.state.pageFirst or 1) + index - 1)
			refreshList(container, ctx)
			refreshDetail(container, ctx)
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
	container.detail = detail
	container.title = ui:Text(detail, 17, 'color.text.title', ns.Widgets.HEADING_FACE)
	container.title:SetPoint('TOPLEFT', detail, 'TOPLEFT')
	container.rulePicker = ui:Stepper(detail, 300, function(delta)
		local choices = ruleChoices()
		if #choices == 0 then
			return
		end
		local _, currentIndex = currentRule(container)
		local nextRule = choices[((currentIndex - 1 + delta) % #choices) + 1]
		container.state.ruleId = nextRule.id
		container.state.priceOverride = nil
		disarm(container)
		ctx.window:Refresh()
	end)
	container.rulePicker:SetPoint('TOPLEFT', container.title, 'BOTTOMLEFT', 0, -12)
	container.pricePicker = ui:Stepper(detail, 300, function(delta)
		local row = selectedRow(container)
		if row then
			container.state.priceOverride = ns.Sell.stepPrice(row, container.state.priceOverride, delta)
			disarm(container)
			refreshDetail(container, ctx)
		end
	end, { '-', '+' })
	container.pricePicker:SetPoint('TOPLEFT', container.rulePicker, 'BOTTOMLEFT', 0, -8)
	container.durationPicker = ui:Stepper(detail, 300, function(delta)
		local durations = ns.WindowModel.DURATIONS
		local current = ns.WindowModel.durationIndex(ctx.setting('duration'))
		local nextIndex = ((current - 1 + delta) % #durations) + 1
		ctx.window.module:SetSetting('duration', durations[nextIndex].value)
		disarm(container)
		ctx.window:Refresh()
	end)
	container.durationPicker:SetPoint('TOPLEFT', container.pricePicker, 'BOTTOMLEFT', 0, -8)
	local body = ctx.wow:CreateFrame('Frame', detail)
	body:SetPoint('TOPLEFT', container.durationPicker, 'BOTTOMLEFT', 0, -16)
	body:SetSize(400, DETAIL_LINES * 20 + 40)
	container.lines = ui:PagedLines(body, DETAIL_LINES, 13, 400)
	container.lines.frame:SetPoint('TOPLEFT', body, 'TOPLEFT')
	container.postButton = ui:Button(detail, 'Post', 'primary')
	container.postButton:SetPoint('BOTTOMLEFT', detail, 'BOTTOMLEFT')
	container.postButton:OnClick(function()
		onPostClick(container, ctx)
	end)
end

function reloadRows(container, ctx)
	local prices = ns.prices
	if not prices then
		container.state.rows = {}
		return
	end
	local rule = currentRule(container)
	local carried = ctx.wow:CarriedItems()
	local slotByItemId = {}
	for _, entry in ipairs(carried) do
		slotByItemId[entry.itemId] = slotByItemId[entry.itemId] or entry
	end
	local settings = settingsOf(ctx)
	container.state.rows = ns.Sell.rows(carried, {
		prices = prices,
		store = ns.store,
		ruleId = rule and rule.id,
		durationHours = settings.hours,
		threshold = settings.threshold,
		behaviour = settings.behaviour,
		deposit = function(itemId, units)
			return depositFor(ctx, slotByItemId[itemId], units, settings.durationIndex)
		end,
	})
	local rows = container.state.rows
	for index, row in ipairs(rows) do
		if row.itemId == container.state.selectedItemId then
			container.state.selected = index
			return
		end
	end
	selectIndex(container, math.max(1, math.min(#rows, container.state.selected)))
end

function refreshList(container, ctx)
	local rows = container.state.rows
	local page = ns.WindowModel.page(rows, container.state.page, PAGE_SIZE)
	container.state.page, container.state.pageFirst = page.page, page.first
	for index, button in ipairs(container.rowButtons) do
		local row = page.items[index]
		if row then
			button:Show()
			local priceText = row.price and ns.TooltipLines.money(row.price.copper) or 'no price'
			button:SetLabel(
				string.format('%s x%d · %s · %s', itemName(row.itemId), row.count, priceText, actionLabel(row))
			)
			button:SetSelected(page.first + index - 1 == container.state.selected)
		else
			button:Hide()
		end
	end
	container.pager:SetValue(
		#rows == 0 and 'Nothing to sell in your bags' or string.format('Page %d of %d', page.page, page.pageCount)
	)
	return ctx
end

function refreshDetail(container, ctx)
	local row = selectedRow(container)
	local rule = currentRule(container)
	container.rulePicker:SetValue('Rule: ' .. (rule and rule.name or 'none'))
	local durationLabel = ns.WindowModel.DURATIONS[ns.WindowModel.durationIndex(ctx.setting('duration'))].label
	container.durationPicker:SetValue('Duration: ' .. durationLabel)
	if not row then
		ctx.setCredit(nil)
		container.title:SetText('')
		container.pricePicker:SetValue('')
		container.lines:SetLines({})
		container.linesItemId = nil
		container.postButton:SetEnabled(false)
		return
	end
	local verdict = currentVerdict(container, row)
	ctx.setCredit(row.price and row.price.usesPriceSource and ctx.window:Credit() or nil)
	container.title:SetText(itemName(row.itemId))
	container.pricePicker:SetValue(verdict.price and ns.TooltipLines.money(verdict.price) or 'no price')
	local lines = ns.WindowModel.sellLines(row, verdict)
	if not ctx.window:IsAtAuctionHouse() then
		lines[#lines + 1] = { text = 'Posting needs the auction house.', level = 'medium' }
	end
	container.lines:SetLines(lines, row.itemId == container.linesItemId)
	container.linesItemId = row.itemId
	local canPost = ctx.window:IsAtAuctionHouse() and verdict.price ~= nil
	container.postButton:SetEnabled(canPost)
	local armed = armedState(container, row, verdict)
	if armed == 'loss' then
		container.postButton:SetLabel('Post at a loss? Click again')
	elseif armed == 'clientWarning' then
		container.postButton:SetLabel('The auction house warns about this price: click to post')
	else
		container.postButton:SetLabel(row.listings > 1 and 'Post one listing' or 'Post')
	end
end

function selectedRow(container)
	return container.state.rows[container.state.selected]
end

function currentVerdict(container, row)
	if container.state.priceOverride then
		return ns.Sell.verdictAt(row, container.state.priceOverride)
	end
	return row.verdict
end

-- Runs on the Post button's click (a hardware event); the post call is made right here.
function onPostClick(container, ctx)
	local row = selectedRow(container)
	if not row or not ctx.window:IsAtAuctionHouse() then
		return
	end
	local verdict = currentVerdict(container, row)
	local settings = settingsOf(ctx)
	local check = ns.Guardrail.postCheck(verdict, settings.behaviour)
	local armed = armedState(container, row, verdict)
	if check == 'confirm' and armed == nil then
		container.state.armed, container.state.armedFor = 'loss', armedKey(row, verdict)
		refreshDetail(container, ctx)
		return
	end
	local slot = row.slots[1]
	local sellable, reason = ctx.wow:SellableItem(slot.bag, slot.slot, row.itemId)
	if not sellable then
		ctx.setStatus('Not posted: ' .. tostring(reason) .. '.')
		disarm(container)
		return
	end
	local quantity = ns.WindowModel.postQuantity(row, sellable)
	local post = armed == 'clientWarning' and ctx.wow.ConfirmAuction or ctx.wow.PostAuction
	local result, why = post(ctx.wow, sellable, settings.durationIndex, quantity, verdict.price)
	if result == 'needsConfirm' then
		container.state.armed, container.state.armedFor = 'clientWarning', armedKey(row, verdict)
		refreshDetail(container, ctx)
		return
	end
	disarm(container)
	if not result then
		ctx.setStatus('Not posted: ' .. tostring(why) .. '.')
		refreshDetail(container, ctx)
		return
	end
	container.state.priceOverride = nil
	ctx.setStatus(
		string.format('Posted %d x %s at %s.', quantity, itemName(row.itemId), ns.TooltipLines.money(verdict.price))
	)
	refreshDetail(container, ctx)
end

function depositFor(ctx, entry, units, durationIndex)
	if not entry or not ctx.window:IsAtAuctionHouse() then
		return nil
	end
	local sellable = ctx.wow:SellableItem(entry.bag, entry.slot, entry.itemId)
	return sellable and ctx.wow:AuctionDeposit(sellable, durationIndex, units) or nil
end

function ruleChoices()
	return ns.prices and ns.prices:Rules() or {}
end

function itemName(itemId)
	local info = ns.prices and ns.prices:ItemInfo(itemId)
	return info and info.name or ('Item ' .. itemId)
end

function actionLabel(row)
	if row.verdict.action == 'post' then
		return row.check == 'ok' and 'post' or 'post (!)'
	end
	return row.verdict.action
end

function settingsOf(ctx)
	local hoursText = ctx.setting('duration')
	return {
		hours = tonumber(hoursText) or 24,
		durationIndex = ns.WindowModel.durationIndex(hoursText),
		behaviour = ctx.setting('guardrail'),
		threshold = {
			copper = (ctx.setting('vendorThresholdSilver') or 0) * 100,
			percent = ctx.setting('vendorThresholdPercent') or 0,
		},
	}
end

function disarm(container)
	container.state.armed, container.state.armedFor = nil, nil
end

-- Selects a row; another item than the one selected drops the stepped price and the armed Post.
function selectIndex(container, index)
	local state = container.state
	state.selected = index
	local row = state.rows[index]
	local itemId = row and row.itemId
	if itemId ~= state.selectedItemId then
		state.selectedItemId = itemId
		state.priceOverride = nil
		disarm(container)
	end
end

-- The rule picked (the default when none is, or the one picked is gone) and its index.
function currentRule(container)
	local choices = ruleChoices()
	for index, rule in ipairs(choices) do
		if rule.id == container.state.ruleId then
			return rule, index
		end
	end
	container.state.ruleId = nil
	-- Rules() lists the default first.
	return choices[1], 1
end

function armedKey(row, verdict)
	return tostring(row.itemId) .. ':' .. tostring(verdict.price)
end

-- The armed state, only while it is for this item at this price.
function armedState(container, row, verdict)
	if container.state.armed and container.state.armedFor == armedKey(row, verdict) then
		return container.state.armed
	end
	return nil
end
