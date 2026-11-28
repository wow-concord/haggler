--[[
	ScanStore: the latest full scan of each market, as rules read it.

	  Snapshot = { at, source = 'own'|'passive', count, skipped, hasBands = true, isPacked = true,
	               items = { [itemId] = PackedItem } }
	  ScanItem = { min, units, levels = { Level... }, copperSeen, maxStackSeen, isCapped? }
	  Level    = { price, qty, short? }

	Saved items are packed into one string each, as SavedVariables writes a table per level
	(30k items came to ~11 MB a market; packed, ~2 MB):

	  PackedItem = 'units,flags,maxStackSeen;price:qty[:short],price:qty[:short]...'

	flags is 1 for copperSeen plus 2 for isCapped; min is the first level's price. Read items
	through ScanStore.item (cached for the session) or unpackItem. A string that does not parse
	strictly (whole numbers, cheapest first, short <= qty, nothing else) reads as
	{ levels = {}, isMalformed = true }, which rules report as bad input; never an error.
	Table items (the shape before schema 2) are still read as they are.

	A builder takes raw listings one at a time (as Scan reads them from the replicate list) and
	drops junk at the source: a listing without a buyout (bid-only), a price or count that is not
	a finite positive number, an item id that is not a positive whole number, or a price over
	PriceData.MAX_COPPER. Prices are per unit, rounded to whole copper (never under 1); levels
	are cheapest first and capped at MAX_LEVELS per item, while units counts every unit listed.

	copperSeen is read from the listing's own buyout, as posted: copper in any listing of an
	item means its price grid has copper (see ItemMarket). maxStackSeen is the biggest stack
	listed; a stack over one proves the item stacks before the client has cached its item info.

	The snapshot is saved at market.scan (Store:Market). Saved data is player data, so reading
	it back checks the shape: a broken snapshot or item reads as none, never as an error.

	short is the units of a level listed with the short time-left band (1, under 30 minutes
	left), which Sales takes as expired rather than sold when they vanish. Bands are the internal
	ones Wow:ReplicateItem gives (1 short to 4 very long, nil when unknown). The seller is not
	kept: the client often has not loaded it during a replicate read. isCapped marks an item with
	more price levels than were kept.

	Sales keeps the daily summaries (market.scanDays); see Engine/Sales.lua. Markets not scanned
	for keepMarketDays lose their scan and summaries (pruneStaleMarkets). The history of saved
	scans lives apart, with its own retention; see Engine/ScanArchive.lua.
]]
local _, ns = ...

local ScanStore = {}
ns.ScanStore = ScanStore

ScanStore.MAX_LEVELS = 50
-- No item stacks past this; a bigger count is a broken row.
ScanStore.MAX_STACK = 10000
ScanStore.SOURCES = { own = true, passive = true }
ScanStore.SHORT_BAND = 1
ScanStore.DEFAULT_KEEP_MARKET_DAYS = 30
-- Unpacked items kept for the session; the cache is emptied when it reaches this.
ScanStore.CACHE_LIMIT = 512

local COPPER_FLAG = 1
local CAPPED_FLAG = 2
local MALFORMED_ITEM = { levels = {}, isMalformed = true }

-- Helpers live at the bottom of the file; declared here so they stay local.
local isFinitePositive, isPositiveInteger, hasOnlyDaysBefore, itemFromPending, isUsableItem, parsePackedItem, isPackableItem

local unpackedByPacked, unpackedCount = {}, 0

local BuilderMethods = {}
BuilderMethods.__index = BuilderMethods

--- A builder for one snapshot.
--- @param maxLevels number|nil default MAX_LEVELS
function ScanStore.newBuilder(maxLevels)
	return setmetatable({
		maxLevels = maxLevels or ScanStore.MAX_LEVELS,
		pendingByItem = {},
		pendingIds = {},
		packIndex = 1,
		items = {},
		count = 0,
		skipped = 0,
	}, BuilderMethods)
