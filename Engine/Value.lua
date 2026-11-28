--[[
	Value: what owned items are worth to the player, the `value` contract. An item's value is its
	opportunity value (Guardrail.opportunity): what selling it would net after the 5% cut and the
	expected deposit loss, under a rule, and never below the vendor price. Bags, the trade window
	and (later) owned materials in ventures all read this one figure.

	  Value.new({ prices, store, durationHours?, deposit? })
	    prices          PriceService (Get, Context)
	    store           Store (Rule, DefaultRuleId)
	    durationHours() listing duration the deposit risk assumes (default 24)
	    deposit(itemId, units, hours) -> copper|nil   the client's deposit when it can say
	  value:Item(itemId, options?)            one unit
	  value:Stack(itemId, count, options?)    a stack posted as one listing
	  value:Total(entries, options?)          { { itemId, count, isBound? }... }, one context
	  value:Context()                         a price context to pass as options.ctx
	  options = { ruleId?, ctx?, isBound? }

	ItemValue = { itemId, count, copper, perUnit, source = 'ah'|'vendor'|'none', ruleId,
	              rulePrice?, reason?, sellChance?, depositLoss?, deposit?, ahNet?, vendorNet?,
	              lowestListed?, typicalPrice?, recentPrice?, typicalAhNet?, isPriced, confidence }
	lowestListed, typicalPrice (the 30-day median) and recentPrice (the 7-day median) are unit
	prices from PriceContext.facts;
	typicalAhNet is the AH net of listing the stack at typicalPrice, worked out as ahNet is (cut,
	deposit, sell chance), and only while the lowest listing is under it. Advice.forItem reads
	them for the bag decision.
	Total     = { copper, count, unpriced, confidence, items = { ItemValue... } }

	Confidence follows the weakest input: the rule price's reasons plus the value's own (no
	price, no vendor price, sell chance unknown...). A bad call from another add-on (an item id
	or count that is not a positive whole number, an unknown rule) returns nil and a reason.
]]
local _, ns = ...

local Value = {}
ns.Value = Value

Value.MAX_TOTAL_REASONS = 8

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWholePositive, isFinitePositive, safeCall, levelsOf

local ValueMethods = {}
ValueMethods.__index = ValueMethods

--- @param options table see the file header
--- @return table value
function Value.new(options)
	if type(options) ~= 'table' or not options.prices or not options.store then
		error('Value.new: needs prices and store', 2)
	end
	return setmetatable({ options = options }, ValueMethods)
end

