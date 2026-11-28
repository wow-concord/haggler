--[[
	Sales: Haggler's own count of units sold, from consecutive full scans of one market, with
	troll buys left out.

	Diff. Two scans of the same market, at most MAX_GAP_SECONDS apart, are compared per item and
	price level: units vanished from a level = max(0, earlier units - later units). Levels are
	compared one by one, so a new listing at another price never offsets one that vanished. The
	seller is not used: the client often has not loaded it during a replicate read. Limits: a
	new listing at the same price as one that sold offsets it, and a cancelled listing reads as
	sold. Levels past the later scan's level cap were not read and are not taken as vanished.

	Expiry. A listing that vanished may have expired rather than sold. Of a level's vanished
	units, as many as were listed with the short time-left band (under 30 minutes left) are
	taken as expired; the longer bands are taken as sold. This undercounts sales made in a
	listing's last minutes, on purpose: an expiry counted as a sale makes an item look liquid.

	Troll buys. A sale at unit price P is a troll buy when P x 0.95 <= the item's vendor price
	(the seller's take is no more than the vendor pays, so the buyer was likely to vendor it).
	They are counted apart and left out of sales a day everywhere. The vendor price is looked up
	only for items that lost units. While it is not known (the client has not cached the item),
	the vanished units are held unclassified per unit price (pending): they are not sales, the
	item's sales get a reason, and classifyPending sorts them once the vendor price is known.

	A scan with under half the listings of the one before looks incomplete and is not compared.

	Daily summaries, market.scanDays[day] (day = unix seconds / 86400, UTC):
	  { scans, hours, items = { [itemId] = { sold?, troll?, pending = { [unitPrice] = units }? } } }
	scans and hours are the comparisons that ended that day and the gaps they covered; an item
	is kept only for a day it lost units. Days outside the window (salesWindowDays, a rolling
	14 by default) are pruned.

	Choice. Over the window, once the comparisons cover minScans and minHours, sales a
	day is the own count (sold / hours x 24); below that it is AHledger's sold a day, with a
	reason saying so. When troll buys are trollSharePercent or more of the vanished units (and
	at least MIN_TROLL_SAMPLE units vanished), a reason says so, even while AHledger's figure is
	in use: medium, or low when they are over half. Held units add a medium reason.
]]
local _, ns = ...

local Sales = {}
ns.Sales = Sales

Sales.MAX_GAP_SECONDS = 8 * 3600
Sales.INCOMPLETE_SHARE = 0.5
-- The seller keeps 95 percent; compared in whole numbers so 0.95 x P = vendor is exact.
Sales.TROLL_PERCENT = 95
Sales.MIN_TROLL_SAMPLE = 5
Sales.LOW_TROLL_SHARE = 0.5
Sales.SECONDS_PER_DAY = 86400
Sales.DEFAULTS = { minScans = 6, minHours = 12, trollSharePercent = 30, windowDays = 14 }

-- Helpers live at the bottom of the file; declared here so they stay local.
local diffItem, diffLevel, levelsByPrice, lastPrice, classify, isTrollPrice, vendorPriceOf, sumOf
local isFiniteNumber, isFiniteNonNegative, settingOr, ownSalesReason, trollReason, uncheckedReason
local addTo, mergeCounts, classifyItemPending

local DiffMethods = {}
DiffMethods.__index = DiffMethods

--- Whether two scans can be compared.
--- @param earlier table|nil a usable snapshot (ScanStore.latest)
--- @param later table the new snapshot
--- @return boolean canDiff
--- @return string|nil reason when not
function Sales.canDiff(earlier, later)
	if type(earlier) ~= 'table' or type(earlier.items) ~= 'table' or not isFiniteNumber(earlier.at) then
		return false, 'no earlier scan'
	end
	if earlier.hasBands ~= true or later.hasBands ~= true then
		return false, 'a scan has no time-left bands'
	end
	local gap = later.at - earlier.at
	if gap <= 0 then
		return false, 'the scans are not in order'
	end
	if gap > Sales.MAX_GAP_SECONDS then
		return false, 'the scans are more than 8 hours apart'
	end
	if isFiniteNumber(earlier.count) and (later.count or 0) < earlier.count * Sales.INCOMPLETE_SHARE then
		return false, 'the new scan looks incomplete'
	end
	return true
end

--- A comparison of two scans that runs a few items at a time. Never throws on saved data.
--- @param earlier table snapshot
--- @param later table snapshot
--- @param vendorPriceFor function|nil fun(itemId): number|nil copper per unit, nil while unknown
--- @return table|nil diff with :Step(shouldContinue) -> isDone, :Result()
--- @return string|nil reason when the scans cannot be compared
function Sales.newDiff(earlier, later, vendorPriceFor)
	local canDiff, reason = Sales.canDiff(earlier, later)
	if not canDiff then
		return nil, reason
	end
	return setmetatable({
		earlier = earlier,
		later = later,
		vendorPriceFor = vendorPriceFor,
		gap = later.at - earlier.at,
		items = {},
		expiredUnits = 0,
		isDone = false,
	}, DiffMethods)
end

--- Compares items while shouldContinue allows.
--- @param shouldContinue function|nil
--- @return boolean isDone
function DiffMethods:Step(shouldContinue)
	local earlierItems, laterItems = self.earlier.items, self.later.items
	local itemId, earlierItem = next(earlierItems, self.cursor)
	while itemId ~= nil do
		if shouldContinue and not shouldContinue() then
			return false
		end
		local counts, expired =
			diffItem(self, itemId, ns.ScanStore.unpackItem(earlierItem), ns.ScanStore.unpackItem(laterItems[itemId]))
		self.items[itemId] = counts
		self.expiredUnits = self.expiredUnits + expired
		self.cursor = itemId
		itemId, earlierItem = next(earlierItems, itemId)
	end
	self.isDone = true
	return true
end

--- The finished comparison.
--- @return table { at, gapSeconds, items = { [itemId] = { sold?, troll?, pending? } }, expiredUnits }
function DiffMethods:Result()
	if not self.isDone then
		error('Sales diff: Step has not finished', 2)
	end
	return { at = self.later.at, gapSeconds = self.gap, items = self.items, expiredUnits = self.expiredUnits }
end

--- Adds a finished comparison to the daily summaries.
--- @param scanDays table market.scanDays
--- @param result table DiffMethods:Result()
function Sales.record(scanDays, result)
	if type(scanDays) ~= 'table' or type(result) ~= 'table' then
		error('Sales.record: scanDays and result must be tables', 2)
	end
	local day = math.floor(result.at / Sales.SECONDS_PER_DAY)
	local summary = scanDays[day]
	if type(summary) ~= 'table' or type(summary.items) ~= 'table' then
		summary = { scans = 0, hours = 0, items = {} }
		scanDays[day] = summary
	end
	summary.scans = (isFiniteNonNegative(summary.scans) and summary.scans or 0) + 1
	summary.hours = (isFiniteNonNegative(summary.hours) and summary.hours or 0) + result.gapSeconds / 3600
	for itemId, counts in pairs(result.items) do
		local kept = type(summary.items[itemId]) == 'table' and summary.items[itemId] or {}
		summary.items[itemId] = mergeCounts(kept, counts)
	end
end

--- Sorts held units into sold and troll buys for every item whose vendor price is now known.
--- @param scanDays table|nil market.scanDays
--- @param vendorPriceFor function fun(itemId): number|nil
--- @return number units still held
function Sales.classifyPending(scanDays, vendorPriceFor)
	if type(scanDays) ~= 'table' then
		return 0
	end
	local vendorByItem, stillHeld = {}, 0
	for _, summary in pairs(scanDays) do
		local items = type(summary) == 'table' and type(summary.items) == 'table' and summary.items or {}
		for itemId, counts in pairs(items) do
			if type(counts) == 'table' and counts.pending ~= nil then
				stillHeld = stillHeld + classifyItemPending(counts, itemId, vendorPriceFor, vendorByItem)
			end
		end
	end
	return stillHeld
end

--- Drops summaries outside the window, and keys that are not days.
--- @param scanDays table|nil
--- @param now number unix seconds
--- @param windowDays any days kept; DEFAULTS.windowDays when not a positive number
function Sales.prune(scanDays, now, windowDays)
	if type(scanDays) ~= 'table' then
		return
	end
	local window = settingOr({ windowDays = windowDays }, 'windowDays')
	local oldestKept = math.floor(now / Sales.SECONDS_PER_DAY) - window + 1
	local stale = {}
	for day in pairs(scanDays) do
		if not isFiniteNumber(day) or day < oldestKept then
			stale[#stale + 1] = day
		end
	end
	for _, day in ipairs(stale) do
		scanDays[day] = nil
	end
end

--- One item's own count over the window. Broken saved data counts as nothing.
--- @param scanDays table|nil
--- @param itemId number
--- @param now number unix seconds
--- @param windowDays any days summed; DEFAULTS.windowDays when not a positive number
--- @return table { sold, troll, scans, hours, pending }
function Sales.ownStats(scanDays, itemId, now, windowDays)
	local stats = { sold = 0, troll = 0, scans = 0, hours = 0, pending = 0 }
	if type(scanDays) ~= 'table' then
		return stats
	end
	local today = math.floor(now / Sales.SECONDS_PER_DAY)
	local window = settingOr({ windowDays = windowDays }, 'windowDays')
	for day = today - window + 1, today do
		local summary = scanDays[day]
		if type(summary) == 'table' then
			stats.scans = addTo(stats.scans, summary.scans)
			stats.hours = addTo(stats.hours, summary.hours)
			local counts = type(summary.items) == 'table' and summary.items[itemId] or nil
			if type(counts) == 'table' then
				stats.sold = addTo(stats.sold, counts.sold)
				stats.troll = addTo(stats.troll, counts.troll)
				stats.pending = stats.pending + sumOf(counts.pending)
			end
		end
	end
	return stats
end

--- Chooses where sales a day comes from, and the reasons to show.
--- @param stats table Sales.ownStats
--- @param ahledgerSold any AHledger's sold a day, passed through unchecked (Rules checks it)
--- @param settings table|nil { minScans, minHours, trollSharePercent }
--- @return table { perDay, source = 'own'|'ahledger', reasons = { { code, level, text }... }, trollShare? }
function Sales.choose(stats, ahledgerSold, settings)
	local minScans = settingOr(settings, 'minScans')
	local minHours = settingOr(settings, 'minHours')
	local view = { reasons = {} }
	local isCovered = stats.scans >= minScans and stats.hours >= minHours and stats.hours > 0
	if isCovered then
		view.perDay = stats.sold / (stats.hours / 24)
		view.source = 'own'
	else
		view.perDay = ahledgerSold
		view.source = 'ahledger'
		view.reasons[1] = ownSalesReason(stats, minScans, minHours)
	end
	local vanished = stats.sold + stats.troll
	if vanished > 0 then
		view.trollShare = stats.troll / vanished
	end
	local percent = settingOr(settings, 'trollSharePercent')
	if vanished >= Sales.MIN_TROLL_SAMPLE and stats.troll * 100 >= percent * vanished then
		view.reasons[#view.reasons + 1] = trollReason(view)
	end
	local pending = addTo(0, stats.pending)
	if pending > 0 then
		view.reasons[#view.reasons + 1] = uncheckedReason(pending)
	end
	return view
end

--- The pricing settings for the own count.
function Sales.settings()
	return {
		{
			key = 'ownSalesMinScans',
			type = 'slider',
			label = 'Scan comparisons needed before sales a day comes from your own scans',
			default = Sales.DEFAULTS.minScans,
			min = 1,
			max = 200,
		},
		{
			key = 'ownSalesMinHours',
			type = 'slider',
			label = 'Hours between scans needed before sales a day comes from your own scans',
			default = Sales.DEFAULTS.minHours,
			min = 1,
			max = 336,
		},
		{
			key = 'trollSharePercent',
			type = 'slider',
			label = 'Warn when troll buys are at least this percent of the units that vanished',
			default = Sales.DEFAULTS.trollSharePercent,
			min = 1,
			max = 100,
		},
		{
			key = 'salesWindowDays',
			type = 'slider',
			label = 'Days of your own scan comparisons kept and counted',
			default = Sales.DEFAULTS.windowDays,
			min = 1,
			max = 60,
		},
	}
end

-- Helpers ---------------------------------------------------------------------------------

-- One item's vanished units, classified ({ sold?, troll? }) or held ({ pending }), or nil when
-- it lost none; and the units taken as expired. The vendor price is asked for only here.
function diffItem(diff, itemId, earlierItem, laterItem)
	if type(earlierItem) ~= 'table' or type(earlierItem.levels) ~= 'table' then
		return nil, 0
	end
	-- A later item that could not be read says nothing about what vanished.
	if type(laterItem) == 'table' and laterItem.isMalformed == true then
		return nil, 0
	end
	local laterLevels = type(laterItem) == 'table' and type(laterItem.levels) == 'table' and laterItem.levels or {}
	local laterByPrice = levelsByPrice(laterLevels)
	-- Levels past the later scan's cap were not read; they did not vanish.
	local laterCeiling = laterItem and laterItem.isCapped == true and lastPrice(laterLevels) or math.huge
	local vanishedByPrice, vanished, expired = {}, 0, 0
	for _, level in ipairs(earlierItem.levels) do
		if type(level) == 'table' and isFiniteNumber(level.price) and level.price <= laterCeiling then
			local units, expiredUnits = diffLevel(level, laterByPrice[level.price])
			if units > 0 then
				vanishedByPrice[level.price] = (vanishedByPrice[level.price] or 0) + units
				vanished = vanished + units
			end
			expired = expired + expiredUnits
		end
	end
	if vanished == 0 then
		return nil, expired
	end
	local vendor = vendorPriceOf(diff.vendorPriceFor, itemId)
	if vendor == nil then
		return { pending = vanishedByPrice }, expired
	end
	return classify(vanishedByPrice, vendor), expired
end

-- Units vanished from one price level and not taken as expired; and those taken as expired
-- (no more than were listed with the short band).
function diffLevel(level, laterLevel)
	if not isFiniteNonNegative(level.qty) then
		return 0, 0
	end
	local laterQty = type(laterLevel) == 'table' and isFiniteNonNegative(laterLevel.qty) and laterLevel.qty or 0
	local vanished = math.max(0, level.qty - laterQty)
	local short = isFiniteNonNegative(level.short) and level.short or 0
	local expired = math.min(vanished, short)
	return vanished - expired, expired
end

function levelsByPrice(levels)
	local byPrice = {}
	for _, level in ipairs(levels) do
		if type(level) == 'table' and isFiniteNumber(level.price) then
			byPrice[level.price] = level
		end
	end
	return byPrice
end

function lastPrice(levels)
	local last = levels[#levels]
	return type(last) == 'table' and isFiniteNumber(last.price) and last.price or math.huge
end

-- Units by unit price split into { sold?, troll? }, with a known vendor price.
function classify(unitsByPrice, vendor)
	local sold, troll = 0, 0
	for price, units in pairs(unitsByPrice) do
		if isFiniteNumber(price) and isFiniteNonNegative(units) then
			if isTrollPrice(price, vendor) then
				troll = troll + units
			else
				sold = sold + units
			end
		end
	end
	return { sold = sold > 0 and sold or nil, troll = troll > 0 and troll or nil }
end

function isTrollPrice(unitPrice, vendorPrice)
	return vendorPrice > 0 and unitPrice * Sales.TROLL_PERCENT <= vendorPrice * 100
end

--- The troll-buy test (Haggler.md): a unit price that nets the seller no more than the vendor.
Sales.isTrollPrice = isTrollPrice

-- The vendor price when known (0 included); nil while the client has not cached the item.
function vendorPriceOf(vendorPriceFor, itemId)
	if type(vendorPriceFor) ~= 'function' then
		return nil
	end
	local ok, vendor = pcall(vendorPriceFor, itemId)
	return ok and isFiniteNonNegative(vendor) and vendor or nil
end

-- Adds one comparison's counts for an item to a day's kept counts.
function mergeCounts(kept, counts)
	if type(counts) ~= 'table' then
		return kept
	end
	local sold, troll = addTo(kept.sold, counts.sold), addTo(kept.troll, counts.troll)
	kept.sold = sold > 0 and sold or nil
	kept.troll = troll > 0 and troll or nil
	if type(counts.pending) == 'table' then
		local pending = type(kept.pending) == 'table' and kept.pending or {}
		for price, units in pairs(counts.pending) do
			if isFiniteNumber(price) and isFiniteNonNegative(units) then
				pending[price] = (pending[price] or 0) + units
			end
		end
		kept.pending = next(pending) ~= nil and pending or nil
	end
	return kept
end

-- Classifies one item's held units of one day when its vendor price is known; returns the
-- units still held. vendorByItem caches the answer across days (false when unknown).
function classifyItemPending(counts, itemId, vendorPriceFor, vendorByItem)
	if type(counts.pending) ~= 'table' then
		counts.pending = nil
		return 0
	end
	if vendorByItem[itemId] == nil then
		vendorByItem[itemId] = vendorPriceOf(vendorPriceFor, itemId) or false
	end
	local vendor = vendorByItem[itemId]
	if vendor == false then
		return sumOf(counts.pending)
	end
	local classified = classify(counts.pending, vendor)
	counts.pending = nil
	mergeCounts(counts, classified)
	return 0
end

function sumOf(unitsByPrice)
	local total = 0
	if type(unitsByPrice) == 'table' then
		for _, units in pairs(unitsByPrice) do
			total = addTo(total, units)
		end
	end
	return total
end

function ownSalesReason(stats, minScans, minHours)
	return {
		code = 'ownSalesThin',
		level = 'high',
		text = string.format(
			'sold a day from AHledger, as your own count has %d of %d scans and %d of %d hours',
			stats.scans,
			minScans,
			math.floor(stats.hours),
			minHours
		),
	}
end

function uncheckedReason(units)
	return {
		code = 'trollUnchecked',
		level = 'medium',
		text = string.format('%d sold units wait for item data before the troll check', units),
	}
end

function trollReason(view)
	local percent = math.floor(view.trollShare * 100 + 0.5)
	local level = view.trollShare > Sales.LOW_TROLL_SHARE and 'low' or 'medium'
	local text = view.source == 'own'
			and string.format('%d%% of vanished units were troll buys and are left out', percent)
		or string.format('sales may include troll buys (%d%% of vanished units)', percent)
	return { code = 'trollBuys', level = level, text = text }
end

function settingOr(settings, key)
	local value = type(settings) == 'table' and settings[key] or nil
	if isFiniteNumber(value) and value > 0 then
		return value
	end
	return Sales.DEFAULTS[key]
end

function addTo(total, value)
	return (isFiniteNonNegative(total) and total or 0) + (isFiniteNonNegative(value) and value or 0)
end

function isFiniteNumber(value)
	return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

function isFiniteNonNegative(value)
	return isFiniteNumber(value) and value >= 0
end

return Sales
