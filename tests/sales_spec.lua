local t = ...
local ns = t.loadAddon()
local FakeGame = require('tests.fake_game')
local Sales, ScanStore, Rules = ns.Sales, ns.ScanStore, ns.Rules

local LINEN, WOOL = 2589, 2592
local MARKET = 'forever/normal/alliance/us'
local DAY = 86400
local NOW = 20000 * DAY + 12 * 3600
local HOUR = 3600
local FILLER = 9999
local SHORT, MEDIUM, VERY_LONG = 1, 2, 4

-- A snapshot from listings { itemId, stack, buyout, band? }, as Scan builds it (band is the
-- internal one, 1 = short). Twenty unchanged filler listings keep a small test scan from
-- looking incomplete.
local function snapshotOf(at, listings, maxLevels)
	local builder = ScanStore.newBuilder(maxLevels)
	for _, listing in ipairs(listings) do
		builder:Add(listing[1], listing[2], listing[3], listing[4] or VERY_LONG)
	end
	for _ = 1, 20 do
		builder:Add(FILLER, 1, 100, VERY_LONG)
	end
	builder:Pack()
	return builder:Snapshot(at, 'own')
end

-- The finished comparison of two listing sets, an hour apart unless gap says otherwise.
local function diffOf(earlierListings, laterListings, options)
	options = options or {}
	local gap = options.gap or HOUR
	local earlier = snapshotOf(NOW - gap, earlierListings, options.maxLevels)
	local later = snapshotOf(NOW, laterListings, options.maxLevels)
	local diff = assert(Sales.newDiff(earlier, later, options.vendorPriceFor))
	t.truthy(diff:Step())
	return diff:Result()
end

local function soldOf(result, itemId)
	local counts = result.items[itemId] or {}
	return counts.sold or 0, counts.troll or 0
end

