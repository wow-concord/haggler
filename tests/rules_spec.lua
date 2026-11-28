local t = ...
local ns = t.loadAddon()
local Rules = ns.Rules

local NOW = 100000
local ITEM = 2589 -- Linen Cloth

-- A context with an AHledger row, scan levels and item info for one item.
local function context(options)
	options = options or {}
	return {
		now = NOW,
		priceRow = function(itemId)
			if itemId == ITEM and options.row then
				return options.row, options.updated or (NOW - 3600)
			end
		end,
		scanItem = function(itemId)
			if itemId == ITEM and options.levels then -- false means no scan
				return { levels = options.levels }, options.scannedAt or (NOW - 60)
			end
		end,
		itemInfo = function()
			return options.info or { maxStack = 20, vendorPrice = 13 }
		end,
		craftCost = options.craftCost and function()
			return options.craftCost, NOW - 10
		end,
		realized = options.realized and function()
			return options.realized
		end,
	}
end

local ROW = { median = 500, min = 300, qty = 100, m7 = 480, m30 = 520, lo = 250, hi = 900, sold = 1440 }

local function rule(base, steps, antiBait)
	return {
		id = 'test',
		name = 'Test',
		base = base,
		steps = steps or {},
		antiBait = antiBait or { enabled = false },
	}
end

local function evaluate(testRule, options)
	return Rules.evaluate(testRule, ITEM, context(options))
end

t.group('anti-bait')

t.test('bait units are minutes of sales, at least one', function()
	t.eq(Rules.baitUnits(0, 10), 1, 'no sales still passes over one unit')
	t.eq(Rules.baitUnits(nil, 10), 1)
	t.eq(Rules.baitUnits(-5, 10), 1)
	t.eq(Rules.baitUnits(144, 10), 1)
	t.eq(Rules.baitUnits(1440, 10), 10)
	t.eq(Rules.baitUnits(1441, 10), 11, 'rounds up')
	t.eq(Rules.baitUnits(1440, 0), 1, 'zero minutes still passes over one unit')
end)

t.test('0 sales: the single cheapest unit is passed over', function()
	local levels, skipped, isAllBait = Rules.passOverBait(
		{ { price = 100, qty = 1 }, { price = 300, qty = 5 } },
		{ enabled = true, minutes = 10 },
		0
	)
	t.same(levels, { { price = 300, qty = 5 } })
	t.eq(skipped, 1)
	t.eq(isAllBait, false)
end)

t.test('bait eats part of a level', function()
	local levels, skipped = Rules.passOverBait(
		{ { price = 100, qty = 3 }, { price = 300, qty = 5 } },
		{ enabled = true, minutes = 10 },
		576 -- 4 units in 10 minutes
	)
	t.same(levels, { { price = 300, qty = 4 } })
	t.eq(skipped, 4)
end)

t.test('1 unit listed: everything is bait and that unit is the price', function()
	local levels, skipped, isAllBait = Rules.passOverBait({ { price = 700, qty = 1 } }, { enabled = true }, 0)
	t.same(levels, { { price = 700, qty = 1 } })
	t.eq(skipped, 1)
	t.eq(isAllBait, true)
end)

t.test('everything bait: the dearest level is kept', function()
	local levels, skipped, isAllBait = Rules.passOverBait(
		{ { price = 200, qty = 3 }, { price = 100, qty = 2 }, { price = 900, qty = 1 } },
		{ enabled = true, minutes = 60 },
		1440 -- 60 units an hour
	)
	t.same(levels, { { price = 900, qty = 1 } })
	t.eq(skipped, 6)
	t.eq(isAllBait, true)
end)

t.test('disabled anti-bait passes nothing over, but still sorts', function()
	local input = { { price = 300, qty = 1 }, { price = 100, qty = 1 } }
	local levels, skipped = Rules.passOverBait(input, { enabled = false }, 9999)
	t.same(levels, { { price = 100, qty = 1 }, { price = 300, qty = 1 } })
	t.eq(skipped, 0)
	t.eq(input[1].price, 300, 'input is not changed')
end)

t.test('gapPercent passes over a cheap level far below the next', function()
	local levels, skipped = Rules.passOverBait(
		{ { price = 5, qty = 5 }, { price = 20, qty = 5 }, { price = 100, qty = 5 }, { price = 105, qty = 5 } },
		{ enabled = true, minutes = 10, gapPercent = 50 },
		0
	)
	t.same(levels, { { price = 100, qty = 5 }, { price = 105, qty = 5 } })
	t.eq(skipped, 10)
end)