--- Merges confidences: the weakest level wins, reasons are kept once per code and text.
--- @param confidences table { Confidence... } (nil entries skipped)
--- @param limit number|nil keep at most this many reasons, weakest first
--- @return table Confidence
function Value.mergeConfidence(confidences, limit)
	local reasons, seen, levels = {}, {}, {}
	for _, confidence in pairs(confidences) do
		for _, reason in ipairs(type(confidence) == 'table' and confidence.reasons or {}) do
			local key = tostring(reason.code) .. '|' .. tostring(reason.text)
			if not seen[key] then
				seen[key] = true
				reasons[#reasons + 1] = reason
				levels[#levels + 1] = reason.level
			end
		end
		if type(confidence) == 'table' and confidence.level then
			levels[#levels + 1] = confidence.level
		end
	end
	local rank = { low = 1, medium = 2, high = 3 }
	table.sort(reasons, function(a, b)
		if rank[a.level] ~= rank[b.level] then
			return rank[a.level] < rank[b.level]
		end
		return tostring(a.code) < tostring(b.code)
	end)
	if limit and #reasons > limit then
		for index = #reasons, limit + 1, -1 do
			reasons[index] = nil
		end
	end
	return { level = ns.Rules.weakestLevel(levels), reasons = reasons }
end

--- A price context to share across many calls (one paint pass, one trade read).
function ValueMethods:Context()
	return self.options.prices:Context()
end

--- The rule id an options table asks for, else the default.
function ValueMethods:RuleId(options)
	local ruleId = options and options.ruleId
	return ruleId or self.options.store:DefaultRuleId()
end

--- One unit's value.
--- @return table|nil ItemValue
--- @return string|nil reason
function ValueMethods:Item(itemId, options)
	return self:Stack(itemId, 1, options)
end

--- A stack's value, as one listing of `count` units.
--- @param itemId number
--- @param count number units
--- @param options table|nil { ruleId?, ctx?, isBound? }
--- @return table|nil ItemValue
--- @return string|nil reason
function ValueMethods:Stack(itemId, count, options)
	if not isWholePositive(itemId) then
		return nil, 'item id must be a positive whole number'
	end
	if not isWholePositive(count) then
		return nil, 'count must be a positive whole number'
	end
	options = options or {}
	local store = self.options.store
	local ruleId = self:RuleId(options)
	local rule = store:Rule(ruleId)
	if not rule then
		return nil, 'unknown rule ' .. tostring(ruleId)
	end
	local ctx = options.ctx or self.options.prices:Context()
	local price, reason
	if not options.isBound then
		price, reason = self.options.prices:Get(itemId, ruleId, ctx)
	end
	local facts = ns.PriceContext.facts(ctx, itemId)
	local hours = safeCall(self.options.durationHours) or ns.Guardrail.DEFAULT_DURATION_HOURS
	local deposit = safeCall(self.options.deposit, itemId, count, hours)
	local opportunity = ns.Guardrail.opportunity({
		price = price and price.copper,
		units = count,
		vendor = facts.vendor,
		salesPerDay = facts.salesPerDay,
		levels = levelsOf(facts.levels),
		antiBait = rule.antiBait,
		durationHours = hours,
		deposit = deposit,
		isBound = options.isBound == true,
	})
	local typicalAhNet
	if
		not options.isBound
		and isFinitePositive(facts.typicalPrice)
		and isFinitePositive(facts.lowestListed)
		and facts.lowestListed < facts.typicalPrice
	then
		typicalAhNet = ns.Guardrail.opportunity({
			price = facts.typicalPrice,
			units = count,
			vendor = facts.vendor,
			salesPerDay = facts.salesPerDay,
			levels = levelsOf(facts.levels),
			antiBait = rule.antiBait,
			durationHours = hours,
			deposit = deposit,
		}).ahNet
	end
	return {
		itemId = itemId,
		count = count,
		copper = opportunity.copper,
		perUnit = opportunity.perUnit,
		source = opportunity.source,
		ruleId = ruleId,
		rulePrice = price,
		reason = reason,
		sellChance = opportunity.sellChance,
		depositLoss = opportunity.depositLoss,
		deposit = opportunity.deposit,
		ahNet = opportunity.ahNet,
		vendorNet = opportunity.vendorNet,
		lowestListed = facts.lowestListed,
		typicalPrice = facts.typicalPrice,
		recentPrice = facts.recentPrice,
		typicalAhNet = typicalAhNet,
		isPriced = price ~= nil,
		confidence = Value.mergeConfidence({ price and price.confidence, { reasons = opportunity.reasons } }),
	}
end

--- The value of many stacks under one rule and one context (bag totals, a trade side).
--- @param entries table { { itemId, count, isBound? }... }; junk entries are skipped and counted
--- @param options table|nil { ruleId?, ctx? }
--- @return table|nil Total { copper, count, unpriced, skipped, confidence, items }
--- @return string|nil reason
function ValueMethods:Total(entries, options)
	if type(entries) ~= 'table' then
		return nil, 'entries must be a list'
	end
	options = options or {}
	local ruleId = self:RuleId(options)
	if not self.options.store:Rule(ruleId) then
		return nil, 'unknown rule ' .. tostring(ruleId)
	end
	local ctx = options.ctx or self.options.prices:Context()
	local total = { copper = 0, count = 0, unpriced = 0, skipped = 0, items = {} }
	local confidences = {}
	for _, entry in ipairs(entries) do
		local item = type(entry) == 'table'
			and self:Stack(entry.itemId, entry.count, { ruleId = ruleId, ctx = ctx, isBound = entry.isBound })
		if item then
			total.items[#total.items + 1] = item
			total.copper = total.copper + item.copper
			total.count = total.count + item.count
			total.unpriced = total.unpriced + ((item.isPriced or entry.isBound) and 0 or 1)
			confidences[#confidences + 1] = item.confidence
		else
			total.skipped = total.skipped + 1
		end
	end
	total.confidence = Value.mergeConfidence(confidences, Value.MAX_TOTAL_REASONS)
	return total
end

-- Helpers ---------------------------------------------------------------------------------

function isWholePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

-- A source that throws or returns junk reads as unknown.
function safeCall(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if ok and type(result) == 'number' and result >= 0 and result < math.huge then
		return result
	end
	return nil
end

-- Scan levels as Guardrail reads them; anything but a list reads as no scan.
function levelsOf(levels)
	return type(levels) == 'table' and levels or nil
end

return Value
