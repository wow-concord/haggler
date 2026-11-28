local t = ...
local ns = t.loadAddon()
local FakeGame = require('tests.fake_game')
local VendorStore, VendorPrices = ns.VendorStore, ns.VendorPrices

local THREAD, FLUX, ARROW, TOKEN_ITEM = 2320, 2880, 2515, 9999
local NOW = 2000000
local ALICE, BOB = 66, 1250

local function openStore()
	local archive = {}
	return assert(VendorStore.open(archive)), archive
end

local function observation(npcId, slots, options)
	options = options or {}
	return {
		vendor = {
			npcId = npcId,
			name = options.name or 'Vendor',
			zone = 'Elwynn',
			mapId = 1429,
			reaction = options.reaction,
		},
		slots = slots,
		isComplete = options.isComplete ~= false,
	}
end

local function pricesOf(db, seed, extra)
	return VendorPrices.new({
		db = function()
			return db
		end,
		seed = seed,
		now = function()
			return NOW + 600
		end,
		isVendorSold = extra and extra.isVendorSold,
	})
end

t.test('open never raises and fills the layout', function()
	t.eq(VendorStore.open(nil), nil)
	t.eq(select(2, VendorStore.open('junk')), 'not a table')
	local archive = { vendors = 'broken' }
	local db = VendorStore.open(archive)
	t.eq(db.schema, 2)
	t.same(db.byNpc, {})
	t.eq(archive.vendors, db)
	local broken = { vendors = { schema = 'x', byNpc = 7 } }
	t.truthy(VendorStore.open(broken))
	t.same(broken.vendors.byNpc, {})
end)

t.test('open leaves a newer schema untouched', function()
	local archive = { vendors = { schema = 3, byNpc = { [1] = 'future' } } }
	local db, reason = VendorStore.open(archive)
	t.eq(db, nil)
	t.eq(reason, 'newer schema')
	t.eq(archive.vendors.byNpc[1], 'future')
end)

t.test('the store sits beside the scan history without touching it', function()
	local archive = {}
	ns.ScanArchive.open(archive)
	VendorStore.open(archive)
	t.same(archive.markets, {})
	t.eq(archive.vendors.schema, 2)
	t.eq(archive.schema, 1)
end)

t.test('the vendor cap and the scan-history cap never count each other', function()
	local archive = {}
	local scanDb = ns.ScanArchive.open(archive)
	local db = VendorStore.open(archive)
	local slots = {}
	for index = 1, 30 do
		slots[index] = { itemId = 1000 + index, price = 100 }
	end
	VendorStore.record(db, observation(ALICE, slots), NOW)
	t.eq(ns.ScanArchive.bytes(scanDb), 0)
	t.eq(ns.ScanArchive.prune(scanDb, NOW, { maxBytes = 1 }), 0)
	t.truthy(db.byNpc[ALICE])
	scanDb.markets['forever/normal/alliance/us'] =
		{ { at = NOW, source = 'own', listings = 1, count = 1, skipped = 0, items = '1,100,1,0,0,0,0' } }
	local before = VendorStore.bytes(db)
	t.eq(VendorStore.prune(db, { maxBytes = 1 }), 0)
	t.eq(VendorStore.bytes(db), before)
	t.eq(#scanDb.markets['forever/normal/alliance/us'], 1)
end)

t.test('a newer whole file stays untouched; a newer merchant record does not stop the history', function()
	local archive = { schema = 99, markets = {} }
	t.eq(ns.ScanArchive.open(archive), nil)
	t.eq(select(2, VendorStore.open(archive)), 'newer archive')
	t.eq(archive.vendors, nil)
	local other = { vendors = { schema = 99 } }
	t.truthy(ns.ScanArchive.open(other))
	t.eq(VendorStore.open(other), nil)
	t.eq(other.vendors.schema, 99)
end)

t.test('record keeps the raw price, stack, stock and standing per vendor', function()
	local db = openStore()
	local saved, summary = VendorStore.record(
		db,
		observation(ALICE, {
			{ itemId = THREAD, price = 10, stack = 1, available = -1 },
			{ itemId = ARROW, price = 10, stack = 200, available = 3 },
		}, { reaction = 6 }),
		NOW
	)
	t.truthy(saved)
	t.same(summary, { added = 2, changed = 0, gone = 0 })
	local items = VendorStore.vendorItems(db, ALICE)
	t.eq(items[THREAD].price, 10)
	t.eq(items[ARROW].stack, 200)
	t.eq(items[ARROW].available, 3)
	t.eq(items[THREAD].available, -1)
	t.eq(items[THREAD].reaction, 6)
	t.eq(items[THREAD].seenAt, NOW)
	t.eq(db.byNpc[ALICE].zone, 'Elwynn')
	t.eq(db.byNpc[ALICE].mapId, 1429)
end)

t.test('an item a vendor stops selling is marked gone, not deleted', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 }, { itemId = FLUX, price = 9 } }), NOW)
	local _, summary = VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 } }), NOW + 60)
	t.eq(summary.gone, 1)
	local items = VendorStore.vendorItems(db, ALICE)
	t.eq(items[FLUX].goneAt, NOW + 60)
	t.eq(items[FLUX].seenAt, NOW)
	t.eq(items[THREAD].goneAt, nil)
	-- Back on the list: no longer gone.
	local _, again = VendorStore.record(
		db,
		observation(ALICE, { { itemId = FLUX, price = 9 }, { itemId = THREAD, price = 10 } }),
		NOW + 120
	)
	t.eq(again.changed, 1)
	t.eq(VendorStore.vendorItems(db, ALICE)[FLUX].goneAt, nil)
