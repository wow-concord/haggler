local t = ...
local ns = t.loadAddon()
local FakeGame = require('tests.fake_game')
local ScanArchive, ScanStore = ns.ScanArchive, ns.ScanStore

local LINEN, WOOL, SWORD = 2589, 2592, 2488
local MARKET = 'forever/normal/alliance/us'
local HORDE = 'forever/normal/horde/us'
local DAY = 86400
local NOW = 100 * DAY + 12 * 3600

-- A packed snapshot from raw listings { itemId, stack, buyout }.
local function snapshotOf(listings, at, source)
	local builder = ScanStore.newBuilder()
	for _, listing in ipairs(listings) do
		builder:Add(listing[1], listing[2], listing[3], listing[4])
	end
	assert(builder:Pack())
	return builder:Snapshot(at or NOW, source or 'own')
end

local function entryOf(snapshot)
	local builder = assert(ScanArchive.newEntryBuilder(snapshot))
	t.truthy(builder:Step())
	return builder:Result()
end

local function sortedRecords(export)
	local records = export.records
	table.sort(records, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.itemId < b.itemId
	end)
	return records
end

-- A fake archive entry with count items, for retention tests; items are tiny but valid.
local function fakeEntry(at, count, source)
	local parts = {}
	for index = 1, count do
		parts[index] = string.format('%d,100,1,0,0,0,0', index)
	end
	return {
		at = at,
		source = source or 'own',
		listings = count,
		count = count,
		skipped = 0,
		items = table.concat(parts, ';'),
	}
end

local function ats(db, marketKey)
	local list = {}
	for index, entry in ipairs(db.markets[marketKey] or {}) do
		list[index] = entry.at
	end
	return list
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

t.group('scan archive')

t.test('opens an empty table as schema 1 and leaves a newer schema alone', function()
	local db = {}
	t.eq(ScanArchive.open(db), db)
	t.same(db, { schema = 1, markets = {} })
	local newer = { schema = 2, markets = { x = 1 } }
	local opened, reason = ScanArchive.open(newer)
	t.eq(opened, nil)
	t.eq(reason, 'newer schema')
	t.same(newer, { schema = 2, markets = { x = 1 } }, 'untouched')
	local broken = { schema = 1, markets = 'junk' }
	t.eq(ScanArchive.open(broken), broken)
	t.same(broken.markets, {}, 'a broken markets table is replaced')
end)

t.test('an entry keeps min, units and unit-weighted quantiles per item', function()
	-- Linen: 4 at 90, 6 at 100, 10 at 120 (20 units). Ranks: q10 2 -> 90, q25 5 -> 100,
	-- q50 10 -> 100, q75 15 -> 120.
	local snapshot = snapshotOf({ { LINEN, 4, 360 }, { LINEN, 6, 600 }, { LINEN, 10, 1200 }, { SWORD, 1, 50000 } })
	local entry = entryOf(snapshot)
	t.eq(entry.at, NOW)
	t.eq(entry.source, 'own')
	t.eq(entry.count, 2)
	t.eq(entry.listings, 4)
	local export = ScanArchive.export({ schema = 1, markets = { [MARKET] = { entry } } }, MARKET)
	t.same(sortedRecords(export), {
		{
			at = NOW,
			market = MARKET,
			source = 'own',
			itemId = SWORD,
			min = 50000,
			units = 1,
			q10 = 50000,
			q25 = 50000,
			q50 = 50000,
			q75 = 50000,
		},
		{
			at = NOW,
			market = MARKET,
			source = 'own',
			itemId = LINEN,
			min = 90,
			units = 20,
			q10 = 90,
			q25 = 100,
			q50 = 100,
			q75 = 120,
		},
	})
end)

