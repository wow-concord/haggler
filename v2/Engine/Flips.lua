--[[
	Flips (V2, left out of the release package): listings in the last scan worth buying to sell
	again, from the spec's Flips tab: under what a vendor pays (a vendor flip) or under a rule's
	value (a relist flip). Pure: game reads come in through deps.

	  Flips.find(snapshot, deps, options?) -> FlipRow[], isCapped
	      the best flip per item, highest expected profit first, at most deps.limit; isCapped
	      when more items could be relist flips than were priced
	  Flips.vendorFlip(item, vendor, now?) -> FlipRow|nil
	  Flips.relistFlip(item, price, facts) -> FlipRow|nil
	  Flips.scanConfidence(ageSeconds) -> Confidence   ScanStore.scanConfidence (V1)

	A vendor flip buys every unit listed under the vendor price; its profit is certain once
	bought, so its confidence is only the scan's age. A relist flip buys the units that still
	clear after the AH cut at the rule's price, snapped down to the item's step, and at most the
	sales of one listing period (when sales a day are known), since a bigger stack would only
	sit in the queue. Its expected profit counts the deposit expected lost before it sells
	(Guardrail's queue model), behind the units left listed at or under the relist price. It
	carries the rule price's confidence and the scan's. A relist that is not expected to sell
	(sell chance 0), or that clears no profit, is not a flip.

	snapshot  ScanStore snapshot (read through ScanStore.item)
	deps = {
	  vendorPrice(itemId) -> copper|nil     known vendor prices only (PriceService:KnownVendorPrice)
	  rulePrice(itemId)   -> Price|nil      a rule's Price (copper, step, confidence,
	                                        usesPriceSource), from cached item info only
	  salesPerDay?(itemId) -> number|nil
	  deposit?(itemId, units, hours) -> copper|nil   the client's deposit; estimated from the
	                                        vendor price when nil
	  ownListings?(itemId) -> { { unitPrice, listed, postedAt? }... }   the player's own
	                                        listings, taken out of the scan's levels (no one flips
	                                        their own); one posted after the scan is not in it
	  now?                                  unix seconds, for the scan's age
	  limit? (default LIMIT), maxPriced? (default MAX_PRICED)
	}
	options = { kinds? = { vendor = bool, relist = bool } (both by default),
	            minProfit? copper (default MIN_PROFIT), minPercent? (default 0),
	            durationHours? (default Guardrail.DEFAULT_DURATION_HOURS) }

	FlipRow = { itemId, kind = 'vendor'|'relist', buyPrice, units, cost, sellPrice, profit,
	            percent, confidence, usesPriceSource, rulePrice?, sellChance?, depositLoss?,
	            isCappedBySales? }
	  buyPrice is the cheapest unit's price, cost what every unit takes, sellPrice what one unit
	  sells for (the vendor price, or the relist price on the item's step), profit the expected
	  gain over all units and percent that gain over the cost, rounded down.

	Cost: a scan holds tens of thousands of items. The vendor check is cheap and runs on every
	item; a rule price is a full rule evaluation, so only the maxPriced most listed items are
	priced for relist flips.
]]
local _, ns = ...

local Flips = {}
ns.Flips = Flips

Flips.LIMIT = 100
Flips.MAX_PRICED = 500
Flips.MIN_PROFIT = 1
-- The scan's age confidence lives in ScanStore (V1: Advice reads it too).
Flips.STALE_MEDIUM_SECONDS = ns.ScanStore.STALE_MEDIUM_SECONDS
Flips.STALE_LOW_SECONDS = ns.ScanStore.STALE_LOW_SECONDS
Flips.scanConfidence = ns.ScanStore.scanConfidence

-- Helpers live at the bottom of the file; declared here so they stay local.
local levelsOf, withoutOwn, isWanted, compareRows, compareLiquidity, safeCall, isFinitePositive, percentOf, mergeConfidence

