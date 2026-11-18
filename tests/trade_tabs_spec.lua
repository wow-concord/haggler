local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, WOOL = 2589, 2592
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local CHAR = 'Eilu-Nightslayer'
local AHLEDGER_ROWS = {
	[2589] = { 120, 95, 500, 118, 125, 90, 160, 45 },
	[2592] = { 300, 280, 80, 290, 310, 250, 400, 0.5 },
}
local ITEM_INFO = {
	[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
	[WOOL] = { name = 'Wool Cloth', maxStack = 20, vendorPrice = 33 },
}
-- Linen listed under what a vendor pays for it (13); wool well under its market.
local SNAPSHOT_ITEMS = {
	[LINEN] = { min = 10, units = 5, levels = { { price = 10, qty = 5 }, { price = 90, qty = 100 } } },
	[WOOL] = { min = 200, units = 20, levels = { { price = 200, qty = 20 } } },
}

local function start(options)
	options = options or {}
	local game = FakeGame.new({ now = NOW, itemInfo = ITEM_INFO })
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = AHLEDGER_ROWS })
	local addon = FakeGame.startAddon(t, game, function(started)
		local market = started.store:Market(MARKET)
		started.ScanStore.save(market, { at = NOW - 60, source = 'own', count = 2, items = SNAPSHOT_ITEMS })
		market.auctions = options.auctions or {}
	end)
	-- What the client has shown: vendor prices and names (a find reads cached data only).
	for itemId in pairs(ITEM_INFO) do
		addon.prices:VendorPrice(itemId)
	end
	return game, addon
end

local function openAuctionHouse(game)
	game.env.AuctionHouseFrame:Show()
	game:Fire('AUCTION_HOUSE_SHOW')
end