local function codesOf(reasons)
	local codes = {}
	for _, reason in ipairs(reasons) do
		codes[#codes + 1] = reason.code .. ':' .. reason.level
	end
	return codes
end

local function stats(sold, troll, scans, hours, pending)
	return { sold = sold, troll = troll, scans = scans, hours = hours, pending = pending or 0 }
end

local function vendorPrices(prices)
	return function(itemId)
		return prices[itemId]
	end
end

t.group('sales diff')

t.test('vanished units are counted per item and price level', function()
	local result = diffOf({
		{ LINEN, 20, 2000 },
		{ LINEN, 20, 2000 },
		{ LINEN, 5, 500 },
		{ LINEN, 5, 600 },
	}, {
		{ LINEN, 20, 2000 },
		{ LINEN, 5, 600 },
	}, { vendorPriceFor = vendorPrices({ [LINEN] = 13 }) })
	t.eq(soldOf(result, LINEN), 25)
	t.eq(result.gapSeconds, HOUR)
	t.eq(result.at, NOW)
end)

t.test('a new listing at another price never offsets a vanished one', function()
	local result = diffOf({ { LINEN, 20, 2000 } }, { { LINEN, 20, 1900 }, { LINEN, 40, 4200 } }, {
		vendorPriceFor = vendorPrices({ [LINEN] = 13 }),
	})
	t.eq(soldOf(result, LINEN), 20)
end)

t.test('a level that grew or stayed sells nothing; an item gone entirely sold out', function()
	local result = diffOf({
		{ LINEN, 20, 2000 },
		{ WOOL, 5, 1000 },
	}, {
		{ LINEN, 20, 2000 },
		{ LINEN, 20, 2000 },
	}, { vendorPriceFor = vendorPrices({ [LINEN] = 13, [WOOL] = 33 }) })
	t.eq(soldOf(result, LINEN), 0)
	t.eq(soldOf(result, WOOL), 5)
	t.eq(result.items[LINEN], nil)
end)

t.test('levels past the later scan cap are not taken as vanished', function()
	local earlier = { { LINEN, 1, 500 }, { LINEN, 1, 600 }, { LINEN, 1, 700 } }
	-- Two cheaper levels push 700 out of a three-level cap; 500 sold.
	local later = { { LINEN, 1, 100 }, { LINEN, 1, 200 }, { LINEN, 1, 600 }, { LINEN, 1, 700 } }
	local result = diffOf(earlier, later, { maxLevels = 3, vendorPriceFor = vendorPrices({ [LINEN] = 13 }) })
	t.eq(soldOf(result, LINEN), 1)
end)

t.test('troll buys: exactly 0.95 x P = vendor is a troll buy, a copper over is not', function()
	local result = diffOf({
		{ LINEN, 4, 80 }, -- 20 a unit: 0.95 x 20 = 19 = vendor
		{ WOOL, 3, 63 }, -- 21 a unit: 19.95 > 19
	}, {}, { vendorPriceFor = vendorPrices({ [LINEN] = 19, [WOOL] = 19 }) })
	t.same({ soldOf(result, LINEN) }, { 0, 4 })
	t.same({ soldOf(result, WOOL) }, { 3, 0 })
end)

t.test('a known vendor price of 0 means no troll buys', function()
	local result = diffOf({ { LINEN, 4, 80 } }, {}, { vendorPriceFor = vendorPrices({ [LINEN] = 0 }) })
	t.same({ soldOf(result, LINEN) }, { 4, 0 })
end)

t.test('the vendor price is looked up only for items that lost units', function()
	local asked = {}
	diffOf({ { LINEN, 4, 80 }, { WOOL, 4, 80 } }, { { WOOL, 4, 80 } }, {
		vendorPriceFor = function(itemId)
			asked[#asked + 1] = itemId
			return 13
		end,
	})
	t.same(asked, { LINEN })
end)

t.test('units of an item with no vendor price yet are held unclassified, never as sales', function()
	local result = diffOf({ { LINEN, 4, 80 }, { LINEN, 2, 60 }, { WOOL, 4, 80 } }, {}, {
		vendorPriceFor = function(itemId)
			if itemId == WOOL then
				error('no item info')
			end
			return 0 / 0
		end,
	})
	t.same(result.items[LINEN], { pending = { [20] = 4, [30] = 2 } })
	t.same(result.items[WOOL], { pending = { [20] = 4 } })
end)

t.group('sales diff: expiry')

t.test('vanished units that showed the short band are taken as expired, not sold', function()
	local result = diffOf({ { LINEN, 20, 2000, SHORT } }, {}, { vendorPriceFor = vendorPrices({ [LINEN] = 13 }) })
	t.eq(soldOf(result, LINEN), 0)
	t.eq(result.expiredUnits, 20)
end)

t.test('only the short band is discounted, whatever the gap', function()
	local vendor = vendorPrices({ [LINEN] = 13 })
	local medium = { { LINEN, 5, 500, MEDIUM } }
	t.eq(soldOf(diffOf(medium, {}, { gap = 3 * HOUR, vendorPriceFor = vendor }), LINEN), 5)
	local short = { { LINEN, 5, 500, SHORT } }
	t.eq(soldOf(diffOf(short, {}, { gap = 20 * 60, vendorPriceFor = vendor }), LINEN), 0)
end)

t.test('of a level, no more units are left out than showed the short band', function()
	local result = diffOf({
		{ LINEN, 10, 1000, SHORT },
		{ LINEN, 10, 1000, VERY_LONG },
		{ LINEN, 10, 1000, VERY_LONG },
	}, { { LINEN, 5, 500, VERY_LONG } }, { vendorPriceFor = vendorPrices({ [LINEN] = 13 }) })
	t.eq(soldOf(result, LINEN), 15) -- 25 vanished at 100, 10 of them short
	t.eq(result.expiredUnits, 10)
end)

t.test('scans that cannot be compared', function()
	local scan = snapshotOf(NOW, {})
	t.same({ Sales.canDiff(nil, scan) }, { false, 'no earlier scan' })
	t.same({ Sales.canDiff(snapshotOf(NOW + 1, {}), scan) }, { false, 'the scans are not in order' })
	t.same({ Sales.canDiff(snapshotOf(NOW - 9 * HOUR, {}), scan) }, { false, 'the scans are more than 8 hours apart' })
	local fullerListings = {}
	for index = 1, 21 do
		fullerListings[index] = { LINEN, index, 100 * index }
	end
	local fuller = snapshotOf(NOW - HOUR, fullerListings)
	t.same({ Sales.canDiff(fuller, scan) }, { false, 'the new scan looks incomplete' })
	local oldFormat = { at = NOW - HOUR, count = 20, items = {} }
	t.same({ Sales.canDiff(oldFormat, scan) }, { false, 'a scan has no time-left bands' })
	t.eq(Sales.newDiff(nil, scan), nil)
end)

t.test('a broken earlier scan from saved data reads as nothing sold, never an error', function()
	local later = snapshotOf(NOW, {})
	local earlier = {
		at = NOW - HOUR,
		count = 0,
		hasBands = true,
		items = {
			[LINEN] = { levels = { 'junk', { price = 'x', qty = 3 }, { price = 10, qty = 'y' } } },
			[WOOL] = 'junk',
			[1] = { levels = { { price = 10, qty = 2, short = 'z' } } },
		},
	}
	local diff = assert(Sales.newDiff(earlier, later, vendorPrices({ [1] = 1 })))
	t.truthy(diff:Step())
	local result = diff:Result()
	t.eq(soldOf(result, LINEN), 0)
	t.eq(soldOf(result, 1), 2)
end)

t.test('a broken later item is not compared: its units did not vanish', function()
	local earlier = snapshotOf(NOW - HOUR, { { LINEN, 5, 500 } })
	local later = snapshotOf(NOW, { { WOOL, 1, 100 } })
	later.items[LINEN] = '5,0,1;20:5,10:5'
	local diff = assert(Sales.newDiff(earlier, later, vendorPrices({ [LINEN] = 1 })))
	t.truthy(diff:Step())
	t.eq(soldOf(diff:Result(), LINEN), 0)
end)

t.test('the diff runs a slice at a time', function()
	local earlierListings = {}
	for itemId = 1, 10 do
		earlierListings[#earlierListings + 1] = { itemId, 1, 100 }
	end
	local diff = assert(Sales.newDiff(snapshotOf(NOW - HOUR, earlierListings), snapshotOf(NOW, {}), function()
		return 1
	end))
	local calls = 0
	local isDone = diff:Step(function()
		calls = calls + 1
		return calls <= 4
	end)
	t.eq(isDone, false)
	t.raises(function()
		diff:Result()
	end, 'Step has not finished')
	t.truthy(diff:Step())
	local total = 0
	for itemId = 1, 10 do
		total = total + soldOf(diff:Result(), itemId)
	end
	t.eq(total, 10)
end)

t.group('daily summaries')

t.test('comparisons add up per day; items without sales are not kept', function()
	local scanDays = {}
	Sales.record(scanDays, { at = NOW, gapSeconds = HOUR, items = { [LINEN] = { sold = 20, troll = 5 } } })
	Sales.record(scanDays, {
		at = NOW + 60,
		gapSeconds = HOUR / 2,
		items = { [LINEN] = { sold = 4, pending = { [20] = 3 } }, [WOOL] = { troll = 2 } },
	})
	Sales.record(
		scanDays,
		{ at = NOW + 120, gapSeconds = 60, items = { [LINEN] = { pending = { [20] = 1, [30] = 2 } } } }
	)
	t.same(scanDays, {
		[20000] = {
			scans = 3,
			hours = 1.5 + 1 / 60,
			items = { [LINEN] = { sold = 24, troll = 5, pending = { [20] = 4, [30] = 2 } }, [WOOL] = { troll = 2 } },
		},
	})
end)

t.test('held units are classified once the vendor price is known', function()
	local scanDays = {
		[20000] = {
			scans = 1,
			hours = 1,
			items = { [LINEN] = { sold = 2, pending = { [20] = 4, [30] = 2 } }, [WOOL] = { pending = { [5] = 1 } } },
		},
	}
	local stillHeld = Sales.classifyPending(scanDays, vendorPrices({ [LINEN] = 19 }))
	t.eq(stillHeld, 1)
	t.same(scanDays[20000].items, { [LINEN] = { sold = 4, troll = 4 }, [WOOL] = { pending = { [5] = 1 } } })
end)

t.test('days outside the window are pruned, along with keys that are not days', function()
	local scanDays = { [20000] = {}, [20000 - 13] = {}, [20000 - 14] = {}, junk = {} }
	Sales.prune(scanDays, NOW, 14)
	t.same(scanDays, { [20000] = {}, [20000 - 13] = {} })
	local shorter = { [20000] = {}, [20000 - 3] = {} }
	Sales.prune(shorter, NOW, 3)
	t.same(shorter, { [20000] = {} })
	Sales.prune(nil, NOW, 14)
end)

t.test('own stats sum the window and skip broken days', function()
	local scanDays = {
		[20000] = { scans = 3, hours = 4, items = { [LINEN] = { sold = 10, troll = 2, pending = { [20] = 3 } } } },
		[20000 - 13] = { scans = 2, hours = 2, items = { [LINEN] = { sold = 6 } } },
		[20000 - 14] = { scans = 9, hours = 9, items = { [LINEN] = { sold = 99 } } }, -- outside the window
		[20000 - 1] = { scans = 'x', hours = 0 / 0, items = { [LINEN] = { sold = -1, troll = 'y', pending = 'z' } } },
		[20000 - 2] = 'junk',
	}
	t.same(Sales.ownStats(scanDays, LINEN, NOW, 14), stats(16, 2, 5, 6, 3))
	t.same(Sales.ownStats(scanDays, LINEN, NOW, 1), stats(10, 2, 3, 4, 3))
	t.same(Sales.ownStats(nil, LINEN, NOW, 14), stats(0, 0, 0, 0))
end)

t.group('market pruning')

t.test('markets not scanned for the set days lose their scan and summaries, nothing else', function()
	local markets = {
		fresh = { scan = { at = NOW - 29 * DAY, items = {} }, scanDays = { [1] = {} } },
		stale = { scan = { at = NOW - 31 * DAY, items = {} }, scanDays = { [1] = {} }, ledger = { 'kept' } },
		future = { scan = { at = NOW + DAY, items = {} }, scanDays = {} },
		unscanned = { ledger = {} },
		summariesOnly = { scanDays = { [math.floor(NOW / DAY) - 31] = {} }, ledger = { 'kept' } },
		recentSummariesOnly = { scanDays = { [math.floor(NOW / DAY) - 31] = {}, [math.floor(NOW / DAY) - 2] = {} } },
		junk = 'x',
	}
	local pruned = ScanStore.pruneStaleMarkets(markets, NOW, 30)
	t.same(pruned, { 'stale', 'summariesOnly' })
	t.same(markets.summariesOnly.scanDays, {}, 'no scan, summaries all older than the days kept')
	t.same(markets.summariesOnly.ledger, { 'kept' })
	t.eq(next(markets.recentSummariesOnly.scanDays) ~= nil, true)
	t.eq(markets.stale.scan, nil)
	t.same(markets.stale.scanDays, {})
	t.same(markets.stale.ledger, { 'kept' })
	t.truthy(markets.fresh.scan)
	t.truthy(markets.future.scan)
end)

t.group('sales source')

t.test('below the coverage threshold sales a day is AHledger, with a reason', function()
	local view = Sales.choose(stats(10, 0, 5, 30), 45, { minScans = 6, minHours = 12 })
	t.eq(view.source, 'ahledger')
	t.eq(view.perDay, 45)
	t.same(codesOf(view.reasons), { 'ownSalesThin:high' })
	t.truthy(
		view.reasons[1].text == 'sold a day from AHledger, as your own count has 5 of 6 scans and 30 of 12 hours',
		view.reasons[1].text
	)
	t.eq(Sales.choose(stats(10, 0, 6, 11.9), 45, { minScans = 6, minHours = 12 }).source, 'ahledger')
end)

t.test('at the threshold sales a day is the own troll-filtered count', function()
	local view = Sales.choose(stats(18, 3, 6, 12), 45, { minScans = 6, minHours = 12 })
	t.eq(view.source, 'own')
	t.eq(view.perDay, 36) -- 18 sold in 12 hours; troll buys left out
	t.same(view.reasons, {})
end)

t.test('held units are not sales and add a reason', function()
	local view = Sales.choose(stats(18, 0, 6, 12, 7), 45, { minScans = 6, minHours = 12 })
	t.eq(view.perDay, 36)
	t.same(codesOf(view.reasons), { 'trollUnchecked:medium' })
	t.eq(view.reasons[1].text, '7 sold units wait for item data before the troll check')
end)

t.test('broken settings fall back to the defaults', function()
	local view = Sales.choose(stats(6, 0, 6, 12), nil, { minScans = 'x', minHours = 0 / 0, trollSharePercent = -1 })
	t.eq(view.source, 'own')
	t.eq(Sales.DEFAULTS.minScans, 6)
	t.eq(Sales.DEFAULTS.minHours, 12)
	t.eq(Sales.DEFAULTS.windowDays, 14)
end)

t.group('troll flag')

t.test('the flag starts at the setting and is low over half', function()
	local settings = { minScans = 1, minHours = 1, trollSharePercent = 30 }
	t.same(codesOf(Sales.choose(stats(71, 29, 9, 24), nil, settings).reasons), {}, '29%')
	t.same(codesOf(Sales.choose(stats(70, 30, 9, 24), nil, settings).reasons), { 'trollBuys:medium' }, '30%')
	t.same(codesOf(Sales.choose(stats(50, 50, 9, 24), nil, settings).reasons), { 'trollBuys:medium' }, '50%')
	t.same(codesOf(Sales.choose(stats(49, 51, 9, 24), nil, settings).reasons), { 'trollBuys:low' }, '51%')
	local strict = { minScans = 1, minHours = 1, trollSharePercent = 60 }
	t.same(codesOf(Sales.choose(stats(50, 50, 9, 24), nil, strict).reasons), {}, 'setting 60%')
end)

t.test('too few vanished units raise no flag', function()
	t.same(codesOf(Sales.choose(stats(0, 4, 9, 24), nil, { minScans = 1, minHours = 1 }).reasons), {})
	t.same(codesOf(Sales.choose(stats(0, 5, 9, 24), nil, { minScans = 1, minHours = 1 }).reasons), { 'trollBuys:low' })
end)

t.test('the flag is raised while AHledger figures are in use', function()
	local view = Sales.choose(stats(6, 4, 2, 3), 45, { minScans = 6, minHours = 12 })
	t.eq(view.source, 'ahledger')
	t.same(codesOf(view.reasons), { 'ownSalesThin:high', 'trollBuys:medium' })
	t.eq(view.reasons[2].text, 'sales may include troll buys (40% of vanished units)')
end)

t.test('on own scans the flag says the troll buys are left out, in one plain sentence', function()
	local view = Sales.choose(stats(49, 51, 9, 24), nil, { minScans = 1, minHours = 1 })
	t.eq(view.source, 'own')
	t.eq(view.reasons[1].text, '51% of vanished units were troll buys and are left out')
end)

t.group('sales in rules')

local RULE = { id = 'r', name = 'R', base = { kind = 'median' }, steps = {} }

local function ctxWithSales(view, sold)
	return {
		now = NOW,
		priceRow = function()
			return { median = 1000, sold = sold or 45 }, NOW
		end,
		itemInfo = function()
			return { maxStack = 20 }
		end,
		sales = function()
			return view
		end,
	}
end

t.test('a troll reason sets the price confidence to at least medium, low over half', function()
	local own = { perDay = 30, source = 'own', reasons = {} }
	t.eq(Rules.evaluate(RULE, LINEN, ctxWithSales(own)).confidence.level, 'high')
	local medium = Sales.choose(stats(70, 30, 9, 24), 45, { minScans = 6, minHours = 12 })
	t.eq(Rules.evaluate(RULE, LINEN, ctxWithSales(medium)).confidence.level, 'medium')
	local low = Sales.choose(stats(40, 60, 9, 24), 45, { minScans = 6, minHours = 12 })
	local price = Rules.evaluate(RULE, LINEN, ctxWithSales(low))
	t.eq(price.confidence.level, 'low')
	t.same(codesOf(price.confidence.reasons), { 'trollBuys:low' })
end)

t.test('the own count replaces AHledger sold for sales-driven reasons', function()
	local own = { perDay = 0.5, source = 'own', reasons = {} }
	local price = Rules.evaluate(RULE, LINEN, ctxWithSales(own, 45))
	t.same(codesOf(price.confidence.reasons), { 'fewSales:low' })
end)

t.test('a broken sales view is bad input; a throwing one too', function()
	local price = Rules.evaluate(RULE, LINEN, ctxWithSales({ perDay = 'x', source = 'own', reasons = { 'junk' } }))
	t.same(codesOf(price.confidence.reasons), { 'fewSales:medium', 'badInput:medium' })
	t.eq(price.confidence.reasons[2].text, 'own sales a day was not usable and is treated as unknown')
	local ctx = ctxWithSales(nil)
	ctx.sales = function()
		error('broken')
	end
	local fromRow = Rules.evaluate(RULE, LINEN, ctx)
	t.same(codesOf(fromRow.confidence.reasons), { 'badInput:medium' })
end)

t.group('sales in the add-on')

-- Listings in the fake client's raw form: { itemId, count, buyout, bid, timeLeft, seller }.
local function scanTwice(game, laterListings)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	game.now = game.now + HOUR
	game.listings = laterListings
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
end

t.test('two scans an hour apart add a daily summary that prices read', function()
	local game = FakeGame.new({
		now = NOW,
		listings = { { LINEN, 20, 2000, 0, 4, 'Ann' }, { LINEN, 20, 2000, 0, 4, 'Bob' }, { WOOL, 5, 50, 0, 4, 'Cy' } },
		itemInfo = {
			[LINEN] = { name = 'Linen', maxStack = 20, vendorPrice = 13 },
			[WOOL] = { name = 'Wool', maxStack = 20, vendorPrice = 33 },
		},
	})
	local addon = FakeGame.startAddon(t, game, function(started)
		started.store:Settings().pricing = { ownSalesMinScans = 1, ownSalesMinHours = 1 }
	end)
	-- Bob's listing stays and Dee's new one is at another price, so it offsets nothing.
	scanTwice(game, { { LINEN, 20, 2000, 0, 4, 'Bob' }, { LINEN, 20, 1900, 0, 4, 'Dee' } })
	t.same(addon.errors, {})
	local summary = addon.store:Market(MARKET).scanDays[math.floor((NOW + HOUR) / DAY)]
	t.same(summary, { scans = 1, hours = 1, items = { [LINEN] = { sold = 20 }, [WOOL] = { troll = 5 } } })
	local facts = addon.prices:Quote(LINEN, { 'realistic' }).facts
	t.eq(facts.salesPerDay, 480)
	t.eq(facts.salesSource, 'own')
end)

t.test('sellers the client has not loaded yet never turn listings into sales', function()
	local game = FakeGame.new({
		now = NOW,
		listings = { { LINEN, 20, 2000, 0, 4, 'Ann' }, { LINEN, 20, 2000, 0, 4, 'Bob' } },
		itemInfo = { [LINEN] = { name = 'Linen', maxStack = 20, vendorPrice = 13 } },
	})
	local addon = FakeGame.startAddon(t, game)
	-- The same two listings; on the second read the client has loaded neither seller.
	scanTwice(game, { { LINEN, 20, 2000, 0, 4, isLoaded = false }, { LINEN, 20, 2000, 0, 4, isLoaded = false } })
	t.same(addon.store:Market(MARKET).scanDays[math.floor((NOW + HOUR) / DAY)].items, {})
end)

t.test('a scan the store refuses records no sales', function()
	local game = FakeGame.new({
		now = NOW,
		listings = { { LINEN, 20, 2000, 0, 4, 'Ann' }, { LINEN, 20, 2000, 0, 4, 'Bob' } },
		itemInfo = { [LINEN] = { name = 'Linen', maxStack = 20, vendorPrice = 13 } },
	})
	local addon = FakeGame.startAddon(t, game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	-- A later scan that compares fine but that the store refuses (its rules may tighten).
	local save = addon.ScanStore.save
	addon.ScanStore.save = function()
		return false
	end
	game.now = game.now + HOUR
	game.listings = { { LINEN, 20, 2000, 0, 4, 'Bob' } }
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	addon.ScanStore.save = save
	local market = addon.store:Market(MARKET)
	t.eq(market.scan.at, NOW, 'the earlier scan is kept')
	t.eq(market.scanDays[math.floor((NOW + HOUR) / DAY)], nil, 'no sales from the refused scan')
end)

t.test('an uncached item: data is requested, units held, then classified from the saved vendor price', function()
	local game = FakeGame.new({ now = NOW, listings = { { WOOL, 5, 50, 0, 4 }, { LINEN, 1, 100, 0, 4 } } })
	local addon = FakeGame.startAddon(t, game)
	scanTwice(game, { { LINEN, 1, 100, 0, 4 } })
	t.same(game.itemDataRequests, { WOOL })
	local market = addon.store:Market(MARKET)
	local today = math.floor((NOW + HOUR) / DAY)
	t.same(market.scanDays[today].items[WOOL], { pending = { [10] = 5 } })
	-- The item data arrives once; its vendor price is remembered, and the next scan classifies.
	game.itemInfo[WOOL] = { name = 'Wool', maxStack = 20, vendorPrice = 33 }
	addon.prices:Quote(WOOL, { 'realistic' })
	game.itemInfo[WOOL] = nil
	t.eq(addon.store:VendorPrice(WOOL), 33)
	game.now = game.now + HOUR
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.same(market.scanDays[today].items[WOOL], { troll = 5 })
end)

t.test('a scan prunes stale markets and keeps summaries to the window', function()
	local game = FakeGame.new({ now = NOW, listings = { { LINEN, 1, 100, 0, 4 } } })
	local addon = FakeGame.startAddon(t, game, function(started)
		started.store:Settings().pricing = { salesWindowDays = 3 }
		started.store:Settings().scan = { keepMarketDays = 10 }
		started.store:Market('forever/normal/horde/us').scan = { at = NOW - 11 * DAY, items = {} }
		started.store:Market(MARKET).scanDays[20000 - 3] = { scans = 1, hours = 1, items = {} }
	end)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.same(addon.errors, {})
	t.eq(addon.store:Market('forever/normal/horde/us').scan, nil)
	t.eq(addon.store:Market(MARKET).scanDays[20000 - 3], nil)
end)

t.group('scan follow-up')

local function scannerWithFollowUp(newFollowUp)
	local game = FakeGame.new({ now = NOW, listings = { { LINEN, 1, 100 } } })
	local saved, errors = {}, {}
	local scanner = ns.Scan.new({
		wow = ns.Wow.create(game.env),
		newFollowUp = newFollowUp,
		onSnapshot = function(snapshot, result)
			saved[#saved + 1] = { snapshot = snapshot, result = result }
		end,
		onError = function(where)
			errors[#errors + 1] = where
		end,
	})
	scanner:Enable()
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	return game, scanner, saved, errors
end

t.test('the follow-up runs a slice per frame before the scan is saved with its result', function()
	local steps = 0
	local game, scanner, saved = scannerWithFollowUp(function()
		return {
			Step = function()
				steps = steps + 1
				return steps >= 3
			end,
			Result = function()
				return 'compared'
			end,
		}
	end)
	game:NextFrame()
	game:NextFrame()
	t.eq(scanner:Status().state, 'comparing')
	game:RunFrames()
	t.eq(#saved, 1)
	t.eq(saved[1].result, 'compared')
	t.eq(steps, 3)
end)

t.test('a failing follow-up costs only its result: the scan is still saved', function()
	local game, scanner, saved, errors = scannerWithFollowUp(function()
		return {
			Step = function()
				error('diff broke')
			end,
		}
	end)
	game:RunFrames()
	t.eq(#saved, 1)
	t.eq(saved[1].result, nil)
	t.same(errors, { 'scan follow-up' })
	t.truthy(scanner:Status().lastError:find('diff broke', 1, true))
	local game2, _, saved2 = scannerWithFollowUp(function()
		error('could not start')
	end)
	game2:RunFrames()
	t.eq(#saved2, 1)
end)
