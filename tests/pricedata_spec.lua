local t = ...
local FakeGame = require('tests.fake_game')
local ns = t.loadAddon()
local PriceData, PriceContext, Rules = ns.PriceData, ns.PriceContext, ns.Rules

local LINEN, WOOL, SWORD = 2589, 2592, 2488
local MARKET = 'forever/normal/alliance/us'
local OTHER_MARKET = 'forever/pvp/horde/us'
local NOW = 1000000
local HOUR = 3600
local UPDATED = NOW - 2 * HOUR
-- median, min buyout, quantity, 7- and 30-day median, 30-day low and high, sold a day.
local ROWS = {
	[LINEN] = { 120, 95, 500, 118, 125, 90, 160, 45 },
	[WOOL] = { 300, 0, 0, nil, nil, nil, nil, 0 },
}

local function newSource(options)
	local apiOptions = { market = MARKET, updated = UPDATED, rows = ROWS }
	for key, value in pairs(options or {}) do
		apiOptions[key] = value
	end
	local api, state = FakeGame.newAHledgerAPI(apiOptions)
	return PriceData.newAHledgerSource(function()
		return api
	end), state
end

local function sourceOf(value)
	return PriceData.newAHledgerSource(function()
		return value
	end)
end

local function reasonOf(price, code)
	for _, reason in ipairs(price.confidence.reasons) do
		if reason.code == code then
			return reason
		end
	end
	return nil
end

local function stackOfTwenty()
	return { maxStack = 20, vendorPrice = 13 }
end

local function contextWith(priceSource)
	return PriceContext.build({ now = NOW, marketKey = MARKET, priceSource = priceSource, itemInfo = stackOfTwenty })
end

local function withScan(ctx)
	ctx.scanItem = function()
		return { min = 100, units = 400, levels = { { price = 100, qty = 400 } } }, NOW - 60
	end
	return ctx
end

local function newService(priceSource)
	return ns.PriceService.new({
		now = function()
			return NOW
		end,
		store = assert(ns.Store.open({}, {})),
		priceSource = priceSource,
		marketKey = function()
			return MARKET
		end,
		itemInfo = stackOfTwenty,
	})
end

local MEDIAN_RULE = Rules.builtIns().median
local MINIMUM_RULE = Rules.builtIns().minimum
local VENDOR_RULE = { id = 'v', name = 'Vendor', base = { kind = 'vendor' }, steps = {} }

t.group('price source: AHledger present')

t.test('a row maps AHledgerAPI fields onto PriceRow, with the time of the data', function()
	local source = newSource()
	local row, updated = source:Row(MARKET, LINEN)
	t.same(row, {
		median = 120,
		min = 95,
		qty = 500,
		m7 = 118,
		m30 = 125,
		lo = 90,
		hi = 160,
		sold = 45,
		isSnapshot = false,
	})
	t.eq(updated, UPDATED)
end)

t.test('zero copper is no price; zero listed and zero sold are real figures', function()
	local row = newSource():Row(MARKET, WOOL)
	t.eq(row.median, 300)
	t.eq(row.min, nil)
	t.eq(row.qty, 0)
	t.eq(row.sold, 0)
end)

t.test('a missing item is no row, not an error', function()
	t.eq(newSource():Row(MARKET, SWORD), nil)
end)

t.test('another market is not priced from the player market', function()
	t.eq(newSource():Row(OTHER_MARKET, LINEN), nil)
	local priceTable, reason = newSource():Table(OTHER_MARKET)
	t.eq(priceTable, nil)
	t.eq(reason, 'no AHledger table for this market')
end)

t.test('the status is available, with AHledger credit and market', function()
	local available = { isAvailable = true, credit = 'Prices from AHledger (ahledger.com)', market = MARKET }
	t.same(newSource():Status(), available)
	t.same(newSource():Status(MARKET), available)
	t.eq(newSource({ credit = '' }):Status().credit, PriceData.DEFAULT_CREDIT, 'a blank credit falls back')
	local longCredit = string.rep('x', 121)
	t.eq(newSource({ credit = longCredit }):Status().credit, PriceData.DEFAULT_CREDIT, 'an overlong credit falls back')
	t.eq(newSource({ credit = string.rep('x', 120) }):Status().credit, string.rep('x', 120))
end)