end)

t.test('an incomplete read marks nothing gone', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 }, { itemId = FLUX, price = 9 } }), NOW)
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 } }, { isComplete = false }), NOW + 60)
	t.eq(VendorStore.vendorItems(db, ALICE)[FLUX].goneAt, nil)
	t.eq(select(2, VendorStore.record(db, observation(ALICE, {}, { isComplete = false }), NOW)), 'no items')
end)

t.test('a slot that makes no record makes the read incomplete', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 }, { itemId = FLUX, price = 9 } }), NOW)
	local _, summary =
		VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 }, { itemId = 'junk' } }), NOW + 60)
	t.eq(summary.gone, 0)
	t.eq(VendorStore.vendorItems(db, ALICE)[FLUX].goneAt, nil)
	-- Only junk on a list that says it is complete still saves nothing.
	t.eq(select(2, VendorStore.record(db, observation(BOB, { 'x' }), NOW)), 'no items')
end)

t.test('price 0 without an extended cost is a failed slot and never overwrites a price', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 }, { itemId = FLUX, price = 9 } }), NOW)
	local _, summary = VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 0 }, { itemId = FLUX, price = 9 } }),
		NOW + 60
	)
	t.same(summary, { added = 0, changed = 0, gone = 0 })
	local items = VendorStore.vendorItems(db, ALICE)
	t.eq(items[THREAD].price, 10)
	t.eq(items[THREAD].seenAt, NOW)
	t.eq(items[THREAD].goneAt, nil)
	-- Price 0 beside a currency or item cost is a real offer.
	VendorStore.record(db, observation(ALICE, { { itemId = TOKEN_ITEM, price = 0, hasExtendedCost = true } }), NOW + 61)
	t.eq(VendorStore.vendorItems(db, ALICE)[TOKEN_ITEM].price, 0)
end)

t.test('record refuses a missing vendor and skips junk slots', function()
	local db = openStore()
	t.eq(select(2, VendorStore.record(db, { vendor = {} }, NOW)), 'no vendor')
	t.eq(select(2, VendorStore.record(db, 'junk', NOW)), 'no vendor')
	local saved = VendorStore.record(
		db,
		observation(
			ALICE,
			{ 'x', { itemId = -1, price = 5 }, { itemId = THREAD, price = 1.5 }, { itemId = FLUX, price = 9 } }
		),
		NOW
	)
	t.truthy(saved)
	local items = VendorStore.vendorItems(db, ALICE)
	t.eq(items[THREAD], nil)
	t.eq(items[FLUX].price, 9)
	t.raises(function()
		VendorStore.record({}, observation(ALICE, {}), NOW)
	end, 'open the store first')
end)

t.test('extended costs are kept and flagged', function()
	local db = openStore()
	VendorStore.record(
		db,
		observation(ALICE, {
			{
				itemId = TOKEN_ITEM,
				price = 0,
				costs = { { kind = 'currency', id = 1901, count = 50 }, { kind = 'item', id = 20558, count = 3 } },
			},
			{ itemId = FLUX, price = 100, hasExtendedCost = true },
		}),
		NOW
	)
	local items = VendorStore.vendorItems(db, ALICE)
	t.same(
		items[TOKEN_ITEM].costs,
		{ { kind = 'currency', id = 1901, count = 50 }, { kind = 'item', id = 20558, count = 3 } }
	)
	t.eq(#items[FLUX].costs, 1)
	t.truthy(VendorStore.offers(db, FLUX)[1].hasExtendedCost)
end)

t.test('broken records and vendors read as nothing', function()
	local db = openStore()
	db.byNpc[ALICE] =
		{ seenAt = NOW, items = '2320,10,1,-1,' .. NOW .. ',,,;junk;2880,1.5,1,-1,1,,,;2589,5,1,-1,1,,,zz' }
	db.byNpc[BOB] = 'broken'
	db.byNpc[7] = { items = 5 }
	local items = VendorStore.vendorItems(db, ALICE)
	t.eq(items[2320].price, 10)
	t.eq(items[2880], nil)
	t.eq(items[2589], nil)
	t.same(VendorStore.vendorItems(db, BOB), {})
	t.eq(VendorStore.export(db).skipped, 3)
	t.eq(VendorStore.prune(db), 2)
	t.eq(db.byNpc[BOB], nil)
end)

t.test('offers list every vendor cheapest first', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 12 } }, { name = 'Alice' }), NOW)
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 10 } }, { name = 'Bob' }), NOW)
	local offers = VendorStore.offers(db, THREAD)
	t.eq(#offers, 2)
	t.eq(offers[1].name, 'Bob')
	-- The index follows new reads.
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 8 } }, { name = 'Alice' }), NOW + 1)
	t.eq(VendorStore.offers(db, THREAD)[1].name, 'Alice')
