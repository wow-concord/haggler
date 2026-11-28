local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, WOOL, SWORD, ROCK = 2589, 2592, 2488, 9999
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local TABLE_UPDATED = NOW - 3 * 3600
-- AHledger rows: median, min buyout, quantity, 7- and 30-day median, 30-day low and high, sold a day.
local AHLEDGER_ROWS = {
	[2589] = { 120, 95, 500, 118, 125, 90, 160, 45 },
	[2592] = { 300, 280, 80, 290, 310, 250, 400, 0.5 },
	[2488] = { 12345, 12000, 3, 12000, 12500, 11000, 13000, 3 },
}
local ITEM_INFO = {
	[LINEN] = { maxStack = 20, vendorPrice = 13 },
	[WOOL] = { maxStack = 20, vendorPrice = 33 },
	[SWORD] = { maxStack = 1, vendorPrice = 500 },
}

local ns = t.loadAddon()
local Value = ns.Value

local function newValue(options)
	options = options or {}
	local store = assert(ns.Store.open({}, {}))
	if options.snapshot then
		ns.ScanStore.save(store:Market(MARKET), options.snapshot)
	end
	local api = FakeGame.newAHledgerAPI({ market = MARKET, updated = TABLE_UPDATED, rows = AHLEDGER_ROWS })
	local priceSource = ns.PriceData.newAHledgerSource(function()
		return api
	end)
	local prices = ns.PriceService.new({
		now = function()
			return NOW
		end,
		store = store,
		priceSource = priceSource,
		marketKey = function()
			return MARKET
		end,
		itemInfo = function(itemId)
			return options.itemInfo and options.itemInfo(itemId) or ITEM_INFO[itemId]
		end,
	})
	return Value.new({
		prices = prices,
		store = store,
		durationHours = options.durationHours,
		deposit = options.deposit,
	}),
		store
end

local LINEN_SCAN = {
	at = NOW - 60,
	items = { [LINEN] = { min = 100, units = 40, levels = { { price = 100, qty = 10 }, { price = 120, qty = 30 } } } },
}

local function hasReason(value, code)
	for _, reason in ipairs(value.confidence.reasons) do
		if reason.code == code then
			return reason
		end
	end
	return nil
end

t.group('value')

t.test('one unit that is sure to sell is worth the rule price after the cut', function()
	local value = newValue({ snapshot = LINEN_SCAN })
	local item = assert(value:Item(LINEN, { ruleId = 'median' }))
	t.eq(item.rulePrice.copper, 120)
	t.eq(item.sellChance, 1)
	t.eq(item.copper, 114)
	t.eq(item.source, 'ah')
	t.eq(item.isPriced, true)
	t.eq(item.ruleId, 'median')
end)

t.test('a full stack carries the deposit risk of its queue', function()
	local value = newValue({ snapshot = LINEN_SCAN })
	local stack = assert(value:Stack(LINEN, 20, { ruleId = 'median' }))
	t.eq(stack.sellChance, 0.3)
	t.eq(stack.deposit, 78)
	t.eq(stack.depositLoss, 182)
	t.eq(stack.copper, 2098)
	t.eq(stack.perUnit, 104)
end)

t.test('the vendor is the floor', function()
	local deepQueue = {
		at = NOW - 60,
		items = { [LINEN] = { min = 120, units = 5000, levels = { { price = 120, qty = 5000 } } } },
	}
	local value = newValue({ snapshot = deepQueue })
	local item = assert(value:Item(LINEN, { ruleId = 'median' }))
	t.eq(item.sellChance, 0)
	t.eq(item.source, 'vendor')
	t.eq(item.copper, 13)
	t.truthy(hasReason(item, 'wontSell'))
end)

t.test('an unstackable item is priced on whole silver', function()
	local value = newValue()
	local item = assert(value:Item(SWORD, { ruleId = 'median' }))
	t.eq(item.rulePrice.copper, 12300, '12345 snaps down to 1g 23s')
	t.eq(item.copper, 11685)
	t.truthy(hasReason(item, 'queueUnknown'), 'no scan: the queue is not counted, and said so')
end)

t.test('the listing duration and a deposit source feed the risk', function()
	local value = newValue({
		snapshot = LINEN_SCAN,
		durationHours = function()
			return 48
		end,
		deposit = function(itemId, units, hours)
			t.eq(itemId, LINEN)
			t.eq(units, 20)
			t.eq(hours, 48)
			return 50
		end,
	})
	local stack = assert(value:Stack(LINEN, 20, { ruleId = 'median' }))
	-- 90 sales in 48 h, 39 ahead: p = 51 / 20, clamped to 1.
	t.eq(stack.sellChance, 1)
	t.eq(stack.deposit, 50)
	t.eq(stack.copper, 2280)
	t.eq(hasReason(stack, 'depositEstimated'), nil)
end)

t.test('a deposit source that throws or returns junk falls back to the estimate', function()
	local value = newValue({
		snapshot = LINEN_SCAN,
		deposit = function()
			error('client said no')
		end,
	})
	local stack = assert(value:Stack(LINEN, 20, { ruleId = 'median' }))
	t.eq(stack.deposit, 78)
	t.truthy(hasReason(stack, 'depositEstimated'))
end)