t.test('the credit comes only with a price that used an AHledger figure', function()
	local service = newService(newSource())
	t.eq(Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(newSource())).usesPriceSource, true)
	t.eq(Rules.evaluate(VENDOR_RULE, LINEN, contextWith(newSource())).usesPriceSource, false)
	t.eq(service:Quote(LINEN, { 'median' }).credit, 'Prices from AHledger (ahledger.com)')
	t.eq(service:Quote(SWORD, { 'median' }).credit, nil, 'AHledger has no price for it')
end)

t.test('the table reports its time, size and snapshot flag', function()
	t.same(newSource():Table(MARKET), { market = MARKET, updated = UPDATED, count = 2, isSnapshot = false })
end)

t.test('a price from the source has no source reasons', function()
	local price = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(newSource()))
	t.eq(price.copper, 120)
	t.eq(price.source, 'ahledger')
	t.eq(price.ageSeconds, 2 * HOUR)
	t.eq(reasonOf(price, 'snapshot'), nil)
	t.eq(reasonOf(price, 'noPriceSource'), nil)
end)

t.test('old AHledger data is a stale reason', function()
	local price = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(newSource({ updated = NOW - 80 * HOUR })))
	t.same(reasonOf(price, 'stale'), { code = 'stale', level = 'low', text = 'data is 80 hours old' })
	t.eq(price.confidence.level, 'low')
end)

t.test('an unknown time of the data says so', function()
	local source, state = newSource()
	state.updated = nil
	local _, updated = source:Row(MARKET, LINEN)
	t.eq(updated, nil)
	local price = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(source))
	t.same(reasonOf(price, 'stale'), { code = 'stale', level = 'medium', text = 'data age unknown' })
end)

t.group('price source: AHledger snapshot')

t.test('a bundled-copy row is flagged and the price says so', function()
	local source = newSource({ snapshot = true })
	t.eq(source:Row(MARKET, LINEN).isSnapshot, true)
	t.eq(source:Table(MARKET).isSnapshot, true)
	local price = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(source))
	t.same(
		reasonOf(price, 'snapshot'),
		{ code = 'snapshot', level = 'medium', text = 'bundled AHledger prices, older than synced ones' }
	)
	t.eq(price.confidence.level, 'medium')
end)

t.test('a snapshot sales figure also marks a scan-based price', function()
	local ctx = contextWith(newSource({ snapshot = true }))
	ctx.scanItem = function()
		return { min = 100, units = 400, levels = { { price = 100, qty = 400 } } }, NOW - 60
	end
	local price = Rules.evaluate(Rules.builtIns().minimum, LINEN, ctx)
	t.eq(price.source, 'scan')
	t.truthy(reasonOf(price, 'snapshot'), 'sales a day came from the bundled copy')
end)

t.test('a snapshot median is marked when sales a day are the own count', function()
	local ctx = contextWith(newSource({ snapshot = true }))
	ctx.sales = function()
		return { perDay = 50, source = 'own', reasons = {} }
	end
	local price = Rules.evaluate(MEDIAN_RULE, LINEN, ctx)
	t.truthy(reasonOf(price, 'snapshot'), 'the median itself is from the bundled copy')
end)

t.test('a vendor price never carries the snapshot reason', function()
	local price = Rules.evaluate(VENDOR_RULE, LINEN, contextWith(newSource({ snapshot = true })))
	t.same(price.confidence.reasons, {})
end)

t.group('price source: AHledger absent')

t.test('no AHledger: no rows, no table, a reason, never an error', function()
	local source = sourceOf(nil)
	t.same(source:Status(), { isAvailable = false, code = 'noPriceSource', reason = 'AHledger is not loaded' })
	t.eq(source:Row(MARKET, LINEN), nil)
	local priceTable, reason = source:Table(MARKET)
	t.eq(priceTable, nil)
	t.eq(reason, 'AHledger is not loaded')
end)

t.test('no AHledger: a scan price is low confidence, naming why', function()
	local ctx = contextWith(sourceOf(nil))
	ctx.scanItem = function()
		return { min = 100, units = 400, levels = { { price = 100, qty = 400 } } }, NOW - 60
	end
	local price = Rules.evaluate(Rules.builtIns().minimum, LINEN, ctx)
	t.eq(price.copper, 99)
	t.same(
		reasonOf(price, 'noPriceSource'),
		{ code = 'noPriceSource', level = 'low', text = "AHledger is not loaded, so only Haggler's own scans count" }
	)
	t.eq(price.confidence.level, 'low')
	local median, reason = Rules.evaluate(MEDIAN_RULE, LINEN, ctx)
	t.eq(median, nil)
	t.eq(reason, 'no AHledger median')
end)