end)

t.test('buyPrice prefers the cheapest unlimited vendor and counts vendors', function()
	local db = openStore()
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 8, available = 2 } }, { name = 'Alice' }),
		NOW
	)
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 10 } }, { name = 'Bob', reaction = 4 }), NOW)
	local price = pricesOf(db):BuyPrice(THREAD)
	t.eq(price.price, 10)
	t.eq(price.source, 'seen')
	t.eq(price.vendorCount, 2)
	t.eq(price.cheapestVendor.name, 'Bob')
	t.eq(price.cheapestVendor.npcId, BOB)
	t.eq(price.ageSeconds, 600)
	t.eq(price.isLimited, false)
	t.eq(price.isBasePrice, true)
end)

t.test('buyPrice falls to the cheapest limited vendor when none is unlimited', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 8, available = 2 } }), NOW)
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 9, available = 1 } }), NOW)
	local price = pricesOf(db):BuyPrice(THREAD)
	t.eq(price.price, 8)
	t.eq(price.isLimited, true)
	t.eq(price.isBasePrice, false)
end)

t.test('a discounted or unknown read never erases a vendor base price', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 8 } }, { reaction = 8 }), NOW)
	local first = VendorStore.vendorItems(db, ALICE)[THREAD]
	t.eq(first.reaction, 8)
	t.eq(first.basePrice, nil)
	t.eq(VendorStore.offers(db, THREAD)[1].isBasePrice, false)
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 } }, { reaction = 4 }), NOW + 1)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].reaction, 4)
	-- An exalted read, then one of unknown standing: the latest price moves, the base stays.
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 8, available = 4 } }, { reaction = 8 }),
		NOW + 2
	)
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 9, available = 3 } }), NOW + 3)
	local record = VendorStore.vendorItems(db, ALICE)[THREAD]
	t.eq(record.reaction, nil)
	t.eq(record.price, 9)
	t.eq(record.available, 3)
	t.eq(record.seenAt, NOW + 3)
	t.eq(record.basePrice, 10)
	t.eq(record.baseStack, 1)
	t.eq(record.baseSeenAt, NOW + 1)
	local offer = VendorStore.offers(db, THREAD)[1]
	t.eq(offer.price, 10)
	t.eq(offer.unitPrice, 10)
	t.eq(offer.isBasePrice, true)
	t.eq(offer.priceSeenAt, NOW + 1)
	t.eq(offer.latestPrice, 9)
	t.eq(offer.seenAt, NOW + 3)
	t.eq(offer.priceFromBase, true)
	local price = pricesOf(db):BuyPrice(THREAD)
	t.eq(price.price, 10)
	t.eq(price.isBasePrice, true)
	t.eq(price.ageSeconds, 600 - 1)
	-- The latest read's standing is unknown; priceFromBase says the price is not from it.
	t.eq(price.cheapestVendor.reaction, nil)
	t.eq(price.cheapestVendor.priceFromBase, true)
	-- Gone still applies to the kept base.
	VendorStore.record(db, observation(ALICE, { { itemId = FLUX, price = 9 } }, { reaction = 8 }), NOW + 4)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].goneAt, NOW + 4)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].basePrice, 10)
	-- A later base read replaces the kept base and needs none beside it.
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 11 } }, { reaction = 3 }), NOW + 5)
	local rebased = VendorStore.vendorItems(db, ALICE)[THREAD]
	t.eq(rebased.price, 11)
	t.eq(rebased.basePrice, nil)
	t.eq(VendorStore.offers(db, THREAD)[1].price, 11)
	t.eq(pricesOf(db):BuyPrice(THREAD).cheapestVendor.priceFromBase, false)
end)

t.test('a dearer discounted read proves the kept base stale', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 100 } }, { reaction = 4 }), NOW)
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 150 } }, { reaction = 8 }), NOW + 60)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].basePrice, nil)
	local price = pricesOf(db):BuyPrice(THREAD)
	t.eq(price.price, 150)
	t.eq(price.isBasePrice, false)
	-- The review's case: base 100, a year later an exalted read at 150.
	local yearDb = openStore()
	VendorStore.record(yearDb, observation(ALICE, { { itemId = THREAD, price = 100 } }, { reaction = 4 }), NOW)
	VendorStore.record(
		yearDb,
		observation(ALICE, { { itemId = THREAD, price = 150 } }, { reaction = 8 }),
		NOW + 365 * 24 * 60 * 60
	)
	local yearPrice = pricesOf(yearDb):BuyPrice(THREAD)
	t.truthy(not (yearPrice.price == 100 and yearPrice.isBasePrice), 'a stale base never answers')
	t.eq(yearPrice.price, 150)
	t.eq(yearPrice.isBasePrice, false)
end)

