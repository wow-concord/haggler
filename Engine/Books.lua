--[[
	Books: keeps the ledger, the cost pools, the tracked auctions and the ventures in step as
	things happen. Features/Tracking.lua turns game events into these calls; every figure the
	game reports is booked as it is.

	  posting       OnPost (the post call) · OnPostWarning / OnPostError · OnAuctionCreated (deposit paid, units leave the pool)
	  auctions      OnCancel · OnOwnedList (provisional sold / expired) · Maintain (expiries, pruning,
	                ledger compaction)
	  mail          OnSaleMail (sale, refund, cut) · OnReturnMail (units and their pool share back)
	                · OnWonMail (buy, pool in)
	  buying        OnPurchase (the purchase call: which venture it was for)
	  merchant      OnVendorBuy (pool in) · OnVendorSell · OnDestroy (pool out)
	  crafting      OnCraft (reagents out of the pool, their cash share to the venture)
	  ventures      CreateVenture · PlanCrafts · CloseVenture · CheckVentures (V2)

	Ventures are V2: without the planner (v2/Engine/Ventures.lua, left out of the release
	package) nothing is booked to a venture and CheckVentures does nothing. Ledger rows and
	tracked auctions keep any ventureId they already carry, and saved ventures are kept as
	they are. CreateVenture, PlanCrafts and CloseVenture need the planner and throw without it.

	Units leave the cost pool when they leave the bags (posted, crafted, vendored, destroyed) and
	an auction keeps the known share it took; units back from an expired or cancelled auction
	bring that share back. Traded items do not enter the pools; crafted output enters only as a
	venture leftover moved to stock, at what the player paid for it.

	Own-only (ASK-M-005): Books stores no value read from a price source. Craft, writeOff and
	toStock events carry their cash part only (the cost-pool share, or what was paid for the
	materials); estimates are read live from the venture (Ventures.profit).

	  Books.new(options) options = { market = fun() -> market|nil, char = fun() -> string|nil,
	    now = fun() -> seconds, held = fun(itemId) -> units, vendorPrice = fun(itemId) -> copper|nil,
	    send = fun(message, ...)? }

	Messages (sent through options.send): AUCTION_SOLD (auctionId|nil, itemId, qty, isProvisional),
	AUCTION_RETURNED (auctionId|nil, itemId, qty, kind), VENTURE_UPDATED (ventureId),
	LEDGER_CHANGED. A sale sends AUCTION_SOLD twice: provisionally when the owned list shows it,
	then for good when its mail is booked; a listener that counts sales skips the provisional one.
]]
local _, ns = ...

local Books = {}
ns.Books = Books

Books.MESSAGES = {
	auctionSold = 'AUCTION_SOLD',
	auctionReturned = 'AUCTION_RETURNED',
	ventureUpdated = 'VENTURE_UPDATED',
	ledgerChanged = 'LEDGER_CHANGED',
}

-- A bid can stand 48 hours; a pending buy no won mail came for by then never will.
Books.PENDING_BUY_SECONDS = 3 * 24 * 3600

local BooksMethods = {}
BooksMethods.__index = BooksMethods

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWholePositive, isWhole, heldOf, send, append, shareBack, ventureOf, openVentureFor, touchVenture
local requirePlanner, dropStaleBuys

--- @param options table see the file header
--- @return table books
function Books.new(options)
	if type(options) ~= 'table' then
		error('Books.new: needs options', 2)
	end
	for _, name in ipairs({ 'market', 'char', 'now', 'held' }) do
		if type(options[name]) ~= 'function' then
			error('Books.new: needs ' .. name, 2)
		end
	end
	return setmetatable({ options = options, pendingPosts = {}, pendingBuys = {} }, BooksMethods)
end

--- A post call: remembered until the auction house reports the new auction.
--- @param post table { itemId, qty, unitPrice, hours, deposit?, isDepositEstimated?, isConfirm?, slot? }
function BooksMethods:OnPost(post)
	local market, char = self.options.market(), self.options.char()
	if not market or not char or type(post) ~= 'table' then
		return
	end
	if not (isWholePositive(post.itemId) and isWholePositive(post.qty)) then
		return
	end
	local venture = openVentureFor(market, 'post', post.itemId)
	local entry = {
		itemId = post.itemId,
		qty = post.qty,
		unitPrice = post.unitPrice,
		hours = post.hours,
		deposit = post.deposit,
		isDepositEstimated = post.isDepositEstimated,
		isConfirm = post.isConfirm,
		slot = post.slot,
		char = char,
		ventureId = venture and venture.id or nil,
		held = heldOf(self, post.itemId),
	}
	ns.AuctionTracker.notePost(self.pendingPosts, entry, self.options.now())
