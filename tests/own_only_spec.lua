local t = ...
local ns = t.loadAddon()
local Ledger, OwnOnly, CostPool, Ventures, Store = ns.Ledger, ns.OwnOnly, ns.CostPool, ns.Ventures, ns.Store

local DAY = 86400
local NOW = 200 * DAY
local MARKET_ID = 'forever/normal/alliance/us'
local CHAR = 'Me-Realm'

-- A version-2 market as Books left it: venture estimates, leftover values and craft, writeOff,
-- toStock and traded-stack copper that came from rule quotes.
local function legacyMarket()
	local market = { ledger = {}, ledgerDays = {}, auctions = {}, costPools = {}, ventures = {}, scanDays = {} }
	local function line(itemId, recipeId, crafted, planned)
		return {
			recipeId = recipeId,
			itemId = itemId,
			perCraft = 1,
			plannedCrafts = planned,
			planned = planned,
			crafted = crafted,
			posted = 0,
			sold = 0,
			returned = 0,
		}
	end
	local function totals(leftoverCopper)
		return {
			gross = 0,
			cut = 0,
			depositPaid = 0,
			depositRefunded = 0,
			trollUnits = 0,
			leftoverCopper = leftoverCopper,
		}
	end
	market.ventures[1] = {
		id = 1,
		name = 'Paid, to stock',
		valuation = 'paid',
		status = 'closed',
		leftoverAction = 'toStock',
		createdAt = 1,
		lines = { line(900, 100, 2, 2) },
		materials = {
			[10] = { need = 4, bought = 4, boughtCopper = 400, used = 4, knownCopper = 400, estimatedCopper = 0 },
			[11] = { need = 2, bought = 0, boughtCopper = 0, used = 2, knownCopper = 0, estimatedCopper = 200 },
		},
		totals = totals(1000),
	}
	market.ventures[2] = {
		id = 2,
		name = 'Opportunity, written off',
		valuation = 'opportunity',
		status = 'closed',
		leftoverAction = 'writeOff',
		createdAt = 2,
		lines = { line(901, 101, 3, 3) },
		materials = {
			[12] = { need = 3, bought = 5, boughtCopper = 50, used = 3, knownCopper = 0, estimatedCopper = 300 },
		},
		totals = totals(0),
	}
	market.ventures[3] = {
		id = 3,
		name = 'Paid, all known',
		valuation = 'paid',
		status = 'crafting',
		createdAt = 3,
		lines = { line(902, 102, 1, 2) },
		materials = {
			[13] = { need = 4, bought = 2, boughtCopper = 70, used = 2, knownCopper = 70, estimatedCopper = 0 },
		},
		totals = totals(0),
	}
	market.ventures[4] = {
		id = 4,
		name = 'Paid, mixed',
		valuation = 'paid',
		status = 'crafting',
		createdAt = 4,
		lines = { line(903, 103, 0, 1) },
		materials = {
			[16] = { need = 3, bought = 0, boughtCopper = 0, used = 3, knownCopper = 50, estimatedCopper = 30 },
		},
		totals = totals(0),
	}
	-- Quotes below the cash part are as derived as quotes above it.
	market.ventures[5] = {
		id = 5,
		name = 'Opportunity, quote below cash',
		valuation = 'opportunity',
		status = 'closed',
		leftoverAction = 'writeOff',
		createdAt = 5,
		lines = { line(904, 104, 0, 1) },
		materials = {
			[18] = { need = 4, bought = 10, boughtCopper = 1000, used = 4, knownCopper = 0, estimatedCopper = 320 },
		},
		totals = totals(0),
	}
	market.ventures[6] = {
		id = 6,
		name = 'Paid, to stock below cash',
		valuation = 'paid',
		status = 'closed',
		leftoverAction = 'toStock',
		createdAt = 6,
		lines = { line(905, 105, 3, 3) },
		materials = {
			[19] = { need = 3, bought = 3, boughtCopper = 900, used = 3, knownCopper = 900, estimatedCopper = 0 },
		},
		totals = totals(300),
	}
	-- Version 2 estimated an unpriced unit at 0: no estimate does not mean every unit was known.
	market.ventures[7] = {
		id = 7,
		name = 'Paid, unpriced units',
		valuation = 'paid',
		status = 'crafting',
		createdAt = 7,
		lines = { line(906, 106, 0, 1) },
		materials = {
			[17] = { need = 10, bought = 0, boughtCopper = 0, used = 10, knownCopper = 500, estimatedCopper = 0 },
		},
		totals = totals(0),
	}
	local function event(fields)
		fields.char = fields.char or CHAR
		fields.t = fields.t or NOW - DAY
		Ledger.append(market, fields)
	end
	event({ kind = 'craft', itemId = 900, qty = 2, copper = 600, ventureId = 1 })
	event({ kind = 'toStock', itemId = 900, qty = 2, copper = 1000, ventureId = 1 })
	event({ kind = 'craft', itemId = 901, qty = 1, copper = 100, ventureId = 2 })
	event({ kind = 'craft', itemId = 901, qty = 2, copper = 200, ventureId = 2 })
	event({ kind = 'writeOff', itemId = 901, qty = 3, copper = 900, ventureId = 2 })
	event({ kind = 'writeOff', itemId = 12, qty = 2, copper = 40, ventureId = 2 })
	event({ kind = 'craft', itemId = 902, qty = 1, copper = 70, ventureId = 3 })
	event({ kind = 'craft', itemId = 904, qty = 1, copper = 55 })
	event({ kind = 'tradeIn', itemId = 2589, qty = 5, copper = 500 })
	event({ kind = 'tradeOut', copper = 900 })
	event({ kind = 'sale', itemId = 900, qty = 1, copper = 1000, isTroll = true })
	event({ kind = 'buy', itemId = 10, qty = 4, copper = 400, t = NOW - 10 * DAY })
	event({ kind = 'vendorBuy', itemId = 14, qty = 10, copper = 100, t = NOW - 100 * DAY })
	event({ kind = 'buy', itemId = 14, qty = 5, copper = 75, t = NOW - 5 * DAY })
	event({ kind = 'destroy', itemId = 900, qty = 1, copper = 500 })
	event({ kind = 'destroy', itemId = 10, qty = 1, copper = 100 })
	event({ kind = 'writeOff', itemId = 18, qty = 6, copper = 480, ventureId = 5 })
	event({ kind = 'toStock', itemId = 905, qty = 3, copper = 300, ventureId = 6 })
	market.costPools = { [10] = { 2, 200 }, [14] = { 12, 150 }, [900] = { 2, 1000 }, [15] = { 3, 30 } }
	market.ledgerDays[100] = {
		craft = { 2, 3, 999 },
		writeOff = { 1, 1, 10 },
		toStock = { 1, 2, 800 },
		tradeInItems = { 1, 5, 300 },
		tradeIn = { 1, 0, 50 },
		sale = { 1, 1, 500 },
		destroy = { 1, 1, 20 },
	}
	market.auctions[77] = { auctionId = 77, itemId = 900, qty = 1, knownUnits = 1, knownCopper = 500 }
	market.auctions[78] = { auctionId = 78, itemId = 10, qty = 1, knownUnits = 1, knownCopper = 100 }
	return market
