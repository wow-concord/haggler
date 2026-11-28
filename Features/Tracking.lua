--[[
	Tracking: turns what the player does into bookkeeping (Engine/Books.lua). It owns ns.books
	and its hooks; the Ledger and Ventures tabs and the profession frame read what it books.

	  auction house  PostItem / PostCommodity (and their Confirm calls) · AUCTION_HOUSE_AUCTION_CREATED
	                 · CancelAuction · OWNED_AUCTIONS_UPDATED · ConfirmCommoditiesPurchase · PlaceBid
	  mailbox        TakeInboxMoney · TakeInboxItem (one attachment) · AutoLootMailItem (all): the
	                 invoice and attachments are read on the call and booked on MAIL_INBOX_UPDATE
	                 for whatever left the mail, once each; MAIL_CLOSED drops the takes not yet
	                 answered, unbooked; an outbid mail drops the bid it answers
	  merchant       BuyMerchantItem · selling with a click (C_Container.UseContainerItem)
	  bags           PickupContainerItem then DeleteCursorItem: a destroyed stack, while the cursor
	                 still holds it (CURSOR_CHANGED drops a pickup that left the cursor)
	  crafting       C_TradeSkillUI.CraftRecipe notes the casts; UNIT_SPELLCAST_SUCCEEDED books each

	Every hook is a post-hook (hooksecurefunc): Haggler never replaces a Blizzard function, so it
	cannot taint them. A hook cannot be removed, so the hooks install once and do nothing while
	the module is off. Haggler never queries owned auctions itself; it reads the list the auction
	house sends when the player opens it.
]]
local _, ns = ...

local MODULE_KEY = 'tracking'
local EVENT_OWNER = 'tracking'
-- Enum.AuctionHouseTimeLeftBand-style durations the post calls take.
local DURATION_HOURS = { [1] = 12, [2] = 24, [3] = 48 }
local NAME_MATCH_LIMIT = 20
-- Won mails without an invoice count whose attachments are being taken one at a time.
local WON_TALLY_LIMIT = 32

-- Helpers live at the bottom of the file; declared here so they stay local.
local installHooks, onPost, onMailTaken, notePendingTake, resolvePendingTakes, discardPendingTakes
local pendingTakeKey, pendingUnitsOnMail, wonTally, noteWonTallyBooked
local isStillInMail, isTakesMail, holdsTake, isSameInvoice, bookTake, attachedUnits, wonShare
local itemIdByName, saleQty, marketNow, charKey, onCraftSucceeded
local onVendorSell, onPickup, onCursorChanged, onDestroy, onMerchantBuy, onBid

local state = {
	isOn = false,
	isHooked = false,
	pendingTakes = {},
	pendingTakeOrder = {},
	wonTallies = {},
	pendingCrafts = {},
	pickup = nil,
	prefixes = nil,
}
local MAIL_EVENTS = { 'MAIL_INBOX_UPDATE', 'MAIL_CLOSED' }

ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Auctions, mail and ledger',
	settings = {
		{ key = 'vendor', type = 'toggle', label = 'Book vendor purchases and sales', default = true },
		{ key = 'destroy', type = 'toggle', label = 'Book destroyed items', default = true },
	},
	onEnable = function(module)
		state.isOn = true
		state.module = module
		ns.books = ns.Books.new({
			market = marketNow,
			char = function()
				return charKey(ns.wow:Player())
			end,
			now = function()
				return ns.wow:Now()
			end,
			held = function(itemId)
				return ns.wow:ItemCount(itemId)
			end,
			vendorPrice = function(itemId)
				return ns.prices and ns.prices:VendorPrice(itemId)
			end,
			send = function(message, ...)
				module:Send(message, ...)
			end,
		})
		ns.books.startedAt = ns.wow:Now()
		installHooks()
		ns.wow:OnEvent('AUCTION_HOUSE_POST_WARNING', function()
			ns.books:OnPostWarning()
		end, EVENT_OWNER)
		ns.wow:OnEvent('AUCTION_HOUSE_POST_ERROR', function()
			ns.books:OnPostError()
		end, EVENT_OWNER)
		ns.wow:OnEvent('AUCTION_HOUSE_AUCTION_CREATED', function(_, auctionId)
			ns.books:OnAuctionCreated(auctionId)
		end, EVENT_OWNER)
		ns.wow:OnEvent('OWNED_AUCTIONS_UPDATED', function()
			local owned = ns.wow:OwnedAuctions()
			if owned then
				ns.books:OnOwnedList(owned)
			end
		end, EVENT_OWNER)
		ns.wow:OnEvent('UNIT_SPELLCAST_SUCCEEDED', function(_, unit, _, spellId)
			if unit == 'player' then
				onCraftSucceeded(spellId)
			end
		end, EVENT_OWNER)
		ns.wow:OnEvent('PLAYER_ENTERING_WORLD', function()
			ns.books:Maintain()
		end, EVENT_OWNER)
		ns.wow:OnEvent('CURSOR_CHANGED', onCursorChanged, EVENT_OWNER)
		ns.wow:OnEvent('MAIL_INBOX_UPDATE', resolvePendingTakes, EVENT_OWNER)
		-- With the mailbox closed the client reads no mail at all, so a take it has not answered
		-- yet cannot be told from one that failed: it is dropped, never booked on a guess.
		ns.wow:OnEvent('MAIL_CLOSED', discardPendingTakes, EVENT_OWNER)
	end,
	onDisable = function()
		state.isOn = false
		for _, event in ipairs({
			'AUCTION_HOUSE_AUCTION_CREATED',
			'AUCTION_HOUSE_POST_WARNING',
			'AUCTION_HOUSE_POST_ERROR',
			'OWNED_AUCTIONS_UPDATED',
			'UNIT_SPELLCAST_SUCCEEDED',
			'PLAYER_ENTERING_WORLD',
			'CURSOR_CHANGED',
			MAIL_EVENTS[1],
			MAIL_EVENTS[2],
		}) do
			ns.wow:OffEvent(event, EVENT_OWNER)
		end
		state.pendingTakes, state.pendingTakeOrder = {}, {}
		state.pickup = nil
		ns.books = nil
	end,
})

