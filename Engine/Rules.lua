--[[
	Rules: calculation rules, each a base price followed by ordered steps.

	  Rule = { id, name, builtIn, base = Base, steps = { Step... },
	           antiBait = { enabled, minutes, gapPercent? } }
	  Base = { kind, n?, hours?, percent? }
	    AHledger: median · median7 · median30 · low30 · high30
	    listings: lowest · afterPercent (past the cheapest percent) · firstWithUnits: the first
	              price at which the cheaper units cover max(n, units sold in `hours`), where units
	              sold an hour is sales a day / 24 (n is minUnits, hours minHours)
	    other:    vendor · craftCost · realized (the price you actually got)
	  Step = { kind = 'cap'|'floor', percent, base } · { kind = 'lower'|'higher', base }
	       · { kind = 'multiply', factor } · { kind = 'undercut', copper }

	Anti-bait runs before a listing-based price is read: it passes over the cheapest units the
	market buys in `minutes` of sales (soldPerDay * minutes / 1440, at least one unit), and with
	gapPercent also any cheapest level priced under that percent of the next level. When every
	listed unit is bait, the dearest level is the only price left.

	Without usable scan depth (no scan, or only junk levels), the listing bases fall back to
	AHledger's lowest buyout. A step whose base has no data is skipped and noted in the trace; only
	a missing base fails the rule. The engine never throws on data, only on a broken call.

	evaluate(rule, itemId, ctx) returns Price = { copper, ageSeconds, source, baseAgeSeconds,
	rowAgeSeconds?, step, confidence, trace }, or nil and a reason. ageSeconds is the oldest input
	(it sets confidence); source and baseAgeSeconds are the base's own; rowAgeSeconds is the age
	of the AHledger row a step read (a cap at the median, say), nil when no step read one, so a
	display never dates one source with another's age. The copper is snapped down to the item's price grid (see
	ItemMarket), except that a floor or higher bound is snapped up: a price never goes under its
	floor. A floor stays in force for every later step, so a later undercut or cap clamps at it;
	when that overrides a cap, the trace and confidence (capOverridden) say so.

	Confidence = { level = 'high'|'medium'|'low', reasons = { { code, level, text }... } }, always
	present; the weakest reason sets the level and every reason is also in the trace. Low
	confidence is always shown to the player, so this field is never optional. Codes: stale,
	fewSales, fewListings, fallbackBase, inferredStep, baitTrimmed, capOverridden, badInput,
	snapshot (an AHledger figure from its bundled copy, not synced), the price source problems
	(low, scans only): noPriceSource (AHledger missing), priceSourceFailing (its calls fail),
	noMarketTable (no AHledger prices for this market), ownScanOverlay (medium: no synced table,
	but AHledger answered from the player's own scan), marketMismatch (info, level high: AHledger
	uses another market) and whatever ctx.sales adds (ownSalesThin, trollBuys).

	A Price also says whether any AHledger figure went into it (usesPriceSource), so the window
	footer shows the credit only with prices that used AHledger (the options panel always shows
	it, the tooltip never), and which inputs it actually read (inputs, a set):
	  ahledger (any AHledger figure: a row base, its lowest buyout, its sold a day) · scan (the
	  player's own scan depth) · ownSales (the player's own sales a day) · vendor · craftCost ·
	  realized
	A rule that can read either its own data or AHledger reports the one it used for this quote,
	so a stored value can later be limited to quotes without ahledger (own-only, ASK-M-005).
	craftCost and realized are Haggler's own figures, but a craft cost can itself stand on
	AHledger reagent prices; it is reported as craftCost, not looked through.

	ctx (every source optional):
	  now                       unix seconds
	  priceRow(itemId)          -> PriceRow, updated, problem?   AHledger (PriceData source)
	  priceSourceProblem        { code, text } why the price source has no prices, or nil
	  marketMismatch            { sourceMarket, marketKey } when AHledger is set elsewhere
	  scanItem(itemId)          -> { min, units, levels = { { price, qty }... }, copperSeen? }, at
	  itemInfo(itemId)          -> { maxStack, vendorPrice }
	  craftCost(itemId)         -> copper, at
	  realized(itemId)          -> copper, at
	  confidence                { staleMediumHours?, staleLowHours? } from the settings
	sales(itemId)             -> { perDay, source = 'own'|'ahledger', reasons } (Sales.choose):
	                          sales a day for anti-bait, depth and confidence; without it,
	                          sales a day is the AHledger row's sold

	Every value a source returns is checked where it is read: a string, NaN, infinity or a
	source that throws is unknown, never an error, and adds a badInput reason (medium) so the
	player sees the price stands on broken input. A base that is junk fails like a missing one.
]]
local _, ns = ...

local Rules = {}
ns.Rules = Rules

