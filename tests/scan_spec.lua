local t = ...
local ns = t.loadAddon()
local FakeGame = require('tests.fake_game')
local Scan, ScanStore = ns.Scan, ns.ScanStore

local LINEN, WOOL, SWORD = 2589, 2592, 2488

-- A scanner on a fake game; returns the game, the scanner and the list of saved snapshots.
local function newScanner(options)
	options = options or {}
	local game = FakeGame.new({ listings = options.listings, hasClock = options.hasClock })
	local wow = ns.Wow.create(game.env)
	local saved = {}
	local errors = {}
	local scanner = Scan.new({
		wow = wow,
		lastSavedAt = function()
			return options.lastSavedAt
		end,
		lastRequestedAt = function()
			return options.lastRequestedAt
		end,
		onSnapshot = options.onSnapshot or function(snapshot)
			saved[#saved + 1] = snapshot
		end,
		newFollowUp = options.newFollowUp,
		settings = function()
			return options.settings or { autoScan = true, graceSeconds = 8, frameBudgetMs = 6 }
		end,
		onError = function(where, err)
			errors[#errors + 1] = where .. ': ' .. tostring(err)
		end,
	})
	scanner:Enable()
	return game, scanner, saved, errors
end

local function manyListings(count)
	local listings = {}
	for index = 1, count do
		listings[index] = { LINEN, 1 + index % 20, 100 * (1 + index % 7) }
	end
	return listings
end

t.group('scan store')

t.test('a snapshot has min, units, sorted levels and the copper and stack seen', function()
	local builder = ScanStore.newBuilder()
	builder:Add(LINEN, 20, 2000, 4) -- 100 each
	builder:Add(LINEN, 5, 455, 2) -- 91 each, copper in the buyout, medium time left
	builder:Add(LINEN, 10, 1000, 1) -- 100 each again, short time left
	builder:Add(LINEN, 2, 200, 1)
	builder:Add(SWORD, 1, 50000)
	t.truthy(builder:Pack())
	local snapshot = builder:Snapshot(500, 'own')
	t.eq(type(snapshot.items[LINEN]), 'string', 'items are saved packed')
	t.eq(snapshot.items[LINEN], '37,1,20;91:5,100:32:12')
	local items = {}
	for itemId in pairs(snapshot.items) do
		items[itemId] = ScanStore.item(snapshot, itemId)
	end
	snapshot.items = items
	t.same(snapshot, {
		at = 500,
		source = 'own',
		count = 5,
		skipped = 0,
		hasBands = true,
		isPacked = true,
		items = {
			[LINEN] = {
				min = 91,
				units = 37,
				levels = {
					{ price = 91, qty = 5 },
					{ price = 100, qty = 32, short = 12 },
				},
				copperSeen = true,
				maxStackSeen = 20,
			},
			[SWORD] = {
				min = 50000,
				units = 1,
				levels = { { price = 50000, qty = 1 } },
				copperSeen = false,
				maxStackSeen = 1,
			},
		},
	})
end)

t.test('junk listings are dropped at the source', function()
	local builder = ScanStore.newBuilder()
	t.eq(builder:Add(LINEN, 5, 0), false, 'bid-only (no buyout)')
	t.eq(builder:Add(LINEN, 5, nil), false, 'no buyout at all')
	t.eq(builder:Add(LINEN, 5, -100), false, 'negative buyout')
	t.eq(builder:Add(LINEN, 5, math.huge), false, 'infinite buyout')
	t.eq(builder:Add(LINEN, 5, 0 / 0), false, 'NaN buyout')
	t.eq(builder:Add(LINEN, 5, '500'), false, 'string buyout')
	t.eq(builder:Add(LINEN, 5, 2 ^ 41), false, 'over the copper cap')
	t.eq(builder:Add(LINEN, 0, 500), false, 'no units')
	t.eq(builder:Add(LINEN, 1.5, 500), false, 'fractional stack')
	t.eq(builder:Add(LINEN, 20000, 500), false, 'impossible stack')
	t.eq(builder:Add(0, 5, 500), false, 'item 0')
	t.eq(builder:Add(nil, 5, 500), false, 'no item')
	t.eq(builder:Add('2589', 5, 500), false, 'string item id')
	t.eq(builder:Add(LINEN, 5, 500), true)
	builder:Pack()
	local snapshot = builder:Snapshot(1, 'passive')
	t.eq(snapshot.count, 1)
	t.eq(snapshot.skipped, 13)
	t.same(ScanStore.item(snapshot, LINEN).levels, { { price = 100, qty = 5 } })
end)

t.test('levels are capped per item; units still count every unit', function()
	local builder = ScanStore.newBuilder(3)
	for price = 1, 6 do
		builder:Add(LINEN, 2, price * 200)
	end
	builder:Pack()
	local item = ScanStore.item(builder:Snapshot(1, 'own'), LINEN)
	t.eq(#item.levels, 3)
	t.eq(item.isCapped, true)
	t.eq(item.levels[3].price, 300)
	t.eq(item.units, 12)
	t.eq(ScanStore.MAX_LEVELS, 50)
end)

t.test('unit prices round to whole copper, never under one', function()
	local builder = ScanStore.newBuilder()
	builder:Add(LINEN, 3, 1000) -- 333.3
	builder:Add(WOOL, 20, 1) -- 0.05
	builder:Pack()
	local snapshot = builder:Snapshot(1, 'own')
	t.eq(ScanStore.item(snapshot, LINEN).min, 333)
	t.eq(ScanStore.item(snapshot, WOOL).min, 1)
end)

t.test('packing stops when the budget says so and resumes', function()
	local builder = ScanStore.newBuilder()
	for itemId = 1, 10 do
		builder:Add(itemId, 1, 100)
	end
	local calls = 0
	t.eq(
		builder:Pack(function()
			calls = calls + 1
			return calls <= 4
		end),
		false
	)
	t.raises(function()
		builder:Snapshot(1, 'own')
	end, 'Pack has not finished')
	t.eq(builder:Pack(), true)
	local count = 0
	for _ in pairs(builder:Snapshot(1, 'own').items) do
		count = count + 1
	end
	t.eq(count, 10)
end)

t.test('saved snapshots are read back only with a usable shape', function()
	local market = {}
	t.eq(ScanStore.latest(market), nil)
	t.eq(ScanStore.save(market, { at = 10, source = 'own', count = 1, items = { [LINEN] = 'x' } }), true)
	t.eq(ScanStore.latest(market).at, 10)
	t.eq(ScanStore.save(market, { at = 20, source = 'own', count = 0, items = {} }), false, 'empty: refused')
	t.eq(ScanStore.save(market, { at = 20, source = 'own', count = 3, items = {} }), false, 'only junk rows')
	t.eq(ScanStore.latest(market).at, 10, 'the real snapshot is kept')
	t.eq(ScanStore.latest({ scan = { at = 'yesterday', items = {} } }), nil)
	t.eq(ScanStore.latest({ scan = { at = 10, items = 'lots' } }), nil)
	t.eq(ScanStore.latest({ scan = 5 }), nil)
	t.eq(ScanStore.latest(nil), nil)
	local snapshot = { at = 10, items = { [LINEN] = { levels = {} }, [WOOL] = 'junk', [SWORD] = { min = 1 } } }
	t.truthy(ScanStore.item(snapshot, LINEN))
	t.eq(select(2, ScanStore.item(snapshot, LINEN)), 10)
	t.same(ScanStore.item(snapshot, WOOL), { levels = {}, isMalformed = true }, 'a broken packed string')
	t.eq(ScanStore.item(snapshot, SWORD), nil, 'an item without levels')
	t.eq(ScanStore.item(nil, LINEN), nil)
end)

t.test('a packed item round-trips, capped and without copper', function()
	local item = ScanStore.unpackItem('12,2,2;200:2,400:2:1,600:2')
	t.same(item, {
		min = 200,
		units = 12,
		copperSeen = false,
		maxStackSeen = 2,
		isCapped = true,
		levels = { { price = 200, qty = 2 }, { price = 400, qty = 2, short = 1 }, { price = 600, qty = 2 } },
	})
	t.eq(ScanStore.packItem(item), '12,2,2;200:2,400:2:1,600:2')
end)

t.test('prices past 32 bits pack exactly (no %d wrap on Windows)', function()
	local price = 2 ^ 40
	local item = { units = 1, maxStackSeen = 1, copperSeen = false, levels = { { price = price, qty = 1 } } }
	local packed = ScanStore.packItem(item)
	t.eq(packed, '1,0,1;1099511627776:1')
	t.eq(ScanStore.unpackItem(packed).min, price)
end)

t.test('a malformed packed item reads as no levels and a flag, never an error', function()
	local broken = {
		'',
		'junk',
		'5,0,1;',
		'5,0,1;10:0',
		'5,0,1;10:5:9', -- more short units than listed
		'5,0,1;20:5,10:5', -- not cheapest first
		'5,0,1;10:5,',
		'5,0,1;,10:5', -- a leading comma
		'5,0,1;10:5,,20:5', -- an empty entry
		'5,9,1;10:5', -- unknown flags
		'5,0,1;10:5;10:5',
		'1e400,0,1;10:5',
		'5,0,1;' .. string.rep('9', 400) .. ':5',
	}
	for _, packed in ipairs(broken) do
		local snapshot = { at = 10, isPacked = true, items = { [LINEN] = packed } }
		local item = ScanStore.item(snapshot, LINEN)
		t.same(item, { levels = {}, isMalformed = true }, packed)
	end
end)

t.test('unpacked items are cached for the session, within a limit', function()
	local snapshot = { at = 10, isPacked = true, items = { [LINEN] = '5,0,5;10:5' } }
	local first = ScanStore.item(snapshot, LINEN)
	t.truthy(first == ScanStore.item(snapshot, LINEN), 'the same table from the cache')
	for index = 1, ScanStore.CACHE_LIMIT + 1 do
		ScanStore.item({ at = 10, isPacked = true, items = { [1] = index .. ',0,1;1:' .. index } }, 1)
	end
	t.truthy(ScanStore.cachedCount() <= ScanStore.CACHE_LIMIT)
end)

t.test('a malformed saved item prices as bad input, with a reason', function()
	local snapshot = { at = 10, isPacked = true, items = { [LINEN] = '5,0,1;20:5,10:5' } }
	local rule = { id = 'r', name = 'R', base = { kind = 'lowest' }, steps = {} }
	local price = ns.Rules.evaluate(rule, LINEN, {
		now = 20,
		scanItem = function(itemId)
			return ScanStore.item(snapshot, itemId)
		end,
		priceRow = function()
			return { min = 100, median = 100, sold = 10 }, 10
		end,
	})
	local texts = {}
	for _, reason in ipairs(price and price.confidence.reasons or {}) do
		texts[#texts + 1] = reason.text
	end
	t.truthy(
		table.concat(texts, ' / '):find('saved scan of this item was not usable', 1, true),
		table.concat(texts, ' / ')
	)
end)

t.group('scan: the 15-minute rule')

t.test('requests only after the grace delay once the house opens', function()
	local game, scanner = newScanner({ listings = {} })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(7)
	t.eq(game.replicateRequests, 0, 'still in the grace delay')
	game:Advance(1)
	t.eq(game.replicateRequests, 1)
	t.eq(scanner:Status().state, 'requested')
end)

t.test("another add-on's scan during the grace delay is read, and no request is made", function()
	local game, scanner, saved = newScanner({ listings = { { LINEN, 20, 2000 } } })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(2)
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	game:Advance(10)
	t.eq(game.replicateRequests, 0)
	t.eq(#saved, 1)
	t.eq(saved[1].source, 'passive')
	t.eq(scanner:NextAllowedIn(), Scan.MIN_INTERVAL - 10)
end)

t.test('no request within 15 minutes of the last saved scan, across a reload', function()
	local game = FakeGame.new()
	local game2, scanner = newScanner({ lastSavedAt = game.now - 14 * 60 })
	game2:Fire('AUCTION_HOUSE_SHOW')
	game2:Advance(30)
	t.eq(game2.replicateRequests, 0)
	t.eq(scanner:NextAllowedIn(), 60 - 30)
	local requested, reason = scanner:RequestNow()
	t.eq(requested, false)
	t.truthy(reason:find('15 minutes'), reason)
end)

t.test('a saved scan time in the future counts as now', function()
	local game = FakeGame.new()
	local _, scanner = newScanner({ lastSavedAt = game.now + 3 * 86400 })
	t.eq(scanner:Status().lastFullScanAt, game.now)
	t.eq(scanner:NextAllowedIn(), 15 * 60)
end)

t.test("another add-on's request blocks ours for 15 minutes, across a reload", function()
	local game = FakeGame.new()
	local game2, scanner = newScanner({ lastRequestedAt = game.now - 5 * 60 })
	game2:Fire('AUCTION_HOUSE_SHOW')
	game2:Advance(30)
	t.eq(game2.replicateRequests, 0)
	t.eq(scanner:NextAllowedIn(), 10 * 60 - 30)
end)

t.test('a recorded request older than 15 minutes does not block', function()
	local game = FakeGame.new()
	local game2, scanner = newScanner({ lastRequestedAt = game.now - 15 * 60 - 1 })
	t.eq(scanner:NextAllowedIn(), 0)
	game2:Fire('AUCTION_HOUSE_SHOW')
	game2:Advance(8)
	t.eq(game2.replicateRequests, 1)
end)

t.test('a recorded request time a little in the future counts as now', function()
	local game = FakeGame.new()
	local _, scanner = newScanner({ lastRequestedAt = game.now + 30 })
	t.eq(scanner:NextAllowedIn(), 15 * 60)
end)

t.test('a scan older than 15 minutes allows a request', function()
	local game = FakeGame.new()
	local game2 = newScanner({ lastSavedAt = game.now - 15 * 60 })
	game2:Fire('AUCTION_HOUSE_SHOW')
	game2:Advance(8)
	t.eq(game2.replicateRequests, 1)
end)

t.test('closing the house before the grace delay ends cancels the request', function()
	local game = newScanner()
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(3)
	game:Fire('AUCTION_HOUSE_CLOSED')
	game:Advance(30)
	t.eq(game.replicateRequests, 0)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('AUCTION_HOUSE_CLOSED')
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	t.eq(game.replicateRequests, 1, 'only the last open counts; stale grace timers do nothing')
end)

t.test('our own request blocks another for 15 minutes even without a reply', function()
	local game, scanner = newScanner()
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	t.eq(game.replicateRequests, 1)
	game:Advance(Scan.NO_REPLY_SECONDS)
	t.eq(scanner:Status().state, 'open')
	t.truthy(scanner:Status().lastError:find('no reply'))
	game:Fire('AUCTION_HOUSE_CLOSED')
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	t.eq(game.replicateRequests, 1)
	game:Advance(Scan.MIN_INTERVAL)
	game:Fire('AUCTION_HOUSE_CLOSED')
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	t.eq(game.replicateRequests, 2)
end)

t.test('a refusal blocks requests for 15 minutes from the refusal', function()
	local game, scanner = newScanner()
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	game:Advance(100)
	game:Fire('AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED')
	t.truthy(scanner:Status().lastError:find('refused'))
	t.eq(scanner:NextAllowedIn(), Scan.MIN_INTERVAL)
end)

t.test('auto scan off: no request, but passive scans are still read', function()
	local game, scanner, saved = newScanner({
		listings = { { LINEN, 1, 100 } },
		settings = { autoScan = false, graceSeconds = 8 },
	})
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(30)
	t.eq(game.replicateRequests, 0)
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 1)
	local requested, reason = scanner:RequestNow()
	t.eq(requested, false)
	t.truthy(reason:find('15 minutes'), reason)
end)

t.test('the reply to our request is an own scan', function()
	local game, _, saved = newScanner({ listings = { { LINEN, 1, 100 } } })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Advance(8)
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(saved[1].source, 'own')
	t.eq(saved[1].at, game.now)
end)

t.test('the same listing announced twice within a minute is read once', function()
	local game, _, saved = newScanner({ listings = { { LINEN, 1, 100 } } })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	game:Advance(30)
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 1)
end)

t.test('a listing that arrives while the house is closed is ignored', function()
	local game, _, saved = newScanner({ listings = { { LINEN, 1, 100 } } })
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 0)
end)

t.test('disabled: events are no longer heard and a read is dropped', function()
	local game, scanner, saved = newScanner({ listings = manyListings(5000) })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	scanner:Disable()
	game:RunFrames()
	t.eq(#saved, 0)
	t.eq(game.frame.events.REPLICATE_ITEM_LIST_UPDATE, nil)
	t.eq(scanner:Status().state, 'closed')
end)

t.group('scan: chunked read')

t.test('a big listing is read across frames within the frame budget', function()
	local game, _, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001 -- 6 ms = 6000 rows a frame
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game.rowsRead = 0
	game:NextFrame()
	t.truthy(game.rowsRead > 0 and game.rowsRead < 20000, 'first frame read part: ' .. game.rowsRead)
	t.truthy(game.rowsRead <= 6000 + Scan.CLOCK_CHECK_EVERY, 'within the budget: ' .. game.rowsRead)
	local frames = game:RunFrames()
	t.truthy(frames >= 3, 'took several frames: ' .. frames)
	t.eq(#saved, 1)
	t.eq(saved[1].count, 20000)
	t.eq(
		ScanStore.item(saved[1], LINEN).units,
		(function()
			local units = 0
			for index = 1, 20000 do
				units = units + 1 + index % 20
			end
			return units
		end)()
	)
end)

t.test('without a frame clock, slices are a fixed number of rows', function()
	local game, _, saved = newScanner({ listings = manyListings(5000), hasClock = false })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game.rowsRead = 0
	game:NextFrame()
	t.eq(game.rowsRead, Scan.ROWS_PER_SLICE)
	game:RunFrames()
	t.eq(saved[1].count, 5000)
end)

t.test('without a frame clock, packing and follow-up slices are a fixed, smaller number of items', function()
	local stepsPerSlice = {}
	local game = newScanner({
		listings = manyListings(10),
		hasClock = false,
		newFollowUp = function()
			local remaining = 3 * Scan.ITEMS_PER_SLICE
			return {
				Step = function(_, shouldContinue)
					local steps = 0
					while remaining > 0 and shouldContinue() do
						remaining, steps = remaining - 1, steps + 1
					end
					stepsPerSlice[#stepsPerSlice + 1] = steps
					return remaining == 0
				end,
				Result = function()
					return nil
				end,
			}
		end,
	})
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.same(stepsPerSlice, { Scan.ITEMS_PER_SLICE, Scan.ITEMS_PER_SLICE, Scan.ITEMS_PER_SLICE })
end)

t.test('the house closing mid-read reads the rest at once and saves the scan', function()
	local game, scanner, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	game:Fire('AUCTION_HOUSE_CLOSED')
	t.eq(scanner:Status().state, 'packing')
	game:RunFrames()
	t.eq(#saved, 1)
	t.eq(saved[1].count, 20000)
end)

t.test('the listing cleared at close drops the read; nothing partial is saved', function()
	local game, scanner, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	game.listings = {}
	game:Fire('AUCTION_HOUSE_CLOSED')
	game:RunFrames()
	t.eq(#saved, 0)
	t.eq(scanner:Status().state, 'closed')
	t.truthy(scanner:Status().lastError:find('cleared'), scanner:Status().lastError)
end)

t.test('a listing replaced mid-read starts the read over on the new one', function()
	local game, _, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	game.listings = { { WOOL, 2, 300 }, { WOOL, 1, 150 } }
	game:RunFrames()
	t.eq(#saved, 1)
	t.eq(saved[1].count, 2)
	t.eq(saved[1].items[LINEN], nil, 'nothing of the old listing is mixed in')
end)

t.test('a listing that keeps changing is given up', function()
	local game, scanner, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	for size = 1, Scan.MAX_RESTARTS + 1 do
		game:NextFrame()
		game.listings = manyListings(20000 + size)
	end
	game:RunFrames()
	t.eq(#saved, 0)
	t.truthy(scanner:Status().lastError:find('kept changing'), scanner:Status().lastError)
end)

-- A follow-up that needs a few slices, so the job stays in its comparing phase across frames.
local function slowFollowUp(slices)
	return function()
		local stepped = 0
		return {
			Step = function()
				stepped = stepped + 1
				return stepped >= slices
			end,
			Result = function()
				return { stepped = stepped }
			end,
		}
	end
end

t.test('repeat listing events while reading, packing and comparing complete as one saved scan', function()
	local listings = {}
	for index = 1, 20000 do
		listings[index] = { 1000 + index % 3000, 1, 100 }
	end
	local game, scanner, saved = newScanner({ listings = listings, newFollowUp = slowFollowUp(3) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	local seen = {}
	for _ = 1, 200 do
		local state = scanner:Status().state
		seen[state] = true
		if state == 'open' then
			break
		end
		-- AHledger's request answered again, or the client repeating the same event.
		game:Fire('REPLICATE_ITEM_LIST_UPDATE')
		game:NextFrame()
	end
	t.truthy(seen.reading and seen.packing and seen.comparing, 'went through every phase')
	t.eq(#saved, 1)
	t.eq(saved[1].count, 20000)
	t.eq(scanner:Status().lastError, nil)
end)

t.test('a listing replaced with an event mid-read still starts over on the new one', function()
	local game, _, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	game.listings = { { WOOL, 2, 300 }, { WOOL, 1, 150 } }
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 1)
	t.eq(saved[1].count, 2)
	t.eq(saved[1].items[LINEN], nil, 'nothing of the old listing is mixed in')
end)

t.test('a listing cleared with an event mid-read drops the read; nothing is saved', function()
	local game, scanner, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	game.listings = {}
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 0)
	t.truthy(scanner:Status().lastError:find('cleared'), scanner:Status().lastError)
end)

t.test('the last full scan is the last saved one; an unsaved listing still blocks requests', function()
	local game, scanner, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	local arrivedAt = game.now
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	t.eq(scanner:Status().lastFullScanAt, nil, 'nothing saved yet')
	t.eq(scanner:NextAllowedIn(), 15 * 60, 'the arrival starts the 15 minutes')
	game.listings = {}
	game:RunFrames()
	t.eq(#saved, 0)
	t.eq(scanner:Status().lastFullScanAt, nil, 'a dropped read is not a full scan')
	t.eq(scanner:NextAllowedIn(), 15 * 60)
	game.listings = manyListings(10)
	game:Advance(16 * 60)
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 1)
	t.eq(scanner:Status().lastFullScanAt, arrivedAt + 16 * 60)
end)

t.test('an empty listing is dropped with a reason, never saved', function()
	local game, scanner, saved = newScanner({ listings = {} })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 0)
	t.truthy(scanner:Status().lastError:find('empty'), scanner:Status().lastError)
	t.eq(scanner:Status().lastFullScanAt, nil)
end)

t.test('a read that starts over is dated from the new listing', function()
	local game, _, saved = newScanner({ listings = manyListings(20000) })
	game.msPerRow = 0.001
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:NextFrame()
	game.now = game.now + 40
	game.listings = { { WOOL, 2, 300 } }
	game:RunFrames()
	t.eq(#saved, 1)
	t.eq(saved[1].at, game.now)
end)

t.test('a client error while reading drops the read and is reported, never raised', function()
	local listings = manyListings(100)
	listings[50] = { throws = true }
	local game, scanner, saved, errors = newScanner({ listings = listings })
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#saved, 0)
	t.eq(#errors, 1)
	t.truthy(scanner:Status().lastError:find('client error'))
	t.eq(scanner:Status().state, 'open', 'the scanner is ready again')
end)

t.test('junk rows in a live listing are skipped, the rest saved', function()
	local game, _, saved = newScanner({
		listings = { { LINEN, 1, 100 }, { LINEN, 1, 0, 500 }, { nil, 1, 100 }, { LINEN, 2, 0 / 0 } },
	})
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(saved[1].count, 1)
	t.eq(saved[1].skipped, 3)
end)

t.test('a failing save is reported, not raised', function()
	local game, scanner, _, errors = newScanner({
		listings = { { LINEN, 1, 100 } },
		onSnapshot = function()
			error('disk full')
		end,
	})
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.eq(#errors, 1)
	t.truthy(scanner:Status().lastError:find('disk full'))
end)