t.test('a kept base older than BASE_MAX_AGE_SECONDS before the latest read is dropped', function()
	local db = openStore()
	local maxAge = VendorStore.BASE_MAX_AGE_SECONDS
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 100 } }, { reaction = 4 }), NOW)
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 90 } }, { reaction = 8 }), NOW + maxAge)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].basePrice, 100)
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 90 } }, { reaction = 8 }), NOW + maxAge + 1)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].basePrice, nil)
	local price = pricesOf(db, { build = 'test', items = { [THREAD] = 95 } }):BuyPrice(THREAD)
	t.eq(price.source, 'seed')
	t.eq(price.price, 95)
	t.eq(pricesOf(db):BuyPrice(THREAD).price, 90)
	-- A record saved with a stale base reads without it.
	local saved = openStore()
	saved.byNpc[ALICE] = {
		seenAt = NOW,
		items = string.format('2320,90,1,-1,%d,,8,,100,1,%d', NOW, NOW - maxAge - 1),
	}
	t.eq(VendorStore.vendorItems(saved, ALICE)[THREAD].basePrice, nil)
	t.eq(VendorStore.offers(saved, THREAD)[1].isBasePrice, false)
end)

t.test('an extended cost drops a kept copper base, in either order', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 } }, { reaction = 4 }), NOW)
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 5, hasExtendedCost = true } }, { reaction = 8 }),
		NOW + 1
	)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].basePrice, nil)
	t.eq(pricesOf(db):BuyPrice(THREAD), nil)
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 9 } }, { reaction = 8 }), NOW + 2)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].basePrice, nil)
	local reversed = openStore()
	VendorStore.record(
		reversed,
		observation(BOB, { { itemId = THREAD, price = 10, hasExtendedCost = true } }, { reaction = 4 }),
		NOW
	)
	VendorStore.record(reversed, observation(BOB, { { itemId = THREAD, price = 9 } }, { reaction = 8 }), NOW + 1)
	t.eq(VendorStore.vendorItems(reversed, BOB)[THREAD].basePrice, nil)
	t.eq(pricesOf(reversed):BuyPrice(THREAD).isBasePrice, false)
end)

t.test('a broken kept base price drops only the base price', function()
	local db = openStore()
	db.byNpc[ALICE] = { firstSeenAt = NOW, seenAt = NOW, items = '2320,9,1,-1,2000000,,8,,0,1,2000000' }
	local record = VendorStore.vendorItems(db, ALICE)[THREAD]
	t.eq(record.price, 9)
	t.eq(record.basePrice, nil)
	db.byNpc[ALICE].items = '2320,9,1,-1,2000000,,8,,10,1,1999999'
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].basePrice, 10)
	local head = '2320,9,1,-1,2000000,,8,'
	for label, tail in pairs({
		tenFields = ',10,1',
		twelveFields = ',10,1,1999999,5',
		negativeBase = ',-10,1,1999999',
		emptyBase = ',,1,1999999',
		emptyStack = ',10,,1999999',
		emptySeenAt = ',10,1,',
		stackOverCap = ',10,' .. (VendorStore.MAX_STACK + 1) .. ',1999999',
		seenAfterRead = ',10,1,2000001',
		junk = ',x',
	}) do
		db.byNpc[ALICE].items = head .. tail
		local parsed = VendorStore.vendorItems(db, ALICE)[THREAD]
		t.truthy(parsed and parsed.price == 9 and parsed.reaction == 8, label .. ': the read stays')
		t.eq(parsed.basePrice, nil, label)
		t.eq(parsed.baseStack, nil, label)
		t.eq(parsed.baseSeenAt, nil, label)
	end
	-- The stack of the read itself is capped the same way, and junk after the costs is no record.
	db.byNpc[ALICE].items = '2320,9,' .. (VendorStore.MAX_STACK + 1) .. ',-1,2000000,,8,'
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD], nil)
	db.byNpc[ALICE].items = '2320,9,1,-1,2000000,,8,c1x2zz'
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD], nil)
	local saved = VendorStore.record(
		db,
		observation(BOB, { { itemId = THREAD, price = 9, stack = VendorStore.MAX_STACK + 1 } }),
		NOW
	)
	t.eq(saved, false)
end)

t.test('export gives the raw records with the kept base beside the latest read', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = THREAD, price = 10 } }, { reaction = 4 }), NOW)
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 8, available = 3 } }, { reaction = 8 }),
		NOW + 1
	)
	local export = VendorStore.export(db)
	t.eq(export.schema, 2)
	t.same(export.vendors[1].items[1], {
		itemId = THREAD,
		price = 8,
		stack = 1,
		available = 3,
		seenAt = NOW + 1,
		reaction = 8,
		costs = {},
		basePrice = 10,
		baseStack = 1,
		baseSeenAt = NOW,
	})
	-- The export is a copy: changing it leaves the store alone.
	export.vendors[1].items[1].costs[1] = { kind = 'item', id = 1, count = 1 }
	t.same(VendorStore.vendorItems(db, ALICE)[THREAD].costs, {})
end)

t.test('a schema 1 store opens as schema 2 and keeps its records', function()
	local archive = {
		vendors = {
			schema = 1,
			byNpc = { [ALICE] = { firstSeenAt = NOW, seenAt = NOW, items = '2320,10,1,-1,2000000,,4,' } },
		},
	}
	local db, reason = VendorStore.open(archive)
	t.eq(reason, nil)
	t.eq(db.schema, 2)
	t.eq(VendorStore.vendorItems(db, ALICE)[THREAD].price, 10)
	t.eq(pricesOf(db):BuyPrice(THREAD).isBasePrice, true)
end)