--- The best flip of each item in the last scan.
--- @param snapshot table|nil ScanStore snapshot
--- @param deps table see the file header
--- @param options table|nil see the file header
--- @return table FlipRow[]
--- @return boolean isCapped more items listed than were priced for relist flips
function Flips.find(snapshot, deps, options)
	if type(deps) ~= 'table' then
		error('Flips.find: needs deps', 2)
	end
	if type(snapshot) ~= 'table' or type(snapshot.items) ~= 'table' then
		return {}, false
	end
	options = type(options) == 'table' and options or {}
	local kinds = type(options.kinds) == 'table' and options.kinds or { vendor = true, relist = true }
	local ageSeconds = type(deps.now) == 'number'
			and type(snapshot.at) == 'number'
			and math.max(0, deps.now - snapshot.at)
		or nil
	local best, candidates = {}, {}
	for itemId in pairs(snapshot.items) do
		local scanItem = type(itemId) == 'number' and ns.ScanStore.item(snapshot, itemId) or nil
		-- ScanStore caches its items for the session: read through, never write into one.
		local item = scanItem
			and isFinitePositive(scanItem.min)
			and withoutOwn(
				setmetatable({ itemId = itemId, ageSeconds = ageSeconds }, { __index = scanItem }),
				safeCall(deps.ownListings, itemId),
				snapshot.at
			)
		if item then
			if kinds.vendor then
				local vendor = safeCall(deps.vendorPrice, itemId)
				local row = Flips.vendorFlip(item, vendor)
				if isWanted(row, options) then
					best[itemId] = row
				end
			end
			if kinds.relist then
				candidates[#candidates + 1] = item
			end
		end
	end
	table.sort(candidates, compareLiquidity)
	local maxPriced = deps.maxPriced or Flips.MAX_PRICED
	for index = 1, math.min(#candidates, maxPriced) do
		local item = candidates[index]
		local row = Flips.relistFlip(item, safeCall(deps.rulePrice, item.itemId), {
			vendor = safeCall(deps.vendorPrice, item.itemId),
			salesPerDay = safeCall(deps.salesPerDay, item.itemId),
			deposit = deps.deposit,
			durationHours = options.durationHours,
		})
		local current = best[item.itemId]
		if isWanted(row, options) and (not current or row.profit > current.profit) then
			best[item.itemId] = row
		end
	end
	local rows = {}
	for _, row in pairs(best) do
		rows[#rows + 1] = row
	end
	table.sort(rows, compareRows)
	for index = #rows, (deps.limit or Flips.LIMIT) + 1, -1 do
		rows[index] = nil
	end
	return rows, #candidates > maxPriced
end

--- Every unit listed under the vendor price, bought and sold to a vendor.
--- @param item table ScanItem + itemId, ageSeconds?
--- @param vendor number|nil what a vendor pays for one
--- @return table|nil FlipRow
function Flips.vendorFlip(item, vendor)
	if type(item) ~= 'table' or not isFinitePositive(vendor) then
		return nil
	end
	local units, cost = 0, 0
	for _, level in ipairs(levelsOf(item)) do
		if level.price >= vendor then
			break
		end
		units, cost = units + level.qty, cost + level.price * level.qty
	end
	if units == 0 then
		return nil
	end
	local profit = vendor * units - cost
	return {
		itemId = item.itemId,
		kind = 'vendor',
		buyPrice = levelsOf(item)[1].price,
		units = units,
		cost = cost,
		sellPrice = vendor,
		profit = profit,
		percent = percentOf(profit, cost),
		confidence = Flips.scanConfidence(item.ageSeconds),
		usesPriceSource = false,
	}
end

--- The units under a rule's value, bought and listed again at that value.
--- @param item table ScanItem + itemId, ageSeconds?
--- @param price table|nil the rule's Price
--- @param facts table { vendor?, salesPerDay?, deposit?(itemId, units, hours), durationHours? }
--- @return table|nil FlipRow
function Flips.relistFlip(item, price, facts)
	if type(item) ~= 'table' or type(price) ~= 'table' or not isFinitePositive(price.copper) then
		return nil
	end
	facts = facts or {}
	local Guardrail, ItemMarket = ns.Guardrail, ns.ItemMarket
	local grid = { step = (price.step == ItemMarket.SILVER_STEP) and price.step or ItemMarket.COPPER_STEP }
	local sellPrice = ItemMarket.snapPrice(grid, price.copper)
	local netPerUnit = Guardrail.saleNet(sellPrice, 1)
	local hours = isFinitePositive(facts.durationHours) and facts.durationHours or Guardrail.DEFAULT_DURATION_HOURS
	-- 0 sales a day is known (nothing sells), not unknown: such a relist is not a flip.
	local salesPerDay = (isFinitePositive(facts.salesPerDay) or facts.salesPerDay == 0) and facts.salesPerDay or nil
	local maxUnits = salesPerDay and math.max(1, math.floor(salesPerDay * hours / Guardrail.HOURS_PER_DAY)) or math.huge
	local units, cost, listedAtOrUnder = 0, 0, 0
	for _, level in ipairs(levelsOf(item)) do
		if level.price > sellPrice then
			break
		end
		listedAtOrUnder = listedAtOrUnder + level.qty
		if level.price < netPerUnit and units < maxUnits then
			local take = math.min(level.qty, maxUnits - units)
			units, cost = units + take, cost + level.price * take
		end
	end
	if units == 0 then
		return nil
	end
	local reasons = {}
	local vendor = isFinitePositive(facts.vendor) and facts.vendor or nil
	local deposit = safeCall(facts.deposit, item.itemId, units, hours)
	if not (type(deposit) == 'number' and deposit >= 0 and deposit < math.huge) then
		deposit = vendor and Guardrail.estimateDeposit(vendor, units, hours) or 0
		if not vendor then
			reasons[#reasons + 1] =
				{ code = 'depositEstimated', level = 'medium', text = 'deposit unknown; not counted' }
		end
	end
	local sellChance = Guardrail.sellChance({
		salesPerDay = salesPerDay,
		durationHours = hours,
		unitsAhead = listedAtOrUnder - units,
		units = units,
	})
	if sellChance == 0 then
		return nil
	end
	local depositLoss = sellChance and Guardrail.depositLoss(deposit, sellChance) or 0
	if not sellChance then
		reasons[#reasons + 1] =
			{ code = 'sellChanceUnknown', level = 'medium', text = 'no sales data; the relist may not sell' }
	end
	local profit = Guardrail.saleNet(sellPrice, units) - cost - depositLoss
	return {
		itemId = item.itemId,
		kind = 'relist',
		buyPrice = levelsOf(item)[1].price,
		units = units,
		cost = cost,
		sellPrice = sellPrice,
		profit = profit,
		percent = percentOf(profit, cost),
		rulePrice = price.copper,
		sellChance = sellChance,
		depositLoss = depositLoss,
		isCappedBySales = units >= maxUnits,
		confidence = mergeConfidence({
			price.confidence,
			Flips.scanConfidence(item.ageSeconds),
			{ level = 'high', reasons = reasons },
		}),
		usesPriceSource = price.usesPriceSource == true,
	}
end

-- Helpers ---------------------------------------------------------------------------------

-- The item's levels, cheapest first; an item without levels is one level at its lowest price.
function levelsOf(item)
	if type(item.levels) == 'table' and #item.levels > 0 then
		return item.levels
	end
	return { { price = item.min, qty = math.max(1, tonumber(item.units) or 1) } }
end

-- The item with the player's own units taken out of its levels (on the proxy, never the cached
-- scan item); nil when nothing but the player's own units is listed. A listing posted after the
-- scan (scanAt) is not in its levels, so it takes nothing out.
function withoutOwn(item, own, scanAt)
	if type(own) ~= 'table' or #own == 0 then
		return item
	end
	local ownAt = {}
	for _, listing in ipairs(own) do
		local isInScan = type(listing) == 'table'
			and not (type(scanAt) == 'number' and type(listing.postedAt) == 'number' and listing.postedAt > scanAt)
		if isInScan and isFinitePositive(listing.unitPrice) and isFinitePositive(listing.listed) then
			ownAt[listing.unitPrice] = (ownAt[listing.unitPrice] or 0) + listing.listed
		end
	end
	local levels, units = {}, 0
	for _, level in ipairs(levelsOf(item)) do
		local taken = math.min(level.qty, ownAt[level.price] or 0)
		ownAt[level.price] = (ownAt[level.price] or 0) - taken
		if level.qty > taken then
			levels[#levels + 1] = { price = level.price, qty = level.qty - taken }
			units = units + level.qty - taken
		end
	end
	if #levels == 0 then
		return nil
	end
	item.levels, item.min, item.units = levels, levels[1].price, units
	return item
end

function isWanted(row, options)
	if not row then
		return false
	end
	local minProfit = type(options.minProfit) == 'number' and options.minProfit or Flips.MIN_PROFIT
	local minPercent = type(options.minPercent) == 'number' and options.minPercent or 0
	return row.profit >= minProfit and row.percent >= minPercent
end

-- Highest profit first; then the deepest percent, then the item id, so the order is stable.
function compareRows(a, b)
	if a.profit ~= b.profit then
		return a.profit > b.profit
	end
	if a.percent ~= b.percent then
		return a.percent > b.percent
	end
	return a.itemId < b.itemId
end

-- The most units listed first: the items a relist can sell soonest.
function compareLiquidity(a, b)
	local unitsA, unitsB = tonumber(a.units) or 0, tonumber(b.units) or 0
	if unitsA ~= unitsB then
		return unitsA > unitsB
	end
	return a.itemId < b.itemId
end

-- fn's first result, or nil when it is missing or throws.
function safeCall(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	local ok, result = pcall(fn, ...)
	return ok and result or nil
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

function percentOf(profit, cost)
	return cost > 0 and math.floor(profit * 100 / cost) or 0
end

function mergeConfidence(confidences)
	return ns.Value.mergeConfidence(confidences)
end
