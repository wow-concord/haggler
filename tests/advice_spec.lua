local t = ...

local ns = t.loadAddon()
local Advice, Guardrail = ns.Advice, ns.Guardrail

local function auction(unitPrice, listed, deposit)
	return { itemId = 7, unitPrice = unitPrice, listed = listed or 1, deposit = deposit or 0 }
end

t.test('undercut by more than the threshold: relist one step under the cheapest', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.action, 'relist')
	t.eq(advice.direction, 'down')
	t.eq(advice.price, 8900)
	t.eq(advice.confidence.level, 'high')
end)

t.test('a copper-step undercut goes one copper under', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.price, 8999)
end)

t.test('undercut by less than the threshold: hold', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9700, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.action, 'hold')
	t.eq(advice.code, 'closeEnough')
end)

t.test('the threshold is an option', function()
	local facts = { cheapestOther = 9700, step = 1, scanAgeSeconds = 60 }
	t.eq(Advice.forAuction(auction(10000), facts, { thresholdPercent = 2 }).action, 'relist')
end)

t.test('the floor: never relist under break-even or the vendor price', function()
	local advice =
		Advice.forAuction(auction(10000), { cheapestOther = 5000, step = 1, breakEven = 6000, scanAgeSeconds = 60 })
	t.eq(advice.code, 'underFloor')
	advice = Advice.forAuction(auction(10000), { cheapestOther = 5000, step = 1, vendor = 7000, scanAgeSeconds = 60 })
	t.eq(advice.code, 'underFloor')
	t.eq(advice.text, 'the cheapest listing is under your floor, so wait or take it out')
	t.eq(advice.text:find(';', 1, true), nil, 'one sentence, no semicolon')
end)

t.test('a relist that nets no more than a vendor after the lost deposit: hold', function()
	-- 10 units: relisting at 4999 nets saleNet(4999, 10) less a big deposit.
	local deposit = Guardrail.saleNet(4999, 10) - 4000 * 10
	local advice = Advice.forAuction(
		auction(10000, 10, deposit),
		{ cheapestOther = 5000, step = 1, vendor = 4000, scanAgeSeconds = 60 }
	)
	t.eq(advice.code, 'costsMore')
end)

t.test('the market rose past the threshold: relist up, one step under the cheapest', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 12000, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.action, 'relist')
	t.eq(advice.direction, 'up')
	t.eq(advice.price, 11900)
	t.eq(advice.gain, Guardrail.saleNet(11900, 1) - Guardrail.saleNet(10000, 1))
end)

t.test('a rise smaller than the deposit lost: hold', function()
	local advice = Advice.forAuction(auction(10000, 1, 2000), { cheapestOther = 12000, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.code, 'costsMore')
end)

t.test('alone on the market: the rule price is the market, snapped to the step', function()
	local advice = Advice.forAuction(auction(10000), { rulePrice = 15050, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.direction, 'up')
	t.eq(advice.price, 15000)
	t.eq(Advice.forAuction(auction(10000), { rulePrice = 10200, step = 1, scanAgeSeconds = 60 }).code, 'cheapest')
end)

t.test('no market at all: hold, and a bad auction is low confidence', function()
	t.eq(Advice.forAuction(auction(10000), { step = 1, scanAgeSeconds = 60 }).code, 'noMarket')
	local advice = Advice.forAuction({ unitPrice = 'x' }, { step = 1 })
	t.eq(advice.code, 'unreadable')
	t.eq(advice.confidence.level, 'low')
end)

t.test('an old scan lowers the advice confidence', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 1, scanAgeSeconds = 3 * 3600 })
	t.eq(advice.confidence.level, 'low')
end)

t.test('cheapestOther skips the levels that are only ours', function()
	local levels = { { price = 900, qty = 2 }, { price = 1000, qty = 5 } }
	t.eq(Advice.cheapestOther(levels, { { unitPrice = 900, listed = 2 } }), 1000)
	t.eq(Advice.cheapestOther(levels, { { unitPrice = 900, listed = 1 } }), 900)
	t.eq(Advice.cheapestOther(levels, {}), 900)
	t.eq(Advice.cheapestOther(nil, nil), nil)
end)