end

--- Adds one raw listing; junk is counted in skipped and dropped.
--- @param itemId any
--- @param stack any units in the listing
--- @param buyout any buyout for the whole listing, copper; 0 or nil on a bid-only listing
--- @param timeLeft any the time-left band, 1 (short) to 4 (very long), nil when unknown
--- @return boolean kept
function BuilderMethods:Add(itemId, stack, buyout, timeLeft)
	local isValid = isPositiveInteger(itemId)
		and isPositiveInteger(stack)
		and stack <= ScanStore.MAX_STACK
		and isFinitePositive(buyout)
		and buyout <= ns.PriceData.MAX_COPPER
	if not isValid then
		self.skipped = self.skipped + 1
		return false
	end
	local unitPrice = math.max(1, math.floor(buyout / stack + 0.5))
	local pending = self.pendingByItem[itemId]
	if not pending then
		pending = { qtyByPrice = {}, shortByPrice = {}, units = 0, copperSeen = false, maxStackSeen = 0 }
		self.pendingByItem[itemId] = pending
		self.pendingIds[#self.pendingIds + 1] = itemId
	end
	pending.qtyByPrice[unitPrice] = (pending.qtyByPrice[unitPrice] or 0) + stack
	if timeLeft == ScanStore.SHORT_BAND then
		pending.shortByPrice[unitPrice] = (pending.shortByPrice[unitPrice] or 0) + stack
	end
	pending.units = pending.units + stack
	pending.copperSeen = pending.copperSeen or buyout % 100 ~= 0
	pending.maxStackSeen = math.max(pending.maxStackSeen, stack)
	self.count = self.count + 1
	return true
end

--- Turns the gathered listings into items, a few at a time.
--- @param shouldContinue function|nil called before each item; false stops this slice
--- @return boolean isDone
function BuilderMethods:Pack(shouldContinue)
	local ids = self.pendingIds
	while self.packIndex <= #ids do
		if shouldContinue and not shouldContinue() then
			return false
		end
		local itemId = ids[self.packIndex]
		self.items[itemId] = ScanStore.packItem(itemFromPending(self.pendingByItem[itemId], self.maxLevels))
		self.pendingByItem[itemId] = nil
		self.packIndex = self.packIndex + 1
	end
	return true
end

--- The finished snapshot; call after Pack returned true.
--- @param at number unix seconds the listing arrived
--- @param source string 'own' | 'passive'
function BuilderMethods:Snapshot(at, source)
	if self.packIndex <= #self.pendingIds then
		error('ScanStore builder: Pack has not finished', 2)
	end
	if not ScanStore.SOURCES[source] then
		error('ScanStore builder: source must be own or passive', 2)
	end
	return {
		at = at,
		source = source,
		count = self.count,
		skipped = self.skipped,
		hasBands = true,
		isPacked = true,
		items = self.items,
	}
end

--- Saves a snapshot as the market's latest. An empty snapshot (no rows, or no item that
--- survived the junk filter) is refused, so it can never replace a real one.
--- @param market table Store:Market(key)
--- @param snapshot table
--- @return boolean saved
function ScanStore.save(market, snapshot)
	if type(market) ~= 'table' or type(snapshot) ~= 'table' then
		error('ScanStore.save: market and snapshot must be tables', 2)
	end
	local hasItems = type(snapshot.items) == 'table' and next(snapshot.items) ~= nil
	local isCountedEmpty = type(snapshot.count) == 'number' and snapshot.count <= 0
	if not hasItems or isCountedEmpty then
		return false
	end
	market.scan = snapshot
	return true
end