Rules.DEFAULT_RULE_ID = 'realistic'
Rules.DEFAULT_BAIT_MINUTES = 10
Rules.DEFAULT_DEPTH_UNITS = 5
Rules.DEFAULT_DEPTH_HOURS = 1
Rules.MINUTES_PER_DAY = 1440
Rules.HOURS_PER_DAY = 24
-- The one line a tooltip shows for a rule that fails validation.
Rules.UNUSABLE_RULE = "This rule can't be used"

-- Confidence thresholds. The two ages are player settings (see confidenceSettings).
Rules.CONFIDENCE = {
	staleMediumHours = 24,
	staleLowHours = 72,
	mediumSalesPerDay = 5,
	lowSalesPerDay = 1,
	fewListingUnits = 5,
	baitTrimmedShare = 0.5,
}

local ROW_FIELD_BY_BASE = {
	median = 'median',
	median7 = 'm7',
	median30 = 'm30',
	low30 = 'lo',
	high30 = 'hi',
}
-- Player-facing names of the fixed bases (listing bases with settings are phrased in describeBase).
local BASE_NAMES = {
	median = 'AHledger median',
	median7 = 'AHledger 7-day median',
	median30 = 'AHledger 30-day median',
	low30 = 'AHledger 30-day low',
	high30 = 'AHledger 30-day high',
	lowest = 'lowest scan price',
	vendor = 'vendor price',
	craftCost = 'craft cost',
	realized = 'your sale price',
}
local MISSING_BASE_TEXT = { realized = 'no sales of yours' }
local LISTING_BASES = { lowest = true, firstWithUnits = true, afterPercent = true }
local OTHER_BASES = { vendor = true, craftCost = true, realized = true }
local STEP_KINDS = { cap = true, floor = true, lower = true, higher = true, multiply = true, undercut = true }
local LEVEL_RANK = { low = 1, medium = 2, high = 3 }
local SECONDS_PER_HOUR = 3600

-- Helpers live at the bottom of the file; declared here so they stay local.
local validateBase, validateStep, validateAntiBait, resolveBase, resolveRowBase, resolveListingBase
local resolveOtherBase, applyStep, readListing, depthUnits, buildItemMarket, sortedLevels, copyTable
local describeBase, isPositiveInteger, isPercent, isFinitePositive, olderOf, ageSince, lookup, sumUnits
local recordSales, recordListing, assessConfidence, addStaleReason, addSalesReason, addReason
local confidenceThresholds, readCopper, noteBadInput, tableOrNil, isFiniteNumber, recordSalesView
local salesReasonsOf, noteSourceFigure, noteRowProblem, sourceProblemOf, noteInput

--- The built-in rules, as fresh copies (the store keeps its own, tunable and resettable).
--- @return table { [ruleId] = Rule }
function Rules.builtIns()
	local antiBait = { enabled = true, minutes = Rules.DEFAULT_BAIT_MINUTES }
	return {
		realistic = {
			id = 'realistic',
			name = 'Realistic',
			builtIn = true,
			base = { kind = 'firstWithUnits', n = Rules.DEFAULT_DEPTH_UNITS, hours = Rules.DEFAULT_DEPTH_HOURS },
			steps = {
				{ kind = 'cap', percent = 100, base = { kind = 'median' } },
				{ kind = 'undercut', copper = 1 },
			},
			antiBait = copyTable(antiBait),
		},
		minimum = {
			id = 'minimum',
			name = 'Minimum',
			builtIn = true,
			base = { kind = 'lowest' },
			steps = { { kind = 'undercut', copper = 1 } },
			antiBait = copyTable(antiBait),
		},
		median = {
			id = 'median',
			name = 'Median',
			builtIn = true,
			base = { kind = 'median' },
			steps = {},
			antiBait = copyTable(antiBait),
		},
	}
end

--- A deep copy of a rule (or any plain table).
function Rules.copy(rule)
	return copyTable(rule)
end

--- Checks a rule's shape (rules are player data, so a bad one is an expected outcome).
--- @return boolean|nil true when valid
--- @return string|nil reason
function Rules.validate(rule)
	if type(rule) ~= 'table' then
		return nil, 'rule must be a table'
	end
	if type(rule.id) ~= 'string' or rule.id == '' then
		return nil, 'rule needs an id'
	end
	if type(rule.name) ~= 'string' or rule.name == '' then
		return nil, 'rule needs a name'
	end
	local baseProblem = validateBase(rule.base)
	if baseProblem then
		return nil, 'base: ' .. baseProblem
	end
	if type(rule.steps) ~= 'table' then
		return nil, 'steps must be a list'
	end
	for index, step in ipairs(rule.steps) do
		local stepProblem = validateStep(step)
		if stepProblem then
			return nil, string.format('step %d: %s', index, stepProblem)
		end
	end
	local antiBaitProblem = validateAntiBait(rule.antiBait)
	if antiBaitProblem then
		return nil, 'antiBait: ' .. antiBaitProblem
	end
	return true