t.group('price source: AHledger broken')

t.test('calls that throw read as no data, and the status says AHledger fails', function()
	local source = newSource({ mode = 'broken' })
	t.same(source:Status(MARKET), { isAvailable = false, code = 'priceSourceFailing', reason = 'AHledger calls fail' })
	local row, updated, problem = source:Row(MARKET, LINEN)
	t.eq(row, nil)
	t.eq(updated, nil)
	t.eq(problem, 'priceSourceFailing')
	t.eq(source:Table(MARKET), nil)
end)

t.test('broken: a scan price is low, naming the failure, with no credit', function()
	local price = Rules.evaluate(MINIMUM_RULE, LINEN, withScan(contextWith(newSource({ mode = 'broken' }))))
	t.eq(price.source, 'scan')
	t.same(
		reasonOf(price, 'priceSourceFailing'),
		{ code = 'priceSourceFailing', level = 'low', text = "AHledger calls fail, so only Haggler's own scans count" }
	)
	t.eq(price.confidence.level, 'low')
	t.eq(newService(newSource({ mode = 'broken' })):Quote(LINEN, { 'minimum' }).credit, nil)
end)

t.test('a GetPrice that throws while the table answers is low too', function()
	local source = newSource({ mode = 'priceBroken' })
	t.eq(source:Status(MARKET).isAvailable, true)
	local price = Rules.evaluate(MINIMUM_RULE, LINEN, withScan(contextWith(source)))
	t.same(
		reasonOf(price, 'priceSourceFailing'),
		{ code = 'priceSourceFailing', level = 'low', text = "AHledger calls fail, so only Haggler's own scans count" }
	)
	t.eq(price.usesPriceSource, false)
end)

t.test('a getter that throws or a non-table global is unavailable', function()
	local throwing = PriceData.newAHledgerSource(function()
		error('boom')
	end)
	t.same(throwing:Status(), { isAvailable = false, code = 'noPriceSource', reason = 'AHledger is not loaded' })
	t.same(
		sourceOf('AHledger'):Status(),
		{ isAvailable = false, code = 'noPriceSource', reason = 'AHledger API is not usable' }
	)
end)

t.test('another API version is not read', function()
	local source = newSource({ version = 2 })
	t.same(source:Status(), {
		isAvailable = false,
		code = 'noPriceSource',
		reason = 'AHledger API version 2 is not supported (Haggler reads 1)',
	})
	t.eq(source:Row(MARKET, LINEN), nil)
end)

t.test('an API without GetPrice is unavailable', function()
	t.eq(sourceOf({ VERSION = 1 }):Status().reason, 'AHledger API has no GetPrice')
end)

t.test('an index that throws is no data', function()
	local hostile = setmetatable({}, {
		__index = function()
			error('no reads')
		end,
	})
	t.eq(sourceOf(hostile):Status().isAvailable, false)
end)

t.test('junk fields pass on as junk, so the price says it stands on bad input', function()
	local source = newSource({ mode = 'junk' })
	local row, updated = source:Row(MARKET, LINEN)
	t.eq(row.median, 'lots')
	t.eq(row.sold, 'many')
	t.eq(updated, nil)
	local price, reason = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(source))
	t.eq(price, nil)
	t.eq(reason, 'AHledger median is not a number')
end)

t.test('out-of-range numbers read as junk, never as a price', function()
	local source = newSource({ rows = { [LINEN] = { 2 ^ 41, -5, -1, 1 / 0, 0 / 0, 120, 160, 2 ^ 30 } } })
	local row = source:Row(MARKET, LINEN)
	t.eq(row.median, math.huge)
	t.eq(row.min, math.huge)
	t.eq(row.qty, math.huge)
	t.eq(row.m7, math.huge)
	t.truthy(row.m30 ~= row.m30, 'NaN passes on as junk')
	t.eq(row.lo, 120)
	t.eq(row.sold, math.huge)
	local _, reason = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(source))
	t.eq(reason, 'AHledger median is not a number')
end)

t.test('a status that throws or is malformed gives the scan-only reason', function()
	local broken = {
		Status = function()
			error('nope')
		end,
		Row = function() end,
		Table = function() end,
	}
	t.same(contextWith(broken).priceSourceProblem, { code = 'priceSourceFailing', text = 'the price source failed' })
end)

t.group('price source: no table for the market')