-- Hooks -------------------------------------------------------------------------------------

function installHooks()
	if state.isHooked then
		return
	end
	state.isHooked = true
	local wow = ns.wow
	local function guarded(handler)
		return function(...)
			if state.isOn and ns.books then
				handler(...)
			end
		end
	end
	wow:HookTable(
		'C_AuctionHouse',
		'PostItem',
		guarded(function(location, duration, qty, _, buyout)
			onPost(location, duration, qty, buyout and qty and qty > 0 and math.floor(buyout / qty), false, false)
		end)
	)
	wow:HookTable(
		'C_AuctionHouse',
		'ConfirmPostItem',
		guarded(function(location, duration, qty, _, buyout)
			onPost(location, duration, qty, buyout and qty and qty > 0 and math.floor(buyout / qty), false, true)
		end)
	)
	wow:HookTable(
		'C_AuctionHouse',
		'PostCommodity',
		guarded(function(location, duration, qty, unitPrice)
			onPost(location, duration, qty, unitPrice, true, false)
		end)
	)
	wow:HookTable(
		'C_AuctionHouse',
		'ConfirmPostCommodity',
		guarded(function(location, duration, qty, unitPrice)
			onPost(location, duration, qty, unitPrice, true, true)
		end)
	)
	wow:HookTable(
		'C_AuctionHouse',
		'CancelAuction',
		guarded(function(auctionId)
			ns.books:OnCancel(auctionId)
		end)
	)
	wow:HookTable(
		'C_AuctionHouse',
		'ConfirmCommoditiesPurchase',
		guarded(function(itemId, qty)
			ns.books:OnPurchase({ itemId = itemId, qty = qty })
		end)
	)
	wow:HookTable('C_AuctionHouse', 'PlaceBid', guarded(onBid))
	wow:HookGlobalFunction(
		'TakeInboxMoney',
		guarded(function(index)
			onMailTaken(index, nil, false)
		end)
	)
	wow:HookGlobalFunction(
		'TakeInboxItem',
		guarded(function(index, attachment)
			onMailTaken(index, attachment, false)
		end)
	)
	wow:HookGlobalFunction(
		'AutoLootMailItem',
		guarded(function(index)
			onMailTaken(index, nil, true)
		end)
	)
	wow:HookGlobalFunction('BuyMerchantItem', guarded(onMerchantBuy))
	wow:HookTable('C_Container', 'UseContainerItem', guarded(onVendorSell))
	wow:HookTable('C_Container', 'PickupContainerItem', guarded(onPickup))
	wow:HookGlobalFunction('DeleteCursorItem', guarded(onDestroy))
	wow:HookTable(
		'C_TradeSkillUI',
		'CraftRecipe',
		guarded(function(recipeId, casts)
			local schematic = ns.wow:RecipeSchematic(recipeId)
			if schematic then
				state.pendingCrafts[recipeId] =
					{ casts = type(casts) == 'number' and casts or 1, schematic = schematic }
			end
		end)
	)
end