end

--- The settings schema for the confidence age thresholds, for the module that owns pricing.
function Rules.confidenceSettings()
	return {
		{
			key = 'staleMediumHours',
			type = 'slider',
			label = 'Prices older than this many hours are medium confidence',
			default = Rules.CONFIDENCE.staleMediumHours,
			min = 1,
			max = 720,
		},
		{
			key = 'staleLowHours',
			type = 'slider',
			label = 'Prices older than this many hours are low confidence',
			default = Rules.CONFIDENCE.staleLowHours,
			min = 1,
			max = 720,
		},
	}
end

--- The weakest of a list of confidence levels; 'high' for an empty list.
--- @param levels string[]
function Rules.weakestLevel(levels)
	local weakest = 'high'
	for _, level in ipairs(levels) do
		if LEVEL_RANK[level] < LEVEL_RANK[weakest] then
			weakest = level
		end
	end
	return weakest
end

--- Units the anti-bait filter passes over: `minutes` of sales, at least one.
--- @param soldPerDay number|nil
--- @param minutes number
function Rules.baitUnits(soldPerDay, minutes)
	local perDay = tonumber(soldPerDay) or 0
	if perDay < 0 then
		perDay = 0
	end
	return math.max(1, math.ceil(perDay * minutes / Rules.MINUTES_PER_DAY))
end