t.test('a market AHledger has no table for is low, with its own reason and no credit', function()
	local source = newSource({ market = OTHER_MARKET })
	t.same(source:Status(MARKET), {
		isAvailable = false,
		code = 'noMarketTable',
		reason = 'AHledger has no prices for forever/normal/alliance/us',
		market = OTHER_MARKET,
	})
	local price = Rules.evaluate(MINIMUM_RULE, LINEN, withScan(contextWith(source)))
	t.same(reasonOf(price, 'noMarketTable'), {
		code = 'noMarketTable',
		level = 'low',
		text = "AHledger has no prices for forever/normal/alliance/us, so only Haggler's own scans count",
	})
	t.eq(newService(source):Quote(LINEN, { 'minimum' }).credit, nil)
end)

t.test('no synced table but AHledger answers from your own scan: no "no prices" next to its figure', function()
	local source = newSource({ ownScanOverlay = true })
	t.eq(source:Status(MARKET).code, 'noMarketTable')
	local price = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(source))
	t.eq(price.copper, 120)
	t.eq(reasonOf(price, 'noMarketTable'), nil)
	t.same(reasonOf(price, 'ownScanOverlay'), {
		code = 'ownScanOverlay',
		level = 'medium',
		text = 'AHledger has no synced table for this market, so its figures come from your own scan',
	})
	local vendor = Rules.evaluate(VENDOR_RULE, LINEN, contextWith(source))
	t.same(vendor.confidence.reasons, {}, 'no AHledger figure, no overlay reason')
end)

t.test('statusOf passes the whitelisted problem codes and maps any other to noPriceSource', function()
	t.same(PriceData.PROBLEM_CODES, { noPriceSource = true, priceSourceFailing = true, noMarketTable = true })
	for code in pairs(PriceData.PROBLEM_CODES) do
		local status = PriceData.statusOf({
			Status = function()
				return { isAvailable = false, code = code, reason = 'why' }
			end,
			Row = function() end,
			Table = function() end,
		})
		t.eq(status.code, code)
	end
	for _, code in ipairs({ 'madeUp', 42, false }) do
		local status = PriceData.statusOf({
			Status = function()
				return { isAvailable = false, code = code, reason = 'why' }
			end,
			Row = function() end,
			Table = function() end,
		})
		t.eq(status.code, 'noPriceSource')
		t.eq(status.reason, 'why')
	end
end)

t.group('price source: market keys')

t.test('AHledger set to another market: Haggler keeps its own and says so', function()
	local source = newSource({ pinnedMarket = OTHER_MARKET })
	t.same(
		source:Status(MARKET),
		{ isAvailable = true, credit = 'Prices from AHledger (ahledger.com)', market = OTHER_MARKET }
	)
	local price = Rules.evaluate(MEDIAN_RULE, LINEN, contextWith(source))
	t.eq(price.copper, 120)
	t.same(reasonOf(price, 'marketMismatch'), {
		code = 'marketMismatch',
		level = 'high',
		text = 'AHledger uses forever/pvp/horde/us while Haggler prices forever/normal/alliance/us',
	})
	t.eq(price.confidence.level, 'high', 'an info reason does not lower confidence')
	local vendor = Rules.evaluate(VENDOR_RULE, LINEN, contextWith(source))
	t.same(vendor.confidence.reasons, {}, 'no AHledger figure, no mismatch reason')
end)

t.test('a key AHledger cannot read falls back to its own market, which Haggler does not use', function()
	local api = FakeGame.newAHledgerAPI({ market = MARKET, rows = ROWS })
	t.eq(api.GetPrice(LINEN, 'not a market').market, MARKET, 'the fake falls back like the real API')
	local source = newSource()
	t.eq(source:Row('not a market', LINEN), nil)
	local priceTable, reason = source:Table('not a market')
	t.eq(priceTable, nil)
	t.eq(reason, 'no AHledger table for this market')
end)

t.group('price source: interface')

t.test('isSource checks the three methods', function()
	t.eq(PriceData.isSource(newSource()), true)
	t.eq(PriceData.isSource({ Status = function() end, Row = function() end }), false)
	t.eq(PriceData.isSource(nil), false)
end)