--- Drops the scan and daily summaries of markets not scanned for keepDays; the rest of a
--- market (ledger, ventures and other player data) is kept. A scan dated in the future counts
--- as fresh.
--- @param markets table|nil Store db.markets
--- @param now number unix seconds
--- @param keepDays number
--- @return table marketKeys pruned, sorted
function ScanStore.pruneStaleMarkets(markets, now, keepDays)
	local pruned = {}
	if type(markets) ~= 'table' then
		return pruned
	end
	local oldestKept = now - keepDays * 86400
	for marketKey, market in pairs(markets) do
		local scan = type(market) == 'table' and market.scan or nil
		local at = type(scan) == 'table' and scan.at or nil
		local isScanStale = type(scan) == 'table' and (not isFinitePositive(at) or at < oldestKept)
		local isOnlyOldSummaries = type(market) == 'table'
			and scan == nil
			and hasOnlyDaysBefore(market.scanDays, math.floor(oldestKept / 86400))
		if isScanStale or isOnlyOldSummaries then
			market.scan = nil
			market.scanDays = {}
			pruned[#pruned + 1] = marketKey
		end
	end
	table.sort(pruned, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return pruned
end

--- The market's latest snapshot when it has a usable shape.
--- @param market table|nil
--- @return table|nil snapshot
function ScanStore.latest(market)
	local snapshot = type(market) == 'table' and market.scan or nil
	local isUsable = type(snapshot) == 'table' and isFinitePositive(snapshot.at) and type(snapshot.items) == 'table'
	return isUsable and snapshot or nil
end

--- One item of a snapshot, unpacked and cached for the session. The table is shared with
--- other readers: do not change it.
--- @return table|nil ScanItem, { levels = {}, isMalformed = true } when its string is broken
--- @return number|nil at
function ScanStore.item(snapshot, itemId)
	if type(snapshot) ~= 'table' or type(snapshot.items) ~= 'table' then
		return nil
	end
	local saved = snapshot.items[itemId]
	if type(saved) ~= 'string' then
		if not isUsableItem(saved) then
			return nil
		end
		return saved, snapshot.at
	end
	local item = unpackedByPacked[saved]
	if not item then
		item = parsePackedItem(saved)
		if unpackedCount >= ScanStore.CACHE_LIMIT then
			unpackedByPacked, unpackedCount = {}, 0
		end
		unpackedByPacked[saved] = item
		unpackedCount = unpackedCount + 1
	end
	return item, snapshot.at
end

--- One saved item read without the cache (for one-off passes such as the sales diff).
--- @param saved any a PackedItem, or a table item from before schema 2
--- @return table|nil ScanItem; the malformed shape for a broken string; nil for anything else
function ScanStore.unpackItem(saved)
	if type(saved) == 'string' then
		return parsePackedItem(saved)
	end
	return isUsableItem(saved) and saved or nil
end

--- Packs a ScanItem into its saved string.
--- @param item any
--- @return string|nil PackedItem; nil when the item is not usable
function ScanStore.packItem(item)
	if not isPackableItem(item) then
		return nil
	end
	-- %.0f, not %d: WoW's %d may go through a 32-bit long on Windows and wrap past ~214,748g.
	local parts = {}
	for index, level in ipairs(item.levels) do
		local short = level.short
		parts[index] = (short and short > 0) and string.format('%.0f:%.0f:%.0f', level.price, level.qty, short)
			or string.format('%.0f:%.0f', level.price, level.qty)
	end
	local flags = (item.copperSeen == true and COPPER_FLAG or 0) + (item.isCapped == true and CAPPED_FLAG or 0)
	return string.format('%.0f,%.0f,%.0f;%s', item.units, flags, item.maxStackSeen, table.concat(parts, ','))
end

--- Unpacked items held in the session cache.
function ScanStore.cachedCount()
	return unpackedCount
end

-- Helpers ---------------------------------------------------------------------------------

function itemFromPending(pending, maxLevels)
	local levels = {}
	for price, qty in pairs(pending.qtyByPrice) do
		levels[#levels + 1] = { price = price, qty = qty, short = pending.shortByPrice[price] }
	end
	table.sort(levels, function(a, b)
		return a.price < b.price
	end)
	local isCapped = #levels > maxLevels
	for index = #levels, maxLevels + 1, -1 do
		levels[index] = nil
	end
	return {
		isCapped = isCapped or nil,
		min = levels[1].price,
		units = pending.units,
		levels = levels,
		copperSeen = pending.copperSeen,
		maxStackSeen = pending.maxStackSeen,
	}
end

function isUsableItem(item)
	return type(item) == 'table' and type(item.levels) == 'table'
end

function parsePackedItem(packed)
	local unitsText, flagsText, maxStackText, levelsText = packed:match('^(%d+),(%d+),(%d+);(.+)$')
	local hasEmptyEntry = levelsText
		and (levelsText:sub(1, 1) == ',' or levelsText:sub(-1) == ',' or levelsText:find(',,', 1, true))
	if not levelsText or hasEmptyEntry then
		return MALFORMED_ITEM
	end
	local units, flags, maxStack = tonumber(unitsText), tonumber(flagsText), tonumber(maxStackText)
	local isHeaderValid = isPositiveInteger(units)
		and flags <= COPPER_FLAG + CAPPED_FLAG
		and isPositiveInteger(maxStack)
		and maxStack <= ScanStore.MAX_STACK
	if not isHeaderValid then
		return MALFORMED_ITEM
	end
	local levels, listedUnits = {}, 0
	for token in levelsText:gmatch('[^,]+') do
		local priceText, qtyText, shortText = token:match('^(%d+):(%d+):?(%d*)$')
		local price, qty, short = tonumber(priceText), tonumber(qtyText), tonumber(shortText)
		local previous = levels[#levels]
		local isLevelValid = isPositiveInteger(price)
			and price <= ns.PriceData.MAX_COPPER
			and isPositiveInteger(qty)
			and (shortText == '' or (isPositiveInteger(short) and short <= qty))
			and (previous == nil or previous.price < price)
		if not isLevelValid then
			return MALFORMED_ITEM
		end
		levels[#levels + 1] = { price = price, qty = qty, short = short }
		listedUnits = listedUnits + qty
	end
	if #levels == 0 or listedUnits > units then
		return MALFORMED_ITEM
	end
	return {
		min = levels[1].price,
		units = units,
		levels = levels,
		copperSeen = flags % 2 == COPPER_FLAG,
		maxStackSeen = maxStack,
		isCapped = flags >= CAPPED_FLAG or nil,
	}
end

function isPackableItem(item)
	if
		type(item) ~= 'table'
		or type(item.levels) ~= 'table'
		or #item.levels == 0
		or not isPositiveInteger(item.units)
		or not isPositiveInteger(item.maxStackSeen)
	then
		return false
	end
	local previousPrice, listedUnits = 0, 0
	for _, level in ipairs(item.levels) do
		local short = type(level) == 'table' and level.short or nil
		local isLevelValid = type(level) == 'table'
			and isPositiveInteger(level.price)
			and level.price > previousPrice
			and level.price <= ns.PriceData.MAX_COPPER
			and isPositiveInteger(level.qty)
			and (short == nil or short == 0 or (isPositiveInteger(short) and short <= level.qty))
		if not isLevelValid then
			return false
		end
		previousPrice, listedUnits = level.price, listedUnits + level.qty
	end
	return listedUnits <= item.units
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

-- True when scanDays holds at least one day and every day is before firstKeptDay.
function hasOnlyDaysBefore(scanDays, firstKeptDay)
	if type(scanDays) ~= 'table' or next(scanDays) == nil then
		return false
	end
	for day in pairs(scanDays) do
		if type(day) ~= 'number' or day >= firstKeptDay then
			return false
		end
	end
	return true
end

function isPositiveInteger(value)
	return isFinitePositive(value) and value % 1 == 0
end

return ScanStore
