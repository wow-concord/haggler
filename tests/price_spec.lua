local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, WOOL, SWORD = 2589, 2592, 2488
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local TABLE_UPDATED = NOW - 3 * 3600
-- AHledger rows: median, min buyout, quantity, 7- and 30-day median, 30-day low and high, sold a day.
local AHLEDGER_ROWS =
	{ [2589] = { 120, 95, 500, 118, 125, 90, 160, 45 }, [2592] = { 300, 280, 80, 290, 310, 250, 400, 0.5 } }

local function newGame(options)
	options = options or {}
	local game = FakeGame.new({
		now = NOW,
		listings = options.listings,
		itemInfo = {
			[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
			[WOOL] = { name = 'Wool Cloth', maxStack = 20, vendorPrice = 33 },
		},
	})
	if options.hasTable ~= false then
		game.env.AHledgerAPI =
			FakeGame.newAHledgerAPI({ market = MARKET, updated = TABLE_UPDATED, rows = AHLEDGER_ROWS })
	end
	return game
end

local function hasReason(price, code)
	for _, reason in ipairs(price.confidence.reasons) do
		if reason.code == code then
			return true
		end
	end
	return false
end

t.group('price context')

local ns = t.loadAddon()
local PriceContext, ScanStore = ns.PriceContext, ns.ScanStore

local function sourceWithTable(options)
	local apiOptions = { market = MARKET, updated = TABLE_UPDATED, rows = AHLEDGER_ROWS }
	for key, value in pairs(options or {}) do
		apiOptions[key] = value
	end
	local api = FakeGame.newAHledgerAPI(apiOptions)
	return ns.PriceData.newAHledgerSource(function()
		return api
	end)
end

t.test('joins the AHledger row, the scan item and the item info', function()
	local snapshot =
		{ at = NOW - 60, items = { [LINEN] = { min = 90, units = 40, levels = { { price = 90, qty = 40 } } } } }
	local ctx = PriceContext.build({
		now = NOW,
		marketKey = MARKET,
		priceSource = sourceWithTable(),
		snapshot = snapshot,
		itemInfo = function(itemId)
			return itemId == LINEN and { maxStack = 20, vendorPrice = 13 } or nil
		end,
	})
	local row, updated = ctx.priceRow(LINEN)
	t.eq(row.median, 120)
	t.eq(updated, TABLE_UPDATED)
	local scanItem, at = ctx.scanItem(LINEN)
	t.eq(scanItem.min, 90)
	t.eq(at, NOW - 60)
	t.same(ctx.itemInfo(LINEN), { maxStack = 20, vendorPrice = 13 })
	t.same(ctx.itemInfo(WOOL), {})
end)

t.test('a scan stack over one stands in for a max stack the client has not cached', function()
	local snapshot = {
		at = NOW,
		items = {
			[LINEN] = { levels = {}, maxStackSeen = 12 },
			[WOOL] = { levels = {}, maxStackSeen = 1 },
			[SWORD] = { levels = {}, maxStackSeen = 12 },
		},
	}
	local ctx = PriceContext.build({
		now = NOW,
		snapshot = snapshot,
		itemInfo = function(itemId)
			return itemId == SWORD and { maxStack = 1 } or nil
		end,
	})
	t.eq(ctx.itemInfo(LINEN).maxStack, 12)
	t.eq(ctx.itemInfo(WOOL).maxStack, nil, 'one proves nothing')
	t.eq(ctx.itemInfo(SWORD).maxStack, 1, 'the client wins when it knows')
	t.eq(ctx.priceRow, nil, 'no price source, no row source')
end)

t.test('junk from saved scans and the client is unknown, never an error', function()
	local snapshot = {
		at = NOW - 60,
		items = {
			[LINEN] = {
				min = 'cheap',
				units = 0 / 0,
				levels = { { price = '5', qty = 2 }, 'junk' },
				maxStackSeen = '20',
			},
		},
	}
	local ctx = PriceContext.build({
		now = NOW,
		marketKey = MARKET,
		priceSource = sourceWithTable(),
		snapshot = snapshot,
		itemInfo = function()
			return { maxStack = '20', vendorPrice = 0 / 0 }
		end,
	})
	local price, reason = ns.Rules.evaluate(ns.Rules.builtIns().realistic, LINEN, ctx)
	t.truthy(price, reason)
	t.eq(type(price.copper), 'number')
	t.truthy(hasReason(price, 'badInput'), 'the broken max stack is reported')
	local facts = PriceContext.facts(ctx, LINEN)
	t.eq(facts.listedUnits, nil)
	t.eq(facts.vendor, nil)
	t.eq(facts.maxStack, nil)
	t.eq(facts.lowestListed, 95, 'the AHledger lowest stands in for a junk scan minimum')
	t.eq(facts.lowestListedSource, 'ahledger')
	t.eq(facts.salesPerDay, 45)
	t.eq(facts.typicalPrice, 125, 'the 30-day median')
	t.eq(facts.recentPrice, 118, 'the 7-day median')
end)

t.test('a throwing source reads as no data for display and as bad input for a price', function()
	local ctx = PriceContext.build({
		now = NOW,
		marketKey = MARKET,
		priceSource = sourceWithTable(),
		itemInfo = function()
			error('client not ready')
		end,
	})
	ctx.realized = function()
		error('broken log')
	end
	local facts = PriceContext.facts(ctx, LINEN)
	t.eq(facts.vendor, nil)
	t.eq(facts.salesPerDay, 45)
	local price = ns.Rules.evaluate({ id = 'r', name = 'R', base = { kind = 'realized' }, steps = {} }, LINEN, ctx)
	t.eq(price, nil)
end)

t.test('facts give ages and depth from the sources', function()
	local snapshot = {
		at = NOW - 120,
		items = { [LINEN] = { min = 90, units = 45, levels = { { price = 90, qty = 5 }, { price = 99, qty = 40 } } } },
	}
	local ctx =
		PriceContext.build({ now = NOW, marketKey = MARKET, priceSource = sourceWithTable(), snapshot = snapshot })
	t.same(PriceContext.facts(ctx, LINEN), {
		salesPerDay = 45,
		salesSource = 'ahledger',
		listedUnits = 45,
		levels = snapshot.items[LINEN].levels,
		levelCount = 2,
		lowestListed = 90,
		lowestListedSource = 'scan',
		typicalPrice = 125,
		recentPrice = 118,
		scanAge = 120,
		rowAge = 3 * 3600,
	})
	t.same(PriceContext.facts(ctx, SWORD), {})
end)

t.test("a scan without this item: the lowest listing is AHledger's, with its row age, never the scan's", function()
	local snapshot = { at = NOW - 120, items = { [LINEN] = { min = 90, units = 45, levels = {} } } }
	local ctx =
		PriceContext.build({ now = NOW, marketKey = MARKET, priceSource = sourceWithTable(), snapshot = snapshot })
	local facts = PriceContext.facts(ctx, WOOL)
	t.eq(facts.lowestListed, 280)
	t.eq(facts.lowestListedSource, 'ahledger')
	t.eq(facts.scanAge, nil, 'the item is not in the scan, so the scan has no age for it')
	t.eq(facts.rowAge, 3 * 3600)
end)

t.test("an item in the scan without a minimum: the lowest listing is AHledger's", function()
	local snapshot = { at = NOW - 120, items = { [WOOL] = { units = 0, levels = {} } } }
	local ctx =
		PriceContext.build({ now = NOW, marketKey = MARKET, priceSource = sourceWithTable(), snapshot = snapshot })
	local facts = PriceContext.facts(ctx, WOOL)
	t.eq(facts.lowestListed, 280)
	t.eq(facts.lowestListedSource, 'ahledger')
end)

t.test('build needs now', function()
	t.raises(function()
		PriceContext.build({})
	end, 'need now')
end)

t.group('price service')

local function newService(options)
	options = options or {}
	local store = assert(ns.Store.open({}, {}))
	if options.snapshot then
		ScanStore.save(store:Market(MARKET), options.snapshot)
	end
	return ns.PriceService.new({
		now = function()
			return NOW
		end,
		store = store,
		priceSource = sourceWithTable(),
		marketKey = function()
			return options.marketKey == nil and MARKET or options.marketKey or nil
		end,
		itemInfo = function(itemId)
			return itemId == LINEN and { maxStack = 20, vendorPrice = 13 } or nil
		end,
		confidence = options.confidence,
		requestItemData = options.requestItemData,
		nextFrame = options.nextFrame,
	}),
		store
end

t.test('item data requests are spread over frames, each item once', function()
	local requested, frames = {}, {}
	local service = newService({
		requestItemData = function(itemId)
			requested[#requested + 1] = itemId
		end,
		nextFrame = function(fn)
			frames[#frames + 1] = fn
			return true
		end,
	})
	local count = ns.PriceService.ITEM_REQUESTS_PER_FRAME * 2 + 3
	for itemId = 100, 99 + count do
		t.eq(service:VendorPrice(itemId), nil)
		service:VendorPrice(itemId)
	end
	t.eq(#requested, 0, 'nothing in the same frame')
	local framesRun = 0
	while #frames > 0 do
		table.remove(frames, 1)()
		framesRun = framesRun + 1
		t.truthy(#requested <= framesRun * ns.PriceService.ITEM_REQUESTS_PER_FRAME)
	end
	t.eq(#requested, count)
	t.eq(framesRun, 3)
	t.eq(requested[1], 100)
end)

t.test('without a frame clock item data is requested at once', function()
	local requested = {}
	local service = newService({
		requestItemData = function(itemId)
			requested[#requested + 1] = itemId
		end,
	})
	service:VendorPrice(100)
	t.same(requested, { 100 })
end)

t.test('prices under the default rule or a named one', function()
	local service = newService()
	local realistic = service:Get(LINEN)
	t.eq(realistic.source, 'ahledger')
	t.eq(realistic.ageSeconds, 3 * 3600)
	local median = service:Get(LINEN, 'median')
	t.eq(median.copper, 120)
	t.same(service:Simple(LINEN), { copper = realistic.copper, ageSeconds = realistic.ageSeconds, source = 'ahledger' })
end)

t.test('bad calls return a reason, never throw', function()
	local service = newService()
	for _, itemId in ipairs({ '2589', 0, -1, 1.5, 0 / 0, math.huge }) do
		local price, reason = service:Get(itemId)
		t.eq(price, nil)
		t.truthy(reason:find('item id'), reason)
	end
	t.eq(service:Get(nil), nil)
	local price, reason = service:Get(LINEN, 'nope')
	t.eq(price, nil)
	t.eq(reason, 'unknown rule nope')
	t.eq(service:Simple('x'), nil)
	t.eq(service:Get(SWORD), nil, 'an item nobody trades')
end)

t.test('the latest scan is used once it is saved', function()
	local service = newService({
		snapshot = {
			at = NOW - 60,
			source = 'own',
			count = 3,
			items = { [LINEN] = { min = 100, units = 30, levels = { { price = 100, qty = 30 } }, copperSeen = false } },
		},
	})
	local realistic = service:Get(LINEN)
	t.eq(realistic.source, 'scan')
	t.eq(realistic.ageSeconds, 3 * 3600, 'its cap reads the AHledger median, so the older age counts')
	local minimum = service:Get(LINEN, 'minimum')
	t.eq(minimum.source, 'scan')
	t.eq(minimum.ageSeconds, 60)
	t.same(service:Ages(), { scanAge = 60, tableAge = 3 * 3600, isSnapshot = false })
end)

t.test('without a market key there is no table and no scan, and nothing breaks', function()
	local service = newService({ marketKey = false })
	t.eq(service:MarketKey(), nil)
	local price, reason = service:Get(LINEN)
	t.eq(price, nil)
	t.eq(type(reason), 'string')
	t.same(service:Ages(), { isSnapshot = false })
end)

t.test('rules list the default first; the default can move', function()
	local service, store = newService()
	local rules = service:Rules()
	t.eq(rules[1].id, 'realistic')
	t.eq(rules[1].isDefault, true)
	t.eq(#rules, #store:RuleIds())
	store:SetDefaultRule('median')
	t.eq(service:DefaultRule(), 'median')
	t.eq(service:Rules()[1].id, 'median')
	t.eq(service:Get(LINEN).copper, 120)
end)

t.test('the confidence settings reach the rules', function()
	local strict = newService({
		confidence = function()
			return { staleMediumHours = 1, staleLowHours = 2 }
		end,
	})
	t.eq(strict:Get(LINEN, 'median').confidence.level, 'low')
	t.eq(newService():Get(LINEN, 'median').confidence.level, 'high')
	local broken = newService({
		confidence = function()
			error('settings gone')
		end,
	})
	t.truthy(broken:Get(LINEN, 'median'), 'a throwing settings source falls back to the defaults')
end)

t.test('a quote prices every rule from one context, with facts and ages', function()
	local service = newService()
	local quote = service:Quote(LINEN, { 'realistic', 'median', 'gone' })
	t.eq(#quote.prices, 3)
	t.eq(quote.prices[1].isDefault, true)
	t.eq(quote.prices[2].price.copper, 120)
	t.same(quote.prices[2].price.inputs, { ahledger = true }, 'every quote carries its input set')
	t.eq(type(quote.prices[1].price.inputs), 'table')
	t.eq(quote.prices[3].price, nil)
	t.eq(quote.prices[3].reason, 'unknown rule gone')
	t.eq(quote.facts.salesPerDay, 45)
	t.eq(quote.ages.tableAge, 3 * 3600)
end)

t.group('price providers')

t.test('price v1 and haggler.price v1 are provided once the add-on starts', function()
	local addon = FakeGame.startAddon(t, newGame())
	local price = addon.host.Get('price', 1)
	local haggler = addon.host.Get('haggler.price', 1)
	local simple = price.get(LINEN)
	t.eq(simple.source, 'ahledger')
	t.eq(simple.ageSeconds, 3 * 3600)
	t.eq(simple.copper, haggler.get(LINEN).copper)
	t.eq(haggler.get(LINEN, 'median').copper, 120)
	t.eq(haggler.get(LINEN, 'median').confidence.level, 'high')
	t.eq(haggler.defaultRule(), 'realistic')
	t.eq(haggler.rules()[1].id, 'realistic')
	t.same(addon.errors, {})
end)

t.test('careless callers get nothing back and do not switch the provider off', function()
	local addon = FakeGame.startAddon(t, newGame())
	local price = addon.host.Get('price', 1)
	for _ = 1, 10 do
		t.eq(price.get('linen'), nil)
		t.eq(price.get(nil), nil)
	end
	t.truthy(price.get(LINEN), 'still answering')
	t.same(addon.host.Diagnostics(), {})
end)

t.test('PRICE_TABLE_LOADED names the markets the saved tables cover', function()
	local received
	FakeGame.startAddon(t, newGame(), function(addon)
		addon.host.Bus:Listen('spec', 'PRICE_TABLE_LOADED', function(_, marketKeys)
			received = marketKeys
		end)
	end)
	t.same(received, { MARKET })
end)

t.test('no saved tables: no message, and prices come from the scan alone', function()
	local received
	local game = newGame({ hasTable = false, listings = { { LINEN, 20, 2000 } } })
	local addon = FakeGame.startAddon(t, game, function(started)
		started.host.Bus:Listen('spec', 'PRICE_TABLE_LOADED', function()
			received = true
		end)
	end)
	t.eq(received, nil)
	t.eq(addon.prices:Get(LINEN), nil)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(addon.host.Get('price').get(LINEN).source, 'scan')
end)

t.group('scan module')

t.test('a read scan is saved to the market and announced with SCAN_READY', function()
	local announced = {}
	local game = newGame({ listings = { { LINEN, 20, 1800 }, { LINEN, 5, 500 } } })
	local addon = FakeGame.startAddon(t, game, function(started)
		started.host.Bus:Listen('spec', 'SCAN_READY', function(_, marketKey, summary)
			announced[#announced + 1] = { marketKey = marketKey, summary = summary }
		end)
	end)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.same(announced, { { marketKey = MARKET, summary = { at = NOW, source = 'passive', count = 2 } } })
	t.eq(ns.ScanStore.item(addon.store:Market(MARKET).scan, LINEN).min, 90)
	t.eq(addon.prices:Get(LINEN).source, 'scan')
end)

t.test('a saved scan counts for the 15-minute rule after a reload', function()
	local game = newGame({ listings = { { LINEN, 1, 100 } } })
	local addon = FakeGame.startAddon(t, game, function(started)
		ns.ScanStore.save(
			started.store:Market(MARKET),
			{ at = NOW - 5 * 60, source = 'own', count = 1, items = { [LINEN] = 'x' } }
		)
	end)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(30)
	t.eq(game.replicateRequests, 0)
	t.truthy(addon.host.RunCommand('scan status')[3]:find('Next request allowed in 9 min', 1, true))
end)

t.test('the status line shows no full scan until one is saved, then its age', function()
	local game = newGame({ listings = { { LINEN, 1, 100 } } })
	local addon = FakeGame.startAddon(t, game)
	game:Fire('AUCTION_HOUSE_SHOW')
	t.eq(addon.host.RunCommand('scan status')[2], 'Last full scan: no full scan saved yet')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	t.eq(addon.host.RunCommand('scan status')[2], 'Last full scan: no full scan saved yet', 'while reading')
	game:RunFrames()
	t.eq(addon.host.RunCommand('scan status')[2], 'Last full scan: just now')
	game:Advance(5 * 60)
	t.eq(addon.host.RunCommand('scan status')[2], 'Last full scan: 5 min ago')
end)

t.test("any add-on's scan request is recorded and survives a reload", function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game)
	-- Another add-on (AHledger) asks for the full listing; Haggler has not read it yet.
	game.env.C_AuctionHouse.ReplicateItems()
	t.eq(game.replicateRequests, 1)
	t.eq(addon.store:Market(MARKET).replicateRequestedAt, NOW)
	-- /reload five minutes later, then the auction house opens.
	local reloaded = newGame()
	reloaded.now = NOW + 5 * 60
	reloaded.savedDb, reloaded.savedCharDb = game.savedDb, game.savedCharDb
	local reloadedAddon = FakeGame.startAddon(t, reloaded)
	reloaded:Fire('AUCTION_HOUSE_SHOW')
	reloaded:Advance(30)
	t.eq(reloaded.replicateRequests, 0, 'no request inside the shared 15 minutes')
	local status = reloadedAddon.host.RunCommand('scan status')
	t.eq(status[2], 'Last full scan: no full scan saved yet')
	t.truthy(status[3]:find('Next request allowed in 9 min', 1, true), status[2])
	t.same(reloadedAddon.errors, {})
end)

t.test('a saved request time far in the future is ignored and replaced on the next request', function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game, function(started)
		started.store:Market(MARKET).replicateRequestedAt = NOW + 3 * 86400
	end)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	t.eq(game.replicateRequests, 1, 'a clock that ran ahead does not block requests')
	t.eq(addon.store:Market(MARKET).replicateRequestedAt, NOW + 8)
end)

t.test("Haggler's own request is recorded once, through the same hook", function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	t.eq(game.replicateRequests, 1)
	t.eq(addon.store:Market(MARKET).replicateRequestedAt, NOW + 8)
	t.eq(game:HookCount(), 1, 'hooked once')
	addon.host.Disable('scan')
	addon.host.Enable('scan')
	t.eq(game:HookCount(), 1, 'not hooked again on re-enable')
end)

t.test('no C_AuctionHouse on the client: nothing is hooked and nothing fails', function()
	local game = newGame()
	game.env.C_AuctionHouse = nil
	local addon = FakeGame.startAddon(t, game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	t.eq(game:HookCount(), 0)
	t.same(addon.errors, {})
	t.eq(addon.host.RunCommand('scan status')[1], 'Scan: open')
end)

t.test('no faction yet: the scan is not saved and the problem is reported', function()
	local game = newGame({ listings = { { LINEN, 1, 100 } } })
	game.env.UnitFactionGroup = function()
		return nil
	end
	local addon = FakeGame.startAddon(t, game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.truthy(game.printed[1]:find('market is not known', 1, true), game.printed[1])
	t.eq(addon.store:Market(MARKET).scan, nil)
end)

t.test('/hag scan asks for a scan under the 15-minute rule', function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game)
	t.same(addon.host.RunCommand('scan'), { 'No scan requested: the auction house is closed.' })
	game:Fire('AUCTION_HOUSE_SHOW')
	t.same(addon.host.RunCommand('scan'), { 'Scan requested; the auction house sends the whole listing in a moment.' })
	t.eq(game.replicateRequests, 1)
	t.eq(addon.host.RunCommand('scan status')[1], 'Scan: requested')
end)

t.test('switching the scan module off stops listening and drops its command', function()
	local game = newGame({ listings = { { LINEN, 1, 100 } } })
	local addon = FakeGame.startAddon(t, game)
	addon.host.Disable('scan')
	-- The window and the top bar listen to the auction house opening too; with them off, nothing
	-- else does.
	addon.host.Disable('window')
	addon.host.Disable('topbar')
	t.eq(game.frame.events.AUCTION_HOUSE_SHOW, nil)
	t.eq(game.frame.events.REPLICATE_ITEM_LIST_UPDATE, nil)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(addon.store:Market(MARKET).scan, nil)
	t.same(addon.host.RunCommand('scan'), { 'Unknown command "scan". Try /hag help.' })
	addon.host.Enable('scan')
	t.eq(game.frame.events.AUCTION_HOUSE_SHOW, true)
end)

t.group('cache-only price context')

t.test('a cache-only context reads only cached item info and requests nothing', function()
	local read, cachedRead, requested = {}, {}, {}
	local service = ns.PriceService.new({
		now = function()
			return NOW
		end,
		store = assert(ns.Store.open({}, {})),
		priceSource = sourceWithTable(),
		marketKey = function()
			return MARKET
		end,
		itemInfo = function(itemId)
			read[#read + 1] = itemId
			return { maxStack = 20, vendorPrice = 13 }
		end,
		cachedItemInfo = function(itemId)
			cachedRead[#cachedRead + 1] = itemId
			return nil
		end,
		requestItemData = function(itemId)
			requested[#requested + 1] = itemId
		end,
		nextFrame = function(fn)
			fn()
			return true
		end,
	})
	local ctx = service:Context({ isCacheOnly = true })
	service:Get(LINEN, nil, ctx)
	service:Get(SWORD, nil, ctx)
	t.same(read, {}, 'the loading reader is never called')
	t.truthy(#cachedRead > 0)
	t.same(requested, {})
	service:Get(LINEN, nil, service:Context())
	t.truthy(#read > 0, 'a normal context still reads item info')
end)