--- Passes over the bait at the bottom of a listing.
--- @param levels table { { price, qty }... }, any order; not changed
--- @param antiBait table|nil { enabled, minutes, gapPercent? }
--- @param soldPerDay number|nil
--- @return table levels left, cheapest first (the dearest level alone when all were bait)
--- @return number skippedUnits units passed over
--- @return boolean isAllBait true when every unit counted as bait
function Rules.passOverBait(levels, antiBait, soldPerDay)
	local sorted = sortedLevels(levels)
	if not antiBait or not antiBait.enabled or #sorted == 0 then
		return sorted, 0, false
	end
	local toSkip = Rules.baitUnits(soldPerDay, antiBait.minutes or Rules.DEFAULT_BAIT_MINUTES)
	local remaining, skipped = {}, 0
	for _, level in ipairs(sorted) do
		local skipHere = math.min(level.qty, toSkip - skipped)
		skipped = skipped + skipHere
		if level.qty > skipHere then
			remaining[#remaining + 1] = { price = level.price, qty = level.qty - skipHere }
		end
	end
	local gapPercent = antiBait.gapPercent
	while gapPercent and #remaining >= 2 and remaining[1].price * 100 < remaining[2].price * gapPercent do
		skipped = skipped + remaining[1].qty
		table.remove(remaining, 1)
	end
	if #remaining == 0 then
		local dearest = sorted[#sorted]
		return { { price = dearest.price, qty = dearest.qty } }, skipped, true
	end
	return remaining, skipped, false
end

--- Evaluates a rule for one item.
--- @param rule table Rule
--- @param itemId number
--- @param ctx table see the file header
--- @return table|nil Price { copper, ageSeconds, source, step, confidence, trace }
--- @return string|nil reason Rules.UNUSABLE_RULE for a rule that fails validation, or why the base has no price
function Rules.evaluate(rule, itemId, ctx)
	if type(itemId) ~= 'number' then
		error('Rules.evaluate: itemId must be a number', 2)
	end
	if type(ctx) ~= 'table' or type(ctx.now) ~= 'number' then
		error('Rules.evaluate: ctx needs now', 2)
	end
	local isValid = Rules.validate(rule)
	if not isValid then
		-- The reason reaches the tooltip; Rules.validate keeps the detail for the editor and store.
		return nil, Rules.UNUSABLE_RULE
	end
	local trace = {}
	local facts = {}
	local copper, age, source = resolveBase(rule.base, rule, itemId, ctx, trace, facts)
	if not copper then
		return nil, age
	end
	local ageSeconds = age
	local baseAgeSeconds = age
	local rowAgeSeconds = nil
	-- A floor (or higher bound) stays in force for every later step: nothing takes the price
	-- under it, not even a later cap or undercut.
	local floorCopper = nil
	local ceilingCopper = nil
	for _, step in ipairs(rule.steps) do
		local stepped, stepAge, lowerBound, upperBound, stepSource =
			applyStep(step, copper, rule, itemId, ctx, trace, facts)
		copper = stepped
		ageSeconds = olderOf(ageSeconds, stepAge)
		if stepSource == 'ahledger' then
			rowAgeSeconds = olderOf(rowAgeSeconds, stepAge)
		end
		floorCopper = lowerBound and math.max(floorCopper or 0, lowerBound) or floorCopper
		ceilingCopper = upperBound and math.min(ceilingCopper or math.huge, upperBound) or ceilingCopper
		if floorCopper and copper < floorCopper then
			copper = floorCopper
			trace[#trace + 1] = { kind = 'floor', label = 'held at the floor', copper = copper }
		end
	end
	local market = buildItemMarket(itemId, ctx, facts)
	local snapped = ns.ItemMarket.snapPrice(market, copper)
	local snapLabel = string.format('price step %dc', market.step)
	local snappedFloor = floorCopper and ns.ItemMarket.snapUp(market, floorCopper)
	if snappedFloor and snappedFloor > snapped then
		snapped = snappedFloor
		snapLabel = snapLabel .. ', floor rounded up'
	end
	trace[#trace + 1] = { kind = 'snap', label = snapLabel, copper = snapped }
	if snappedFloor and ceilingCopper and snapped > ceilingCopper and snapped == snappedFloor then
		facts.isCapOverridden = true
		local cause = floorCopper <= ceilingCopper and 'the price step' or 'the floor'
		trace[#trace + 1] = { kind = 'override', label = 'cap overridden by ' .. cause, copper = snapped }
	end
	local confidence = assessConfidence(facts, ageSeconds, market, ctx)
	for _, reason in ipairs(confidence.reasons) do
		trace[#trace + 1] =
			{ kind = 'confidence', label = string.format('%s confidence, %s', reason.level, reason.text) }
	end
	return {
		copper = snapped,
		ageSeconds = ageSeconds,
		source = source,
		baseAgeSeconds = baseAgeSeconds,
		rowAgeSeconds = rowAgeSeconds,
		step = market.step,
		confidence = confidence,
		trace = trace,
		usesPriceSource = facts.usesSourceFigure == true,
		inputs = copyTable(facts.inputs or {}),
	}
end

-- Base resolution -------------------------------------------------------------------------

-- Returns copper, ageSeconds, source; or nil, reason. Records what confidence needs in facts.
function resolveBase(base, rule, itemId, ctx, trace, facts)
	if ROW_FIELD_BY_BASE[base.kind] then
		return resolveRowBase(base, itemId, ctx, trace, facts)
	end
	if LISTING_BASES[base.kind] then
		return resolveListingBase(base, rule, itemId, ctx, trace, facts)
	end
	return resolveOtherBase(base, itemId, ctx, trace, facts)
end

function resolveRowBase(base, itemId, ctx, trace, facts)
	local row, updated, problem = lookup(ctx.priceRow, itemId, facts, 'AHledger data')
	noteRowProblem(facts, problem)
	row = tableOrNil(row)
	local field = ROW_FIELD_BY_BASE[base.kind]
	local copper, isJunk = readCopper(row and row[field])
	if isJunk then
		noteBadInput(facts, describeBase(base))
		return nil, describeBase(base) .. ' is not a number'
	end
	if not copper then
		return nil, 'no ' .. describeBase(base)
	end
	recordSales(facts, row, ctx, itemId)
	noteSourceFigure(facts, row)
	trace[#trace + 1] = { kind = 'base', label = describeBase(base), copper = copper }
	return copper, ageSince(ctx, updated), 'ahledger'
end

function resolveListingBase(base, rule, itemId, ctx, trace, facts)
	local scanItem, scannedAt = lookup(ctx.scanItem, itemId, facts, 'the scan')
	if type(scanItem) == 'table' and scanItem.isMalformed == true then
		noteBadInput(facts, 'saved scan of this item')
	end
	local row, updated, problem = lookup(ctx.priceRow, itemId, facts, 'AHledger data')
	noteRowProblem(facts, problem)
	row = tableOrNil(row)
	recordSales(facts, row, ctx, itemId)
	local soldPerDay = facts.salesPerDay
	local listed = sortedLevels(type(scanItem) == 'table' and scanItem.levels or nil)
	if #listed > 0 then
		local levels, skipped, isAllBait = Rules.passOverBait(listed, rule.antiBait, soldPerDay)
		if skipped > 0 then
			trace[#trace + 1] = {
				kind = 'antiBait',
				label = isAllBait and string.format('all %d units are bait, dearest level kept', skipped)
					or string.format('%d bait units passed over', skipped),
			}
		end
		local copper, isThin = readListing(base, levels, soldPerDay)
		local note = isThin and ' (listing too thin, dearest level)' or ''
		trace[#trace + 1] = { kind = 'base', label = describeBase(base) .. note, copper = copper }
		recordListing(facts, sumUnits(listed), skipped, isAllBait, isThin)
		noteInput(facts, 'scan')
		return copper, ageSince(ctx, scannedAt), 'scan'
	end
	local lowest, isJunk = readCopper(row and row.min)
	if isJunk then
		noteBadInput(facts, 'AHledger lowest buyout')
		return nil, 'AHledger lowest buyout is not a number'
	end
	if not lowest then
		return nil, 'no listings'
	end
	facts.isFallbackBase = true
	noteSourceFigure(facts, row)
	trace[#trace + 1] = { kind = 'base', label = 'AHledger lowest buyout (no scan depth)', copper = lowest }
	return lowest, ageSince(ctx, updated), 'ahledger'
end

function resolveOtherBase(base, itemId, ctx, trace, facts)
	if base.kind == 'vendor' then
		local info = tableOrNil(lookup(ctx.itemInfo, itemId, facts, 'item info'))
		local vendorPrice, isJunk = readCopper(info and info.vendorPrice)
		if isJunk then
			noteBadInput(facts, 'vendor price')
			return nil, 'vendor price is not a number'
		end
		if not vendorPrice or vendorPrice <= 0 then
			return nil, 'no vendor price'
		end
		trace[#trace + 1] = { kind = 'base', label = 'vendor price', copper = vendorPrice }
		noteInput(facts, 'vendor')
		return vendorPrice, 0, 'vendor'
	end
	local source = base.kind == 'craftCost' and 'craft' or 'realized'
	local raw, at = lookup(ctx[base.kind], itemId, facts, describeBase(base))
	local copper, isJunk = readCopper(raw)
	if isJunk then
		noteBadInput(facts, describeBase(base))
		return nil, describeBase(base) .. ' is not a number'
	end
	if not copper or copper <= 0 then
		return nil, MISSING_BASE_TEXT[base.kind] or ('no ' .. describeBase(base))
	end
	trace[#trace + 1] = { kind = 'base', label = describeBase(base), copper = copper }
	noteInput(facts, base.kind)
	return copper, ageSince(ctx, at) or 0, source
end

-- Reads a price from levels already past the bait (never empty); returns copper and whether
-- the listing was too thin to reach the wanted depth.
function readListing(base, levels, soldPerDay)
	if base.kind == 'lowest' then
		return levels[1].price, false
	end
	if base.kind == 'afterPercent' and base.percent >= 100 then
		return levels[#levels].price, false
	end
	local threshold = base.kind == 'firstWithUnits' and depthUnits(base, soldPerDay)
		or sumUnits(levels) * base.percent / 100
	local cumulative = 0
	for _, level in ipairs(levels) do
		cumulative = cumulative + level.qty
		local isDeepEnough = base.kind == 'firstWithUnits' and cumulative >= threshold or cumulative > threshold
		if isDeepEnough then
			return level.price, false
		end
	end
	return levels[#levels].price, true
end

-- The depth firstWithUnits wants: n units, or `hours` of sales when that is more.
function depthUnits(base, soldPerDay)
	local perHour = (tonumber(soldPerDay) or 0) / Rules.HOURS_PER_DAY
	return math.max(base.n, perHour * (base.hours or 0))
end

-- Steps -----------------------------------------------------------------------------------

-- Returns the new copper, the age of any base the step read (nil when none), for floor and
-- higher the lower bound the price must not go under, for cap and lower the upper bound, and
-- the source of the base the step read.
function applyStep(step, copper, rule, itemId, ctx, trace, facts)
	local kind = step.kind
	if kind == 'multiply' then
		local result = copper * step.factor
		trace[#trace + 1] =
			{ kind = 'step', label = string.format('multiply by %s', tostring(step.factor)), copper = result }
		return result
	end
	if kind == 'undercut' then
		local result = copper - step.copper
		trace[#trace + 1] = { kind = 'step', label = string.format('undercut by %dc', step.copper), copper = result }
		return result
	end
	local stepTrace = {}
	local other, age, source = resolveBase(step.base, rule, itemId, ctx, stepTrace, facts)
	if not other then
		trace[#trace + 1] = { kind = 'skip', label = string.format('%s skipped, %s', kind, age) }
		return copper
	end
	local limit = other
	if kind == 'cap' or kind == 'floor' then
		limit = other * step.percent / 100
	end
	local isUpperBound = kind == 'cap' or kind == 'lower'
	local result = isUpperBound and math.min(copper, limit) or math.max(copper, limit)
	local percentText = step.percent and string.format(' %s%%', tostring(step.percent)) or ''
	trace[#trace + 1] = {
		kind = 'step',
		label = string.format('%s at%s %s', kind, percentText, describeBase(step.base)),
		copper = result,
	}
	return result, age, (not isUpperBound) and limit or nil, isUpperBound and limit or nil, source
end

-- Confidence ------------------------------------------------------------------------------

function assessConfidence(facts, ageSeconds, market, ctx)
	local thresholds = confidenceThresholds(ctx)
	local reasons = {}
	if facts.usesMarket then
		local problem = sourceProblemOf(ctx, facts)
		if problem and problem.code == 'noMarketTable' and facts.usesSourceFigure then
			-- AHledger has no synced table yet answered: its figures are its overlay of the
			-- player's own scan, so "no prices" would contradict the figure shown.
			addReason(
				reasons,
				'ownScanOverlay',
				'medium',
				'AHledger has no synced table for this market, so its figures come from your own scan'
			)
		elseif problem then
			addReason(reasons, problem.code, 'low', problem.text .. ", so only Haggler's own scans count")
		end
		if facts.isSnapshot then
			addReason(reasons, 'snapshot', 'medium', 'bundled AHledger prices, older than synced ones')
		end
		addStaleReason(reasons, ageSeconds, thresholds)
		addSalesReason(reasons, facts, thresholds)
		for _, reason in ipairs(facts.salesReasons or {}) do
			addReason(reasons, reason.code, reason.level, reason.text)
		end
	end
	local mismatch = tableOrNil(ctx.marketMismatch)
	if facts.usesSourceFigure and mismatch then
		local text = string.format(
			'AHledger uses %s while Haggler prices %s',
			tostring(mismatch.sourceMarket),
			tostring(mismatch.marketKey)
		)
		addReason(reasons, 'marketMismatch', 'high', text)
	end
	local isFewListings = facts.listedUnits ~= nil and facts.listedUnits < thresholds.fewListingUnits
	if isFewListings or facts.isListingThin then
		addReason(reasons, 'fewListings', 'medium', 'few units listed')
	end
	if facts.isFallbackBase then
		addReason(
			reasons,
			'fallbackBase',
			'medium',
			"no scan depth, so this is AHledger's lowest buyout and not bait-checked"
		)
	end
	if market.isStepInferred then
		addReason(reasons, 'inferredStep', 'medium', 'max stack unknown, so whole silver is assumed')
	end
	for _, input in ipairs(facts.badInputs or {}) do
		addReason(reasons, 'badInput', 'medium', input .. ' was not usable and is treated as unknown')
	end
	if facts.isCapOverridden then
		addReason(reasons, 'capOverridden', 'medium', 'a cap was overridden to keep the floor')
	end
	if facts.isAllBait then
		addReason(reasons, 'baitTrimmed', 'low', 'every listed unit looked like bait')
	elseif (facts.baitShare or 0) > thresholds.baitTrimmedShare then
		addReason(reasons, 'baitTrimmed', 'medium', 'anti-bait passed over most listed units')
	end
	local levels = {}
	for _, reason in ipairs(reasons) do
		levels[#levels + 1] = reason.level
	end
	return { level = Rules.weakestLevel(levels), reasons = reasons }
end

function addStaleReason(reasons, ageSeconds, thresholds)
	if ageSeconds == nil then
		addReason(reasons, 'stale', 'medium', 'data age unknown')
		return
	end
	local hours = ageSeconds / SECONDS_PER_HOUR
	local text = string.format('data is %d hours old', math.floor(hours))
	if hours > thresholds.staleLowHours then
		addReason(reasons, 'stale', 'low', text)
	elseif hours > thresholds.staleMediumHours then
		addReason(reasons, 'stale', 'medium', text)
	end
end

function addSalesReason(reasons, facts, thresholds)
	local perDay = facts.salesPerDay
	if perDay == nil then
		addReason(reasons, 'fewSales', 'medium', 'no sales data')
	elseif perDay < thresholds.lowSalesPerDay then
		addReason(reasons, 'fewSales', 'low', string.format('%s sold a day', tostring(perDay)))
	elseif perDay < thresholds.mediumSalesPerDay then
		addReason(reasons, 'fewSales', 'medium', string.format('%s sold a day', tostring(perDay)))
	end
end

function addReason(reasons, code, level, text)
	reasons[#reasons + 1] = { code = code, level = level, text = text }
end

-- The defaults, with the age thresholds from ctx.confidence when they are valid numbers.
function confidenceThresholds(ctx)
	local thresholds = copyTable(Rules.CONFIDENCE)
	local fromSettings = type(ctx.confidence) == 'table' and ctx.confidence or {}
	for _, key in ipairs({ 'staleMediumHours', 'staleLowHours' }) do
		if isFinitePositive(fromSettings[key]) then
			thresholds[key] = fromSettings[key]
		end
	end
	return thresholds
end

-- Market facts: the sales figure of any AHledger row a market base read.
-- Sales a day comes from ctx.sales when the context has it (PriceContext: the own troll-filtered
-- count or AHledger's, with reasons), else from the AHledger row.
function recordSales(facts, row, ctx, itemId)
	facts.usesMarket = true
	local view = tableOrNil((lookup(ctx.sales, itemId, facts, 'sales')))
	if view then
		recordSalesView(facts, view)
		if facts.salesSource == 'ahledger' and facts.salesPerDay ~= nil then
			noteSourceFigure(facts, row)
		end
		return
	end
	if not row or row.sold == nil then
		return
	end
	if isFiniteNumber(row.sold) and row.sold >= 0 then
		facts.salesPerDay = row.sold
		noteSourceFigure(facts, row)
	else
		noteBadInput(facts, 'AHledger sold a day')
	end
end

function recordSalesView(facts, view)
	local isOwn = view.source == 'own'
	facts.salesSource = isOwn and 'own' or 'ahledger'
	facts.salesReasons = salesReasonsOf(view.reasons)
	facts.salesPerDay = nil
	if view.perDay == nil then
		return
	end
	if isFiniteNumber(view.perDay) and view.perDay >= 0 then
		facts.salesPerDay = view.perDay
		if isOwn then
			noteInput(facts, 'ownSales')
		end
	else
		noteBadInput(facts, isOwn and 'own sales a day' or 'AHledger sold a day')
	end
end

-- The well-formed reasons of a sales view; the rest are dropped.
function salesReasonsOf(reasons)
	local kept = {}
	if type(reasons) ~= 'table' then
		return kept
	end
	for _, reason in ipairs(reasons) do
		local isWellFormed = type(reason) == 'table'
			and type(reason.code) == 'string'
			and LEVEL_RANK[reason.level] ~= nil
			and type(reason.text) == 'string'
		if isWellFormed then
			kept[#kept + 1] = { code = reason.code, level = reason.level, text = reason.text }
		end
	end
	return kept
end

function recordListing(facts, listedUnits, skipped, isAllBait, isThin)
	facts.listedUnits = math.min(facts.listedUnits or listedUnits, listedUnits)
	facts.baitShare = math.max(facts.baitShare or 0, skipped / listedUnits)
	facts.isAllBait = facts.isAllBait or isAllBait
	facts.isListingThin = facts.isListingThin or isThin
end

-- Helpers ---------------------------------------------------------------------------------

-- A copper amount from another source: the number when finite, else nil and whether the value
-- was junk (present but not a finite number) rather than simply missing.
function readCopper(value)
	if value == nil then
		return nil, false
	end
	if isFiniteNumber(value) then
		return value, false
	end
	return nil, true
end

-- An AHledger figure went into the price; from its bundled copy when the row says so.
function noteSourceFigure(facts, row)
	if not row then
		return
	end
	facts.usesSourceFigure = true
	noteInput(facts, 'ahledger')
	if row.isSnapshot == true then
		facts.isSnapshot = true
	end
end

-- An input the quote read.
function noteInput(facts, input)
	facts.inputs = facts.inputs or {}
	facts.inputs[input] = true
end

-- A row call that failed (the source said so) rather than an item without a price.
function noteRowProblem(facts, problem)
	if problem == 'priceSourceFailing' then
		facts.isRowFailing = true
	end
end

-- The price source's problem for this market, or a failed row call; nil when neither.
function sourceProblemOf(ctx, facts)
	local problem = tableOrNil(ctx.priceSourceProblem)
	if problem and type(problem.code) == 'string' and type(problem.text) == 'string' then
		return problem
	end
	if facts.isRowFailing then
		return { code = 'priceSourceFailing', text = 'AHledger calls fail' }
	end
	return nil
end

function noteBadInput(facts, what)
	facts.badInputs = facts.badInputs or {}
	for _, seen in ipairs(facts.badInputs) do
		if seen == what then
			return
		end
	end
	facts.badInputs[#facts.badInputs + 1] = what
end

function tableOrNil(value)
	return type(value) == 'table' and value or nil
end

-- A real number: not NaN, not infinite, not a string that looks like one.
function isFiniteNumber(value)
	return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

function validateBase(base)
	if type(base) ~= 'table' then
		return 'must be a table'
	end
	local kind = base.kind
	if not (ROW_FIELD_BY_BASE[kind] or LISTING_BASES[kind] or OTHER_BASES[kind]) then
		return string.format('unknown kind %q', tostring(kind))
	end
	if kind == 'firstWithUnits' and not isPositiveInteger(base.n) then
		return 'firstWithUnits needs n, a positive whole number'
	end
	local hours = base.hours
	if
		kind == 'firstWithUnits'
		and hours ~= nil
		and not (type(hours) == 'number' and hours >= 0 and hours < math.huge)
	then
		return 'firstWithUnits hours must be 0 or more'
	end
	if kind == 'afterPercent' and not isPercent(base.percent) then
		return 'afterPercent needs percent from 0 to 100'
	end
	return nil
end

function validateStep(step)
	if type(step) ~= 'table' or not STEP_KINDS[step.kind] then
		return string.format('unknown kind %q', tostring(type(step) == 'table' and step.kind or step))
	end
	local kind = step.kind
	if kind == 'multiply' then
		local isFactor = type(step.factor) == 'number' and step.factor > 0 and step.factor < math.huge
		return not isFactor and 'multiply needs a positive factor' or nil
	end
	if kind == 'undercut' then
		local isAmount = type(step.copper) == 'number' and step.copper >= 0 and step.copper % 1 == 0
		return not isAmount and 'undercut needs whole copper, 0 or more' or nil
	end
	if (kind == 'cap' or kind == 'floor') and not isFinitePositive(step.percent) then
		return kind .. ' needs a positive percent'
	end
	local baseProblem = validateBase(step.base)
	return baseProblem and ('base ' .. baseProblem) or nil
end

function validateAntiBait(antiBait)
	if antiBait == nil then
		return nil
	end
	if type(antiBait) ~= 'table' or type(antiBait.enabled) ~= 'boolean' then
		return 'needs enabled'
	end
	local minutes = antiBait.minutes
	if minutes ~= nil and not (type(minutes) == 'number' and minutes >= 0 and minutes < math.huge) then
		return 'minutes must be 0 or more'
	end
	local gapPercent = antiBait.gapPercent
	if gapPercent ~= nil and not (isPercent(gapPercent) and gapPercent > 0) then
		return 'gapPercent must be above 0 and at most 100'
	end
	return nil
end

-- The item's price grid: max stack and vendor price from item info, copper seen from the scan.
function buildItemMarket(itemId, ctx, facts)
	local info = tableOrNil(lookup(ctx.itemInfo, itemId, facts, 'item info'))
	local scanItem = tableOrNil(lookup(ctx.scanItem, itemId))
	local copperSeen = scanItem ~= nil
		and (scanItem.copperSeen == true or ns.ItemMarket.hasCopper(sortedLevels(scanItem.levels), scanItem.min))
	local maxStack = info and info.maxStack
	local vendor = info and info.vendorPrice
	if maxStack ~= nil and not isFinitePositive(maxStack) then
		noteBadInput(facts, 'item max stack')
	end
	if vendor ~= nil and not (isFiniteNumber(vendor) and vendor >= 0) then
		noteBadInput(facts, 'item vendor price')
	end
	return ns.ItemMarket.forItem({
		maxStack = isFinitePositive(maxStack) and maxStack or nil,
		vendor = isFinitePositive(vendor) and vendor or nil,
		copperSeen = copperSeen,
	})
end

-- The usable levels, cheapest first: junk (not a table, bid-only, a price or quantity that is
-- not a finite positive number) is dropped, so no caller ever reads a raw level.
function sortedLevels(levels)
	local sorted = {}
	for _, level in ipairs(type(levels) == 'table' and levels or {}) do
		if type(level) == 'table' and isFinitePositive(level.qty) and isFinitePositive(level.price) then
			sorted[#sorted + 1] = { price = level.price, qty = level.qty }
		end
	end
	table.sort(sorted, function(a, b)
		return a.price < b.price
	end)
	return sorted
end

function copyTable(source)
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = type(value) == 'table' and copyTable(value) or value
	end
	return copy
end

function sumUnits(levels)
	local total = 0
	for _, level in ipairs(levels) do
		total = total + level.qty
	end
	return total
end

function describeBase(base)
	if base.kind == 'firstWithUnits' and base.hours and base.hours > 0 then
		return string.format('scan first price with %d units or %s hours of sales', base.n, tostring(base.hours))
	end
	if base.kind == 'firstWithUnits' then
		return string.format('scan first price with %d units', base.n)
	end
	if base.kind == 'afterPercent' then
		return string.format('scan price after the cheapest %s%%', tostring(base.percent))
	end
	return BASE_NAMES[base.kind] or 'this price'
end

function isPositiveInteger(value)
	return type(value) == 'number' and value >= 1 and value % 1 == 0
end

function isPercent(value)
	return type(value) == 'number' and value >= 0 and value <= 100
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

-- Seconds since a unix time, never negative; nil when the time is unknown.
function ageSince(ctx, at)
	if not isFiniteNumber(at) then
		return nil
	end
	return math.max(0, ctx.now - at)
end

-- Calls an optional ctx source. A source that throws counts as no data and, when facts are
-- given, as bad input.
function lookup(source, itemId, facts, what)
	if type(source) ~= 'function' then
		return nil
	end
	local ok, value, at, extra = pcall(source, itemId)
	if not ok then
		if facts then
			noteBadInput(facts, what)
		end
		return nil
	end
	return value, at, extra
end

-- The older of two ages; an unknown (nil) age never wins.
function olderOf(a, b)
	if a == nil then
		return b
	end
	if b == nil then
		return a
	end
	return math.max(a, b)
end

return Rules