t.test('a base-price read beats a cheaper discounted read from any vendor', function()
	local db = openStore()
	-- An exalted main at Alice, a neutral alt at Bob.
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 8 } }, { name = 'Alice', reaction = 8 }),
		NOW
	)
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 10 } }, { name = 'Bob', reaction = 4 }), NOW)
	local price = pricesOf(db):BuyPrice(THREAD)
	t.eq(price.price, 10)
	t.eq(price.cheapestVendor.name, 'Bob')
	t.eq(price.isBasePrice, true)
	t.eq(price.vendorCount, 2)
	-- A limited base-price offer still sets the price over an unlimited discounted one, but the
	-- item is not limited while any vendor sells it without a limit.
	VendorStore.record(
		db,
		observation(BOB, { { itemId = THREAD, price = 12, available = 3 } }, { name = 'Bob', reaction = 3 }),
		NOW + 1
	)
	local limited = pricesOf(db):BuyPrice(THREAD)
	t.eq(limited.price, 12)
	t.eq(limited.cheapestVendor.name, 'Bob')
	t.eq(limited.isLimited, false)
	t.eq(limited.isBasePrice, true)
end)

t.test('isLimited counts every usable vendor; at one price the unlimited vendor wins', function()
	local db = openStore()
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 10, available = 2 } }, { name = 'Alice', reaction = 4 }),
		NOW
	)
	local only = pricesOf(db):BuyPrice(THREAD)
	t.eq(only.isLimited, true)
	-- Bob's npc id sorts after Alice's, at the same price and without a limit.
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 10 } }, { name = 'Bob', reaction = 4 }), NOW)
	local price = pricesOf(db):BuyPrice(THREAD)
	t.eq(price.cheapestVendor.name, 'Bob')
	t.eq(price.isLimited, false)
	t.eq(VendorStore.offers(db, THREAD)[1].npcId, BOB)
end)

t.test('with only discounted reads the seed base price comes back with the seen count', function()
	local db = openStore()
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 8 } }, { name = 'Alice', reaction = 8 }),
		NOW
	)
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 9 } }, { name = 'Bob' }), NOW)
	local price = pricesOf(db, { build = 'test', items = { [THREAD] = 10 } }):BuyPrice(THREAD)
	t.eq(price.source, 'seed')
	t.eq(price.price, 10)
	t.eq(price.isBasePrice, true)
	t.eq(price.vendorCount, 2)
	t.eq(price.isLimited, false)
	t.eq(price.cheapestVendor, nil)
end)

t.test('with only discounted reads and no seed entry the discounted price comes back, flagged', function()
	local db = openStore()
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = THREAD, price = 8 } }, { name = 'Alice', reaction = 8 }),
		NOW
	)
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 9 } }, { name = 'Bob' }), NOW)
	local price = pricesOf(db, { build = 'test', items = { [FLUX] = 10 } }):BuyPrice(THREAD)
	t.eq(price.source, 'seen')
	t.eq(price.price, 8)
	t.eq(price.cheapestVendor.reaction, 8)
	t.eq(price.isBasePrice, false)
	t.eq(price.vendorCount, 2)
end)

t.test('buyPrice gives the unit price of a stack', function()
	local db = openStore()
	VendorStore.record(db, observation(ALICE, { { itemId = ARROW, price = 10, stack = 200 } }), NOW)
	local price = pricesOf(db):BuyPrice(ARROW)
	t.eq(price.price, 0.05)
	t.eq(price.stackPrice, 10)
	t.eq(price.stack, 200)
end)

t.test('seen prices beat the seed; gone and extended-cost offers fall back to it', function()
	local seed =
		{ build = 'test', items = { [THREAD] = 11, [ARROW] = { 10, 200 }, [FLUX] = 9 }, limited = { [FLUX] = true } }
	local db = openStore()
	VendorStore.record(
		db,
		observation(
			ALICE,
			{ { itemId = THREAD, price = 10 }, { itemId = FLUX, price = 50, hasExtendedCost = true } },
			{ reaction = 4 }
		),
		NOW
	)
	local prices = pricesOf(db, seed)
	t.eq(prices:BuyPrice(THREAD).source, 'seen')
	local flux = prices:BuyPrice(FLUX)
	t.eq(flux.source, 'seed')
	t.eq(flux.price, 9)
	t.eq(flux.isLimited, true)
	t.eq(flux.vendorCount, 0)
	VendorStore.record(db, observation(ALICE, { { itemId = FLUX, price = 50, hasExtendedCost = true } }), NOW + 1)
	t.eq(prices:BuyPrice(THREAD).source, 'seed')
	t.eq(prices:BuyPrice(THREAD).price, 11)
	t.eq(prices:BuyPrice(ARROW).price, 0.05)
	t.eq(prices:BuyPrice(12345), nil)
end)