t.test('empty or junk levels are ignored', function()
	local levels, skipped = Rules.passOverBait(
		{ { price = 0, qty = 4 }, { price = 50, qty = 0 } },
		{ enabled = true },
		0
	)
	t.same(levels, {})
	t.eq(skipped, 0)
end)

t.group('bases')

t.test('AHledger bases read their field', function()
	local cases = { median = 500, median7 = 480, median30 = 520, low30 = 250, high30 = 900 }
	for kind, expected in pairs(cases) do
		local price = evaluate(rule({ kind = kind }), { row = ROW })
		t.eq(price.copper, expected, kind)
		t.eq(price.source, 'ahledger', kind)
		t.eq(price.ageSeconds, 3600, kind)
	end
end)

t.test('lowest reads the scan past the bait', function()
	local price = evaluate(rule({ kind = 'lowest' }, {}, { enabled = true, minutes = 10 }), {
		row = ROW,
		levels = { { price = 120, qty = 3 }, { price = 310, qty = 50 } },
	})
	t.eq(price.copper, 310)
	t.eq(price.source, 'scan')
	t.eq(price.ageSeconds, 60)
	t.eq(price.trace[1].kind, 'antiBait')
end)

t.test('listing bases fall back to the AHledger lowest buyout without scan depth', function()
	for _, base in ipairs({
		{ kind = 'lowest' },
		{ kind = 'firstWithUnits', n = 5 },
		{ kind = 'afterPercent', percent = 10 },
	}) do
		local price = evaluate(rule(base), { row = ROW })
		t.eq(price.copper, 300, base.kind)
		t.eq(price.source, 'ahledger', base.kind)
	end
	local price, reason = evaluate(rule({ kind = 'lowest' }), {})
	t.eq(price, nil)
	t.eq(reason, 'no listings')
end)

t.test('firstWithUnits finds the first price n units deep', function()
	local levels =
		{ { price = 100, qty = 2 }, { price = 110, qty = 2 }, { price = 120, qty = 2 }, { price = 200, qty = 50 } }
	t.eq(evaluate(rule({ kind = 'firstWithUnits', n = 5 }), { levels = levels }).copper, 120)
	t.eq(evaluate(rule({ kind = 'firstWithUnits', n = 4 }), { levels = levels }).copper, 110, 'exactly n counts')
	local thin = evaluate(rule({ kind = 'firstWithUnits', n = 100 }), { levels = levels })
	t.eq(thin.copper, 200, 'too thin: the dearest level')
	t.truthy(thin.trace[1].label:find('too thin'))
end)

t.test('afterPercent reads the price past the cheapest share of units', function()
	local levels = { { price = 100, qty = 10 }, { price = 200, qty = 10 }, { price = 300, qty = 80 } }
	t.eq(evaluate(rule({ kind = 'afterPercent', percent = 0 }), { levels = levels }).copper, 100)
	t.eq(evaluate(rule({ kind = 'afterPercent', percent = 10 }), { levels = levels }).copper, 200)
	t.eq(evaluate(rule({ kind = 'afterPercent', percent = 15 }), { levels = levels }).copper, 200)
	t.eq(evaluate(rule({ kind = 'afterPercent', percent = 20 }), { levels = levels }).copper, 300)
	t.eq(evaluate(rule({ kind = 'afterPercent', percent = 100 }), { levels = levels }).copper, 300)
end)

t.test('vendor, craft cost and realized bases', function()
	local vendor = evaluate(rule({ kind = 'vendor' }), { info = { maxStack = 20, vendorPrice = 25 } })
	t.eq(vendor.copper, 25)
	t.eq(vendor.source, 'vendor')
	t.eq(vendor.ageSeconds, 0)
	local craft = evaluate(rule({ kind = 'craftCost' }), { craftCost = 777 })
	t.eq(craft.copper, 777)
	t.eq(craft.source, 'craft')
	t.eq(craft.ageSeconds, 10)
	local realized = evaluate(rule({ kind = 'realized' }), { realized = 640 })
	t.eq(realized.copper, 640)
	t.eq(realized.source, 'realized')
end)

t.test('a base without data fails with a reason', function()
	local cases = {
		{ { kind = 'median' }, 'no AHledger median' },
		{ { kind = 'vendor' }, 'no vendor price' },
		{ { kind = 'craftCost' }, 'no craftCost' },
		{ { kind = 'realized' }, 'no realized' },
	}
	for _, case in ipairs(cases) do
		local price, reason = evaluate(rule(case[1]), { info = { maxStack = 20, vendorPrice = 0 } })
		t.eq(price, nil, case[1].kind)
		t.eq(reason, case[2], case[1].kind)
	end
end)

t.group('steps')