t.test('quantiles past the kept levels of a capped item are unknown, not guessed', function()
	local listings = {}
	for price = 1, 4 do
		listings[#listings + 1] = { WOOL, 10, price * 10 }
	end
	local builder = ScanStore.newBuilder(2)
	for _, listing in ipairs(listings) do
		builder:Add(listing[1], listing[2], listing[3])
	end
	assert(builder:Pack())
	local entry = entryOf(builder:Snapshot(NOW, 'passive'))
	local record = ScanArchive.export({ schema = 1, markets = { [MARKET] = { entry } } }, MARKET).records[1]
	-- 40 units, 20 kept at 1 and 2 copper: q10 (rank 4) and q25 (rank 10) are known, q50 is
	-- rank 20 (the last kept unit), q75 rank 30 lies past the kept levels.
	t.same(
		record,
		{ at = NOW, market = MARKET, source = 'passive', itemId = WOOL, min = 1, units = 40, q10 = 1, q25 = 1, q50 = 2 }
	)
end)

t.test('quantile ranks are exact whole units', function()
	-- 30 units: q10 is unit 3 exactly (0.1 * 30 in floating point would round up to unit 4).
	local entry = entryOf(snapshotOf({ { LINEN, 3, 30 }, { LINEN, 27, 540 } }))
	t.eq(entry.items, '2589,10,30,0,10,0,0')
end)

t.test('an item record is packed as id,min,units then quantile steps', function()
	local entry = entryOf(snapshotOf({ { LINEN, 4, 360 }, { LINEN, 6, 600 }, { LINEN, 10, 1200 } }))
	t.eq(entry.items, '2589,90,20,0,10,0,20')
end)

t.test('the builder works a slice at a time', function()
	local listings = {}
	for itemId = 1, 50 do
		listings[itemId] = { itemId, 1, 100 }
	end
	local builder = assert(ScanArchive.newEntryBuilder(snapshotOf(listings)))
	local calls = 0
	local isDone = builder:Step(function()
		calls = calls + 1
		return calls <= 10
	end)
	t.eq(isDone, false)
	t.raises(function()
		builder:Result()
	end, 'Step has not finished')
	t.truthy(builder:Step())
	t.eq(builder:Result().count, 50)
end)

t.group('scan archive: own observations only')

t.test('only own and passive scans can be archived', function()
	local snapshot = snapshotOf({ { LINEN, 1, 100 } })
	for _, source in ipairs({ 'ahledger', 'scan', 'snapshot', 'import', '' }) do
		local tagged = deepCopy(snapshot)
		tagged.source = source
		local builder, reason = ScanArchive.newEntryBuilder(tagged)
		t.eq(builder, nil, source)
		t.eq(reason, 'not an own scan', source)
		local db = ScanArchive.open({})
		local entry = fakeEntry(NOW, 1, source)
		local isSaved, why = ScanArchive.record(db, MARKET, entry)
		t.eq(isSaved, false, source)
		t.eq(why, 'not an own scan', source)
		t.same(db.markets, {}, source)
	end
end)

t.test('an AHledger-derived value cannot enter the archive', function()
	-- A snapshot carrying AHledger rows (PriceData's PriceRow shape) as items, tagged own: the
	-- archive takes only packed listing strings, so none of it is kept.
	local ahledgerRow = { median = 120, min = 95, qty = 500, m7 = 118, m30 = 125, lo = 90, hi = 160, sold = 45 }
	local disguised = {
		at = NOW,
		source = 'own',
		count = 1,
		isPacked = true,
		items = { [LINEN] = ahledgerRow, [WOOL] = { min = 280, units = 80, levels = { { price = 280, qty = 80 } } } },
	}
	local builder = assert(ScanArchive.newEntryBuilder(disguised))
	t.truthy(builder:Step())
	t.eq(builder:Result(), nil, 'no record from a table item')

	-- End to end: AHledger prices Linen at 95 min / 120 median; the listing says 90 and 100.
	-- The archive holds the listing's figures and nothing else.
	local game = FakeGame.new({
		now = NOW,
		listings = { { LINEN, 20, 1800 }, { LINEN, 5, 500 } },
		itemInfo = { [LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 } },
	})
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({
		market = MARKET,
		updated = NOW - 3600,
		rows = { [LINEN] = { 120, 95, 500, 118, 125, 90, 160, 45 } },
	})
	local addon = FakeGame.startAddon(t, game)
	t.eq(addon.prices:Get(LINEN).source, 'ahledger', 'AHledger prices are in use')
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.same(addon.errors, {})
	local records = ScanArchive.export(game.savedArchiveDb, MARKET).records
	t.same(records, {
		{
			at = NOW,
			market = MARKET,
			source = 'passive',
			itemId = LINEN,
			min = 90,
			units = 25,
			q10 = 90,
			q25 = 90,
			q50 = 90,
			q75 = 90,
		},
	})
	local saved = game.savedArchiveDb.markets[MARKET][1].items
	for _, ahledgerFigure in ipairs({ '95', '120', '118', '125', '160', '45', '500' }) do
		t.eq(saved:find(ahledgerFigure, 1, true), nil, 'AHledger figure ' .. ahledgerFigure)
	end
end)

t.group('scan archive: saved data')

t.test('malformed records read as nothing and never raise', function()
	local good = '2589,90,20,0,10,0,20'
	local db = {
		schema = 1,
		markets = {
			[MARKET] = {
				{
					at = NOW,
					source = 'own',
					count = 9,
					items = table.concat({
						good,
						'2589,90,20', -- too few fields
						'x,1,1,0,0,0,0',
						'0,90,20,0,0,0,0', -- item id 0
						'2592,0,20,0,0,0,0', -- min 0
						'2592,90,0,0,0,0,0', -- no units
						'2592,90,20,,0,0,0', -- a known step after an unknown one
						'2592,90,20,1.5,0,0,0',
						'2592,90,20,-1,0,0,0',
						'2592,1099511627777,20,0,0,0,0', -- past MAX_COPPER
						'',
					}, ';'),
				},
				{ at = 'soon', source = 'own', items = good },
				{ at = NOW, source = 'ahledger', items = good },
				{ at = NOW, source = 'own', items = 42 },
				'junk',
				42,
			},
			[HORDE] = 'junk',
		},
	}
	local export = ScanArchive.export(db, MARKET)
	t.eq(#export.records, 1)
	t.eq(export.records[1].itemId, LINEN)
	t.eq(export.skipped, 9)
	t.same(ScanArchive.export(db, HORDE).records, {})
	for _, junk in ipairs({ {}, 'x', 42, { schema = 1, markets = 1 }, { schema = 1, markets = { [MARKET] = 'x' } } }) do
		t.same(ScanArchive.export(junk, MARKET).records, {})
	end
	t.same(ScanArchive.export(nil, MARKET).records, {})
end)

t.test('export is pure and filters by market and time range', function()
	local db = ScanArchive.open({})
	t.truthy(ScanArchive.record(db, MARKET, fakeEntry(NOW - 2 * DAY, 2)))
	t.truthy(ScanArchive.record(db, MARKET, fakeEntry(NOW - DAY, 1)))
	t.truthy(ScanArchive.record(db, MARKET, fakeEntry(NOW, 1, 'passive')))
	t.truthy(ScanArchive.record(db, HORDE, fakeEntry(NOW, 3)))
	local before = deepCopy(db)
	local export = ScanArchive.export(db, MARKET, NOW - DAY, NOW)
	t.same(db, before, 'the archive is not changed')
	t.eq(export.schema, 1)
	t.eq(export.market, MARKET)
	t.eq(#export.records, 2)
	t.eq(export.records[1].at, NOW - DAY)
	t.eq(export.records[2].source, 'passive')
	t.eq(#ScanArchive.export(db, MARKET).records, 4, 'no range: everything')
	t.eq(#ScanArchive.export(db, MARKET, nil, NOW - DAY).records, 3, 'open start')
end)

t.test('record keeps entries in time order and refuses a repeat or an empty entry', function()
	local db = ScanArchive.open({})
	t.truthy(ScanArchive.record(db, MARKET, fakeEntry(NOW, 1)))
	t.truthy(ScanArchive.record(db, MARKET, fakeEntry(NOW - 60, 1)))
	local isSaved, reason = ScanArchive.record(db, MARKET, fakeEntry(NOW, 1))
	t.eq(isSaved, false)
	t.eq(reason, 'already archived')
	isSaved, reason = ScanArchive.record(db, MARKET, { at = NOW + 60, source = 'own', count = 0, items = '' })
	t.eq(isSaved, false)
	t.eq(reason, 'empty')
	t.same(ats(db, MARKET), { NOW - 60, NOW })
	t.raises(function()
		ScanArchive.record(db, 'not a market', fakeEntry(NOW, 1))
	end, 'bad market key')
	t.raises(function()
		ScanArchive.record({}, MARKET, fakeEntry(NOW, 1))
	end, 'open')
end)

t.group('scan archive: retention')

t.test('recent days keep the fullest scan per six hours, older days the fullest per day', function()
	local db = ScanArchive.open({})
	local today = math.floor(NOW / DAY) * DAY
	-- Today (recent): two scans in the 06:00 slot, one in the 12:00 slot.
	ScanArchive.record(db, MARKET, fakeEntry(today + 7 * 3600, 5))
	ScanArchive.record(db, MARKET, fakeEntry(today + 8 * 3600, 9))
	ScanArchive.record(db, MARKET, fakeEntry(today + 12 * 3600, 4))
	-- Ten days ago (past the recent days): three scans in one day, two equally full.
	local old = today - 10 * DAY
	ScanArchive.record(db, MARKET, fakeEntry(old + 3600, 7))
	ScanArchive.record(db, MARKET, fakeEntry(old + 9 * 3600, 7))
	ScanArchive.record(db, MARKET, fakeEntry(old + 20 * 3600, 2))
	local dropped = ScanArchive.prune(db, NOW, { recentDays = 3, maxBytes = 2 ^ 30 })
	t.eq(dropped, 3)
	t.same(ats(db, MARKET), { old + 9 * 3600, today + 8 * 3600, today + 12 * 3600 }, 'ties go to the later scan')
end)

t.test('the size cap drops the oldest scans first and keeps each market newest', function()
	local db = ScanArchive.open({})
	for day = 5, 1, -1 do
		ScanArchive.record(db, MARKET, fakeEntry(NOW - day * DAY, 100))
	end
	ScanArchive.record(db, HORDE, fakeEntry(NOW - 9 * DAY, 100))
	local entryBytes = ScanArchive.entryBytes(db.markets[MARKET][1])
	t.truthy(entryBytes > 100 * 15, 'counts the packed items and the entry overhead')
	t.eq(ScanArchive.bytes(db), 6 * entryBytes)
	local dropped = ScanArchive.prune(db, NOW, { recentDays = 3, maxBytes = 3 * entryBytes })
	t.eq(dropped, 3)
	t.same(ats(db, MARKET), { NOW - 2 * DAY, NOW - DAY })
	t.same(ats(db, HORDE), { NOW - 9 * DAY }, 'the only scan of a market stays')
	ScanArchive.prune(db, NOW, { recentDays = 3, maxBytes = 1 })
	t.same(ats(db, MARKET), { NOW - DAY })
	t.same(ats(db, HORDE), { NOW - 9 * DAY })
end)

t.test('prune drops broken entries and markets', function()
	local db = {
		schema = 1,
		markets = { [MARKET] = { fakeEntry(NOW, 1), 'junk', { at = NOW } }, [HORDE] = 'junk' },
	}
	ScanArchive.prune(db, NOW, {})
	t.same(ats(db, MARKET), { NOW })
	t.eq(db.markets[HORDE], nil)
end)

t.test('a full 30k-item scan packs well under a megabyte', function()
	-- A deterministic stand-in for a full market: 30,000 items, 1 to 40 listings each, prices
	-- from 1 silver to 500 gold within 40% of the item's price.
	local seed = 12345
	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local builder = ScanStore.newBuilder()
	for itemId = 1, 30000 do
		local price = math.floor(math.exp(math.log(100) + random() * math.log(50000)))
		for _ = 1, 1 + math.floor(random() * random() * 40) do
			local stack = 1 + math.floor(random() * random() * 20)
			builder:Add(itemId + 1000, stack, math.floor(price * (1 + random() * 0.4)) * stack)
		end
	end
	assert(builder:Pack())
	local entry = entryOf(builder:Snapshot(NOW, 'own'))
	t.eq(entry.count, 30000)
	t.truthy(ScanArchive.entryBytes(entry) < 1024 * 1024, 'bytes ' .. ScanArchive.entryBytes(entry))
end)

t.group('scan archive: scan module')

t.test('each saved scan is archived and outlives the stale-market drop', function()
	local game = FakeGame.new({ now = NOW, listings = { { LINEN, 20, 1800 } } })
	local addon = FakeGame.startAddon(t, game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.same(ats(game.savedArchiveDb, MARKET), { NOW })
	-- 40 days later another market is scanned: the first market's scan is pruned, its
	-- archive is not.
	local later = NOW + 40 * DAY
	addon.store:Market(HORDE)
	ns.ScanStore.pruneStaleMarkets(addon.store:Markets(), later, 30)
	t.eq(addon.store:Market(MARKET).scan, nil)
	t.same(ats(game.savedArchiveDb, MARKET), { NOW })
	t.same(addon.errors, {})
end)

t.test('switching the archive off keeps scans out of it', function()
	local game = FakeGame.new({ now = NOW, listings = { { LINEN, 20, 1800 } } })
	local addon = FakeGame.startAddon(t, game)
	addon.host.RunCommand('set scan.archive off')
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	t.truthy(addon.store:Market(MARKET).scan, 'the scan is still saved')
	t.same(game.savedArchiveDb.markets, {})
end)

t.test('the status lines report the archive size', function()
	local game = FakeGame.new({ now = NOW, listings = { { LINEN, 20, 1800 } } })
	local addon = FakeGame.startAddon(t, game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
	local lines = table.concat(addon.host.RunCommand('scan status'), '\n')
	t.truthy(lines:find('Scan history: 1 scan, 0.0 of 32 MB', 1, true), lines)
end)

t.group('scan archive: review fixes')

t.test('open answers a non-table with a reason, never an error', function()
	for _, junk in ipairs({ 'junk', 42, true }) do
		local opened, reason = ScanArchive.open(junk)
		t.eq(opened, nil)
		t.eq(reason, 'not a table')
	end
end)

t.test("a market's newest scan stays beside its slot's fullest, which the slot keeps", function()
	local db = ScanArchive.open({})
	local today = math.floor(NOW / DAY) * DAY
	local fullest, newest, later = today + 12 * 3600, today + 13 * 3600 + 1800, today + 19 * 3600
	ScanArchive.record(db, MARKET, fakeEntry(fullest, 48))
	ScanArchive.record(db, MARKET, fakeEntry(newest, 30))
	ScanArchive.prune(db, newest, { recentDays = 3, maxBytes = 2 ^ 30 })
	t.same(ats(db, MARKET), { fullest, newest }, 'the newest is kept in addition to the fullest')
	-- Once a later scan arrives, the slot keeps its fullest scan as usual.
	ScanArchive.record(db, MARKET, fakeEntry(later, 1))
	ScanArchive.prune(db, later, { recentDays = 3, maxBytes = 2 ^ 30 })
	t.same(ats(db, MARKET), { fullest, later })
end)

t.test('a newest scan that is also the fullest is kept once, with nothing beside it', function()
	local db = ScanArchive.open({})
	local today = math.floor(NOW / DAY) * DAY
	ScanArchive.record(db, MARKET, fakeEntry(today + 12 * 3600, 10))
	ScanArchive.record(db, MARKET, fakeEntry(today + 13 * 3600, 20))
	ScanArchive.prune(db, today + 13 * 3600, { recentDays = 3, maxBytes = 2 ^ 30 })
	t.same(ats(db, MARKET), { today + 13 * 3600 })
end)

t.test('prune with a missing or broken now changes nothing', function()
	for _, now in ipairs({ false, 0 / 0, -1, 1 / 0 }) do
		local db = ScanArchive.open({})
		ScanArchive.record(db, MARKET, fakeEntry(NOW - DAY, 5))
		ScanArchive.record(db, MARKET, fakeEntry(NOW, 5))
		local before = deepCopy(db)
		t.eq(ScanArchive.prune(db, now or nil, { maxBytes = 1 }), 0, tostring(now))
		t.same(db, before, tostring(now))
	end
end)

t.test('only the newest scan at or before now is protected; far-future entries are dropped', function()
	local db = ScanArchive.open({})
	ScanArchive.record(db, MARKET, fakeEntry(NOW - 2 * DAY, 5))
	ScanArchive.record(db, MARKET, fakeEntry(NOW, 5))
	ScanArchive.record(db, MARKET, fakeEntry(NOW + 3600, 5))
	ScanArchive.record(db, MARKET, fakeEntry(NOW + 2 * DAY, 50))
	ScanArchive.prune(db, NOW, { recentDays = 3, maxBytes = 2 ^ 30 })
	t.same(ats(db, MARKET), { NOW - 2 * DAY, NOW, NOW + 3600 }, 'past a day ahead it is gone')
	local entryBytes = ScanArchive.entryBytes(fakeEntry(NOW, 5))
	ScanArchive.prune(db, NOW, { recentDays = 3, maxBytes = entryBytes })
	t.same(ats(db, MARKET), { NOW }, 'an entry ahead of now cannot take the protection')
end)

t.test('the slot and day edge sits exactly at recentFrom', function()
	local db = ScanArchive.open({})
	local now = NOW + 3600
	local recentFrom = now - 3 * DAY
	-- Both in the same six-hour slot and the same day; only recentFrom tells them apart.
	local slotStart = math.floor(recentFrom / ScanArchive.SLOT_SECONDS) * ScanArchive.SLOT_SECONDS
	t.truthy(recentFrom - 1 >= slotStart, 'the fixture straddles recentFrom inside one slot')
	ScanArchive.record(db, MARKET, fakeEntry(recentFrom - 1, 3))
	ScanArchive.record(db, MARKET, fakeEntry(recentFrom, 2))
	ScanArchive.record(db, MARKET, fakeEntry(now, 1))
	ScanArchive.prune(db, now, { recentDays = 3, maxBytes = 2 ^ 30 })
	t.same(ats(db, MARKET), { recentFrom - 1, recentFrom, now }, 'one counts by day, one by slot')
end)

t.test('days split at UTC midnight', function()
	local db = ScanArchive.open({})
	local midnight = math.floor(NOW / DAY) * DAY - 10 * DAY
	ScanArchive.record(db, MARKET, fakeEntry(midnight - 2, 4))
	ScanArchive.record(db, MARKET, fakeEntry(midnight - 1, 3))
	ScanArchive.record(db, MARKET, fakeEntry(midnight, 2))
	ScanArchive.record(db, MARKET, fakeEntry(midnight + 1, 1))
	ScanArchive.record(db, MARKET, fakeEntry(NOW, 1))
	ScanArchive.prune(db, NOW, { recentDays = 3, maxBytes = 2 ^ 30 })
	t.same(ats(db, MARKET), { midnight - 2, midnight, NOW })
end)

t.test('records with an implausible id or units, or leading zeros, read as nothing', function()
	local db = {
		schema = 1,
		markets = {
			[MARKET] = {
				{
					at = NOW,
					source = 'own',
					count = 9,
					items = table.concat({
						'2589,90,20,0,10,0,20',
						'10000001,90,20,0,0,0,0', -- item id past MAX_ITEM_ID
						'2592,90,1000000001,0,0,0,0', -- units past MAX_UNITS
						'02592,90,20,0,0,0,0',
						'2592,090,20,0,0,0,0',
						'2592,90,020,0,0,0,0',
						'2592,90,20,00,0,0,0',
						'2592,90,20,0,01,0,0',
					}, ';'),
				},
			},
		},
	}
	local export = ScanArchive.export(db, MARKET)
	t.eq(#export.records, 1)
	t.eq(export.skipped, 7)
end)

t.test('export is sorted by time even when saved out of order', function()
	local db = {
		schema = 1,
		markets = { [MARKET] = { fakeEntry(NOW, 1), fakeEntry(NOW - DAY, 1), fakeEntry(NOW - 2 * DAY, 1) } },
	}
	local times = {}
	for index, record in ipairs(ScanArchive.export(db, MARKET).records) do
		times[index] = record.at
	end
	t.same(times, { NOW - 2 * DAY, NOW - DAY, NOW })
end)

-- A game with a previous scan saved, so the new scan has a sales diff to record.
local function gameWithPreviousScan()
	local game = FakeGame.new({ now = NOW, listings = { { LINEN, 20, 1800 } } })
	local addon = FakeGame.startAddon(t, game, function(started)
		ScanStore.save(started.store:Market(MARKET), snapshotOf({ { LINEN, 30, 2700, 4 } }, NOW - 3600, 'own'))
	end)
	local announced, salesRecorded = {}, 0
	addon.host.Bus:Listen('spec', 'SCAN_READY', function(_, marketKey)
		announced[#announced + 1] = marketKey
	end)
	local record = addon.Sales.record
	addon.Sales.record = function(...)
		salesRecorded = salesRecorded + 1
		return record(...)
	end
	return game, addon, function()
		return announced, salesRecorded
	end
end

local function runScan(game)
	game:Fire('AUCTION_HOUSE_SHOW')
	game:Fire('REPLICATE_ITEM_LIST_UPDATE')
	game:RunFrames()
end

for _, failing in ipairs({ 'record', 'prune' }) do
	t.test('a throwing archive ' .. failing .. ' still records sales and sends SCAN_READY', function()
		local game, addon, results = gameWithPreviousScan()
		addon.ScanArchive[failing] = function()
			error('archive broke')
		end
		runScan(game)
		local announced, salesRecorded = results()
		t.same(announced, { MARKET })
		t.eq(salesRecorded, 1)
		t.eq(addon.scanControl.Status().lastError, nil, 'the scan is not reported as failed')
		local lines = table.concat(addon.host.RunCommand('scan status'), '\n')
		t.truthy(lines:find('Scan history problem: ', 1, true) and lines:find('archive broke', 1, true), lines)
	end)
end

t.test('an archive build failure shows in the scan status and costs only the history', function()
	local game, addon, results = gameWithPreviousScan()
	addon.ScanArchive.newEntryBuilder = function()
		return {
			Step = function()
				error('builder broke')
			end,
			Result = function()
				return nil
			end,
		}
	end
	runScan(game)
	local announced, salesRecorded = results()
	t.same(announced, { MARKET })
	t.eq(salesRecorded, 1)
	t.same(game.savedArchiveDb.markets, {})
	local lines = table.concat(addon.host.RunCommand('scan status'), '\n')
	t.truthy(lines:find('builder broke', 1, true), lines)
end)

t.test('archiveMaxMB reaches prune', function()
	local game = FakeGame.new({ now = NOW, listings = { { LINEN, 20, 1800 } } })
	local addon = FakeGame.startAddon(t, game)
	addon.host.RunCommand('set scan.archiveMaxMB 4')
	local seenOptions
	local prune = addon.ScanArchive.prune
	addon.ScanArchive.prune = function(db, now, options)
		seenOptions = options
		return prune(db, now, options)
	end
	runScan(game)
	t.eq(seenOptions.maxBytes, 4 * ScanArchive.BYTES_PER_MB)
end)