function onPost(location, duration, qty, unitPrice, isCommodity, isConfirm)
	local itemId = ns.wow:ItemIdAt(location)
	if not itemId or type(qty) ~= 'number' or type(unitPrice) ~= 'number' then
		return
	end
	local hours = DURATION_HOURS[duration] or 24
	local deposit = ns.wow:PostDeposit(location, itemId, duration, qty, isCommodity)
	local isDepositEstimated = deposit == nil
	if isDepositEstimated then
		deposit = ns.Guardrail.estimateDeposit(ns.prices and ns.prices:VendorPrice(itemId) or 0, qty, hours)
	end
	ns.books:OnPost({
		itemId = itemId,
		qty = qty,
		unitPrice = unitPrice,
		hours = hours,
		deposit = deposit,
		isDepositEstimated = isDepositEstimated,
		isConfirm = isConfirm,
		slot = ns.wow:SlotKey(location),
	})
end

function onBid(auctionId)
	local auction = ns.wow:AuctionItem(auctionId)
	if auction then
		ns.books:OnPurchase({ itemId = auction.itemId, qty = auction.qty, isBid = true })
	end
end

-- A take is booked once the client confirms it (MAIL_INBOX_UPDATE): money still on the mail, or
-- an attachment still in its slot, was not taken (full bags, gold cap, a double click). What the
-- mail holds is read now, while it is still there.
function onMailTaken(index, attachment, isAutoLoot)
	local header = ns.wow:InboxHeader(index)
	if not header then
		return
	end
	state.prefixes = state.prefixes or ns.MailMatcher.prefixes(function(name)
		return ns.wow.env[name]
	end)
	local kind, itemName = ns.MailMatcher.classify(header.subject, state.prefixes)
	if not kind then
		return
	end
	local mail =
		{ index = index, kind = kind, itemName = itemName, subject = header.subject, inboxCount = ns.wow:InboxCount() }
	if kind == 'sold' and header.money > 0 and (attachment == nil or isAutoLoot) then
		notePendingTake(mail, { money = header.money, invoice = ns.wow:InboxInvoice(index) })
	end
	if kind == 'outbid' and header.money > 0 then
		notePendingTake(mail, { money = header.money })
	end
	if kind == 'won' or kind == 'expired' or kind == 'cancelled' then
		local invoice = kind == 'won' and ns.wow:InboxInvoice(index) or nil
		-- Every unit the mail brought and how many left it before each take: those the server
		-- took (the units less what is still attached) and those still waiting on its answer.
		-- The units are the invoice's count; without one, a tally of the mail's earlier takes
		-- remembers them.
		local attached = attachedUnits(ns.wow:InboxItems(index))
		local hasCount = invoice and type(invoice.count) == 'number' and invoice.count >= attached
		local tally = invoice and not hasCount and wonTally(mail, invoice, attached) or nil
		local units = math.max(hasCount and invoice.count or tally and tally.units or attached, 1)
		local before = units - attached + pendingUnitsOnMail(mail)
		local wanted = isAutoLoot and ns.wow:InboxItems(index) or (attachment and ns.wow:InboxItems(index, attachment))
		for _, item in ipairs(wanted or {}) do
			local take = { item = item, invoice = invoice, units = units, before = before, tally = tally }
			if not state.pendingTakes[pendingTakeKey(mail, take)] then
				notePendingTake(mail, take)
				before = before + item.count
			end
		end
	end
end