end

--- The client held the newest post for a confirm, or refused it.
function BooksMethods:OnPostWarning()
	ns.AuctionTracker.noteWarning(self.pendingPosts)
end

function BooksMethods:OnPostError()
	ns.AuctionTracker.noteError(self.pendingPosts)
end

--- The auction house created an auction: the deposit is paid and the units leave the pool.
--- @return table|nil Tracked
function BooksMethods:OnAuctionCreated(auctionId)
	local market, now = self.options.market(), self.options.now()
	if not market then
		return nil
	end
	local record, post = ns.AuctionTracker.created(market, self.pendingPosts, auctionId, now)
	if not record then
		return nil
	end
	-- Held was read in the post call, while the units were still in the bags.
	local held = math.max(isWhole(post.held) and post.held or 0, record.qty)
	local split = ns.CostPool.remove(market, record.itemId, record.qty, held)
	record.knownUnits, record.knownCopper = split.knownUnits, split.knownCopper
	local common = { t = now, char = record.char, ventureId = record.ventureId, auctionId = auctionId }
	append(
		market,
		common,
		{ kind = 'post', itemId = record.itemId, qty = record.qty, copper = record.unitPrice * record.qty }
	)
	append(market, common, { kind = 'deposit', itemId = record.itemId, qty = record.qty, copper = record.deposit })
	local venture = ventureOf(market, record.ventureId)
	if venture then
		ns.Ventures.notePost(venture, record.itemId, record.qty, record.deposit)
		touchVenture(self, venture)
	end
	send(self, Books.MESSAGES.ledgerChanged)
	return record
end

--- The player cancelled an auction (its deposit is lost; the units come back by mail).
function BooksMethods:OnCancel(auctionId)
	local market = self.options.market()
	return market and ns.AuctionTracker.noteCancel(market, auctionId, self.options.now()) or nil
end

--- The character's owned-auction list: marks sold and expired auctions until the mail comes.
--- @param owned table { { auctionId, qty, isSold } }
function BooksMethods:OnOwnedList(owned)
	local market, char = self.options.market(), self.options.char()
	if not market or not char then
		return {}
	end
	local changes = ns.AuctionTracker.reconcile(market, owned, char, self.options.now())
	for _, change in ipairs(changes) do
		if change.soldQty or change.to == 'sold' then
			local record = market.auctions[change.auctionId]
			send(self, Books.MESSAGES.auctionSold, change.auctionId, record and record.itemId, change.soldQty, true)
		end
	end
	return changes
end

--- A sale invoice: the buyer's bid, the deposit back and the cut, as the server booked them.
--- @param sale table { itemId, qty, bid, deposit, cut }
--- @return number|nil auctionId the sale settled
function BooksMethods:OnSaleMail(sale)
	local market, char, now = self.options.market(), self.options.char(), self.options.now()
	if not market or not char or type(sale) ~= 'table' then
		return nil
	end
	if not (isWholePositive(sale.itemId) and isWholePositive(sale.qty) and isWhole(sale.bid)) then
		return nil
	end
	local auctionId = ns.MailMatcher.findSale(market, sale, char)
	local record = auctionId and market.auctions[auctionId]
	local ventureId = record and record.ventureId or nil
	local vendor = self.options.vendorPrice and self.options.vendorPrice(sale.itemId) or 0
	local isTroll = ns.MailMatcher.isTroll(math.floor(sale.bid / sale.qty), tonumber(vendor) or 0)
	local common = { t = now, char = char, ventureId = ventureId, auctionId = auctionId }
	append(
		market,
		common,
		{ kind = 'sale', itemId = sale.itemId, qty = sale.qty, copper = sale.bid, isTroll = isTroll }
	)
	if isWholePositive(sale.deposit) then
		append(market, common, { kind = 'refund', itemId = sale.itemId, qty = sale.qty, copper = sale.deposit })
	end
	if isWholePositive(sale.cut) then
		append(market, common, { kind = 'cut', itemId = sale.itemId, qty = sale.qty, copper = sale.cut })
	end
	if auctionId then
		ns.AuctionTracker.settle(market, auctionId, sale.qty, now)
	end
	local venture = ventureOf(market, ventureId)
	if venture then
		ns.Ventures.noteSale(venture, sale.itemId, sale.qty, {
			gross = sale.bid,
			cut = isWhole(sale.cut) and sale.cut or 0,
			refund = isWhole(sale.deposit) and sale.deposit or 0,
			isTroll = isTroll,
		})
		touchVenture(self, venture)
	end
	send(self, Books.MESSAGES.auctionSold, auctionId, sale.itemId, sale.qty)
	send(self, Books.MESSAGES.ledgerChanged)
	-- The last sale of a venture closes it now, not at the next login.
	if venture then
		self:CheckVentures()
	end
	return auctionId