t.test('a Haggler-owned source plugs into the service with the same shape', function()
	local store = assert(ns.Store.open({}, {}))
	local ownSource = {
		id = 'own',
		Status = function()
			return { isAvailable = true, credit = 'Own prices' }
		end,
		Row = function(_, marketKey, itemId)
			if marketKey == MARKET and itemId == LINEN then
				return { median = 77, sold = 50 }, NOW - 60
			end
			return nil
		end,
		Table = function(_, marketKey)
			return { market = marketKey, updated = NOW - 60, count = 1, isSnapshot = false }
		end,
	}
	local service = ns.PriceService.new({
		now = function()
			return NOW
		end,
		store = store,
		priceSource = ownSource,
		marketKey = function()
			return MARKET
		end,
		itemInfo = stackOfTwenty,
	})
	t.eq(service:Get(LINEN, 'median').copper, 77)
	t.eq(service:Quote(LINEN, { 'median' }).credit, 'Own prices')
	t.same(service:Ages(), { tableAge = 60, isSnapshot = false })
end)

t.test('the service refuses something that is not a source (a programmer error)', function()
	t.raises(function()
		ns.PriceService.new({
			now = function()
				return NOW
			end,
			store = {},
			priceSource = {},
			marketKey = function() end,
		})
	end, 'priceSource must be a PriceSource')
	t.raises(function()
		PriceData.newAHledgerSource(nil)
	end, 'getApi must be a function')
end)

t.group('pricing module and AHledger')

local function newGame(api)
	local game = FakeGame.new({
		now = NOW,
		listings = { { LINEN, 20, 2000, 0, 4, 'Ann' } },
		itemInfo = { [LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 } },
	})
	game.env.AHledgerAPI = api
	return game
end