-- One pending take a money or an attachment: a second call before the client answers adds none.
function notePendingTake(mail, take)
	local key = pendingTakeKey(mail, take)
	if state.pendingTakes[key] then
		return
	end
	take.mail = mail
	state.pendingTakes[key] = take
	state.pendingTakeOrder[#state.pendingTakeOrder + 1] = key
end

function resolvePendingTakes()
	local order = state.pendingTakeOrder
	state.pendingTakeOrder = {}
	local takes = state.pendingTakes
	state.pendingTakes = {}
	if not (state.isOn and ns.books) then
		return
	end
	for _, key in ipairs(order) do
		local take = takes[key]
		if not isStillInMail(take) then
			bookTake(take)
		end
	end
end

function discardPendingTakes()
	state.pendingTakes, state.pendingTakeOrder = {}, {}
end

-- Whether the mail still holds what the take asked for. The index names the mail only while the
-- inbox count holds: fewer mails means one left (the one at this index now may be the next one
-- with the same subject), more means new mail came in at the top and pushed this one down. A
-- money take also checks the invoice, which tells two mails of one subject apart.
function isStillInMail(take)
	local mail = take.mail
	local index = mail.index
	local inboxCount = ns.wow:InboxCount()
	if inboxCount and mail.inboxCount and inboxCount ~= mail.inboxCount then
		if inboxCount < mail.inboxCount then
			return false
		end
		-- Usually new mail lands on top. Only when the mail there is not the take's does the take
		-- look in place, for new mail that sorted below it.
		local shifted = index + inboxCount - mail.inboxCount
		if isTakesMail(take, shifted) then
			return holdsTake(take, shifted)
		end
		return isTakesMail(take, index) and holdsTake(take, index)
	end
	return isTakesMail(take, index) and holdsTake(take, index)
end

-- Whether the mail at index has the take's subject and invoice.
function isTakesMail(take, index)
	local header = ns.wow:InboxHeader(index)
	return header ~= nil
		and header.subject == take.mail.subject
		and isSameInvoice(take.invoice, ns.wow:InboxInvoice(index))
end

-- Whether the take's mail, at index, still holds what was asked for.
function holdsTake(take, index)
	local header = ns.wow:InboxHeader(index)
	if take.money then
		return header.money > 0
	end
	local item = ns.wow:InboxItems(index, take.item.attachment)[1]
	return item ~= nil and item.itemId == take.item.itemId and item.count == take.item.count
end

function bookTake(take)
	local books, mail = ns.books, take.mail
	if take.money and mail.kind == 'outbid' then
		local itemId = itemIdByName(mail.itemName)
		if itemId then
			books:OnOutbidMail({ itemId = itemId })
		end
		return
	end
	if take.money then
		local invoice = take.invoice
		local itemId = itemIdByName(invoice and invoice.itemName or mail.itemName)
		if not invoice or not itemId then
			return
		end
		books:OnSaleMail({
			itemId = itemId,
			qty = invoice.count or saleQty(itemId, invoice.bid),
			bid = invoice.bid,
			deposit = invoice.deposit,
			cut = invoice.cut,
			money = take.money,
		})
		return
	end
	local item = take.item
	if mail.kind == 'won' then
		books:OnWonMail({ itemId = item.itemId, qty = item.count, bid = wonShare(take, item.count) })
		noteWonTallyBooked(take.tally, item.count)
	else
		books:OnReturnMail({ kind = mail.kind, itemId = item.itemId, qty = item.count })
	end
end

function onMerchantBuy(index, qty)
	if not state.module:Setting('vendor') then
		return
	end
	local item = ns.wow:MerchantItem(index)
	if not item or item.hasExtendedCost or item.price <= 0 then
		return
	end
	local units = type(qty) == 'number' and qty > 0 and qty or item.stack
	ns.books:OnVendorBuy({
		itemId = item.itemId,
		qty = units,
		copper = math.floor(item.price * units / math.max(item.stack, 1)),
	})
end

function onVendorSell(bag, slot)
	if not state.module:Setting('vendor') or not ns.wow:IsMerchantOpen() then
		return
	end
	local item = ns.wow:ContainerItem(bag, slot)
	if not item or not item.itemId or item.hasNoValue then
		return
	end
	local vendor = ns.prices and ns.prices:VendorPrice(item.itemId) or 0
	-- The post-hook runs before the server takes the stack, so the bags still hold it.
	ns.books:OnVendorSell({
		itemId = item.itemId,
		qty = item.count,
		copper = vendor * item.count,
		held = math.max(ns.wow:ItemCount(item.itemId), item.count),
	})
end

function onPickup(bag, slot)
	local item = ns.wow:ContainerItem(bag, slot)
	state.pickup = item and item.itemId and { itemId = item.itemId, qty = item.count } or nil
end

-- A pickup that left the cursor (put back, swapped) is not what a later delete destroys.
function onCursorChanged()
	local picked = state.pickup
	if picked and ns.wow:CursorItemId() ~= picked.itemId then
		state.pickup = nil
	end
end

function onDestroy()
	local picked = state.pickup
	state.pickup = nil
	if not picked or not state.module:Setting('destroy') then
		return
	end
	-- The cursor may already be empty as the post-hook runs; another item on it is not the pickup.
	local onCursor = ns.wow:CursorItemId()
	if onCursor and onCursor ~= picked.itemId then
		return
	end
	ns.books:OnDestroy({ itemId = picked.itemId, qty = picked.qty })
end

function onCraftSucceeded(spellId)
	local pending = state.pendingCrafts[spellId]
	if not pending or not state.isOn or not ns.books then
		return
	end
	pending.casts = pending.casts - 1
	if pending.casts <= 0 then
		state.pendingCrafts[spellId] = nil
	end
	local schematic = pending.schematic
	ns.books:OnCraft({
		recipeId = spellId,
		outputItemId = schematic.outputItemId,
		made = schematic.quantity,
		reagents = schematic.reagents,
	})
end

-- Helpers ---------------------------------------------------------------------------------

function marketNow()
	local marketKey = ns.prices and ns.prices:MarketKey()
	return marketKey and ns.store:Market(marketKey) or nil
end

function charKey(player)
	return ns.store and ns.store:CharacterKey(player) or nil
end

-- An invoice names the item, not its id: a tracked auction of that name first (the player's own
-- listing), then a pending buy (the player's bid), then the names the price source knows.
function itemIdByName(itemName)
	if type(itemName) ~= 'string' or itemName == '' then
		return nil
	end
	local market = marketNow()
	for _, record in pairs(market and market.auctions or {}) do
		local info = type(record.itemId) == 'number' and ns.wow:ItemInfo(record.itemId)
		if info and info.name == itemName then
			return record.itemId
		end
	end
	for _, buy in ipairs(ns.books and ns.books.pendingBuys or {}) do
		local info = ns.wow:ItemInfo(buy.itemId)
		if info and info.name == itemName then
			return buy.itemId
		end
	end
	local lower = itemName:lower()
	for _, itemId in ipairs(ns.prices and ns.prices:ItemIdsByName(lower, NAME_MATCH_LIMIT) or {}) do
		local info = ns.prices:ItemInfo(itemId)
		local name = ns.prices:KnownName(itemId) or (info and info.name)
		if type(name) == 'string' and name:lower() == lower then
			return itemId
		end
	end
	return nil
end

function isSameInvoice(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a.itemName == b.itemName
		and a.bid == b.bid
		and a.deposit == b.deposit
		and a.cut == b.cut
		and a.count == b.count
end

-- The copper of count more units of a won mail: the price paid covers every unit the mail
-- brought, and each take books the difference of the running totals before and after it, so the
-- attachments add up to what was paid (the last one takes the rounding remainder).
function wonShare(take, count)
	local paid = take.invoice and take.invoice.bid or 0
	local before = math.max(0, math.min(take.before or 0, take.units))
	local after = math.min(before + count, take.units)
	return math.floor(paid * after / take.units) - math.floor(paid * before / take.units)
end

function attachedUnits(items)
	local units = 0
	for _, item in ipairs(items) do
		units = units + item.count
	end
	return units
end

function pendingTakeKey(mail, take)
	local what = take.item and ('a' .. take.item.attachment .. ':' .. take.item.itemId .. 'x' .. take.item.count)
		or ('m' .. take.money)
	return table.concat({ mail.index, mail.subject, what }, '|')
end

-- The units of the mail's item takes still waiting on the server.
function pendingUnitsOnMail(mail)
	local units = 0
	for _, take in pairs(state.pendingTakes) do
		if take.item and take.mail.index == mail.index and take.mail.subject == mail.subject then
			units = units + take.item.count
		end
	end
	return units
end

-- The tally of a won mail without an invoice count: the units it brought and those booked from
-- it so far. The tally whose units not yet booked are what is still attached is this mail's;
-- without one, the mail is whole and starts one. Tallies end once every unit is booked, and the
-- oldest goes past WON_TALLY_LIMIT.
function wonTally(mail, invoice, attached)
	local key = table.concat({
		mail.subject,
		tostring(invoice.itemName),
		tostring(invoice.bid),
		tostring(invoice.deposit),
		tostring(invoice.cut),
	}, '|')
	for _, tally in ipairs(state.wonTallies) do
		if tally.key == key and tally.units - tally.booked == attached then
			return tally
		end
	end
	local tally = { key = key, units = attached, booked = 0 }
	table.insert(state.wonTallies, tally)
	if #state.wonTallies > WON_TALLY_LIMIT then
		table.remove(state.wonTallies, 1)
	end
	return tally
end

function noteWonTallyBooked(tally, count)
	if not tally then
		return
	end
	tally.booked = tally.booked + count
	if tally.booked < tally.units then
		return
	end
	for i, other in ipairs(state.wonTallies) do
		if other == tally then
			table.remove(state.wonTallies, i)
			return
		end
	end
end

-- A client without the invoice count: the units the bid buys at the unit price of the auction
-- the sale will settle.
function saleQty(itemId, bid)
	local market = marketNow()
	local auctionId = market
		and ns.MailMatcher.findSale(market, { itemId = itemId, bid = bid }, charKey(ns.wow:Player()))
	local unitPrice = auctionId and market.auctions[auctionId].unitPrice
	if type(unitPrice) == 'number' and unitPrice > 0 then
		return math.max(1, math.floor(bid / unitPrice + 0.5))
	end
	return 1
end