end

--- Units back from an expired or cancelled auction; their cost-pool share comes back with them.
--- @param back table { kind = 'expired' | 'cancelled', itemId, qty }
--- @return number|nil auctionId
function BooksMethods:OnReturnMail(back)
	local market, char, now = self.options.market(), self.options.char(), self.options.now()
	if not market or not char or type(back) ~= 'table' then
		return nil
	end
	if not (isWholePositive(back.itemId) and isWholePositive(back.qty)) then
		return nil
	end
	local auctionId = ns.MailMatcher.findReturn(market, back, char, now)
	local record = auctionId and market.auctions[auctionId]
	if record then
		local units, copper = shareBack(record, back.qty)
		if units > 0 then
			ns.CostPool.add(market, record.itemId, units, copper)
		end
		ns.AuctionTracker.settle(market, auctionId, back.qty, now)
	end
	local kind = back.kind == 'cancelled' and 'cancel' or 'expire'
	local ventureId = record and record.ventureId or nil
	append(market, { t = now, char = char, ventureId = ventureId, auctionId = auctionId }, {
		kind = kind,
		itemId = back.itemId,
		qty = back.qty,
		copper = 0,
	})
	local venture = ventureOf(market, ventureId)
	if venture then
		ns.Ventures.noteReturn(venture, back.itemId, back.qty)
		touchVenture(self, venture)
	end
	send(self, Books.MESSAGES.auctionReturned, auctionId, back.itemId, back.qty, back.kind)
	send(self, Books.MESSAGES.ledgerChanged)
	return auctionId
end

--- A purchase call on the auction house: which venture the units are for, until the mail.
--- @param buy table { itemId, qty, isBid? } isBid: a bid that can still be outbid
function BooksMethods:OnPurchase(buy)
	local market = self.options.market()
	if not market or type(buy) ~= 'table' or not isWholePositive(buy.itemId) or not isWholePositive(buy.qty) then
		return
	end
	local now = self.options.now()
	dropStaleBuys(self, now)
	local venture = openVentureFor(market, 'buy', buy.itemId)
	self.pendingBuys[#self.pendingBuys + 1] = {
		itemId = buy.itemId,
		qty = buy.qty,
		ventureId = venture and venture.id or nil,
		isBid = buy.isBid == true or nil,
		t = now,
	}
end

--- An "outbid" mail: the oldest bid on the item will bring no won mail.
--- @param outbid table { itemId }
function BooksMethods:OnOutbidMail(outbid)
	if type(outbid) ~= 'table' or not isWholePositive(outbid.itemId) then
		return
	end
	for index, buy in ipairs(self.pendingBuys) do
		if buy.isBid and buy.itemId == outbid.itemId then
			table.remove(self.pendingBuys, index)
			return
		end
	end
end

--- An "auction won" invoice: the units enter the cost pool at the price paid.
--- @param won table { itemId, qty, bid }
function BooksMethods:OnWonMail(won)
	local market, char, now = self.options.market(), self.options.char(), self.options.now()
	if not market or not char or type(won) ~= 'table' then
		return
	end
	if not (isWholePositive(won.itemId) and isWholePositive(won.qty) and isWhole(won.bid)) then
		return
	end
	dropStaleBuys(self, now)
	local ventureId = ns.MailMatcher.takeBuy(self.pendingBuys, won.itemId, won.qty)
	local venture = ventureOf(market, ventureId) or openVentureFor(market, 'buy', won.itemId)
	self:BookBuy(market, 'buy', won.itemId, won.qty, won.bid, venture, now, char)
end

--- A vendor purchase: the units enter the cost pool.
--- @param buy table { itemId, qty, copper }
function BooksMethods:OnVendorBuy(buy)
	local market, char, now = self.options.market(), self.options.char(), self.options.now()
	if not market or not char or type(buy) ~= 'table' then
		return
	end
	if not (isWholePositive(buy.itemId) and isWholePositive(buy.qty) and isWhole(buy.copper)) then
		return
	end
	local venture = openVentureFor(market, 'buy', buy.itemId)
	self:BookBuy(market, 'vendorBuy', buy.itemId, buy.qty, buy.copper, venture, now, char)
end