t.test('untracked: active owned auctions with no venture', function()
	local owned = {
		{ auctionId = 1, itemId = 7 },
		{ auctionId = 2, itemId = 7 },
		{ auctionId = 3, itemId = 7, isSold = true },
		{ auctionId = 4, itemId = 7 },
		'junk',
	}
	local tracked = { [2] = { ventureId = 5 }, [4] = { ventureId = nil } }
	local list = Advice.untracked(owned, tracked)
	t.eq(#list, 2)
	t.eq(list[1].auctionId, 1)
	t.eq(list[2].auctionId, 4)
	t.same(Advice.untracked(nil, nil), {})
end)

t.test('a down relist reports a signed change and its margin over a vendor', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 9000, step = 100, scanAgeSeconds = 60 })
	t.eq(advice.net, Guardrail.saleNet(8900, 1))
	t.eq(advice.gain, Guardrail.saleNet(8900, 1) - Guardrail.saleNet(10000, 1))
	t.truthy(advice.gain < 0, 'a down relist gives up margin')
	t.eq(advice.overVendor, advice.net)
end)

t.test('a down relist against a deposit: the deposit comes off the net', function()
	local advice = Advice.forAuction(
		auction(10000, 2, 500),
		{ cheapestOther = 9000, step = 100, vendor = 1000, scanAgeSeconds = 60 }
	)
	t.eq(advice.action, 'relist')
	t.eq(advice.net, Guardrail.saleNet(8900, 2) - 500)
	t.eq(advice.gain, advice.net - Guardrail.saleNet(10000, 2))
	t.eq(advice.overVendor, advice.net - 2000)
end)

t.test('a tie with the cheapest other listing says so', function()
	local advice = Advice.forAuction(auction(10000), { cheapestOther = 10000, step = 1, scanAgeSeconds = 60 })
	t.eq(advice.code, 'tied')
	t.eq(advice.text:find('cheapest', 1, true), nil)
end)

t.test('the rule price confidence counts only when the rule price set the target', function()
	local low = { level = 'low', reasons = { { code = 'thin', level = 'low', text = 'thin market' } } }
	local fromScan = Advice.forAuction(
		auction(10000),
		{ cheapestOther = 9000, rulePrice = 20000, step = 1, scanAgeSeconds = 60, confidence = low }
	)
	t.eq(fromScan.confidence.level, 'high')
	t.eq(fromScan.usesRulePrice, nil)
	local fromRule =
		Advice.forAuction(auction(10000), { rulePrice = 20000, step = 1, scanAgeSeconds = 60, confidence = low })
	t.eq(fromRule.confidence.level, 'low')
	t.eq(fromRule.usesRulePrice, true)
end)