t.test('cap and floor at a percent of a base', function()
	t.eq(
		evaluate(
			rule({ kind = 'high30' }, { { kind = 'cap', percent = 100, base = { kind = 'median' } } }),
			{ row = ROW }
		).copper,
		500
	)
	t.eq(
		evaluate(
			rule({ kind = 'high30' }, { { kind = 'cap', percent = 80, base = { kind = 'median' } } }),
			{ row = ROW }
		).copper,
		400
	)
	t.eq(
		evaluate(
			rule({ kind = 'low30' }, { { kind = 'cap', percent = 100, base = { kind = 'median' } } }),
			{ row = ROW }
		).copper,
		250,
		'cap leaves a lower price'
	)
	t.eq(
		evaluate(
			rule({ kind = 'low30' }, { { kind = 'floor', percent = 90, base = { kind = 'median' } } }),
			{ row = ROW }
		).copper,
		450
	)
	t.eq(
		evaluate(
			rule({ kind = 'high30' }, { { kind = 'floor', percent = 90, base = { kind = 'median' } } }),
			{ row = ROW }
		).copper,
		900
	)
end)

t.test('lower and higher of two bases', function()
	t.eq(
		evaluate(rule({ kind = 'median' }, { { kind = 'lower', base = { kind = 'median7' } } }), { row = ROW }).copper,
		480
	)
	t.eq(
		evaluate(rule({ kind = 'median' }, { { kind = 'higher', base = { kind = 'median30' } } }), { row = ROW }).copper,
		520
	)
end)

t.test('multiply and undercut', function()
	t.eq(evaluate(rule({ kind = 'median' }, { { kind = 'multiply', factor = 1.5 } }), { row = ROW }).copper, 750)
	t.eq(
		evaluate(rule({ kind = 'median' }, { { kind = 'multiply', factor = 0.333 } }), { row = ROW }).copper,
		166,
		'fractions round down'
	)
	t.eq(evaluate(rule({ kind = 'median' }, { { kind = 'undercut', copper = 7 } }), { row = ROW }).copper, 493)
	t.eq(evaluate(rule({ kind = 'median' }, { { kind = 'undercut', copper = 0 } }), { row = ROW }).copper, 500)
end)

t.test('steps run in order', function()
	local steps = { { kind = 'undercut', copper = 100 }, { kind = 'multiply', factor = 2 } }
	t.eq(evaluate(rule({ kind = 'median' }, steps), { row = ROW }).copper, 800)
end)

t.test('a step whose base has no data is skipped and traced', function()
	local price = evaluate(
		rule({ kind = 'median' }, { { kind = 'floor', percent = 100, base = { kind = 'craftCost' } } }),
		{ row = ROW }
	)
	t.eq(price.copper, 500)
	t.eq(price.trace[2].kind, 'skip')
end)

t.test('the oldest base used sets the age', function()
	local price = evaluate(rule({ kind = 'lowest' }, { { kind = 'cap', percent = 100, base = { kind = 'median' } } }), {
		row = ROW,
		levels = { { price = 900, qty = 9 } },
	})
	t.eq(price.copper, 500)
	t.eq(price.ageSeconds, 3600)
end)

t.test('a price never goes under one step', function()
	local price = evaluate(rule({ kind = 'median' }, { { kind = 'undercut', copper = 10000 } }), { row = ROW })
	t.eq(price.copper, 1)
end)

t.group('built-in rules')

local MARKET = {
	row = { median = 250, min = 120, qty = 305, m7 = 240, m30 = 260, lo = 110, hi = 400, sold = 800 },
	levels = {
		{ price = 120, qty = 19 },
		{ price = 184, qty = 55 },
		{ price = 185, qty = 80 },
		{ price = 195, qty = 151 },
	},
}

t.test('Realistic, Minimum and Median ship with anti-bait on', function()
	local builtIns = Rules.builtIns()
	for _, id in ipairs({ 'realistic', 'minimum', 'median' }) do
		local builtIn = builtIns[id]
		t.truthy(Rules.validate(builtIn), id)
		t.eq(builtIn.builtIn, true, id)
		t.eq(builtIn.antiBait.enabled, true, id)
		t.eq(builtIn.antiBait.minutes, 10, id)
	end
	t.eq(Rules.DEFAULT_RULE_ID, 'realistic')
	builtIns.realistic.antiBait.minutes = 99
	t.eq(Rules.builtIns().realistic.antiBait.minutes, 10, 'fresh copies every call')
end)

t.test('Realistic: first price with depth past the bait, capped at the median, undercut', function()
	-- 800 a day: 6 bait units, then 13 left at 120c; an hour of sales (33 units) is 184c deep, minus 1c.
	local price = evaluate(Rules.builtIns().realistic, MARKET)
	t.eq(price.copper, 183)
	t.eq(price.source, 'scan')
end)