function BooksMethods:BookBuy(market, kind, itemId, qty, copper, venture, now, char)
	ns.CostPool.add(market, itemId, qty, copper)
	append(market, { t = now, char = char, ventureId = venture and venture.id or nil }, {
		kind = kind,
		itemId = itemId,
		qty = qty,
		copper = copper,
	})
	if venture then
		ns.Ventures.noteBuy(venture, itemId, qty, copper)
		touchVenture(self, venture)
	end
	send(self, Books.MESSAGES.ledgerChanged)
end

--- Units sold to a vendor.
--- @param sale table { itemId, qty, copper, held? } held: units before the sale
function BooksMethods:OnVendorSell(sale)
	self:BookOut('vendorSell', sale)
end

--- Units destroyed; the ledger keeps the known cost lost.
--- @param destroyed table { itemId, qty, held? }
function BooksMethods:OnDestroy(destroyed)
	self:BookOut('destroy', destroyed)
end

function BooksMethods:BookOut(kind, out)
	local market, char, now = self.options.market(), self.options.char(), self.options.now()
	if not market or not char or type(out) ~= 'table' then
		return
	end
	if not (isWholePositive(out.itemId) and isWholePositive(out.qty)) then
		return
	end
	local held = isWhole(out.held) and out.held or heldOf(self, out.itemId) + out.qty
	local split = ns.CostPool.remove(market, out.itemId, out.qty, held)
	local copper = kind == 'vendorSell' and (isWhole(out.copper) and out.copper or 0) or split.knownCopper
	append(market, { t = now, char = char }, { kind = kind, itemId = out.itemId, qty = out.qty, copper = copper })
	send(self, Books.MESSAGES.ledgerChanged)
end

--- A craft finished: the reagents leave the pool (held already counts them out), the venture
--- that planned the recipe gets the output and the reagents' cash share. The rest of the
--- reagents' cost is valued on read, at the venture's valuation (Ventures.profit).
--- @param craft table { recipeId, outputItemId?, made, reagents = { { itemId, qty } } }
--- @return table|nil costs { [itemId] = { qty, knownUnits, knownCopper } }
function BooksMethods:OnCraft(craft)
	local market, char, now = self.options.market(), self.options.char(), self.options.now()
	if not market or not char or type(craft) ~= 'table' or not isWholePositive(craft.recipeId) then
		return nil
	end
	local venture = openVentureFor(market, 'craft', craft.recipeId)
	local costs, total = {}, 0
	for _, reagent in ipairs(type(craft.reagents) == 'table' and craft.reagents or {}) do
		if isWholePositive(reagent.itemId) and isWholePositive(reagent.qty) then
			local held = heldOf(self, reagent.itemId) + reagent.qty
			local split = ns.CostPool.remove(market, reagent.itemId, reagent.qty, held)
			costs[reagent.itemId] =
				{ qty = reagent.qty, knownUnits = split.knownUnits, knownCopper = split.knownCopper }
			total = total + split.knownCopper
		end
	end
	local made = isWholePositive(craft.made) and craft.made or 0
	append(market, { t = now, char = char, ventureId = venture and venture.id or nil }, {
		kind = 'craft',
		itemId = isWholePositive(craft.outputItemId) and craft.outputItemId or nil,
		qty = made,
		copper = total,
	})
	if venture then
		ns.Ventures.noteCraft(venture, craft.recipeId, made, costs)
		touchVenture(self, venture)
	end
	send(self, Books.MESSAGES.ledgerChanged)
	return costs
end

--- Starts a venture.
function BooksMethods:CreateVenture(spec)
	requirePlanner('CreateVenture')
	local market = self.options.market()
	if not market then
		return nil, 'no market'
	end
	local venture = ns.Ventures.create(market, spec, self.options.now())
	touchVenture(self, venture)
	return venture
end

--- Plans crafts in a venture (a new one when ventureId is nil and none is open for the recipe).
--- @return table|nil Venture
--- @return string|nil reason
function BooksMethods:PlanCrafts(ventureId, recipe, crafts, spec)
	requirePlanner('PlanCrafts')
	local market = self.options.market()
	if not market then
		return nil, 'no market'
	end
	local venture = ventureOf(market, ventureId)
		or (type(recipe) == 'table' and openVentureFor(market, 'craft', recipe.recipeId))
		or ns.Ventures.create(market, spec, self.options.now())
	local line, reason = ns.Ventures.addCrafts(venture, recipe, crafts)
	if not line then
		return nil, reason
	end
	touchVenture(self, venture)
	return venture
end