local function startWith(api)
	local game = newGame(api)
	local received = {}
	local addon = FakeGame.startAddon(t, game, function(started)
		started.host.Bus:Listen('spec', 'PRICE_TABLE_LOADED', function(_, marketKeys)
			received[#received + 1] = marketKeys
		end)
	end)
	return game, addon, received
end

local function scan(game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
end

t.test('present: PRICE_TABLE_LOADED names the player market, no chat notice', function()
	local game, addon, received =
		startWith((FakeGame.newAHledgerAPI({ market = MARKET, updated = UPDATED, rows = ROWS })))
	t.same(received, { { MARKET } })
	t.same(game.printed, {})
	t.same(
		addon.prices:SourceStatus(),
		{ isAvailable = true, credit = 'Prices from AHledger (ahledger.com)', market = MARKET }
	)
end)

t.test('present but no table yet: PRICE_TABLE_LOADED waits for PLAYER_LOGIN', function()
	local api, state = FakeGame.newAHledgerAPI({ market = 'forever/unknown/x/us', updated = UPDATED, rows = ROWS })
	local game, _, received = startWith(api)
	t.same(received, {})
	state.market = MARKET
	game:Fire('PLAYER_LOGIN')
	t.same(received, { { MARKET } })
	game:Fire('PLAYER_LOGIN')
	t.eq(#received, 1, 'sent once')
end)

t.test('absent: says once that Haggler needs AHledger, and prices from scans are low', function()
	local game, addon, received = startWith(nil)
	t.same(received, {})
	t.eq(#game.printed, 1)
	t.truthy(game.printed[1]:find('needs AHledger for market prices (AHledger is not loaded)', 1, true))
	scan(game)
	local price = addon.prices:Get(LINEN, 'minimum')
	t.eq(price.source, 'scan')
	t.eq(price.confidence.level, 'low')
	t.truthy(reasonOf(price, 'noPriceSource'))
	t.same(addon.errors, {})
end)

t.test('absent: the tooltip shows no credit, and the low marker names the reason', function()
	local game = startWith(nil)
	scan(game)
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(#lines, 4, 'the block, its low reason and its collapsed closing separator')
	t.eq(lines[1].right, 'scan just now · no table')
	t.eq(lines[3].left, "Low confidence, AHledger is not loaded, so only Haggler's own scans count")
end)

t.test('broken: nothing throws; prices come from scans', function()
	local game, addon = startWith((FakeGame.newAHledgerAPI({ market = MARKET, rows = ROWS, mode = 'broken' })))
	scan(game)
	local price = addon.prices:Get(LINEN, 'minimum')
	t.eq(price.source, 'scan')
	t.eq(addon.prices:Get(LINEN, 'median'), nil)
	local lines = game:ShowItemTooltip(LINEN)
	t.truthy(#lines >= 2)
	t.eq(tostring(lines[#lines].left):find('AHledger', 1, true), nil, 'no credit without an AHledger figure')
	t.truthy(reasonOf(price, 'priceSourceFailing'))
	t.same(addon.errors, {})
end)

t.test('snapshot: a market price and the ages carry the bundled-copy flag', function()
	local api = FakeGame.newAHledgerAPI({ market = MARKET, updated = UPDATED, rows = ROWS, snapshot = true })
	local _, addon = startWith(api)
	t.truthy(reasonOf(addon.prices:Get(LINEN, 'median'), 'snapshot'))
	t.eq(addon.prices:Ages().isSnapshot, true)
	t.same(addon.errors, {})
end)

t.test('AHledger set to another market: one chat note, prices keep Haggler market', function()
	local api =
		FakeGame.newAHledgerAPI({ market = MARKET, pinnedMarket = OTHER_MARKET, updated = UPDATED, rows = ROWS })
	local game, addon, received = startWith(api)
	t.same(received, { { MARKET } })
	t.eq(#game.printed, 1)
	t.truthy(game.printed[1]:find('AHledger uses forever/pvp/horde/us', 1, true))
	game:Fire('PLAYER_LOGIN')
	t.eq(#game.printed, 1, 'said once')
	t.truthy(reasonOf(addon.prices:Get(LINEN, 'median'), 'marketMismatch'))
end)

t.test('AHledger on another market with nothing for Haggler: the note comes at PLAYER_LOGIN', function()
	local api = FakeGame.newAHledgerAPI({ market = OTHER_MARKET, updated = UPDATED, rows = ROWS })
	local game, addon, received = startWith(api)
	t.same(received, {})
	t.same(game.printed, {}, 'AHledger is there, so no "needs AHledger" notice')
	game:Fire('PLAYER_LOGIN')
	t.eq(#game.printed, 1)
	t.truthy(game.printed[1]:find('AHledger uses forever/pvp/horde/us', 1, true))
	scan(game)
	t.truthy(reasonOf(addon.prices:Get(LINEN, 'minimum'), 'noMarketTable'))
end)

t.group('client build 71037: GetRealmName answers ""')

local EU_NORMAL = 'forever/normal/horde/eu'
local EU_PVP = 'forever/pvp/horde/eu'

local function startRealmlessHorde(api)
	local game = newGame(api)
	game.env.GetRealmName = function()
		return ''
	end
	game.env.UnitFactionGroup = function()
		return 'Horde'
	end
	game.env.GetCurrentRegion = function()
		return 3
	end
	game.env.UnitGUID = function(unit)
		return unit == 'player' and 'Player-6928-00A1AEB0' or nil
	end
	return game, FakeGame.startAddon(t, game)
end

t.test("no realm name on a PvP character: the market is AHledger's, available, nothing said", function()
	local game, addon =
		startRealmlessHorde((FakeGame.newAHledgerAPI({ market = EU_PVP, updated = UPDATED, rows = ROWS })))
	t.eq(addon.prices:MarketKey(), EU_PVP)
	t.eq(addon.prices:SourceStatus().isAvailable, true)
	game:Fire('PLAYER_LOGIN')
	t.same(game.printed, {})
	t.same(addon.errors, {})
end)

t.test('no realm name on a Normal character: the Normal market stays available', function()
	local game, addon =
		startRealmlessHorde((FakeGame.newAHledgerAPI({ market = EU_NORMAL, updated = UPDATED, rows = ROWS })))
	t.eq(addon.prices:MarketKey(), EU_NORMAL)
	t.eq(addon.prices:SourceStatus().isAvailable, true)
	game:Fire('PLAYER_LOGIN')
	t.same(game.printed, {})
	t.same(addon.errors, {})
end)

t.test("no realm name and no GUID yet: the market waits for the character, then takes AHledger's", function()
	-- AHledger answers the Normal market until it knows the character (its GUID), as 0.15.1 does.
	local api, apiState = FakeGame.newAHledgerAPI({ market = EU_NORMAL, updated = UPDATED, rows = ROWS })
	local game = newGame(api)
	game.env.GetRealmName = function()
		return ''
	end
	game.env.UnitFactionGroup = function()
		return 'Horde'
	end
	game.env.GetCurrentRegion = function()
		return 3
	end
	local addon = FakeGame.startAddon(t, game)
	t.eq(addon.prices:MarketKey(), nil, 'not cached from a guess')
	game.env.UnitGUID = function(unit)
		return unit == 'player' and 'Player-6945-0052E899' or nil
	end
	apiState.market = EU_PVP
	game:Fire('PLAYER_LOGIN')
	t.eq(addon.prices:MarketKey(), EU_PVP)
	t.same(addon.errors, {})
end)