t.test('Realistic falls to the median when depth sits above it', function()
	local price = evaluate(Rules.builtIns().realistic, { row = MARKET.row, levels = { { price = 900, qty = 50 } } })
	t.eq(price.copper, 249)
end)

t.test('Minimum: lowest past the bait, undercut', function()
	local bait = Rules.builtIns().minimum
	local price = evaluate(bait, { row = MARKET.row, levels = { { price = 50, qty = 1 }, { price = 184, qty = 55 } } })
	t.eq(price.copper, 183, 'a lone 50c bait unit is passed over')
end)

t.test('Median: the AHledger median as it is', function()
	t.eq(evaluate(Rules.builtIns().median, MARKET).copper, 250)
end)

t.group('price steps')

local function unstackable(options)
	options.info = { maxStack = 1, vendorPrice = 200 }
	return options
end

t.test('undercut on a whole-silver item goes down a full silver', function()
	local price = evaluate(
		Rules.builtIns().minimum,
		unstackable({ levels = { { price = 300, qty = 1 }, { price = 300, qty = 9 } } })
	)
	t.eq(price.copper, 200)
	t.eq(price.step, 100)
	local snapEntries = {}
	for _, entry in ipairs(price.trace) do
		if entry.kind == 'snap' then
			snapEntries[#snapEntries + 1] = entry
		end
	end
	t.eq(#snapEntries, 1)
end)

t.test('copper seen in the scan allows copper on an unstackable item', function()
	local price = evaluate(
		Rules.builtIns().minimum,
		unstackable({ levels = { { price = 250, qty = 1 }, { price = 300, qty = 9 } } })
	)
	t.eq(price.copper, 299)
	t.eq(price.step, 1)
end)

t.test('stackable items keep copper', function()
	local price =
		evaluate(Rules.builtIns().minimum, { levels = { { price = 300, qty = 1 }, { price = 300, qty = 9 } } })
	t.eq(price.copper, 299)
end)

t.test('every rule result snaps down to the step', function()
	local price = evaluate(rule({ kind = 'median' }), unstackable({ row = { median = 2550, qty = 0 } }))
	t.eq(price.copper, 2500)
	local tiny = evaluate(rule({ kind = 'median' }), unstackable({ row = { median = 40, qty = 0 } }))
	t.eq(tiny.copper, 100, 'never under one silver')
end)

t.group('evaluate contract')

t.test('an invalid rule returns a reason; a bad call throws', function()
	local price, reason = Rules.evaluate({ id = 'x', name = 'X', base = { kind = 'median' } }, ITEM, context())
	t.eq(price, nil)
	t.eq(reason, 'invalid rule: steps must be a list')
	t.raises(function()
		Rules.evaluate(Rules.builtIns().median, 'linen', context())
	end, 'itemId')
	t.raises(function()
		Rules.evaluate(Rules.builtIns().median, ITEM, {})
	end, 'ctx needs now')
end)

t.test('a context with no sources fails cleanly', function()
	local price, reason = Rules.evaluate(Rules.builtIns().realistic, ITEM, { now = NOW })
	t.eq(price, nil)
	t.eq(reason, 'no listings')
end)

t.test('validate explains what is wrong', function()
	local function reasonFor(changes)
		local candidate = rule({ kind = 'median' })
		for key, value in pairs(changes) do
			candidate[key] = value
		end
		local _, reason = Rules.validate(candidate)
		return reason
	end
	t.eq(reasonFor({}), nil)
	t.eq(reasonFor({ id = '' }), 'rule needs an id')
	t.eq(reasonFor({ name = 5 }), 'rule needs a name')
	t.eq(
		reasonFor({ base = { kind = 'firstWithUnits', n = 0 } }),
		'base: firstWithUnits needs n, a positive whole number'
	)
	t.eq(
		reasonFor({ base = { kind = 'afterPercent', percent = 120 } }),
		'base: afterPercent needs percent from 0 to 100'
	)
	t.eq(
		reasonFor({ steps = { { kind = 'cap', percent = 0, base = { kind = 'median' } } } }),
		'step 1: cap needs a positive percent'
	)
	t.eq(reasonFor({ steps = { { kind = 'lower', base = { kind = 'nope' } } } }), 'step 1: base unknown kind "nope"')
	t.eq(reasonFor({ steps = { { kind = 'multiply', factor = -1 } } }), 'step 1: multiply needs a positive factor')
	t.eq(
		reasonFor({ steps = { { kind = 'undercut', copper = 1.5 } } }),
		'step 1: undercut needs whole copper, 0 or more'
	)
	t.eq(reasonFor({ steps = { { kind = 'round' } } }), 'step 1: unknown kind "round"')
	t.eq(reasonFor({ antiBait = { enabled = 'yes' } }), 'antiBait: needs enabled')
	t.eq(reasonFor({ antiBait = { enabled = true, minutes = -1 } }), 'antiBait: minutes must be 0 or more')
	t.eq(
		reasonFor({ antiBait = { enabled = true, gapPercent = 0 } }),
		'antiBait: gapPercent must be above 0 and at most 100'
	)
end)

t.group('review fixes')

t.test('junk-only scan levels fall back to AHledger instead of throwing', function()
	local junk = { { price = 0, qty = 5 }, { price = 300, qty = 0 } }
	for _, antiBait in ipairs({ { enabled = true }, { enabled = false } }) do
		for _, base in ipairs({
			{ kind = 'lowest' },
			{ kind = 'firstWithUnits', n = 5 },
			{ kind = 'afterPercent', percent = 10 },
		}) do
			local price = evaluate(rule(base, {}, antiBait), { row = ROW, levels = junk })
			t.eq(price.copper, 300, base.kind)
			t.eq(price.source, 'ahledger', base.kind)
		end
	end
	local price, reason = evaluate(rule({ kind = 'lowest' }), { levels = junk })
	t.eq(price, nil)
	t.eq(reason, 'no listings')
end)

t.test('a floor or higher bound on a whole-silver item snaps up, never under its bound', function()
	local silverItem = { levels = { { price = 300, qty = 9 } }, info = { maxStack = 1, vendorPrice = 250 } }
	local floorRule = rule({ kind = 'lowest' }, {
		{ kind = 'undercut', copper = 1 },
		{ kind = 'floor', percent = 100, base = { kind = 'vendor' } },
	})
	t.eq(evaluate(floorRule, silverItem).copper, 300, 'undercut to 2s 99c, floored at 2s 50c, is 3s')
	local higherRule = rule({ kind = 'lowest' }, {
		{ kind = 'undercut', copper = 100 },
		{ kind = 'higher', base = { kind = 'vendor' } },
	})
	t.eq(evaluate(higherRule, silverItem).copper, 300)
	local cappedAfter = rule({ kind = 'lowest' }, {
		{ kind = 'floor', percent = 100, base = { kind = 'vendor' } },
		{ kind = 'cap', percent = 100, base = { kind = 'median' } },
	})
	local capped = evaluate(cappedAfter, {
		row = { median = 220, qty = 1, sold = 100 },
		levels = { { price = 100, qty = 9 } },
		info = { maxStack = 1, vendorPrice = 250 },
	})
	t.eq(capped.copper, 300, 'the floor stays in force over a later, lower cap')
end)

t.test('Realistic depth covers an hour of sales when that is more than five units', function()
	local builtIn = Rules.builtIns().realistic
	t.eq(builtIn.base.n, 5)
	t.eq(builtIn.base.hours, 1)
	-- 2400 a day is 100 an hour; 17 bait units pass first.
	local price = evaluate(builtIn, {
		row = { median = 1000, qty = 170, sold = 2400 },
		levels = { { price = 100, qty = 20 }, { price = 150, qty = 50 }, { price = 200, qty = 100 } },
	})
	t.eq(price.copper, 199)
	local slow = evaluate(builtIn, {
		row = { median = 1000, qty = 170, sold = 24 },
		levels = { { price = 100, qty = 20 }, { price = 150, qty = 50 } },
	})
	t.eq(slow.copper, 99, 'one an hour: five units deep wins')
	local _, reason = Rules.validate(rule({ kind = 'firstWithUnits', n = 5, hours = -1 }))
	t.eq(reason, 'base: firstWithUnits hours must be 0 or more')
end)

t.test('cap and floor percents must be finite', function()
	local _, reason = Rules.validate(rule({ kind = 'median' }, {
		{ kind = 'cap', percent = math.huge, base = { kind = 'median' } },
	}))
	t.eq(reason, 'step 1: cap needs a positive percent')
end)

t.test('afterPercent 100 reads the dearest level without a thin-listing note', function()
	local price = evaluate(
		rule({ kind = 'afterPercent', percent = 100 }),
		{ levels = { { price = 100, qty = 10 }, { price = 300, qty = 80 } } }
	)
	t.eq(price.copper, 300)
	for _, entry in ipairs(price.trace) do
		t.eq(entry.label:find('too thin'), nil, entry.label)
	end
end)

t.test('an unknown max stack prices in whole silver until the item info arrives', function()
	local price = evaluate(rule({ kind = 'median' }), { row = { median = 255, qty = 1, sold = 100 }, info = {} })
	t.eq(price.copper, 200)
	t.eq(price.step, 100)
end)

t.group('confidence')

local function reasonText(price, code)
	for _, reason in ipairs(price.confidence.reasons) do
		if reason.code == code then
			return reason.text
		end
	end
	return nil
end

local function reasonLevel(price, code)
	for _, reason in ipairs(price.confidence.reasons) do
		if reason.code == code then
			return reason.level
		end
	end
	return nil
end

-- A healthy market: fresh data, plenty of sales and listings, known max stack.
local function healthy(overrides)
	local options = {
		row = { median = 500, min = 300, qty = 200, sold = 1440 },
		levels = { { price = 300, qty = 200 } },
		updated = NOW - 3600,
		scannedAt = NOW - 60,
	}
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end
	return options
end

local LOWEST = rule({ kind = 'lowest' }, {}, { enabled = true, minutes = 10 })

t.test('a healthy market is high confidence with no reasons', function()
	local price = evaluate(LOWEST, healthy())
	t.same(price.confidence, { level = 'high', reasons = {} })
end)

t.test('stale data lowers confidence by the age thresholds', function()
	local dayOld = evaluate(rule({ kind = 'median' }), healthy({ updated = NOW - 30 * 3600 }))
	t.eq(dayOld.confidence.level, 'medium')
	t.eq(reasonLevel(dayOld, 'stale'), 'medium')
	local weekOld = evaluate(rule({ kind = 'median' }), healthy({ updated = NOW - 7 * 86400 }))
	t.eq(reasonLevel(weekOld, 'stale'), 'low')
	local ctx = context(healthy({ updated = NOW - 3 * 3600 }))
	ctx.confidence = { staleMediumHours = 2, staleLowHours = 48 }
	t.eq(
		reasonLevel(Rules.evaluate(rule({ kind = 'median' }), ITEM, ctx), 'stale'),
		'medium',
		'thresholds come from ctx'
	)
	t.eq(Rules.confidenceSettings()[1].key, 'staleMediumHours')
end)

t.test('few or unknown sales lower confidence', function()
	local slow = evaluate(LOWEST, healthy({ row = { median = 500, qty = 200, sold = 0.5 } }))
	t.eq(reasonLevel(slow, 'fewSales'), 'low')
	local some = evaluate(LOWEST, healthy({ row = { median = 500, qty = 200, sold = 3 } }))
	t.eq(reasonLevel(some, 'fewSales'), 'medium')
	local unknown = evaluate(LOWEST, healthy({ row = { median = 500, qty = 200 } }))
	t.eq(reasonLevel(unknown, 'fewSales'), 'medium')
	local vendor = evaluate(rule({ kind = 'vendor' }), healthy({ row = { median = 500, qty = 200, sold = 0.5 } }))
	t.eq(reasonLevel(vendor, 'fewSales'), nil, 'sales do not matter to a vendor price')
end)

t.test('few listings lower confidence', function()
	local thin = evaluate(LOWEST, healthy({ levels = { { price = 300, qty = 1 }, { price = 320, qty = 2 } } }))
	t.eq(reasonLevel(thin, 'fewListings'), 'medium')
	local shallow = evaluate(rule({ kind = 'firstWithUnits', n = 500 }), healthy())
	t.eq(reasonLevel(shallow, 'fewListings'), 'medium')
end)

t.test('the AHledger fallback base lowers confidence', function()
	local price = evaluate(LOWEST, healthy({ levels = false }))
	t.eq(price.source, 'ahledger')
	t.eq(reasonLevel(price, 'fallbackBase'), 'medium')
	t.eq(reasonText(price, 'fallbackBase'), "no scan depth, so this is AHledger's lowest buyout and not bait-checked")
end)

t.test('an inferred price step lowers confidence', function()
	local price = evaluate(rule({ kind = 'median' }), healthy({ info = {} }))
	t.eq(reasonLevel(price, 'inferredStep'), 'medium')
	t.eq(reasonText(price, 'inferredStep'), 'max stack unknown, so whole silver is assumed')
	local copperSeen = evaluate(LOWEST, healthy({ info = {}, levels = { { price = 301, qty = 200 } } }))
	t.eq(reasonLevel(copperSeen, 'inferredStep'), nil, 'copper in the scan settles the step')
end)

t.test('anti-bait trimming most of the listing lowers confidence', function()
	local most = evaluate(LOWEST, healthy({ levels = { { price = 100, qty = 8 }, { price = 300, qty = 6 } } }))
	t.eq(reasonLevel(most, 'baitTrimmed'), 'medium')
	local all = evaluate(LOWEST, healthy({ levels = { { price = 100, qty = 3 }, { price = 300, qty = 4 } } }))
	t.eq(reasonLevel(all, 'baitTrimmed'), 'low')
end)

t.test('the weakest reason sets the level, and the trace says why', function()
	local price = evaluate(LOWEST, healthy({ levels = false, row = { min = 300, qty = 200, sold = 0.5 } }))
	t.eq(reasonLevel(price, 'fallbackBase'), 'medium')
	t.eq(reasonLevel(price, 'fewSales'), 'low')
	t.eq(price.confidence.level, 'low')
	local traced = 0
	for _, entry in ipairs(price.trace) do
		if entry.kind == 'confidence' then
			traced = traced + 1
		end
	end
	t.eq(traced, #price.confidence.reasons)
	t.eq(Rules.weakestLevel({ 'high', 'medium', 'high' }), 'medium')
	t.eq(Rules.weakestLevel({}), 'high')
end)

t.group('second review round')

local JUNK_LEVEL_SETS = {
	{ name = 'bid-only level', levels = { { qty = 3 } } },
	{ name = 'non-table level', levels = { 5 } },
	{ name = 'string price', levels = { { price = '299', qty = 3 } } },
	{ name = 'non-numeric string price', levels = { { price = 'abc', qty = 3 } } },
	{ name = 'levels not a table', levels = 'levels' },
}

local LEVEL_READING_BASES = {
	{ kind = 'lowest' },
	{ kind = 'firstWithUnits', n = 5 },
	{ kind = 'afterPercent', percent = 50 },
	{ kind = 'median' },
}

local function junkScanContext(levels, min)
	local ctx = context({ row = ROW, levels = false })
	ctx.scanItem = function()
		return { levels = levels, min = min }, NOW - 60
	end
	return ctx
end

t.test('junk scan levels never throw, for every base that reads them', function()
	for _, junk in ipairs(JUNK_LEVEL_SETS) do
		for _, base in ipairs(LEVEL_READING_BASES) do
			local label = junk.name .. ' / ' .. base.kind
			local ok, price = pcall(Rules.evaluate, rule(base), ITEM, junkScanContext(junk.levels, 'x'))
			t.eq(ok, true, label .. ': ' .. tostring(price))
			t.eq(type(ok and price and price.copper), 'number', label)
		end
	end
end)

t.test('a scan entry that is not a table is ignored', function()
	local ctx = context({ row = ROW, levels = false })
	ctx.scanItem = function()
		return 42, NOW - 60
	end
	local ok, price = pcall(Rules.evaluate, rule({ kind = 'lowest' }), ITEM, ctx)
	t.eq(ok, true, tostring(price))
	t.eq(price.source, 'ahledger')
end)

t.test('junk levels do not count as copper seen', function()
	local silverInfo = context({ row = ROW, levels = false, info = { maxStack = 1 } })
	silverInfo.scanItem = function()
		return { levels = { { price = '299', qty = 3 }, { price = 400, qty = 9 } } }, NOW - 60
	end
	t.eq(Rules.evaluate(rule({ kind = 'lowest' }), ITEM, silverInfo).step, 100)
end)

t.test('a floor that snaps past a looser cap wins, and says so', function()
	local price = evaluate(
		rule({ kind = 'lowest' }, {
			{ kind = 'floor', percent = 100, base = { kind = 'vendor' } },
			{ kind = 'cap', percent = 100, base = { kind = 'median' } },
		}),
		{
			row = { median = 280, qty = 100, sold = 1440 },
			levels = { { price = 100, qty = 9 } },
			info = { maxStack = 1, vendorPrice = 250 },
		}
	)
	t.eq(price.copper, 300, 'no silver price between 2s 50c and 2s 80c')
	t.eq(reasonLevel(price, 'capOverridden'), 'medium')
	local isTraced = false
	for _, entry in ipairs(price.trace) do
		if entry.kind == 'override' and entry.label:find('cap overridden by the price step') then
			isTraced = true
		end
	end
	t.eq(isTraced, true, 'trace notes the override')
end)

t.test('a floor stays in force: a later undercut clamps at the snapped floor', function()
	local floorThenUndercut = rule({ kind = 'lowest' }, {
		{ kind = 'floor', percent = 100, base = { kind = 'vendor' } },
		{ kind = 'undercut', copper = 100 },
	})
	local copperItem = evaluate(floorThenUndercut, {
		levels = { { price = 300, qty = 9 } },
		info = { maxStack = 20, vendorPrice = 250 },
	})
	t.eq(copperItem.copper, 250)
	local silverItem = evaluate(floorThenUndercut, {
		levels = { { price = 300, qty = 9 } },
		info = { maxStack = 1, vendorPrice = 250 },
	})
	t.eq(silverItem.copper, 300)
	t.eq(reasonLevel(copperItem, 'capOverridden'), nil, 'no cap, no override')
end)

t.test('a level with a non-finite quantity or price is junk', function()
	local price = evaluate(rule({ kind = 'lowest' }, {}, { enabled = true, minutes = 10 }), {
		row = ROW,
		levels = {
			{ price = 100, qty = math.huge },
			{ price = 150, qty = 0 / 0 },
			{ price = math.huge, qty = 5 },
			{ price = 200, qty = 50 },
		},
	})
	t.eq(price.copper, 200)
	local isNumber = true
	for _, reason in ipairs(price.confidence.reasons) do
		isNumber = isNumber and reason.text:find('nan') == nil and reason.text:find('inf') == nil
	end
	t.eq(isNumber, true)
	t.eq(
		Rules.passOverBait({ { price = 100, qty = math.huge }, { price = 200, qty = 5 } }, { enabled = false }, 0)[1].price,
		200
	)
end)

t.group('rules: inputs from other sources')

-- Step 1 review: a string or non-finite value from another module threw inside Rules (the
-- sales comparison and the craft cost / realized check). They are unknown, with a reason.
local function hasReason(price, code)
	for _, reason in ipairs(price.confidence.reasons) do
		if reason.code == code then
			return true
		end
	end
	return false
end

t.test('a string sold figure is unknown sales, not an error', function()
	local row = { median = 500, min = 300, sold = '12' }
	local price = evaluate(rule({ kind = 'median' }), { row = row, levels = false })
	t.eq(price.copper, 500)
	t.truthy(hasReason(price, 'badInput'), 'badInput reason')
	t.truthy(hasReason(price, 'fewSales'), 'sales treated as unknown')
end)

t.test('a non-finite sold figure is unknown sales', function()
	local row = { median = 500, sold = 0 / 0 }
	local price = evaluate(rule({ kind = 'median' }), { row = row, levels = false })
	t.truthy(hasReason(price, 'badInput'), 'NaN sold flagged')
end)

t.test('a string or non-finite craft cost or realized price is no base', function()
	for _, bad in ipairs({ '500', math.huge, 0 / 0, {} }) do
		local price, reason = evaluate(rule({ kind = 'craftCost' }), { craftCost = bad, levels = false })
		t.eq(price, nil, 'craftCost ' .. tostring(bad))
		t.truthy(reason:find('not a number'), 'reason says why: ' .. tostring(reason))
		price, reason = evaluate(rule({ kind = 'realized' }), { realized = bad, levels = false })
		t.eq(price, nil, 'realized ' .. tostring(bad))
		t.truthy(reason:find('not a number'), 'reason says why: ' .. tostring(reason))
	end
end)

t.test('a junk AHledger field is no base; a junk min is no fallback', function()
	local price, reason = evaluate(rule({ kind = 'median' }), { row = { median = '500', sold = 10 }, levels = false })
	t.eq(price, nil)
	t.truthy(reason:find('not a number'), tostring(reason))
	price, reason = evaluate(rule({ kind = 'lowest' }), { row = { min = math.huge, sold = 10 }, levels = false })
	t.eq(price, nil)
	t.truthy(reason:find('not a number'), tostring(reason))
end)

t.test('a step whose base is junk is skipped with the reason; the rule still prices', function()
	local price = evaluate(
		rule({ kind = 'median' }, { { kind = 'floor', percent = 100, base = { kind = 'craftCost' } } }),
		{ row = ROW, levels = false, craftCost = 'lots' }
	)
	t.eq(price.copper, 500)
	t.truthy(hasReason(price, 'badInput'), 'badInput reason from the skipped step')
end)

t.test('a string vendor price is no vendor base', function()
	local price, reason = evaluate(rule({ kind = 'vendor' }), { info = { maxStack = 20, vendorPrice = '13' } })
	t.eq(price, nil)
	t.truthy(reason:find('not a number'), tostring(reason))
end)

t.test('a source that throws is no data, not an error', function()
	local ctx = context({ row = ROW, levels = false })
	ctx.craftCost = function()
		error('boom')
	end
	local price = Rules.evaluate(
		rule({ kind = 'median' }, { { kind = 'floor', percent = 100, base = { kind = 'craftCost' } } }),
		ITEM,
		ctx
	)
	t.eq(price.copper, 500)
	t.truthy(hasReason(price, 'badInput'), 'failing source flagged')
end)
