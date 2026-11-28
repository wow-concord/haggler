--[[
	PriceContext: joins the price sources into the ctx Rules.evaluate reads, and reads the facts
	the tooltip's detail block shows.

	  build(sources) -> ctx
	  sources = { now, marketKey?, priceSource?, snapshot?, itemInfo = fun(itemId)?, craftCost?,
	              realized?, confidence?, scanDays?, salesSettings? }

	The joined sources are the AHledger row (priceSource:Row, see PriceData), the latest scan
	item (ScanStore.item), the client's item info and, when given, craft cost and realized
	price. Rules checks every
	value where it reads it (a string, NaN, infinity or a throwing source is unknown with a
	badInput reason), so the context passes values through and only joins them. One join is its
	own: the client may not have cached an item yet, and a scan stack over one proves the item
	stacks, so the scan's maxStackSeen stands in for a missing maxStack. The other is sales a
	day: ctx.sales(itemId) is Sales.choose over the market's daily summaries (scanDays) and the
	AHledger row, so Rules and the tooltip read the same figure and reasons.

	ctx.sourceStatus is the price source's status for the market (PriceData.statusOf). When it
	has no prices there, ctx.priceSourceProblem = { code, text }; when it is set to another
	market than Haggler's, ctx.marketMismatch = { sourceMarket, marketKey }.

	facts(ctx, itemId) reads the same sources for display: salesPerDay, salesSource, listedUnits,
	levelCount, lowestListed, lowestListedSource, typicalPrice (the 30-day median), recentPrice
	(the 7-day median), vendor, scanAge, rowAge. A value that is not a finite number reads as nil.
	lowestListed is the item's own scan minimum when the scan has one, else AHledger's lowest
	buyout; lowestListedSource says which ('scan' or 'ahledger'), so a display shows the age of
	the data it came from (scanAge or rowAge), never the scan's age for an AHledger figure.
	scanAge is the age of the scan that holds this item, nil when the item is not in it.
]]
local _, ns = ...

local PriceContext = {}
ns.PriceContext = PriceContext

-- Helpers live at the bottom of the file; declared here so they stay local.
local joinItemInfo, finiteOrNil, ageOrNil, callSource, newSalesSource, problemOf, mismatchOf

--- Builds the context for Rules.evaluate.
--- @param sources table see the file header
--- @return table ctx
function PriceContext.build(sources)
	if type(sources) ~= 'table' or type(sources.now) ~= 'number' then
		error('PriceContext.build: sources need now', 2)
	end
	local priceSource, marketKey, snapshot = sources.priceSource, sources.marketKey, sources.snapshot
	local sourceStatus = priceSource and ns.PriceData.statusOf(priceSource, marketKey) or nil
	local ctx = {
		now = sources.now,
		confidence = sources.confidence,
		craftCost = sources.craftCost,
		realized = sources.realized,
		sourceStatus = sourceStatus,
		priceSourceProblem = problemOf(sourceStatus),
		marketMismatch = mismatchOf(sourceStatus, marketKey),
	}
	if priceSource and marketKey then
		ctx.priceRow = function(itemId)
			return priceSource:Row(marketKey, itemId)
		end
	end
	if snapshot then
		ctx.scanItem = function(itemId)
			return ns.ScanStore.item(snapshot, itemId)
		end
	end
	ctx.sales = newSalesSource(sources, ctx.priceRow)
	ctx.itemInfo = function(itemId)
		return joinItemInfo(callSource(sources.itemInfo, itemId), ns.ScanStore.item(snapshot, itemId))
	end
	return ctx
end

--- Facts about one item for display; every field may be nil.
--- @param ctx table from build
--- @param itemId number
--- @return table { salesPerDay, listedUnits, levelCount, lowestListed, lowestListedSource, typicalPrice,
---   recentPrice, vendor, scanAge, rowAge, maxStack }
function PriceContext.facts(ctx, itemId)
	local row, updated = callSource(ctx.priceRow, itemId)
	row = type(row) == 'table' and row or nil
	local scanItem, scannedAt = callSource(ctx.scanItem, itemId)
	scanItem = type(scanItem) == 'table' and scanItem or nil
	local info = callSource(ctx.itemInfo, itemId)
	info = type(info) == 'table' and info or nil
	local levels = scanItem and type(scanItem.levels) == 'table' and scanItem.levels or nil
	local sales = callSource(ctx.sales, itemId)
	sales = type(sales) == 'table' and sales or { perDay = row and row.sold }
	local scanLowest = finiteOrNil(scanItem and scanItem.min)
	local rowLowest = finiteOrNil(row and row.min)
	local lowestListedSource = scanLowest and 'scan' or (rowLowest and 'ahledger' or nil)
	return {
		salesPerDay = finiteOrNil(sales.perDay),
		salesSource = finiteOrNil(sales.perDay) and sales.source or nil,
		listedUnits = finiteOrNil(scanItem and scanItem.units),
		levels = levels,
		levelCount = levels and #levels or nil,
		lowestListed = scanLowest or rowLowest,
		lowestListedSource = lowestListedSource,
		typicalPrice = finiteOrNil(row and row.m30),
		recentPrice = finiteOrNil(row and row.m7),
		vendor = finiteOrNil(info and info.vendorPrice),
		maxStack = finiteOrNil(info and info.maxStack),
		scanAge = scanItem and ageOrNil(ctx.now, scannedAt) or nil,
		rowAge = row and ageOrNil(ctx.now, updated) or nil,
	}
end

-- Helpers ---------------------------------------------------------------------------------

function joinItemInfo(info, scanItem)
	local joined = {}
	if type(info) == 'table' then
		joined.maxStack = info.maxStack
		joined.vendorPrice = info.vendorPrice
		joined.name = info.name
	end
	local stackSeen = scanItem and finiteOrNil(scanItem.maxStackSeen)
	if finiteOrNil(joined.maxStack) == nil and stackSeen and stackSeen > 1 then
		joined.maxStack = stackSeen
	end
	return joined
end

function newSalesSource(sources, priceRow)
	return function(itemId)
		local row = callSource(priceRow, itemId)
		local ahledgerSold = type(row) == 'table' and row.sold or nil
		local windowDays = type(sources.salesSettings) == 'table' and sources.salesSettings.windowDays or nil
		local stats = ns.Sales.ownStats(sources.scanDays, itemId, sources.now, windowDays)
		return ns.Sales.choose(stats, ahledgerSold, sources.salesSettings)
	end
end

-- A source that throws reads as no data here; Rules notes it as bad input when it prices.
function callSource(source, itemId)
	if type(source) ~= 'function' then
		return nil
	end
	local ok, value, at = pcall(source, itemId)
	if not ok then
		return nil
	end
	return value, at
end

-- Why the price source has no prices, or nil when it has them (or there is none to ask).
function problemOf(sourceStatus)
	if sourceStatus == nil or sourceStatus.isAvailable then
		return nil
	end
	return { code = sourceStatus.code, text = sourceStatus.reason }
end

function mismatchOf(sourceStatus, marketKey)
	local sourceMarket = sourceStatus and sourceStatus.market
	if not sourceMarket or not marketKey or sourceMarket == marketKey then
		return nil
	end
	return { sourceMarket = sourceMarket, marketKey = marketKey }
end

function finiteOrNil(value)
	if type(value) == 'number' and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

function ageOrNil(now, at)
	at = finiteOrNil(at)
	if not at then
		return nil
	end
	return math.max(0, now - at)
end

return PriceContext