--- Closes a venture by hand. Leftover crafted units are written off or moved to stock (into the
--- cost pool at what the player paid for them; the venture is credited their value on read);
--- unused materials are in the pool already, so only the venture's books change.
--- @return table|nil leftovers
--- @return string|nil reason
function BooksMethods:CloseVenture(ventureId, action)
	requirePlanner('CloseVenture')
	local market = self.options.market()
	local venture = market and ventureOf(market, ventureId)
	if not venture or not self.options.char() then
		return nil, 'no such venture'
	end
	return self:BookClose(market, venture, action, 'manual')
end

--- Closes every open venture that has sold out; unused materials go to stock.
--- @return number count closed (0 without the V2 planner)
function BooksMethods:CheckVentures()
	if not ns.Ventures.hasPlanner then
		return 0
	end
	local market = self.options.market()
	local closed = 0
	for _, venture in ipairs(market and ns.Ventures.list(market, { isOpen = true }) or {}) do
		if ns.Ventures.isSoldOut(venture) and self:BookClose(market, venture, 'toStock', 'sold') then
			closed = closed + 1
		end
	end
	return closed
end

function BooksMethods:BookClose(market, venture, action, reason)
	local char, now = self.options.char(), self.options.now()
	if not char then
		return nil, 'no character'
	end
	local leftovers, problem = ns.Ventures.close(venture, now, action, reason)
	if not leftovers then
		return nil, problem
	end
	for _, leftover in ipairs(leftovers) do
		local copper = ns.Ventures.cashCost(venture, leftover)
		-- Units with nothing paid known stay of unknown origin rather than enter the pool free.
		if action == 'toStock' and leftover.kind == 'crafted' and copper > 0 then
			ns.CostPool.add(market, leftover.itemId, leftover.qty, copper)
		end
		append(market, { t = now, char = char, ventureId = venture.id }, {
			kind = action,
			itemId = leftover.itemId,
			qty = leftover.qty,
			copper = copper,
		})
	end
	touchVenture(self, venture)
	send(self, Books.MESSAGES.ledgerChanged)
	return leftovers
end

--- Housekeeping on login: expiries by the clock, old records pruned, old ledger events folded.
function BooksMethods:Maintain()
	local market, now = self.options.market(), self.options.now()
	if not market then
		return
	end
	ns.AuctionTracker.expireDue(market, now)
	ns.AuctionTracker.prune(market, now)
	ns.Ledger.compact(market, now)
	self:CheckVentures()
end

-- Helpers ---------------------------------------------------------------------------------

function isWholePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function heldOf(books, itemId)
	local ok, held = pcall(books.options.held, itemId)
	return ok and isWhole(held) and held or 0
end

function send(books, message, ...)
	if type(books.options.send) == 'function' then
		books.options.send(message, ...)
	end
end

function append(market, common, event)
	event.t, event.char = common.t, common.char
	event.ventureId, event.auctionId = common.ventureId, common.auctionId
	ns.Ledger.append(market, event)
end

-- The known pool share that comes back with qty returned units, in proportion to what remains.
function shareBack(record, qty)
	local knownUnits, knownCopper = record.knownUnits or 0, record.knownCopper or 0
	if knownUnits == 0 or record.remaining == 0 then
		return 0, 0
	end
	local units =
		math.min(knownUnits, math.floor(knownUnits * math.min(qty, record.remaining) / record.remaining + 0.5))
	local copper = units == knownUnits and knownCopper or math.floor(knownCopper * units / knownUnits)
	record.knownUnits, record.knownCopper = knownUnits - units, knownCopper - copper
	return units, copper
end

-- Without the planner no venture is booked to, so a saved one is left as it is.
function ventureOf(market, ventureId)
	return ns.Ventures.hasPlanner and ventureId and ns.Ventures.get(market, ventureId) or nil
end

function openVentureFor(market, role, key)
	return ns.Ventures.hasPlanner and ns.Ventures.openFor(market, role, key) or nil
end

function requirePlanner(method)
	if not ns.Ventures.hasPlanner then
		error('Books:' .. method .. ': ventures are V2 and their planner is not loaded', 3)
	end
end

function touchVenture(books, venture)
	send(books, Books.MESSAGES.ventureUpdated, venture.id)
end

function dropStaleBuys(books, now)
	local kept = {}
	for _, buy in ipairs(books.pendingBuys) do
		if not (type(buy.t) == 'number' and now - buy.t > Books.PENDING_BUY_SECONDS) then
			kept[#kept + 1] = buy
		end
	end
	books.pendingBuys = kept
end

return Books