t.test('buyPrice survives a missing store, a broken seed and asks Questie only to confirm', function()
	local prices = pricesOf(nil, { items = { [THREAD] = 'x', [FLUX] = { 0, 1 } } }, {
		isVendorSold = function(itemId)
			return itemId == ARROW
		end,
	})
	t.eq(prices:BuyPrice(THREAD), nil)
	t.eq(prices:BuyPrice(FLUX), nil)
	t.eq(prices:BuyPrice(ARROW), nil)
	local confirmed = pricesOf(nil, { items = { [ARROW] = { 10, 200 } } }, {
		isVendorSold = function()
			return true
		end,
	})
	t.eq(confirmed:BuyPrice(ARROW).isVendorConfirmed, true)
	t.eq(pricesOf(nil, { items = { [ARROW] = 1 } }):BuyPrice(ARROW).isVendorConfirmed, nil)
	t.raises(function()
		prices:BuyPrice('2320')
	end, 'whole number')
end)

t.test('export returns per-vendor records oldest first, filtered by time', function()
	local db = openStore()
	VendorStore.record(db, observation(BOB, { { itemId = THREAD, price = 10 } }, { name = 'Bob' }), NOW + 100)
	VendorStore.record(
		db,
		observation(ALICE, { { itemId = FLUX, price = 9 }, { itemId = THREAD, price = 12 } }, { name = 'Alice' }),
		NOW
	)
	local before = VendorStore.bytes(db)
	local export = VendorStore.export(db)
	t.eq(export.schema, 2)
	t.eq(#export.vendors, 2)
	t.eq(export.vendors[1].name, 'Alice')
	t.eq(export.vendors[1].items[1].itemId, THREAD)
	t.eq(export.vendors[1].items[1].price, 12)
	t.eq(export.vendors[1].items[2].itemId, FLUX)
	t.eq(export.vendors[2].npcId, BOB)
	local later = VendorStore.export(db, NOW + 50)
	t.eq(#later.vendors, 1)
	t.eq(later.vendors[1].npcId, BOB)
	t.eq(#VendorStore.export(db, nil, NOW - 1).vendors, 0)
	t.eq(VendorStore.bytes(db), before)
	t.same(VendorStore.export('junk'), { schema = 2, vendors = {}, skipped = 0 })
end)

t.test('prune fits the budget, oldest vendors first, never the newest', function()
	local db = openStore()
	local slots = {}
	for index = 1, 30 do
		slots[index] = { itemId = 1000 + index, price = 100 + index, stack = 1 }
	end
	for npcId = 1, 10 do
		VendorStore.record(db, observation(npcId, slots, { reaction = 5 }), NOW + npcId)
	end
	local perVendor = VendorStore.vendorBytes(db.byNpc[1])
	t.truthy(perVendor > 0 and perVendor < 1400, 'a 30-item vendor costs ' .. perVendor .. ' bytes')
	t.eq(VendorStore.prune(db, { maxBytes = perVendor * 4 }), 6)
	t.eq(db.byNpc[6], nil)
	t.truthy(db.byNpc[7] and db.byNpc[10])
	t.eq(VendorStore.prune(db, { maxBytes = 1 }), 3)
	t.truthy(db.byNpc[10])
	t.eq(VendorStore.summary(db).vendors, 1)
	t.eq(VendorStore.summary(db).items, 30)
end)

t.test('a vendor keeps at most MAX_ITEMS_PER_VENDOR records, the longest gone go first', function()
	local db = openStore()
	local slots = {}
	for index = 1, VendorStore.MAX_ITEMS_PER_VENDOR do
		slots[index] = { itemId = index, price = 1 }
	end
	VendorStore.record(db, observation(ALICE, slots), NOW)
	VendorStore.record(db, observation(ALICE, { { itemId = 5000, price = 1 } }), NOW + 1)
	local items = VendorStore.vendorItems(db, ALICE)
	local count = 0
	for _ in pairs(items) do
		count = count + 1
	end
	t.eq(count, VendorStore.MAX_ITEMS_PER_VENDOR)
	t.truthy(items[5000])
end)

-- The module on a fake client ------------------------------------------------------------

local function merchantGame()
	local game = FakeGame.new({ now = NOW })
	game.merchantNpc =
		{ guid = 'Creature-0-4372-0-17-66-00001A2B3C', name = 'Tharynn Bouden', faction = 'Alliance', reaction = 5 }
	game.mapId, game.zone = 1429, 'Elwynn Forest'
	game.merchant = {
		{ itemId = THREAD, price = 10, stack = 1 },
		{ itemId = ARROW, price = 10, stack = 200, available = 5 },
		{
			itemId = TOKEN_ITEM,
			price = 0,
			hasExtendedCost = true,
			costs = { { link = '|cff|Hcurrency:1901|h[Honor]|h|r', count = 50 } },
		},
	}
	return game
end

t.test('MERCHANT_SHOW records the open merchant after a frame', function()
	local game = merchantGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('MERCHANT_SHOW')
	game:Fire('MERCHANT_UPDATE')
	t.eq(addon.vendorDb.byNpc[66], nil)
	game:NextFrame()
	local vendor = addon.vendorDb.byNpc[66]
	t.eq(vendor.name, 'Tharynn Bouden')
	t.eq(vendor.zone, 'Elwynn Forest')
	t.eq(vendor.mapId, 1429)
	t.eq(vendor.faction, 'Alliance')
	t.eq(vendor.reaction, 5)
	local items = addon.VendorStore.vendorItems(addon.vendorDb, 66)
	t.eq(items[ARROW].available, 5)
	t.same(items[TOKEN_ITEM].costs, { { kind = 'currency', id = 1901, count = 50 } })
	t.eq(game.savedArchiveDb.vendors, addon.vendorDb)
	t.same(addon.errors, {})
	-- A friendly read may be discounted, so the seed's base price answers, counting the vendor.
	local buyPrice = addon.host.Get('vendorPrices', 1).buyPrice
	t.eq(buyPrice(THREAD).source, 'seed')
	t.eq(buyPrice(THREAD).vendorCount, 1)
	game.merchantNpc.reaction = 4
	game:Fire('MERCHANT_UPDATE')
	game:NextFrame()
	local price = buyPrice(THREAD)
	t.eq(price.source, 'seen')
	t.eq(price.isBasePrice, true)
	t.eq(price.cheapestVendor.name, 'Tharynn Bouden')
end)

t.test('an empty or filtered merchant list marks nothing gone', function()
	local game = merchantGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('MERCHANT_SHOW')
	game:NextFrame()
	local items = game.merchant
	game.merchant = {}
	game:Fire('MERCHANT_UPDATE')
	game:NextFrame()
	t.eq(addon.VendorStore.vendorItems(addon.vendorDb, 66)[THREAD].goneAt, nil)
	game.merchant = { items[1] }
	game.merchantFilter = 2
	game:Fire('MERCHANT_UPDATE')
	game:NextFrame()
	t.eq(addon.VendorStore.vendorItems(addon.vendorDb, 66)[ARROW].goneAt, nil)
	game.merchantFilter = 1
	game:Advance(30)
	game:Fire('MERCHANT_UPDATE')
	game:NextFrame()
	t.eq(addon.VendorStore.vendorItems(addon.vendorDb, 66)[ARROW].goneAt, NOW + 30)
end)

t.test('a slot the client fails on makes the read incomplete', function()
	local game = merchantGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('MERCHANT_SHOW')
	game:NextFrame()
	game.merchant[2] = { itemId = ARROW, throws = true }
	game:Fire('MERCHANT_UPDATE')
	game:NextFrame()
	t.eq(addon.VendorStore.vendorItems(addon.vendorDb, 66)[ARROW].goneAt, nil)
	t.same(addon.errors, {})
end)

t.test('a slot priced 0 with no extended cost makes the read incomplete', function()
	local game = merchantGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('MERCHANT_SHOW')
	game:NextFrame()
	game.merchant[1] = { itemId = THREAD, price = 0 }
	game.merchant[2] = nil
	game:Advance(30)
	game:Fire('MERCHANT_UPDATE')
	game:NextFrame()
	local items = addon.VendorStore.vendorItems(addon.vendorDb, 66)
	t.eq(items[THREAD].price, 10)
	t.eq(items[ARROW].goneAt, nil)
	t.same(addon.errors, {})
end)

t.test('the standing is read under a guard', function()
	local game = merchantGame()
	local wow = ns.Wow.create(game.env)
	t.eq(wow:MerchantVendor().reaction, 5)
	game.env.UnitReaction = function()
		error('client error')
	end
	local vendor = wow:MerchantVendor()
	t.eq(vendor.npcId, 66)
	t.eq(vendor.reaction, nil)
end)

t.test('nothing is recorded with the setting off, for a player or without a store', function()
	local game = merchantGame()
	local addon = FakeGame.startAddon(t, game)
	addon.host.Module('vendors'):SetSetting('record', false)
	game:Fire('MERCHANT_SHOW')
	game:NextFrame()
	t.eq(addon.vendorDb.byNpc[66], nil)
	addon.host.Module('vendors'):SetSetting('record', true)
	game.merchantNpc.guid = 'Player-4372-0ABCDEF0'
	game:Fire('MERCHANT_SHOW')
	game:NextFrame()
	t.eq(next(addon.vendorDb.byNpc), nil)
	t.same(addon.errors, {})
end)

t.test('/hag vendors reports the record and the seed', function()
	local game = merchantGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('MERCHANT_SHOW')
	game:NextFrame()
	local lines = addon.host.RunCommand('vendors')
	t.truthy(lines[1]:match('^Merchant record: 1 vendor, 3 items, %d+%.%d of 512 KB$'), lines[1])
	t.truthy(
		lines[2]:match('^Seed: %d+ items from build ' .. addon.VendorSeed.build:gsub('%.', '%%.') .. '$'),
		lines[2]
	)
end)

t.test('/hag vendors says when the tooltip could not read vendor prices, never the raw error', function()
	local game = merchantGame()
	local addon = FakeGame.startAddon(t, game)
	t.eq(#addon.host.RunCommand('vendors'), 2, 'no failure, no line')
	addon.vendorPrices = {
		BuyPrice = function()
			error('vendor store broke at line 12')
		end,
	}
	game:ShowItemTooltip(THREAD)
	local lines = addon.host.RunCommand('vendors')
	t.eq(#lines, 3)
	t.eq(lines[3], "The tooltip couldn't read vendor prices this session")
	for _, line in ipairs(lines) do
		t.eq(line:find('broke', 1, true), nil, line)
	end
	t.same(addon.errors, {})
end)

t.test('Questie is read only to confirm, guarded', function()
	local game = merchantGame()
	local wow = ns.Wow.create(game.env)
	t.eq(wow:QuestieItemVendors(THREAD), nil)
	game.env.QuestieLoader = {
		ImportModule = function(_, name)
			return name == 'QuestieDB'
					and {
						QueryItemSingle = function(itemId, field)
							if itemId == FLUX then
								error('questie broke')
							end
							return field == 'vendors' and itemId == THREAD and { 66 } or nil
						end,
					}
				or nil
		end,
	}
	t.eq(wow:QuestieItemVendors(THREAD), true)
	t.eq(wow:QuestieItemVendors(ARROW), nil)
	t.eq(wow:QuestieItemVendors(FLUX), nil)
end)

t.test('the shipped seed loads and every row is well formed', function()
	local seed = ns.VendorSeed
	t.truthy(type(seed.build) == 'string' and seed.build ~= '')
	local count = 0
	for itemId, entry in pairs(seed.items) do
		count = count + 1
		local isPlain = type(entry) == 'number' and entry > 0 and entry % 1 == 0
		local isStack = type(entry) == 'table' and entry[1] > 0 and entry[2] > 1
		t.truthy(itemId > 0 and (isPlain or isStack), 'seed row ' .. itemId)
	end
	t.truthy(count >= 0)
end)

-- The generator ------------------------------------------------------------------------------

local Gen = dofile('tools/gen-vendor-seed.lua')

t.test('a bare LibPeriodicTable id never clears a CMaNGOS limited flag', function()
	local prices = { [2515] = { price = 10, stack = 200 }, [2320] = { price = 10, stack = 1 } }
	local lpt = { [2515] = true, [2320] = true }
	local cmangos = { [2515] = { isLimited = true }, [2320] = { isLimited = false } }
	for _, lists in ipairs({ { lpt, cmangos }, { cmangos, lpt } }) do
		local seed = Gen.buildSeed(prices, lists)
		t.eq(seed[2515].isLimited, true)
		t.eq(seed[2320].isLimited, false)
	end
	t.eq(Gen.buildSeed(prices, { lpt })[2515].isLimited, false)
	-- Two lists that know disagree: unlimited wins.
	t.eq(Gen.buildSeed(prices, { cmangos, { [2515] = { isLimited = false } } })[2515].isLimited, false)
end)

t.test('the generator parses quoted CSV', function()
	local rows = Gen.parseCsv('a,b,c\n1,"x, ""y""\nz",3\r\n')
	t.same(rows, { { 'a', 'b', 'c' }, { '1', 'x, "y"\nz', '3' } })
end)

t.test('the generator joins ItemSparse prices with the vendor lists', function()
	local csv = table.concat({
		'ID,Display_lang,BuyPrice,VendorStackCount,SellPrice',
		'2320,"Coarse Thread",10,1,2',
		'2515,"Sharp Arrow, fine",10,200,0',
		'2589,Linen Cloth,0,1,13',
		'4289,Salt,50,1,12',
		'159,"Refreshing ""Spring"" Water",25,5,1',
		'',
	}, '\n')
	local prices = Gen.readItemSparse(csv)
	t.same(prices[2515], { price = 10, stack = 200 })
	t.eq(prices[2589], nil)
	local lpt = Gen.readPeriodicTable('\t["Tradeskill.Mat.BySource.Vendor"]="2320,4289:5,2589",\n')
	t.same(lpt, { [2320] = true, [4289] = true, [2589] = true })
	local sql = "INSERT INTO `npc_vendor` VALUES (66,2320,0,0,1,0,'Coarse, Thread'),(66,2515,5,9000,2,0,'Arrow');\n"
		.. "INSERT INTO `npc_vendor_template` VALUES (1,159,0,0,1,0,'Water \\'cold\\'');\n"
		.. 'INSERT INTO `creature` VALUES (1,4289,0);\n'
	local cmangos = Gen.readCmangosVendors(sql)
	t.same(cmangos, { [2320] = { isLimited = false }, [2515] = { isLimited = true }, [159] = { isLimited = false } })
	t.same(Gen.readIdList('# vendor items\n2320\n  4289  # salt\nnope\n'), { [2320] = true, [4289] = true })
	local seed = Gen.buildSeed(prices, { lpt, cmangos })
	t.same(seed[2320], { price = 10, stack = 1, isLimited = false })
	t.same(seed[2515], { price = 10, stack = 200, isLimited = true })
	t.eq(seed[2589], nil)
	local source = Gen.render(seed, { build = '1.60.1.71037', date = '2026-11-28', sources = { 'fixture' } })
	t.truthy(source:find('Build 1.60.1.71037, generated 2026-11-28.', 1, true))
	local loaded = {}
	assert(loadstring(source))('Haggler', loaded)
	t.same(loaded.VendorSeed.items, { [159] = { 25, 5 }, [2320] = 10, [2515] = { 10, 200 }, [4289] = 50 })
	t.same(loaded.VendorSeed.limited, { [2515] = true })
	t.raises(function()
		Gen.readItemSparse('ID,Name\n1,x\n')
	end, 'BuyPrice')
end)