local function callsNamed(game, name)
	local calls = {}
	for _, call in ipairs(game.auctionHouse.calls) do
		if call[1] == name then
			calls[#calls + 1] = call
		end
	end
	return calls
end

local function tracked(itemId, unitPrice, extra)
	local record = {
		itemId = itemId,
		qty = 1,
		remaining = 1,
		listed = 1,
		unitPrice = unitPrice,
		deposit = 0,
		postedAt = NOW - 600,
		hours = 48,
		state = 'active',
		changedAt = NOW - 600,
		char = CHAR,
		knownUnits = 0,
		knownCopper = 0,
	}
	for key, value in pairs(extra or {}) do
		record[key] = value
	end
	return record
end

local function owned(auctionId, itemId)
	return { auctionID = auctionId, itemKey = { itemID = itemId }, quantity = 1, status = 0 }
end

local function textOf(lines)
	local texts = {}
	for _, line in ipairs(lines) do
		texts[#texts + 1] = line.text
	end
	return table.concat(texts, '\n')
end

-- Flips tab -------------------------------------------------------------------------------

t.v2test('the Flips tab lists nothing until asked, then the vendor flip with its confidence', function()
	local _, addon = start()
	addon.window:Open('flips')
	local flips = addon.window.containers.flips
	t.eq(#flips.state.rows, 0, 'no find on build')
	-- Vendor flips only: the find keeps one flip per item, and linen also relists.
	flips.kindPicker.forward:Click()
	local vendorRow
	for _, row in ipairs(flips.state.rows) do
		if row.itemId == LINEN and row.kind == 'vendor' then
			vendorRow = row
		end
	end
	t.truthy(vendorRow, 'linen under its vendor price')
	t.eq(vendorRow.units, 5)
	t.eq(vendorRow.cost, 50)
	local text = textOf(addon.FlipsTab.lines(vendorRow))
	t.truthy(text:find('Buy 5', 1, true), 'buy line')
	t.truthy(text:find('Confidence: ', 1, true), 'confidence line')
	t.same(addon.errors, {})
end)

t.v2test('the Flips tab counts out our listings the scan saw, and keeps those posted after it', function()
	local function linenVendorFlip(postedAt)
		local own = tracked(LINEN, 10, { qty = 5, remaining = 5, listed = 5, postedAt = postedAt })
		local _, addon = start({ auctions = { [21] = own } })
		addon.window:Open('flips')
		local flips = addon.window.containers.flips
		flips.kindPicker.forward:Click()
		for _, row in ipairs(flips.state.rows) do
			if row.itemId == LINEN and row.kind == 'vendor' then
				return row
			end
		end
		return nil
	end
	t.eq(linenVendorFlip(NOW - 600), nil, 'the cheap linen is ours')
	t.truthy(linenVendorFlip(NOW), "posted after the scan: the cheap linen is someone else's")
end)

t.v2test('flip lines show every reason that is not high', function()
	local _, addon = start()
	local lines = addon.FlipsTab.lines({
		kind = 'relist',
		units = 2,
		cost = 100,
		buyPrice = 50,
		sellPrice = 120,
		profit = 80,
		percent = 80,
		confidence = {
			level = 'low',
			reasons = {
				{ level = 'high', text = 'fresh scan' },
				{ level = 'low', text = 'thin market' },
			},
		},
	})
	local text = textOf(lines)
	t.truthy(text:find('thin market', 1, true), 'low reason shown')
	t.eq(text:find('fresh scan', 1, true), nil, 'high reason left out')
	t.eq(lines[#lines].level, 'low')
end)

t.v2test('Buy on a flip opens the Buy tab on the item and searches it live at the auction house', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window:Open('flips')
	local flips = addon.window.containers.flips
	flips.findButton:Click()
	for index, row in ipairs(flips.state.rows) do
		if row.itemId == LINEN then
			flips.state.selected = index
		end
	end
	addon.window:Refresh()
	flips.buyButton:Click()
	t.eq(addon.window.currentTabKey, 'buy')
	local buy = addon.window.containers.buy
	t.eq(buy.state.rows[buy.state.selected].itemId, LINEN)
	local searches = callsNamed(game, 'SendSearchQuery')
	t.eq(searches[#searches] and searches[#searches][2], LINEN)
	t.same(addon.errors, {})
end)

t.v2test("the Flips tab leaves the player's own listings out", function()
	-- Linen's five units at 10 are a vendor flip until they are our own listing.
	local function linenBuyPriceWith(auctions)
		local _, addon = start({ auctions = auctions })
		addon.window:Open('flips')
		local flips = addon.window.containers.flips
		flips.findButton:Click()
		t.same(addon.errors, {})
		for _, row in ipairs(flips.state.rows) do
			if row.itemId == LINEN then
				return row.buyPrice
			end
		end
		return nil
	end
	t.eq(linenBuyPriceWith({}), 10)
	local buyPrice = linenBuyPriceWith({ [7] = tracked(LINEN, 10, { qty = 5, remaining = 5, listed = 5 }) })
	t.truthy(buyPrice == nil or buyPrice > 10, 'our own units at 10 are not bought back')
end)

-- Auctions tab ----------------------------------------------------------------------------

t.test('advice rows: relists first, holds after', function()
	local _, addon = start()
	local snapshot = { at = NOW - 60, items = {} }
	snapshot.items[LINEN] = { min = 90, units = 5, maxStackSeen = 20, levels = { { price = 90, qty = 5 } } }
	snapshot.items[WOOL] = { min = 299, units = 5, maxStackSeen = 20, levels = { { price = 299, qty = 5 } } }
	local rows = addon.AuctionsTab.rows({
		tracked(WOOL, 300, { auctionId = 2, postedAt = NOW }),
		tracked(LINEN, 200, { auctionId = 1 }),
	}, {
		snapshot = snapshot,
		scanAge = 60,
		rulePrice = function()
			return nil
		end,
		vendorPrice = function()
			return nil
		end,
	})
	t.eq(rows[1].record.auctionId, 1)
	t.eq(rows[1].advice.action, 'relist')
	t.eq(rows[1].advice.price, 89)
	t.eq(rows[2].advice.action, 'hold')
end)

t.test('advice: our listing posted after the scan is not counted out of it', function()
	local _, addon = start()
	local snapshot = { at = NOW - 60, items = {} }
	snapshot.items[WOOL] = {
		min = 300,
		units = 6,
		maxStackSeen = 20,
		levels = { { price = 300, qty = 1 }, { price = 400, qty = 5 } },
	}
	local rows = addon.AuctionsTab.rows({ tracked(WOOL, 300, { auctionId = 2, postedAt = NOW }) }, {
		snapshot = snapshot,
		scanAge = 60,
		rulePrice = function()
			return nil
		end,
		vendorPrice = function()
			return nil
		end,
	})
	t.eq(rows[1].advice.code, 'tied', "the unit at 300 is someone else's")
end)

t.test('cancel to relist arms on the first click and cancels on the second, at the auction house only', function()
	local game, addon = start({ auctions = { [11] = tracked(LINEN, 200) } })
	game.owned[1] = owned(11, LINEN)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	t.eq(#auctions.state.rows, 1)
	t.eq(auctions.cancelButton.isEnabled, false, 'greyed out away from the auction house')
	openAuctionHouse(game)
	auctions.cancelButton:Click()
	t.eq(#callsNamed(game, 'CancelAuction'), 0, 'first click only arms')
	t.truthy(auctions.cancelButton.label:GetText():find('Confirm', 1, true), 'armed label')
	auctions.cancelButton:Click()
	t.same(callsNamed(game, 'CancelAuction'), { { 'CancelAuction', 11 } })
	t.same(addon.errors, {})
end)

local function linesText(lines)
	local texts = {}
	for _, line in ipairs(lines.strings) do
		texts[#texts + 1] = line:GetText() or ''
	end
	return table.concat(texts, '\n')
end

local function noPrice()
	return nil
end

local function adviceRows(addon, records, levels, extra)
	local snapshot = { at = NOW - 60, items = { [LINEN] = { min = levels[1].price, units = 5, levels = levels } } }
	local deps = { snapshot = snapshot, scanAge = 60, rulePrice = noPrice, vendorPrice = noPrice }
	for key, value in pairs(extra or {}) do
		deps[key] = value
	end
	return addon.AuctionsTab.rows(records, deps)
end

t.test('without a rule price the step comes from the scan: no copper undercut on a silver item', function()
	local _, addon = start()
	-- No copper in any listing and no stack seen: whole silver, as ItemMarket infers it.
	local rows = adviceRows(addon, { tracked(LINEN, 10000, { auctionId = 1 }) }, { { price = 9000, qty = 1 } })
	t.eq(rows[1].advice.price, 8900)
	-- Copper in a listing: copper step.
	rows = adviceRows(addon, { tracked(LINEN, 10000, { auctionId = 1 }) }, { { price = 9001, qty = 1 } })
	t.eq(rows[1].advice.price, 9000)
end)

t.test('the floor is the auction break-even from its cost-pool share', function()
	local _, addon = start()
	local record = tracked(LINEN, 10000, { auctionId = 1, knownUnits = 1, knownCopper = 9500 })
	local rows = adviceRows(addon, { record }, { { price = 9000, qty = 1 } })
	t.eq(rows[1].advice.code, 'underFloor')
	record.knownCopper = 5000
	rows = adviceRows(addon, { record }, { { price = 9000, qty = 1 } })
	t.eq(rows[1].advice.action, 'relist')
end)

t.test('the rule price credit and confidence show only when the rule price set the target', function()
	local _, addon = start()
	local low = { level = 'low', reasons = { { code = 'thin', level = 'low', text = 'thin market' } } }
	local function rulePrice()
		return { copper = 20000, step = 100, confidence = low, usesPriceSource = true }
	end
	local rows = adviceRows(
		addon,
		{ tracked(LINEN, 10000, { auctionId = 1 }) },
		{ { price = 9000, qty = 1 } },
		{ rulePrice = rulePrice }
	)
	t.eq(rows[1].usesPriceSource, false, 'the scan set the target')
	t.eq(rows[1].advice.confidence.level, 'high')
	local snapshotless = addon.AuctionsTab.rows({ tracked(LINEN, 10000, { auctionId = 1 }) }, {
		scanAge = 60,
		rulePrice = rulePrice,
		vendorPrice = noPrice,
	})
	t.eq(snapshotless[1].usesPriceSource, true, 'the rule price set the target')
	t.eq(snapshotless[1].advice.confidence.level, 'low')
end)

t.test('a down relist shows its signed change, not a wrapped positive', function()
	local game, addon = start({ auctions = { [11] = tracked(WOOL, 20000) } })
	game.owned[1] = owned(11, WOOL)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	t.eq(auctions.state.rows[1].advice.direction, 'down')
	local text = linesText(auctions.lines)
	t.truthy(text:find('Against the listing as it stands: -', 1, true), 'negative change: ' .. text)
	t.truthy(text:find('Against selling to a vendor: +', 1, true), 'over a vendor')
end)

t.test('cancel untracked takes out one untracked auction per click and waits for the server', function()
	local game, addon = start({ auctions = { [11] = tracked(LINEN, 200, { ventureId = 4 }) } })
	game.owned = { owned(11, LINEN), owned(12, WOOL), owned(13, WOOL) }
	openAuctionHouse(game)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	t.truthy(auctions.untrackedButton.label:GetText():find('(2)', 1, true), 'two untracked')
	auctions.untrackedButton:Click()
	t.eq(#callsNamed(game, 'CancelAuction'), 0, 'first click only arms')
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	t.same(callsNamed(game, 'CancelAuction'), { { 'CancelAuction', 12 } }, 'one cancel until the server answers')
	t.eq(auctions.untrackedButton.isEnabled, false, 'waiting for the server')
	-- The server answers before it drops 12 from the owned list: 12 is never offered again.
	game:Fire('OWNED_AUCTIONS_UPDATED')
	t.truthy(auctions.untrackedButton.label:GetText():find('(1)', 1, true), 'one left')
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	t.same(callsNamed(game, 'CancelAuction'), { { 'CancelAuction', 12 }, { 'CancelAuction', 13 } })
	game:Fire('AUCTION_CANCELED')
	t.eq(auctions.untrackedButton.isEnabled, false, 'none left')
	t.same(addon.errors, {})
end)

t.test('cancel untracked frees the button when the server never answers', function()
	local game, addon = start()
	game.owned = { owned(12, WOOL), owned(13, WOOL) }
	openAuctionHouse(game)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	t.same(callsNamed(game, 'CancelAuction'), { { 'CancelAuction', 12 } })
	game.now = game.now + 3
	game:RunTimers()
	t.eq(auctions.untrackedButton.isEnabled, false, 'still waiting')
	game.now = game.now + 3
	game:RunTimers()
	t.eq(auctions.untrackedButton.isEnabled, true, 'freed')
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	t.same(callsNamed(game, 'CancelAuction'), { { 'CancelAuction', 12 }, { 'CancelAuction', 13 } })
	t.same(addon.errors, {})
end)

t.test('a stale server wait does not free the button while a newer cancel waits', function()
	local game, addon = start()
	game.owned = { owned(12, WOOL), owned(13, WOOL), owned(14, WOOL) }
	openAuctionHouse(game)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	game.now = game.now + 3
	-- The server answers the first cancel; a second goes out before the first wait ends.
	game.owned = { owned(13, WOOL), owned(14, WOOL) }
	game:Fire('OWNED_AUCTIONS_UPDATED')
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	t.same(callsNamed(game, 'CancelAuction'), { { 'CancelAuction', 12 }, { 'CancelAuction', 13 } })
	game.now = game.now + 3
	game:RunTimers()
	t.eq(auctions.untrackedButton.isEnabled, false, 'the newer cancel still waits')
	game.now = game.now + 3
	game:RunTimers()
	t.eq(auctions.untrackedButton.isEnabled, true, 'freed by its own wait')
	t.same(addon.errors, {})
end)

t.test('cancel untracked spares a venture auction the clock expired while it is still listed', function()
	local expired = tracked(LINEN, 200, { ventureId = 4, state = 'expired' })
	local game, addon = start({ auctions = { [11] = expired } })
	game.owned = { owned(11, LINEN), owned(12, WOOL) }
	openAuctionHouse(game)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	t.truthy(auctions.untrackedButton.label:GetText():find('(1)', 1, true), 'only the untracked one')
	auctions.untrackedButton:Click()
	auctions.untrackedButton:Click()
	t.same(callsNamed(game, 'CancelAuction'), { { 'CancelAuction', 12 } })
end)

t.test('cancel untracked spares an auction a pending venture post explains', function()
	local game, addon = start()
	game.owned = { owned(12, WOOL) }
	addon.books.pendingPosts[1] = { itemId = WOOL, qty = 1, ventureId = 3 }
	openAuctionHouse(game)
	addon.window:Open('auctions')
	local auctions = addon.window.containers.auctions
	t.truthy(auctions.untrackedButton.label:GetText():find('(0)', 1, true), 'nothing to cancel')
	t.eq(auctions.untrackedButton.isEnabled, false)
end)