end

local function migrated()
	local market = legacyMarket()
	OwnOnly.migrateMarket(market, NOW)
	return market
end

local function eventsOf(market, kind)
	return Ledger.events(market, { kind = kind })
end

local function deepCopy(value)
	if type(value) ~= 'table' then
		return value
	end
	local copy = {}
	for key, inner in pairs(value) do
		copy[key] = deepCopy(inner)
	end
	return copy
end

-- Every number stored anywhere under value, with its path.
local function collectNumbers(value, path, found)
	found = found or {}
	if type(value) == 'number' then
		found[#found + 1] = { path = path, value = value }
	elseif type(value) == 'table' then
		for key, inner in pairs(value) do
			collectNumbers(inner, path .. '.' .. tostring(key), found)
		end
	end
	return found
end

-- Every key stored anywhere under value.
local function hasKey(value, wanted)
	if type(value) ~= 'table' then
		return false
	end
	for key, inner in pairs(value) do
		if key == wanted or hasKey(inner, wanted) then
			return true
		end
	end
	return false
end

t.group('own-only migration')

t.test('the store migrates version 2 to 3 with the time it is given', function()
	t.eq(Store.SCHEMA_VERSION, 3)
	local db = { version = 2, markets = { [MARKET_ID] = legacyMarket() } }
	local store = assert(Store.open(db, {}, { now = NOW }))
	t.eq(db.version, 3)
	local market = store:Market(MARKET_ID)
	t.same(CostPool.get(market, 10), { units = 2, copper = 200 })
	t.eq(market.ventures[1].totals.leftoverCopper, nil)
end)

t.test('step 1: shares taken from tainted pools (crafted leftovers moved to stock) are reset', function()
	local market = migrated()
	t.eq(market.auctions[77].knownUnits, 0)
	t.eq(market.auctions[77].knownCopper, 0)
	t.eq(market.auctions[78].knownCopper, 100, 'an auction of a bought item keeps its share')
	local destroyed = eventsOf(market, 'destroy')
	t.eq(destroyed[1].copper, 0)
	t.eq(destroyed[1].valueDropped, true)
	t.eq(destroyed[2].copper, 100)
	t.eq(destroyed[2].valueDropped, nil)
end)

t.test('step 2: craft events keep the cash part the venture gives, or lose their copper', function()
	local crafts = eventsOf(migrated(), 'craft')
	t.eq(crafts[1].copper, 400, 'the only craft of a paid venture: its known copper')
	t.eq(crafts[1].valueDropped, true)
	t.eq(crafts[2].copper, 0, 'one of several crafts with estimates: not splittable')
	t.eq(crafts[2].valueDropped, true)
	t.eq(crafts[3].copper, 0)
	t.eq(crafts[4].copper, 70, 'a venture that estimated nothing: all cash')
	t.eq(crafts[4].valueDropped, nil)
	t.eq(crafts[5].copper, 0, 'no venture: no cash part known')
	t.eq(crafts[5].valueDropped, true)
end)

t.test('step 2: writeOff and toStock events keep their cash cost', function()
	local market = migrated()
	local toStock = eventsOf(market, 'toStock')[1]
	t.eq(toStock.copper, 400, 'crafted units of a paid venture: their share of the known copper')
	t.eq(toStock.valueDropped, true)
	local writeOffs = eventsOf(market, 'writeOff')
	t.eq(writeOffs[1].copper, 0, 'crafted units of an opportunity venture: nothing paid recorded')
	t.eq(writeOffs[1].valueDropped, true)
	t.eq(writeOffs[2].copper, 20, 'unused materials: what was paid for them')
	t.eq(writeOffs[2].valueDropped, true)
	t.eq(writeOffs[3].copper, 600, 'a quote below cash: raised to what was paid')
	t.eq(writeOffs[3].valueDropped, true)
	local below = eventsOf(market, 'toStock')[2]
	t.eq(below.copper, 900, 'crafted units moved to stock under their cost: their known copper')
	t.eq(below.valueDropped, true)
end)

t.test('step 2: traded stacks lose their value; money kinds stay', function()
	local market = migrated()
	local tradeIn = eventsOf(market, 'tradeIn')[1]
	t.eq(tradeIn.copper, 0)
	t.eq(tradeIn.valueDropped, true)
	t.eq(eventsOf(market, 'tradeOut')[1].copper, 900, 'gold traded is cash')
	local sale = eventsOf(market, 'sale')[1]
	t.eq(sale.copper, 1000)
	t.eq(sale.isTroll, true, 'the troll flag survives the rewrite')
	t.eq(sale.valueDropped, nil)
	t.eq(#eventsOf(market, 'buy'), 2)
	t.eq(eventsOf(market, 'vendorBuy')[1].copper, 100)
end)

t.test('step 3: ventures drop their estimates; known units are restored where certain', function()
	local market = migrated()
	for _, venture in pairs(market.ventures) do
		t.eq(venture.totals.leftoverCopper, nil)
		for _, material in pairs(venture.materials) do
			t.eq(material.estimatedCopper, nil)
		end
	end
	t.eq(market.ventures[1].materials[10].knownUnits, 4, 'all known')
	t.eq(market.ventures[1].materials[11].knownUnits, 0, 'nothing known')
	t.eq(market.ventures[3].materials[13].knownUnits, 2)
	t.eq(market.ventures[4].materials[16].knownUnits, nil, 'a mixed split is lost')
	t.eq(market.ventures[4].materials[16].knownCopper, 50, 'the known copper stays')
	t.eq(market.ventures[7].materials[17].knownUnits, nil, 'no estimate, fewer units bought than used: lost')
	t.eq(market.ventures[6].materials[19].knownUnits, 3, 'no estimate, every unit bought: all known')
end)

t.v2test('step 3: estimates are read live; a lost split reads as incomplete', function()
	local market = migrated()
	local function valueOf(_, qty)
		return 7 * qty
	end
	local stocked = Ventures.profit(market.ventures[1], valueOf)
	t.eq(stocked.knownCopper, 400)
	t.eq(stocked.estimatedCopper, 2 * 7, 'item 11 valued now')
	t.eq(stocked.leftoverEstimate, 2 * 7, 'the crafted leftovers valued now')
	t.eq(stocked.isEstimateComplete, true)
	local mixed = Ventures.profit(market.ventures[4], valueOf)
	t.eq(mixed.knownCopper, 50)
	t.eq(mixed.estimatedCopper, 0)
	t.eq(mixed.isEstimateComplete, false)
	t.eq(mixed.isSplitLost, true)
	t.eq(mixed.hasUnpricedUnits, false, 'a lost split is not a missing price')
	local unpriced = Ventures.profit(market.ventures[3], function() end)
	t.eq(unpriced.isSplitLost, false)
	t.eq(unpriced.hasUnpricedUnits, false, 'every unit known: nothing to price')
	local stockedUnpriced = Ventures.profit(market.ventures[1], function() end)
	t.eq(stockedUnpriced.hasUnpricedUnits, true)
	t.eq(stockedUnpriced.isSplitLost, false)
end)

t.test('step 4: day summaries lose copper for the value kinds, keep count and qty', function()
	local day = migrated().ledgerDays[100]
	t.same(day.craft, { 2, 3, 0 })
	t.same(day.writeOff, { 1, 1, 0 })
	t.same(day.toStock, { 1, 2, 0 })
	t.same(day.tradeInItems, { 1, 5, 0 })
	t.same(day.tradeIn, { 1, 0, 50 }, 'gold traded stays')
	t.same(day.sale, { 1, 1, 500 }, 'money kinds stay')
end)

t.test('step 5: cost pools are rebuilt from buys in the window; older amounts are unknown', function()
	local market = migrated()
	t.same(CostPool.get(market, 10), { units = 2, copper = 200 }, 'never more units than the pool held')
	t.same(CostPool.get(market, 14), { units = 5, copper = 75 }, 'the buy 100 days ago is out of the window')
	t.eq(CostPool.get(market, 900), nil, 'a crafted leftover at its value: gone')
	t.eq(CostPool.get(market, 15), nil, 'no buy in the window: unknown origin')
end)

t.test('without a time the window ends at the newest event', function()
	local market = legacyMarket()
	OwnOnly.migrateMarket(market)
	t.same(CostPool.get(market, 14), { units = 5, copper = 75 })
end)

t.test('the migration is idempotent', function()
	local db = { version = 2, markets = { [MARKET_ID] = legacyMarket() } }
	OwnOnly.migrate(db, { now = NOW })
	local once = deepCopy(db)
	OwnOnly.migrate(db, { now = NOW })
	t.same(db, once)
end)

t.test('junk markets, ventures and tuples are left alone', function()
	local db = {
		markets = {
			junk = 'x',
			[MARKET_ID] = { ledger = { 'junk', { 1, 'nope' } }, ventures = { [1] = 'x' }, costPools = { [5] = 'x' } },
		},
	}
	OwnOnly.migrate(db, { now = NOW })
	t.eq(db.markets.junk, 'x')
	t.eq(db.markets[MARKET_ID].ledger[1], 'junk')
	t.eq(db.markets[MARKET_ID].ventures[1], 'x')
	t.same(db.markets[MARKET_ID].costPools, {})
	OwnOnly.migrate({}, nil)
end)

t.group('own-only persistence')

-- A per-unit price no cash amount in these specs comes near: any stored number this large
-- came from a price source.
local SOURCE_UNIT = 1000000007

local function sourceValueOf(_, qty)
	return SOURCE_UNIT * qty
end

local function assertNothingDerived(db)
	for _, found in ipairs(collectNumbers(db, 'db')) do
		if found.value >= SOURCE_UNIT then
			error(string.format('%s holds %d, a price-source value', found.path, found.value), 2)
		end
	end
	t.eq(hasKey(db, 'estimatedCopper'), false, 'estimatedCopper stored')
	t.eq(hasKey(db, 'leftoverCopper'), false, 'leftoverCopper stored')
end

t.v2test('nothing Books, Ventures or the ledger store is derived from a price source', function()
	local db = { version = Store.SCHEMA_VERSION, markets = {} }
	local store = assert(Store.open(db, {}, { now = NOW }))
	local market = store:Market(MARKET_ID)
	local held, clock = {}, { now = NOW }
	local books = ns.Books.new({
		market = function()
			return market
		end,
		char = function()
			return CHAR
		end,
		now = function()
			return clock.now
		end,
		held = function(itemId)
			return held[itemId] or 0
		end,
		vendorPrice = function()
			return 1
		end,
		-- Books takes no valueOf any more; one passed by an old caller must be ignored.
		valueOf = sourceValueOf,
	})
	local recipe = {
		recipeId = 100,
		itemId = 900,
		perCraft = 1,
		reagents = { { itemId = 10, qty = 2 }, { itemId = 11, qty = 1 } },
	}
	for _, valuation in ipairs({ 'paid', 'opportunity' }) do
		local venture = books:PlanCrafts(nil, recipe, 3, { valuation = valuation, ruleId = 'realistic' })
		books:OnVendorBuy({ itemId = 10, qty = 4, copper = 40 })
		held[11] = 5 -- of unknown origin
		books:OnCraft({ recipeId = 100, outputItemId = 900, made = 1, reagents = recipe.reagents })
		books:OnCraft({ recipeId = 100, outputItemId = 900, made = 1, reagents = recipe.reagents })
		books:OnPost({ itemId = 900, qty = 1, unitPrice = 500, hours = 12, deposit = 5 })
		books:OnAuctionCreated(valuation == 'paid' and 1 or 2)
		books:OnSaleMail({ itemId = 900, qty = 1, bid = 500, deposit = 5, cut = 25 })
		Ventures.profit(venture, sourceValueOf)
		Ventures.forecast(venture, {
			valueOf = sourceValueOf,
			costOf = function()
				return SOURCE_UNIT
			end,
			salesPerDay = function()
				return 2
			end,
		})
		books:CloseVenture(venture.id, valuation == 'paid' and 'toStock' or 'writeOff')
		books:OnDestroy({ itemId = 900, qty = 1, held = 1 })
	end
	local stack = { itemId = 2589, qty = 5, value = { copper = 5 * SOURCE_UNIT } }
	local trade = {
		player = { gold = 0, items = { stack } },
		target = { gold = 100, items = { { itemId = 2590, qty = 1, value = { copper = SOURCE_UNIT } } } },
	}
	Ledger.appendAll(market, Ledger.tradeEvents(trade, NOW, CHAR))
	clock.now = NOW + 400 * DAY
	books:Maintain()
	t.truthy(next(market.ledgerDays), 'the events were folded into summaries too')
	assertNothingDerived(db)
end)

t.test('a migrated version-2 market keeps nothing derived', function()
	local db = { version = 2, markets = { [MARKET_ID] = legacyMarket() } }
	assert(Store.open(db, {}, { now = NOW }))
	t.eq(hasKey(db, 'estimatedCopper'), false)
	t.eq(hasKey(db, 'leftoverCopper'), false)
	local market = db.markets[MARKET_ID]
	for _, event in ipairs(Ledger.events(market)) do
		if Ledger.OWN_VALUE_KINDS[event.kind] or (event.kind == 'tradeIn' and event.itemId) then
			t.truthy(event.copper == 0 or event.valueDropped or event.kind == 'craft', 'value kind kept a value')
		end
	end
end)

-- The cash part each value-kind event must carry after the migration, worked out by hand from
-- the fixture: what the venture paid, or 0 where that cannot be known.
local EXPECTED_CASH = {
	craft = { 400, 0, 0, 70, 0 },
	writeOff = { 0, 20, 600 },
	toStock = { 400, 900 },
	tradeIn = { 0 },
}

t.test('every value-kind event carries exactly its cash part, flagged when it changed', function()
	local before = legacyMarket()
	local after = migrated()
	for kind, expected in pairs(EXPECTED_CASH) do
		local old, new = eventsOf(before, kind), eventsOf(after, kind)
		t.eq(#new, #expected, kind .. ' events')
		for index, cash in ipairs(expected) do
			local what = string.format('%s %d', kind, index)
			t.eq(new[index].copper, cash, what)
			t.eq(new[index].valueDropped == true, old[index].copper ~= cash, what .. ' flagged')
		end
	end
end)

t.test('cashCost reads a junk material as nothing paid', function()
	local venture = {
		lines = {},
		materials = { [1] = { need = 1, used = 1 }, [2] = { need = 1, bought = 2, used = 1 } },
	}
	t.eq(Ventures.cashCost(venture, { kind = 'material', itemId = 1, qty = 1 }), 0)
	t.eq(Ventures.cashCost(venture, { kind = 'material', itemId = 2, qty = 1 }), 0)
end)

t.test('cashCost reads a junk crafted line as nothing crafted', function()
	local venture = {
		lines = { { itemId = 900 }, 'junk', { itemId = 901, crafted = 2 } },
		materials = { [10] = { need = 1, used = 1, knownCopper = 100 } },
	}
	t.eq(Ventures.cashCost(venture, { kind = 'crafted', itemId = 901, qty = 1 }), 50)
	venture.lines = { { itemId = 900 } }
	t.eq(Ventures.cashCost(venture, { kind = 'crafted', itemId = 900, qty = 1 }), 0)
end)

t.test('the migration survives a closed venture whose line lost its crafted count', function()
	local market = legacyMarket()
	market.ventures[6].lines[1].crafted = nil
	OwnOnly.migrateMarket(market, NOW)
	t.eq(eventsOf(market, 'toStock')[2].copper, 0)
end)

t.group('own-only boundary: quotes carry their inputs')

local ITEM = 2589
local ROW = { median = 500, min = 300, qty = 100, sold = 48 }
-- Own scan depth when there is one, else AHledger's lowest buyout: own or AHledger by the data.
local MIXED_RULE = {
	id = 'mixed',
	name = 'Mixed',
	base = { kind = 'firstWithUnits', n = 5, hours = 1 },
	steps = {},
	antiBait = { enabled = false },
}

local function quoteContext(options)
	return {
		now = NOW,
		priceRow = function()
			return options.row, NOW - 3600
		end,
		scanItem = function()
			if options.levels then
				return { levels = options.levels }, NOW - 60
			end
		end,
		itemInfo = function()
			return { maxStack = 20, vendorPrice = 13 }
		end,
		sales = options.sales and function()
			return options.sales
		end,
	}
end

t.test('a mixed rule reports the input it actually used', function()
	local levels = { { price = 290, qty = 10 } }
	local own = ns.Rules.evaluate(
		MIXED_RULE,
		ITEM,
		quoteContext({ levels = levels, sales = { perDay = 24, source = 'own', reasons = {} } })
	)
	t.same(own.inputs, { scan = true, ownSales = true })
	t.eq(own.usesPriceSource, false)
	local fallback = ns.Rules.evaluate(MIXED_RULE, ITEM, quoteContext({ row = ROW }))
	t.eq(fallback.copper, 300)
	t.same(fallback.inputs, { ahledger = true })
	t.eq(fallback.usesPriceSource, true)
	local mixed = ns.Rules.evaluate(MIXED_RULE, ITEM, quoteContext({ levels = levels, row = ROW }))
	t.same(mixed.inputs, { scan = true, ahledger = true }, 'own depth, AHledger sales a day')
end)

t.test('every base reports its input; a skipped step adds none', function()
	local vendor = ns.Rules.evaluate(
		{ id = 'v', name = 'V', base = { kind = 'vendor' }, steps = { { kind = 'lower', base = { kind = 'median' } } } },
		ITEM,
		quoteContext({})
	)
	t.same(vendor.inputs, { vendor = true }, 'no AHledger row: the step is skipped')
	local capped = ns.Rules.evaluate({
		id = 'c',
		name = 'C',
		base = { kind = 'vendor' },
		steps = { { kind = 'higher', base = { kind = 'median' } } },
	}, ITEM, quoteContext({ row = ROW }))
	t.same(capped.inputs, { vendor = true, ahledger = true })
end)