t.test('an item with no price is worth its vendor price, at medium confidence', function()
	local value = newValue({
		itemInfo = function(itemId)
			return itemId == ROCK and { vendorPrice = 7 } or nil
		end,
	})
	local item = assert(value:Stack(ROCK, 3))
	t.eq(item.copper, 21)
	t.eq(item.isPriced, false)
	t.eq(item.confidence.level, 'medium')
end)

t.test('an item with no price and no vendor price is worth 0, at low confidence', function()
	local value = newValue({
		itemInfo = function()
			return nil
		end,
	})
	local item = assert(value:Item(ROCK))
	t.eq(item.copper, 0)
	t.eq(item.source, 'none')
	t.eq(item.confidence.level, 'low')
end)

t.test('a bound item is worth its vendor price and asks for no AH price', function()
	local value = newValue()
	local item = assert(value:Item(SWORD, { ruleId = 'median', isBound = true }))
	t.eq(item.copper, 500)
	t.eq(item.rulePrice, nil)
	t.truthy(hasReason(item, 'bound'))
end)

t.test('bad calls from other add-ons get nil and a reason', function()
	local value = newValue()
	local item, reason = value:Item(0)
	t.eq(item, nil)
	t.truthy(reason:find('item id', 1, true))
	item, reason = value:Stack(LINEN, 1.5)
	t.eq(item, nil)
	t.truthy(reason:find('count', 1, true))
	item, reason = value:Item(LINEN, { ruleId = 'nope' })
	t.eq(item, nil)
	t.truthy(reason:find('unknown rule', 1, true))
	local total
	total, reason = value:Total('x')
	t.eq(total, nil)
	t.truthy(reason:find('list', 1, true))
end)

t.test('the default rule is used when none is asked for', function()
	local value, store = newValue({ snapshot = LINEN_SCAN })
	local item = assert(value:Item(LINEN))
	t.eq(item.ruleId, store:DefaultRuleId())
end)

t.test('a total sums the stacks and follows the weakest item', function()
	local value = newValue({
		snapshot = LINEN_SCAN,
		itemInfo = function(itemId)
			return ITEM_INFO[itemId] or (itemId == ROCK and {} or nil)
		end,
	})
	local total = assert(value:Total({
		{ itemId = LINEN, count = 1 },
		{ itemId = SWORD, count = 1 },
		{ itemId = ROCK, count = 2 },
		{ itemId = 'junk', count = 1 },
		'junk',
	}, { ruleId = 'median' }))
	t.eq(total.copper, 114 + 11685)
	t.eq(total.count, 4)
	t.eq(total.unpriced, 1)
	t.eq(total.skipped, 2)
	t.eq(#total.items, 3)
	t.eq(total.confidence.level, 'low', 'the unpriced rock with no vendor price is low')
	t.eq(total.confidence.reasons[1].level, 'low', 'weakest reasons come first')
	t.truthy(#total.confidence.reasons <= Value.MAX_TOTAL_REASONS)
end)

t.test('merging confidences keeps each reason once and the weakest level', function()
	local reason = { code = 'stale', level = 'medium', text = 'old' }
	local merged = Value.mergeConfidence({
		{ level = 'high', reasons = {} },
		{ level = 'medium', reasons = { reason } },
		{ level = 'medium', reasons = { reason, { code = 'thin', level = 'low', text = 'thin' } } },
	})
	t.eq(merged.level, 'low')
	t.eq(#merged.reasons, 2)
	t.eq(merged.reasons[1].code, 'thin')
	t.eq(Value.mergeConfidence({}).level, 'high', 'nothing to doubt is high')
end)

t.test('a stack carries the market facts the bag decision reads', function()
	local value = newValue()
	local linen = assert(value:Stack(LINEN, 5, { ruleId = 'median' }))
	t.eq(linen.lowestListed, 95, 'the lowest listing (AHledger stands in without a scan)')
	t.eq(linen.typicalPrice, 125, 'the 30-day median')
	t.eq(linen.recentPrice, 118, 'the 7-day median')
	local scanned = assert(newValue({ snapshot = LINEN_SCAN }):Stack(LINEN, 5, { ruleId = 'median' }))
	t.eq(scanned.lowestListed, 100, 'the scan minimum wins')
	local rock = assert(value:Stack(ROCK, 1, { ruleId = 'median' }))
	t.eq(rock.lowestListed, nil)
	t.eq(rock.typicalPrice, nil)
	t.eq(rock.recentPrice, nil)
	t.eq(rock.typicalAhNet, nil)
end)

t.test('a stack carries the AH net at its usual price, deposit risk counted as for its own', function()
	local value = newValue()
	local wool = assert(value:Stack(WOOL, 5, { ruleId = 'median' }))
	t.eq(wool.typicalPrice, 310)
	local expected = ns.Guardrail.opportunity({ price = 310, units = 5, vendor = 33, salesPerDay = 0.5 })
	t.eq(wool.typicalAhNet, expected.ahNet)
	t.truthy(wool.typicalAhNet < ns.Guardrail.saleNet(310, 5), 'under a sale a day, some deposits are lost')
	local free = assert(newValue({
		deposit = function()
			return 0
		end,
	}):Stack(WOOL, 5, { ruleId = 'median' }))
	t.eq(free.typicalAhNet, ns.Guardrail.saleNet(310, 5), 'no deposit, nothing to lose')
end)