t.test('untracked: skipped ids, and an unrecorded auction a pending venture post explains', function()
	local owned = {
		{ auctionId = 1, itemId = 7, qty = 2 },
		{ auctionId = 2, itemId = 7, qty = 2 },
		{ auctionId = 3, itemId = 8, qty = 1 },
	}
	local list = Advice.untracked(owned, {}, {
		pendingVenturePosts = { { itemId = 7, qty = 2 } },
		skip = { [3] = true },
	})
	-- One pending post explains one auction only.
	t.eq(#list, 1)
	t.eq(list[1].auctionId, 2)
	local expiredVenture = { [1] = { ventureId = 5, state = 'expired' } }
	t.eq(#Advice.untracked({ owned[1] }, expiredVenture), 0)
end)

t.group('advice: a bag item')

local HIGH = { level = 'high', reasons = {} }

-- An ItemValue as Value:Stack returns it: an AH item at 1g, market at its 30-day median.
local function itemValue(fields)
	local result = {
		count = 1,
		copper = 9500,
		source = 'ah',
		isPriced = true,
		vendorNet = 100,
		lowestListed = 10000,
		typicalPrice = 10000,
		recentPrice = 10000,
		typicalAhNet = 9500,
		confidence = HIGH,
	}
	for key, field in pairs(fields or {}) do
		result[key] = field
	end
	return result
end

local function decisionOf(value, item)
	local advice = Advice.forItem(value, item)
	return advice and advice.decision or 'none'
end

-- The lowest listing that many whole percent under a typical price of 10000.
local function lowestUnder(percent)
	return 10000 - percent * 100
end

t.test('forItem: the AH nets more, the market is normal: post', function()
	local advice = Advice.forItem(itemValue())
	t.eq(advice.decision, 'post')
	t.eq(advice.code, 'ah')
end)

t.test('forItem: the vendor pays more: sell', function()
	local advice = Advice.forItem(itemValue({ source = 'vendor', copper = 100, typicalPrice = 90, lowestListed = 90 }))
	t.eq(advice.decision, 'sell')
	t.eq(advice.code, 'vendor')
end)

t.test('forItem: a vendor-only item (no AH price) is sell', function()
	local vendorOnly = itemValue({
		source = 'vendor',
		isPriced = false,
		lowestListed = false,
		typicalPrice = false,
		confidence = { level = 'medium', reasons = {} },
	})
	t.eq(decisionOf(vendorOnly), 'sell')
end)

t.test('forItem: the lowest listing unusually far under the 30-day median: wait', function()
	local threshold = Advice.WAIT_UNDER_TYPICAL_PERCENT
	local advice = Advice.forItem(itemValue({ lowestListed = lowestUnder(threshold) }))
	t.eq(advice.decision, 'wait')
	t.eq(advice.code, 'marketLow')
end)

t.test('forItem: the post/wait edge sits exactly on WAIT_UNDER_TYPICAL_PERCENT', function()
	local threshold = Advice.WAIT_UNDER_TYPICAL_PERCENT
	t.eq(decisionOf(itemValue({ lowestListed = lowestUnder(threshold - 1) })), 'post', 'one percent short')
	t.eq(decisionOf(itemValue({ lowestListed = lowestUnder(threshold) })), 'wait', 'on the threshold')
	t.eq(decisionOf(itemValue({ lowestListed = lowestUnder(threshold + 1) })), 'wait', 'past it')
	t.eq(decisionOf(itemValue({ lowestListed = lowestUnder(threshold) + 1 })), 'post', 'a copper short')
end)

t.test('forItem: the threshold is a named constant, wider than a relist nudge', function()
	t.eq(type(Advice.WAIT_UNDER_TYPICAL_PERCENT), 'number')
	t.truthy(Advice.WAIT_UNDER_TYPICAL_PERCENT > Advice.THRESHOLD_PERCENT)
end)

t.test('forItem: a dip under the vendor waits when the usual price beats the vendor', function()
	-- Today the vendor wins (the dip), but a normal market nets more than the vendor: wait, never sell.
	local dip = itemValue({ source = 'vendor', copper = 5000, vendorNet = 5000, lowestListed = 4000 })
	t.eq(decisionOf(dip), 'wait')
end)

t.test('forItem: the sell/wait edge is the vendor against the usual price after the cut', function()
	-- A sale at the typical 10000 nets 9500 after the 5% cut.
	local atCut = itemValue({ source = 'vendor', copper = 9500, vendorNet = 9500, lowestListed = 4000 })
	t.eq(decisionOf(atCut), 'sell', 'the usual price nets no more than the vendor')
	local underCut = itemValue({ source = 'vendor', copper = 9499, vendorNet = 9499, lowestListed = 4000 })
	t.eq(decisionOf(underCut), 'wait', 'the usual price nets a copper more')
end)

t.test('forItem: the usual price counts for the whole stack', function()
	local stack = itemValue({
		count = 20,
		source = 'vendor',
		vendorNet = 20 * 9000,
		lowestListed = 4000,
		typicalAhNet = 20 * 9500,
	})
	t.eq(decisionOf(stack), 'wait', '20 x 9500 beats 20 x 9000')
	stack.vendorNet = 20 * 9600
	t.eq(decisionOf(stack), 'sell')
end)

t.test('forItem: wait measures the usual price as Post does, deposit risk included', function()
	-- At the typical 10000 the sale nets 9500 after the cut, a copper over the vendor's 9499;
	-- but the deposit lost to unsold listings at that price brings the expected net to 9300.
	local value = itemValue({ source = 'vendor', copper = 9499, vendorNet = 9499, lowestListed = 4000 })
	value.typicalAhNet = 9300
	t.eq(decisionOf(value), 'sell', 'the deposit tips the usual price under the vendor')
	value.typicalAhNet = 9500
	t.eq(decisionOf(value), 'wait')
	value.typicalAhNet = nil
	t.eq(decisionOf(value), 'sell', 'no measured net at the usual price: no wait')
	value.typicalAhNet = 0 / 0
	t.eq(decisionOf(value), 'sell', 'NaN')
end)

t.test('forItem: low confidence is undecided, whatever else it would be', function()
	local low = { level = 'low', reasons = { { code = 'stale', level = 'low', text = 'old' } } }
	t.eq(decisionOf(itemValue({ confidence = low })), 'undecided')
	t.eq(decisionOf(itemValue({ confidence = low, source = 'vendor' })), 'undecided')
	t.eq(decisionOf(itemValue({ confidence = low, lowestListed = 1000 })), 'undecided', 'over wait')
	t.eq(Advice.forItem(itemValue({ confidence = low })).code, 'lowConfidence')
end)

t.test('forItem: the undecided edge is the confidence level, not its reasons', function()
	local medium = { level = 'medium', reasons = { { code = 'fewSales', level = 'medium', text = 'thin' } } }
	t.eq(decisionOf(itemValue({ confidence = medium })), 'post')
	t.eq(decisionOf(itemValue({ confidence = false })), 'undecided', 'no confidence at all')
end)

t.test('forItem: nothing pays (no AH price, no vendor price): undecided', function()
	local advice = Advice.forItem(itemValue({
		source = 'none',
		isPriced = false,
		copper = 0,
		vendorNet = false,
		confidence = { level = 'medium', reasons = {} },
	}))
	t.eq(advice.decision, 'undecided')
	t.eq(advice.code, 'noPrice')
	local worthless = itemValue({ source = 'vendor', isPriced = false, copper = 0, vendorNet = 0 })
	worthless.confidence = { level = 'medium', reasons = {} }
	t.eq(decisionOf(worthless), 'undecided', 'a vendor price of nothing is no sale')
end)

t.test('forItem: wait needs both the lowest listing and the usual price', function()
	t.eq(decisionOf(itemValue({ lowestListed = false })), 'post')
	t.eq(decisionOf(itemValue({ typicalPrice = false, lowestListed = 1 })), 'post')
	t.eq(decisionOf(itemValue({ typicalPrice = 0 / 0, lowestListed = 1 })), 'post', 'NaN')
	t.eq(decisionOf(itemValue({ typicalPrice = math.huge, lowestListed = 1 })), 'post', 'infinity')
end)

t.test('forItem: wait carries its reason, how far under the usual price and the gain over the vendor', function()
	local advice = Advice.forItem(itemValue({ lowestListed = 6800, vendorNet = 100, typicalAhNet = 9500 }))
	t.eq(advice.decision, 'wait')
	t.eq(advice.underTypicalPercent, 32, 'whole percent, as the threshold measures it')
	t.eq(advice.gainOverVendor, 9400, 'the net at the usual price over the vendor net')
	local onEdge = Advice.forItem(itemValue({ lowestListed = lowestUnder(Advice.WAIT_UNDER_TYPICAL_PERCENT) }))
	t.eq(onEdge.underTypicalPercent, Advice.WAIT_UNDER_TYPICAL_PERCENT)
end)

t.test('forItem: a wait needs a gain over the vendor of at least a whole copper', function()
	local under = Advice.forItem(itemValue({ lowestListed = 6800, vendorNet = 9499, typicalAhNet = 9499.9 }))
	t.eq(under.decision, 'post', 'under a copper more: no wait, never "nets 0c more"')
	local copper = Advice.forItem(itemValue({ lowestListed = 6800, vendorNet = 9499, typicalAhNet = 9500.7 }))
	t.eq(copper.decision, 'wait')
	t.eq(copper.gainOverVendor, 1, 'floored to whole copper')
end)

t.test('forItem: a wait with no vendor price gains the whole net at the usual price', function()
	local advice = Advice.forItem(itemValue({ lowestListed = 4000, vendorNet = false, typicalAhNet = 9500 }))
	t.eq(advice.decision, 'wait')
	t.eq(advice.gainOverVendor, 9500)
	t.eq(advice.underTypicalPercent, 60)
end)

t.test('forItem: only wait carries the wait reason', function()
	local post = Advice.forItem(itemValue())
	t.eq(post.underTypicalPercent, nil)
	t.eq(post.gainOverVendor, nil)
	local sell = Advice.forItem(itemValue({ source = 'vendor', copper = 100, typicalPrice = 90, lowestListed = 90 }))
	t.eq(sell.gainOverVendor, nil)
end)

t.test('forItem: a recent median 10% or more under the 30-day median is a trend: no wait', function()
	t.eq(Advice.WAIT_TREND_FALL_PERCENT, 10)
	local falling = Advice.forItem(itemValue({ lowestListed = 6800, recentPrice = 9000 }))
	t.eq(falling.decision, 'post', 'on the edge: the drop is a trend, post as usual')
	t.eq(falling.code, 'ah')
	t.eq(falling.recentUnderTypicalPercent, 10, 'the trend figure rides along')
	t.eq(falling.underTypicalPercent, nil, 'no wait reason')
	local steeper = itemValue({ source = 'vendor', vendorNet = 9000, lowestListed = 4000, recentPrice = 8000 })
	t.eq(decisionOf(steeper), 'sell', 'a falling market falls through to sell too')
end)

t.test('forItem: a recent median under 10% below the 30-day median is a dip: wait', function()
	local dip = Advice.forItem(itemValue({ lowestListed = 6800, recentPrice = 9001 }))
	t.eq(dip.decision, 'wait', 'a copper short of the edge')
	t.eq(dip.recentUnderTypicalPercent, 9)
	local rising = Advice.forItem(itemValue({ lowestListed = 6800, recentPrice = 11000 }))
	t.eq(rising.decision, 'wait', 'a rising market holds')
	t.eq(rising.recentUnderTypicalPercent, 0, 'not under the usual price at all')
end)

t.test('forItem: no recent median: the trend is unknown, no wait', function()
	for _, recent in ipairs({ false, 0, 0 / 0, math.huge }) do
		local advice = Advice.forItem(itemValue({ lowestListed = 6800, recentPrice = recent }))
		t.eq(advice.decision, 'post', tostring(recent))
		t.eq(advice.recentUnderTypicalPercent, nil, tostring(recent))
	end
end)

t.test('forItem: bound and quest items get no decision; no value gets none', function()
	t.eq(Advice.forItem(itemValue(), { isBound = true }), nil)
	t.eq(Advice.forItem(itemValue(), { isQuest = true }), nil)
	t.eq(Advice.forItem(nil), nil)
	t.eq(Advice.forItem('junk'), nil)
end)

t.test('isMarketLow: whole percent under the usual price', function()
	t.eq(Advice.isMarketLow(7500, 10000), true)
	t.eq(Advice.isMarketLow(7501, 10000), false)
	t.eq(Advice.isMarketLow(10000, 10000), false)
	t.eq(Advice.isMarketLow(12000, 10000), false, 'over the usual price')
	t.eq(Advice.isMarketLow(nil, 10000), false)
	t.eq(Advice.isMarketLow(0, 10000), false, 'no listing price')
end)
