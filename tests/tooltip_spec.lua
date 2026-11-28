local t = ...
local FakeGame = require('tests.fake_game')
local ns = t.loadAddon()
local TooltipLines, Theme = ns.TooltipLines, ns.Theme

local LINEN, WOOL, SWORD = 2589, 2592, 2488
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local AHLEDGER_ROWS = { [2589] = { 120, 95, 500, 118, 125, 90, 160, 45 } }

local theme = Theme.new(ns.Tokens)
local icons = ns.IconSet.new({ theme = theme })
local COIN_ICONS = FakeGame.COIN_ICONS
local coins = FakeGame.coins
local LOW_ICON = icons:Inline('triangle-alert', 0, 'color.state.caution')
local MEDIUM_ICON = icons:Inline('triangle-alert', 0, 'color.state.warning')
local INFO_ICON = icons:Inline('info', 0, 'color.text.muted')
local CART_ICON = icons:Inline('shopping-cart', 0, 'color.text.accent')
local SEARCH_ICON = icons:Inline('search', 0, 'color.text.muted')
local PLUG_ICON = icons:Inline('plug', 0, 'color.text.muted')
-- How texts() writes a separator line between two sections.
local SEPARATOR = '---'

-- The module icon the TOC's IconTexture names, inline at the line's own text height (0).
local function tocIconTexture()
	for line in io.lines('Haggler.toc') do
		local path = line:match('^## IconTexture:%s*(.-)%s*$')
		if path then
			return path
		end
	end
end
local HEADER_ICON = '|T' .. tocIconTexture() .. ':0|t'

local function price(copper, level, reasons, trace)
	return {
		copper = copper,
		ageSeconds = 3 * 3600,
		baseAgeSeconds = 3 * 3600,
		source = 'ahledger',
		step = 1,
		confidence = { level = level or 'high', reasons = reasons or {} },
		trace = trace or { { kind = 'base', label = 'scan lowest', copper = copper } },
	}
end

local function quote(options)
	options = options or {}
	return {
		prices = options.prices or {
			{ ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94) },
			{ ruleId = 'median', name = 'Median', isDefault = false, price = price(120) },
		},
		facts = options.facts or {
			salesPerDay = 45,
			listedUnits = 60,
			levelCount = 2,
			levels = { { price = 90, qty = 20 }, { price = 99, qty = 40 } },
			lowestListed = 90,
			lowestListedSource = 'scan',
			scanAge = 12 * 60,
			rowAge = 5 * 3600,
			vendor = 13,
		},
		ages = options.ages or { scanAge = 12 * 60, tableAge = 3 * 3600 },
	}
end

local function build(input)
	input.theme = input.theme or theme
	input.icons = input.icons or icons
	input.quote = input.quote or quote()
	return TooltipLines.build(input)
end

local function texts(lines)
	local result = {}
	for index, line in ipairs(lines) do
		if line.kind == TooltipLines.SEPARATOR then
			result[index] = SEPARATOR
		else
			result[index] = line.right and (line.left .. ' | ' .. line.right) or line.left
		end
	end
	return result
end

-- The index of the first line whose text holds text, or nil.
local function indexOf(lines, text)
	for index, line in ipairs(texts(lines)) do
		if line:find(text, 1, true) then
			return index
		end
	end
	return nil
end

-- The Sell section: the lines after the last separator before the module icon header.
local function sellLines(lines)
	local first = indexOf(lines, HEADER_ICON)
	local result = {}
	for index = first or 1, #lines do
		if lines[index].kind == TooltipLines.SEPARATOR then
			break
		end
		result[#result + 1] = lines[index]
	end
	return result
end

local function find(lines, text)
	for _, line in ipairs(texts(lines)) do
		if line:find(text, 1, true) then
			return line
		end
	end
	return nil
end

t.group('tooltip lines')

t.test('compact: a Buy and a Sell section split by a separator, each under its icon and data age', function()
	t.same(texts(build({ stackCount = 20 })), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		'Auction house (each) | ' .. coins('90c'),
		SEPARATOR,
		HEADER_ICON .. ' | ' .. PLUG_ICON .. ' 3 h',
		'Price (each) | ' .. coins('94c'),
		'Price × 20 | ' .. coins('18s 80c'),
	})
end)

t.test('the headers name no source in words, only the icon and the age', function()
	local lines = build({ stackCount = 20 })
	for _, index in ipairs({ 1, 4 }) do
		t.eq(lines[index].right:find('scan', 1, true), nil, lines[index].right)
		t.eq(lines[index].right:find('table', 1, true), nil, lines[index].right)
	end
	t.same(lines[1].color, theme:Color('color.text.accent'))
	t.same(lines[1].rightColor, theme:Color('color.text.muted'))
end)

t.test('a single item shows one Price line, no count', function()
	t.same({ unpack(texts(build({ stackCount = 1 })), 4) }, {
		HEADER_ICON .. ' | ' .. PLUG_ICON .. ' 3 h',
		'Price | ' .. coins('94c'),
	})
end)

t.test('the Buy section is one unit row from the lowest listing, never a total', function()
	local lines = build({ stackCount = 20, quote = quote({ facts = { lowestListed = 1234, salesPerDay = 2 } }) })
	t.eq(texts(lines)[2], 'Auction house (each) | ' .. coins('12s 34c'))
	t.same(lines[2].color, theme:Color('color.text.secondary'))
	t.same(lines[2].rightColor, theme:Color('color.text.primary'))
end)

t.test('no listing: the Buy section and its separator are left out', function()
	t.same(texts(build({ stackCount = 20, quote = quote({ facts = { salesPerDay = 2 } }) })), {
		HEADER_ICON .. ' | ' .. PLUG_ICON .. ' 3 h',
		'Price (each) | ' .. coins('94c'),
		'Price × 20 | ' .. coins('18s 80c'),
	})
end)

t.test('a vendor buy price heads the Buy section under the store icon, with no age of its own', function()
	local storeIcon = icons:Inline('store', 0, 'color.text.secondary')
	local lines = build({ stackCount = 20, vendorBuy = { price = 40, stackPrice = 40, stack = 1, source = 'seed' } })
	t.same({ unpack(texts(lines), 1, 3) }, {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		storeIcon .. ' Vendor (each) | ' .. coins('40c'),
		'Auction house (each) | ' .. coins('90c'),
	})
	t.same(lines[2].color, theme:Color('color.text.secondary'))
	t.same(lines[2].rightColor, theme:Color('color.text.primary'))
end)

t.test('a vendor price alone keeps the Buy section, its header without an age', function()
	local storeIcon = icons:Inline('store', 0, 'color.text.secondary')
	local lines = build({
		quote = quote({ facts = { salesPerDay = 2, rowAge = 3600 } }),
		vendorBuy = { price = 40, stackPrice = 40, stack = 1, source = 'seen' },
	})
	t.same({ unpack(texts(lines), 1, 3) }, { CART_ICON, storeIcon .. ' Vendor (each) | ' .. coins('40c'), SEPARATOR })
end)

t.test('items a vendor sells in stacks read the stack price, never a rounded unit', function()
	local storeIcon = icons:Inline('store', 0, 'color.text.secondary')
	local arrows = { price = 0.5, stackPrice = 100, stack = 200, source = 'seed' }
	t.eq(texts(build({ vendorBuy = arrows }))[2], storeIcon .. ' Vendor × 200 | ' .. coins('1s'))
end)

t.test('no vendor buy price, or none worth a copper figure: no Vendor row', function()
	for _, vendorBuy in ipairs({ false, { price = 0, stackPrice = 0, stack = 1 }, { price = 0 / 0, stack = 1 } }) do
		t.eq(find(build({ vendorBuy = vendorBuy or nil }), 'Vendor (each)'), nil)
	end
	local bare = {
		Inline = function()
			return ''
		end,
	}
	local plain = build({ icons = bare, vendorBuy = { price = 40, stackPrice = 40, stack = 1 } })
	t.eq(texts(plain)[2], 'Vendor (each) | ' .. coins('40c'), 'without the atlas the row reads its word alone')
end)

local PERCENT_ICON = icons:Inline('badge-percent', 0, 'color.text.muted')
local STORE_ICON = icons:Inline('store', 0, 'color.text.secondary')
local DISCOUNTED_READ = {
	price = 40,
	stackPrice = 40,
	stack = 1,
	source = 'seen',
	vendorCount = 1,
	isBasePrice = false,
	isLimited = true,
	ageSeconds = 3 * 86400,
	cheapestVendor = { npcId = 7, name = 'Gina Lang', reaction = 6, priceFromBase = false },
}
-- Vendor details show with the detail block only. These options switch the detail section's
-- own rows off, the Vendor pays line too. The Buy vendor details have their own option
-- (detailVendorInfo), left at its default, on.
local VENDOR_ONLY = {
	detailTrace = false,
	detailSales = false,
	detailListings = false,
	detailVendor = false,
}

-- The Buy section's lines, header first, as texts.
local function buyTexts(lines)
	local result = {}
	for _, text in ipairs(texts(lines)) do
		if text == SEPARATOR then
			break
		end
		result[#result + 1] = text
	end
	return result
end

t.test('a discounted vendor price carries the discount icon, and no details without the detail block', function()
	t.same(buyTexts(build({ vendorBuy = DISCOUNTED_READ })), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		STORE_ICON .. ' Vendor (each) | ' .. coins('40c') .. ' ' .. PERCENT_ICON,
		'Auction house (each) | ' .. coins('90c'),
	})
end)

t.test('the detail block adds who sold it, the standing it was read at, its age and limited stock', function()
	local lines = build({ vendorBuy = DISCOUNTED_READ, isDetail = true, options = VENDOR_ONLY })
	t.same(buyTexts(lines), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		STORE_ICON .. ' Vendor (each) | ' .. coins('40c') .. ' ' .. PERCENT_ICON,
		'Sold by | Gina Lang',
		'Standing | Honored',
		'Read | 3 d ago',
		'Limited stock',
		'Auction house (each) | ' .. coins('90c'),
	})
	for index = 3, 6 do
		t.eq(lines[index].textSize, 'small', texts(lines)[index])
		t.same(lines[index].color, theme:Color('color.text.muted'))
	end
end)

t.test('a full vendor price shows no icon; the detail block adds its read, never a seed price', function()
	local fullRead = {
		price = 40,
		stackPrice = 40,
		stack = 1,
		source = 'seen',
		vendorCount = 1,
		isBasePrice = true,
		isLimited = false,
		ageSeconds = 2 * 3600,
		cheapestVendor = { npcId = 7, name = 'Gina Lang', reaction = 4, priceFromBase = false },
	}
	t.same(buyTexts(build({ vendorBuy = fullRead }))[2], STORE_ICON .. ' Vendor (each) | ' .. coins('40c'))
	t.same(buyTexts(build({ vendorBuy = fullRead, isDetail = true, options = VENDOR_ONLY })), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		STORE_ICON .. ' Vendor (each) | ' .. coins('40c'),
		'Sold by | Gina Lang',
		'Standing | Neutral',
		'Read | 2 h ago',
		'Auction house (each) | ' .. coins('90c'),
	})
	local seedOnly = {
		price = 0.5,
		stackPrice = 100,
		stack = 200,
		source = 'seed',
		vendorCount = 0,
		isLimited = false,
		isBasePrice = true,
	}
	t.same(buyTexts(build({ vendorBuy = seedOnly, isDetail = true, options = VENDOR_ONLY })), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		STORE_ICON .. ' Vendor × 200 | ' .. coins('1s'),
		'Auction house (each) | ' .. coins('90c'),
	}, 'a seed price has no vendor, standing or read to show')
	local unknownStanding = {
		price = 40,
		stackPrice = 40,
		stack = 1,
		source = 'seen',
		vendorCount = 1,
		isLimited = false,
		isBasePrice = false,
		cheapestVendor = { npcId = 7, reaction = 99, priceFromBase = false },
	}
	t.eq(find(build({ vendorBuy = unknownStanding, isDetail = true }), 'Standing'), nil, 'never a raw number')
end)

t.test('a price kept from an earlier base read leaves the standing out', function()
	local keptBase = {
		price = 40,
		stackPrice = 40,
		stack = 1,
		source = 'seen',
		vendorCount = 1,
		isLimited = false,
		isBasePrice = true,
		ageSeconds = 600,
		cheapestVendor = { npcId = 7, name = 'Gina Lang', reaction = 8, priceFromBase = true },
	}
	local lines = build({ vendorBuy = keptBase, isDetail = true, options = VENDOR_ONLY })
	t.eq(find(lines, 'Standing'), nil, 'the latest read was Exalted, the price is not from it')
	t.truthy(find(lines, 'Sold by | Gina Lang'))
end)

t.test('with the detail block the Buy vendor price and the vendor pays line stand apart', function()
	local lines = build({
		stackCount = 20,
		vendorBuy = DISCOUNTED_READ,
		isDetail = true,
		options = { detailTrace = false, detailSales = false, detailListings = false },
	})
	t.truthy(find(lines, STORE_ICON .. ' Vendor (each) | ' .. coins('40c')), 'what a vendor charges')
	t.truthy(find(lines, 'Vendor pays × 20 | ' .. coins('2s 60c')), 'what a vendor pays, in the detail block')
	t.truthy(find(build({ stackCount = 1, isDetail = true, options = { detailTrace = false } }), 'Vendor pays | '))
end)

t.test('the vendor details setting hides the Buy detail rows; Vendor pays keeps its own setting', function()
	local options = { detailTrace = false, detailVendorInfo = false }
	local lines = build({ stackCount = 20, vendorBuy = DISCOUNTED_READ, isDetail = true, options = options })
	t.same(buyTexts(lines), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		STORE_ICON .. ' Vendor (each) | ' .. coins('40c') .. ' ' .. PERCENT_ICON,
		'Auction house (each) | ' .. coins('90c'),
	})
	t.truthy(find(lines, 'Vendor pays × 20 | ' .. coins('2s 60c')), 'detailVendor still on')
	local payOff = build({ vendorBuy = DISCOUNTED_READ, isDetail = true, options = { detailVendor = false } })
	t.truthy(find(payOff, 'Sold by | Gina Lang'), 'detailVendor leaves the vendor details alone')
	t.truthy(find(payOff, 'Limited stock'))
	t.eq(find(payOff, 'Vendor pays'), nil)
end)

t.test('without the icon atlas the discount reads as a word', function()
	local bare = {
		Inline = function()
			return ''
		end,
	}
	t.eq(
		texts(build({ icons = bare, vendorBuy = DISCOUNTED_READ }))[2],
		'Vendor (each) | ' .. coins('40c') .. ' Discounted'
	)
end)

t.test('other shown rules move to the detail view', function()
	t.eq(find(build({ stackCount = 20 }), 'Median'), nil, 'compact: the default rule only')
	local detailed = build({ stackCount = 20, isDetail = true, options = { detailTrace = false } })
	t.eq(find(detailed, 'Median'), 'Median × 20 | ' .. coins('24s'))
	local separatorIndex = 7
	t.eq(texts(detailed)[separatorIndex], SEPARATOR, 'the detail block has its own separator after Sell')
	t.eq(texts(detailed)[separatorIndex + 1], 'Median × 20 | ' .. coins('24s'))
end)

t.test('no Shift unit view: Shift changes nothing but the detail block', function()
	t.same(texts(build({ stackCount = 20, isUnitView = true })), texts(build({ stackCount = 20 })))
end)

t.test('low confidence is marked on the line itself; medium is not', function()
	local lines = build({
		quote = quote({
			prices = {
				{ ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'low') },
				{ ruleId = 'median', name = 'Median', isDefault = false, price = price(120, 'medium') },
			},
		}),
		stackCount = 20,
	})
	t.eq(lines[5].right, coins('94c') .. ' ' .. LOW_ICON, 'the caution triangle, no text mark')
	t.eq(lines[6].right, coins('18s 80c'), 'once, on the first price row')
	t.eq(lines[7].left, 'Low confidence', 'the word goes on its own line, last')
	local detailed = build({
		quote = quote({
			prices = {
				{ ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'high') },
				{ ruleId = 'median', name = 'Median', isDefault = false, price = price(120, 'medium') },
			},
		}),
		isDetail = true,
	})
	t.eq(find(detailed, 'Median'), 'Median | ' .. coins('1s 20c'), 'medium is not marked')
end)

t.test('with the detail off, the top low reason wraps on its own line under the price', function()
	local reasons = {
		{ code = 'trollBuys', level = 'low', text = '81% of vanished units were troll buys and are left out' },
	}
	local lowQuote = quote({
		prices = { { ruleId = 'minimum', name = 'Minimum', isDefault = true, price = price(24, 'low', reasons) } },
	})
	local lines = build({ quote = lowQuote, stackCount = 2 })
	t.same(texts(sellLines(lines)), {
		HEADER_ICON .. ' | ' .. PLUG_ICON .. ' 3 h',
		'Price (each) | ' .. coins('24c') .. ' ' .. LOW_ICON,
		'Price × 2 | ' .. coins('48c'),
		'Low confidence, 81% of vanished units were troll buys and are left out',
	})
	t.eq(lines[#lines].wrap, true, 'wraps at the tooltip width instead of widening it')
	t.same(lines[#lines].color, theme:Color('color.state.caution'))
end)

t.test('with the detail off, a low line names its top reason inline', function()
	local reasons = {
		{ code = 'stale', level = 'medium', text = 'scan is 3 h old' },
		{ code = 'fewSales', level = 'low', text = 'few sales' },
	}
	local lowQuote = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'low', reasons) } },
	})
	t.same({ unpack(texts(build({ quote = lowQuote })), 5, 6) }, {
		'Price | ' .. coins('94c') .. ' ' .. LOW_ICON,
		'Low confidence, few sales',
	})
	local detailed = texts(build({ quote = lowQuote, isDetail = true, options = { detailTrace = false } }))
	t.eq(detailed[5], 'Price | ' .. coins('94c') .. ' ' .. LOW_ICON)
	t.eq(detailed[6], SEPARATOR, 'the detail block replaces the short reason')
	t.eq(detailed[7], MEDIUM_ICON .. ' Medium confidence, scan is 3 h old', 'the detail block lists every reason')
end)

t.test('a rule without a price says so on one Price line', function()
	local lines = build({
		quote = quote({
			prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, reason = 'no data' } },
		}),
		stackCount = 20,
	})
	t.same({ unpack(texts(lines), 5) }, { 'Price | no price' })
end)

t.test('Buy header: a listing from AHledger shows the plug and its row age, never the scan age', function()
	local facts = { lowestListed = 280, lowestListedSource = 'ahledger', rowAge = 7200 }
	local lines = build({ quote = quote({ facts = facts, ages = { scanAge = 60, tableAge = 600 } }) })
	t.eq(lines[1].right, PLUG_ICON .. ' 2 h', 'a scan exists but this item is not in it')
	t.eq(lines[2].right, coins('2s 80c'))
end)

t.test("Buy header: a listing from the scan shows the search icon and the item's own scan age", function()
	local facts = { lowestListed = 90, lowestListedSource = 'scan', scanAge = 300, rowAge = 7200 }
	local lines = build({ quote = quote({ facts = facts, ages = { scanAge = 60, tableAge = 600 } }) })
	t.eq(lines[1].right, SEARCH_ICON .. ' 5 min')
end)

t.test("Sell header: the age of the price's own source, search for a scan, plug for AHledger", function()
	local scanned = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94) } },
	})
	scanned.prices[1].price.source, scanned.prices[1].price.baseAgeSeconds = 'scan', 300
	t.eq(build({ quote = scanned })[4].right, SEARCH_ICON .. ' 5 min')
	t.eq(build({ quote = quote() })[4].right, PLUG_ICON .. ' 3 h')
end)

t.test('no age next to a source never reads no data: the icon stands alone, or nothing at all', function()
	local noRowAge = build({ quote = quote({ facts = { lowestListed = 90, lowestListedSource = 'ahledger' } }) })
	t.eq(noRowAge[1].right, PLUG_ICON)
	local vendorPriced = quote()
	vendorPriced.prices[1].price.source = 'vendor'
	t.eq(build({ quote = vendorPriced })[4].right, nil, 'a vendor price has no market age')
	local unpriced = build({
		quote = quote({
			prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, reason = 'no data' } },
		}),
	})
	t.eq(unpriced[4].right, nil, 'no price, no age')
	for _, line in ipairs(texts(build({ quote = quote({ ages = {} }) }))) do
		t.eq(line:find('no data', 1, true), nil, line)
	end
end)

-- A quote for linen priced by the real default rule, from a scan dated scannedAt (nil for a
-- snapshot without a valid time) and an AHledger table two days old.
local function realisticQuote(scannedAt)
	local api = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 2 * 86400, rows = AHLEDGER_ROWS })
	local ctx = ns.PriceContext.build({
		now = NOW,
		marketKey = MARKET,
		priceSource = ns.PriceData.newAHledgerSource(function()
			return api
		end),
		snapshot = {
			at = scannedAt,
			items = { [LINEN] = { min = 100, units = 40, levels = { { price = 100, qty = 40 } } } },
		},
	})
	local defaultPrice = ns.Rules.evaluate(ns.Rules.builtIns().realistic, LINEN, ctx)
	return {
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, price = defaultPrice } },
		facts = ns.PriceContext.facts(ctx, LINEN),
	}
end

t.test('an unknown scan time shows the search icon alone, never the AHledger age after it', function()
	local lines = build({ quote = realisticQuote(nil) })
	t.eq(lines[4].right, SEARCH_ICON .. ' ' .. PLUG_ICON .. ' 2 d', 'the median cap still dates AHledger by its row')
	t.eq(build({ quote = realisticQuote(NOW - 300) })[4].right, SEARCH_ICON .. ' 5 min ' .. PLUG_ICON .. ' 2 d')
end)

t.test('without the icon atlas each age is named in words, so two ages never stand bare', function()
	local bare = {
		Inline = function()
			return ''
		end,
	}
	local lines = build({ quote = realisticQuote(NOW - 300), icons = bare })
	t.eq(lines[1].left, TooltipLines.BUY_FALLBACK)
	t.eq(lines[1].right, 'Scan 5 min')
	t.eq(lines[4].right, 'Scan 5 min AHledger 2 d')
	t.eq(build({ quote = realisticQuote(nil), icons = bare })[4].right, 'Scan AHledger 2 d')
	t.eq(build({ quote = quote(), icons = bare })[4].right, 'AHledger 3 h')
end)

t.test('a vendor, craft cost or own-sales base with an AHledger step names its base before the row age', function()
	for source, label in pairs({ vendor = 'Vendor pays', craft = 'Craft cost', realized = 'Your sales' }) do
		local stepped = quote()
		local stepPrice = stepped.prices[1].price
		stepPrice.source, stepPrice.baseAgeSeconds, stepPrice.rowAgeSeconds = source, 0, 7200
		t.eq(build({ quote = stepped })[4].right, label .. ' ' .. PLUG_ICON .. ' 2 h', source)
	end
end)

t.test('an item Haggler knows nothing about gets no lines', function()
	local unknown = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, reason = 'no data' } },
		facts = { vendor = 50 },
	})
	t.same(build({ quote = unknown, isDetail = true }), {})
end)

t.test('detail: the trace, reasons, sales, listings and vendor pays, no sell time', function()
	local reasons = {
		{ code = 'stale', level = 'medium', text = 'AHledger data is 30 hours old' },
	}
	local trace = {
		{ kind = 'base', label = 'scan first price with 5 units', copper = 99 },
		{ kind = 'skip', label = 'cap skipped, no median' },
		{ kind = 'step', label = 'undercut by 1c', copper = 98 },
		{ kind = 'snap', label = 'price step 1c', copper = 98 },
		{ kind = 'confidence', label = 'medium confidence, AHledger data is 30 hours old' },
	}
	local detailed = quote({
		prices = {
			{ ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(98, 'medium', reasons, trace) },
			{
				ruleId = 'median',
				name = 'Median',
				isDefault = false,
				price = price(120, 'low', { { code = 'fewSales', level = 'low', text = 'under 1 sale a day' } }),
			},
		},
	})
	t.same(texts(build({ quote = detailed, stackCount = 20, isDetail = true })), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		'Auction house (each) | ' .. coins('90c'),
		SEPARATOR,
		HEADER_ICON .. ' | ' .. PLUG_ICON .. ' 3 h',
		'Price (each) | ' .. coins('98c'),
		'Price × 20 | ' .. coins('19s 60c'),
		SEPARATOR,
		'Median × 20 | ' .. coins('24s') .. ' ' .. LOW_ICON,
		'Realistic (each)',
		'  scan first price with 5 units | ' .. coins('99c'),
		'  cap skipped, no median',
		'  undercut by 1c | ' .. coins('98c'),
		'  price step 1c | ' .. coins('98c'),
		MEDIUM_ICON .. ' Medium confidence, AHledger data is 30 hours old',
		LOW_ICON .. ' Median, low confidence, under 1 sale a day',
		'Sold a day | 45',
		'Listed | × 60',
		'Price levels | 2',
		'Vendor pays × 20 | ' .. coins('2s 60c'),
	})
end)

t.test('detail lines follow their settings; the reasons always show', function()
	local reasons = { { code = 'stale', level = 'low', text = 'old data' } }
	local lowQuote = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'low', reasons) } },
	})
	local options = {
		detailTrace = false,
		detailSales = false,
		detailListings = false,
		detailVendor = false,
	}
	t.same(texts(build({ quote = lowQuote, isDetail = true, options = options })), {
		CART_ICON .. ' | ' .. SEARCH_ICON .. ' 12 min',
		'Auction house (each) | ' .. coins('90c'),
		SEPARATOR,
		HEADER_ICON .. ' | ' .. PLUG_ICON .. ' 3 h',
		'Price | ' .. coins('94c') .. ' ' .. LOW_ICON,
		SEPARATOR,
		LOW_ICON .. ' Low confidence, old data',
	})
end)

t.test('detail lines that can grow long wrap at the tooltip width', function()
	local reasons = { { code = 'stale', level = 'low', text = 'old data' } }
	local lowQuote = quote({
		prices = {
			{ ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'low', reasons) },
			{ ruleId = 'median', name = 'Median', isDefault = false, reason = 'too few sales in the window' },
		},
		facts = { salesPerDay = 0.2, levels = {} },
	})
	local lines = build({ quote = lowQuote, isDetail = true, options = { detailTrace = false } })
	for _, text in ipairs({ 'old data', 'no price, too few sales' }) do
		local isFound = false
		for _, line in ipairs(lines) do
			if (line.left or ''):find(text, 1, true) then
				isFound = true
				t.eq(line.wrap, true, text)
				t.eq(line.right, nil, text)
			end
		end
		t.truthy(isFound, text)
	end
end)

t.test('a rule that fails validation reads one plain line, no internal detail', function()
	local brokenQuote = quote({
		prices = {
			{ ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94) },
			{ ruleId = 'mine', name = 'Mine', isDefault = false, reason = ns.Rules.UNUSABLE_RULE },
		},
	})
	local lefts = {}
	for _, line in ipairs(build({ quote = brokenQuote, isDetail = true, options = { detailTrace = false } })) do
		lefts[#lefts + 1] = line.left or ''
	end
	local joined = table.concat(lefts, ' / ')
	t.truthy(joined:find("Mine can't be used", 1, true), joined)
	t.eq(joined:find('no price, Mine', 1, true), nil)
	t.eq(joined:find('invalid', 1, true), nil, joined)
	for _, left in ipairs(lefts) do
		local words = left:gsub('|T.-|t', '')
		t.eq(words:find('[:;]'), nil, left)
	end
end)

t.test('an informational reason gets its own marker, never a bare leading space', function()
	local reasons = { { code = 'ownSalesThin', level = 'high', text = 'sold a day from AHledger' } }
	local infoQuote = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'high', reasons) } },
	})
	local lines = build({ quote = infoQuote, isDetail = true, options = { detailTrace = false } })
	t.truthy(find(lines, INFO_ICON .. ' Sold a day from AHledger'))
end)

t.test('the sales line says when sales a day is the own count', function()
	local facts = { salesPerDay = 12.5, salesSource = 'own', listedUnits = 3, levelCount = 1 }
	local lines = build({ isDetail = true, quote = quote({ facts = facts }) })
	t.eq(find(lines, 'Sold a day'), 'Sold a day | 12.5')
	t.eq(find(lines, 'Sales from'), 'Sales from | Own scans')
end)

t.test('no sell time line, and saved sell time settings are ignored', function()
	local slow = quote({ facts = { salesPerDay = 0.2, levels = {} } })
	local options = { detailSellTime = true, sellTimeNote = true }
	for _, lines in ipairs({ build({ isDetail = true, quote = slow }), build({ isDetail = true, options = options }) }) do
		for _, text in ipairs(texts(lines)) do
			t.eq(text:find('Sell time', 1, true), nil, text)
			t.eq(text:find('under 1 sale a day', 1, true), nil, text)
			t.eq(text:find('not in-game time', 1, true), nil, text)
		end
	end
	t.eq(TooltipLines.sellTimeDays, nil)
	t.eq(TooltipLines.SELL_TIME_NOTE, nil)
end)

t.test('without sales data the sales line reads unknown', function()
	local lines = build({
		isDetail = true,
		quote = quote({ facts = { listedUnits = 3, levelCount = 1, levels = { { price = 90, qty = 3 } } } }),
	})
	t.eq(find(lines, 'Sold a day'), 'Sold a day | unknown')
	t.eq(find(lines, 'Vendor'), nil)
end)

t.test('money and ages read short', function()
	t.eq(TooltipLines.money(0), '0' .. COIN_ICONS.c)
	t.eq(TooltipLines.money(48), '48' .. COIN_ICONS.c)
	t.eq(TooltipLines.money(100), '1' .. COIN_ICONS.s)
	t.eq(TooltipLines.money(10000), '1' .. COIN_ICONS.g, 'zero parts are left out, as the game does')
	t.eq(TooltipLines.money(12005), '1' .. COIN_ICONS.g .. ' 20' .. COIN_ICONS.s .. ' 5' .. COIN_ICONS.c)
	t.eq(TooltipLines.money(1230000), '123' .. COIN_ICONS.g)
	t.eq(TooltipLines.age(5), 'just now')
	t.eq(TooltipLines.age(150), '2 min')
	t.eq(TooltipLines.age(7300), '2 h')
	t.eq(TooltipLines.age(3 * 86400), '3 d')
end)

t.test('ago: just now has no "ago"; older ages do', function()
	t.eq(TooltipLines.ago(5), 'just now')
	t.eq(TooltipLines.ago(150), '2 min ago')
	t.eq(TooltipLines.ago(3 * 86400), '3 d ago')
end)

t.test('lines use theme colours', function()
	local lines = build({})
	t.same(lines[1].color, theme:Color('color.text.accent'))
	t.same(lines[1].rightColor, theme:Color('color.text.muted'))
end)

t.group('theme')

t.test('colours come from the theme, then what it extends, then the default theme, then grey', function()
	local tokens = {
		themes = {
			banneret = {
				tokens = { ['color.a'] = { 1, 0, 0, 1 }, ['color.b'] = { 0, 1, 0, 1 }, ['color.c'] = { 0, 0, 1 } },
			},
			base = { tokens = { ['color.b'] = { 0, 0, 0, 1 } } },
			child = { extends = 'base', tokens = { ['color.a'] = { 1, 1, 1, 0.5 } } },
			loop = { extends = 'loop', tokens = {} },
		},
	}
	local child = Theme.new(tokens, 'child')
	t.same(child:Color('color.a'), { r = 1, g = 1, b = 1, a = 0.5 })
	t.same(child:Color('color.b'), { r = 0, g = 0, b = 0, a = 1 }, 'from what it extends')
	t.same(child:Color('color.c'), { r = 0, g = 0, b = 1, a = 1 }, 'from the default theme')
	t.same(child:Color('color.none'), Theme.FALLBACK_COLOR)
	t.same(Theme.new(tokens, 'loop'):Color('color.a'), { r = 1, g = 0, b = 0, a = 1 }, 'a loop ends')
	t.eq(Theme.new(tokens, 'missing').key, 'banneret')
	t.eq(Theme.new(tokens):Hex('color.a'), 'ffff0000')
	t.eq(Theme.new(tokens):Wrap('color.b', 'hi'), '|cff00ff00hi|r')
	t.same(Theme.new(nil, 'x'):Color('color.text.accent'), theme:Color('color.text.accent'))
	t.same(Theme.new({}):Color('color.a'), Theme.FALLBACK_COLOR)
end)

t.test('the generated tokens have the colours the tooltip uses', function()
	for _, name in ipairs({
		'color.text.accent',
		'color.text.primary',
		'color.text.secondary',
		'color.text.muted',
		'color.state.danger',
		'color.state.warning',
	}) do
		t.truthy(theme:Color(name) ~= Theme.FALLBACK_COLOR, name)
	end
end)

t.group('tooltip host')

local function newRegistry(options)
	local game = FakeGame.new(options)
	local errors = {}
	local wow = ns.Wow.create(game.env)
	local tooltips = ns.Tooltip.new({
		wow = wow,
		theme = theme,
		onError = function(owner, err)
			errors[#errors + 1] = owner .. ': ' .. tostring(err)
		end,
	})
	return game, tooltips, errors
end

t.test('the hook goes in with the first provider; lines draw and the tooltip is shown again', function()
	local game, tooltips = newRegistry()
	t.eq(#game.postCalls, 0)
	tooltips:AddProvider('a', function(itemId, info)
		return {
			{ left = 'item ' .. itemId, right = 'x' .. info.stackCount, color = { r = 1, g = 0, b = 0 } },
			{ left = 'note' },
		}
	end)
	t.eq(#game.postCalls, 1)
	local lines = game:ShowItemTooltip(LINEN)
	t.same(lines[1], { left = 'item 2589', right = 'x1', lr = 1, lg = 0, lb = 0, rr = 1, rg = 1, rb = 1 })
	t.same(lines[2], { left = 'note', r = 1, g = 1, b = 1, wrap = false })
	t.eq(game.env.GameTooltip.shownCount, 1)
end)

t.test('one failing provider is reported; the others still draw', function()
	local game, tooltips, errors = newRegistry()
	tooltips:AddProvider('broken', function()
		error('oops')
	end)
	tooltips:AddProvider('junk', function()
		return { 'not a line', { right = 'no left' }, { left = 'kept' } }
	end)
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(#lines, 2, 'the kept line and the collapsed closing separator')
	t.eq(lines[1].left, 'kept')
	t.eq(#errors, 1)
	t.truthy(errors[1]:find('broken'))
end)

t.test('no lines: the tooltip is left alone', function()
	local game, tooltips = newRegistry()
	tooltips:AddProvider('quiet', function()
		return {}
	end)
	game:ShowItemTooltip(LINEN)
	t.eq(game.env.GameTooltip.shownCount, 0)
end)

t.test('removing the last provider stops drawing; adding again reuses the one hook', function()
	local game, tooltips = newRegistry()
	local provider = function()
		return { { left = 'line' } }
	end
	tooltips:AddProvider('a', provider)
	tooltips:AddProvider('a', provider)
	t.eq(#game:ShowItemTooltip(LINEN), 2, 'adding again replaces: one line and the closing separator')
	tooltips:RemoveProvider('a')
	t.eq(tooltips:HasProviders(), false)
	t.eq(#game:ShowItemTooltip(LINEN), 0)
	tooltips:AddProvider('a', provider)
	t.eq(#game:ShowItemTooltip(LINEN), 2)
	t.eq(#game.postCalls, 1, 'the client hook cannot be undone, so it goes in once')
end)

t.test('without the data processor the tooltip scripts are hooked instead', function()
	local game, tooltips = newRegistry({ hasProcessor = false })
	tooltips:AddProvider('a', function()
		return { { left = 'line' } }
	end)
	t.truthy(game.env.GameTooltip.scripts.OnTooltipSetItem)
	t.eq(#game:ShowItemTooltip(LINEN), 2)
end)

t.test('the stack count comes from the bag slot under the cursor, when it holds the item', function()
	local game, tooltips = newRegistry()
	local seen = {}
	tooltips:AddProvider('a', function(_, info)
		seen[#seen + 1] = info.stackCount
		return {}
	end)
	local slot = {
		GetBagID = function()
			return 0
		end,
		GetID = function()
			return 3
		end,
	}
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 17 }
	game.env.GameTooltip.owner = slot
	game:ShowItemTooltip(LINEN)
	game:ShowItemTooltip(WOOL)
	game.env.GameTooltip.owner = nil
	game:ShowItemTooltip(LINEN)
	t.same(seen, { 17, 1, 1 })
end)

t.test('modifiers reach the providers; a forbidden tooltip is skipped', function()
	local game, tooltips = newRegistry()
	local seen
	tooltips:AddProvider('a', function(_, info)
		seen = info.modifiers
		return { { left = 'x' } }
	end)
	game.modifiers.shift = true
	game:ShowItemTooltip(LINEN)
	t.same(seen, { shift = true, ctrl = false, alt = false })
	game.env.GameTooltip.isForbidden = true
	t.eq(#game:ShowItemTooltip(LINEN), 0)
end)

local SPACER_16 = '|TInterface\\AddOns\\Haggler\\media\\spacer.png:1:16|t'

local function lineFonts(game, tooltip, index)
	local left = game.env[tooltip.name .. 'TextLeft' .. index]
	local right = game.env[tooltip.name .. 'TextRight' .. index]
	return left:GetFontObject(), right:GetFontObject()
end

local function lineColors(game, tooltip, index)
	local left = game.env[tooltip.name .. 'TextLeft' .. index]
	local right = game.env[tooltip.name .. 'TextRight' .. index]
	return { left:GetTextColor() }, { right:GetTextColor() }
end

local function runPostCall(game, tooltip)
	game.postCalls[1].handler(tooltip, { id = LINEN })
end

local function withSupportingRow(tooltips)
	tooltips:AddProvider('haggler', function()
		return {
			{ left = 'Decision', right = 'Wait' },
			{
				left = 'Market',
				right = 'Steady',
				color = { r = 0.5, g = 0.5, b = 0.5 },
				rightColor = { r = 0.4, g = 0.4, b = 0.4 },
				textSize = 'small',
				indent = 16,
			},
			{ left = 'Vendor', right = '13c' },
		}
	end)
end

t.test('a small line draws in the client small tooltip font, both columns, indented by a spacer', function()
	local game, tooltips = newRegistry()
	withSupportingRow(tooltips)
	local tooltip = game.env.GameTooltip
	local lines = game:ShowItemTooltip(LINEN)
	local small, normal, header =
		game.env.GameTooltipTextSmall, game.env.GameTooltipText, game.env.GameTooltipHeaderText
	t.eq(lines[2].left, SPACER_16 .. 'Market', 'the spacer is the indent')
	t.eq(lines[2].right, 'Steady', 'the value keeps its right edge')
	t.same({ lineFonts(game, tooltip, 2) }, { small, small })
	t.same(
		{ lineColors(game, tooltip, 2) },
		{ { 0.5, 0.5, 0.5, 1 }, { 0.4, 0.4, 0.4, 1 } },
		'the small font keeps the line colours'
	)
	t.same({ lineFonts(game, tooltip, 1) }, { header, header }, 'the line above keeps its font')
	t.same({ lineFonts(game, tooltip, 3) }, { normal, normal }, 'the line below keeps its font')
	t.eq(lines[3].left, 'Vendor', 'no indent on other lines')
end)

t.test('the spacer texture ships with the add-on and the release keeps it', function()
	local file = io.open('media/spacer.png', 'rb')
	t.truthy(file, 'media/spacer.png')
	if file then
		file:close()
	end
	for line in io.lines('.pkgmeta') do
		t.eq(line:match('^%s*%-%s*media/?$'), nil, 'media is not ignored')
		t.eq(line:match('^%s*%-%s*media/spacer'), nil, 'the spacer is not ignored')
	end
end)

t.test('a reused line gets its own font back: on clear, on hide and for the next item', function()
	local game, tooltips = newRegistry()
	withSupportingRow(tooltips)
	local tooltip = game.env.GameTooltip
	local normal, small = game.env.GameTooltipText, game.env.GameTooltipTextSmall
	game:ShowItemTooltip(LINEN)
	tooltip:ClearLines()
	t.same({ lineFonts(game, tooltip, 2) }, { normal, normal }, 'cleared')
	tooltip:AddDoubleLine('Other add-on', 'value')
	tooltip:AddDoubleLine('Other add-on', 'value')
	t.same({ lineFonts(game, tooltip, 2) }, { normal, normal }, 'another add-on line on the reused index')
	game:ShowItemTooltip(LINEN)
	t.eq(tooltip.isShown, true, 'shown again')
	t.same({ lineFonts(game, tooltip, 2) }, { small, small }, 'small before the hide')
	tooltip:Hide()
	t.same({ lineFonts(game, tooltip, 2) }, { normal, normal }, 'hidden')
	tooltips:RemoveProvider('haggler')
	tooltips:AddProvider('other', function()
		return { { left = 'a' }, { left = 'b', right = 'c' } }
	end)
	game:ShowItemTooltip(LINEN)
	t.same({ lineFonts(game, tooltip, 2) }, { normal, normal }, 'the next item')
end)

t.test('the next render restores a line reused without a clear, keeping its new colour', function()
	local game, tooltips = newRegistry()
	withSupportingRow(tooltips)
	local tooltip = game.env.GameTooltip
	local normal = game.env.GameTooltipText
	game:ShowItemTooltip(LINEN)
	-- Lines dropped and reused with no OnTooltipCleared.
	tooltip.lines = {}
	tooltip:AddLine('x', 1, 0, 0)
	tooltip:AddDoubleLine('Other add-on', 'value', 0, 1, 0, 0, 0, 1)
	runPostCall(game, tooltip)
	t.same({ lineFonts(game, tooltip, 2) }, { normal, normal }, 'restored before drawing')
	t.same({ lineColors(game, tooltip, 2) }, { { 0, 1, 0, 1 }, { 0, 0, 1, 1 } }, 'its owner colours stay')
end)

t.test('a duplicate post-call leaves the small rows still on screen small', function()
	local game, tooltips = newRegistry()
	withSupportingRow(tooltips)
	local tooltip = game.env.GameTooltip
	local small = game.env.GameTooltipTextSmall
	game:ShowItemTooltip(LINEN)
	runPostCall(game, tooltip)
	t.same({ lineFonts(game, tooltip, 2) }, { small, small }, 'the first block')
	t.same({ lineColors(game, tooltip, 2) }, { { 0.5, 0.5, 0.5, 1 }, { 0.4, 0.4, 0.4, 1 } })
end)

t.test('a line that was not normal before keeps its own font after the small row', function()
	local game, tooltips = newRegistry()
	withSupportingRow(tooltips)
	local tooltip = game.env.GameTooltip
	local custom = { name = 'SomeAddonFont', path = 'Fonts\\ARIALN.TTF', size = 11 }
	tooltip:AddLine('x')
	tooltip:AddLine('y')
	game.env.GameTooltipTextLeft2:SetFontObject(custom)
	game:ShowItemTooltip(LINEN)
	t.eq(game.env.GameTooltipTextLeft2:GetFontObject(), game.env.GameTooltipTextSmall)
	tooltip:ClearLines()
	t.eq(game.env.GameTooltipTextLeft2:GetFontObject(), custom, 'restored to what it had')
end)

t.test('a skin font set with SetFont comes back, with or without a font object behind it', function()
	local game, tooltips = newRegistry()
	withSupportingRow(tooltips)
	local tooltip = game.env.GameTooltip
	tooltip:AddLine('x')
	tooltip:AddDoubleLine('y', 'z')
	local left, right = game.env.GameTooltipTextLeft2, game.env.GameTooltipTextRight2
	left:SetFont('Interface\\AddOns\\Skin\\font.ttf', 13, 'OUTLINE')
	right.fontObject = nil
	right:SetFont('Interface\\AddOns\\Skin\\font.ttf', 11, '')
	game:ShowItemTooltip(LINEN)
	t.eq(left:GetFontObject(), game.env.GameTooltipTextSmall)
	tooltip:ClearLines()
	t.same({ left:GetFont() }, { 'Interface\\AddOns\\Skin\\font.ttf', 13, 'OUTLINE' }, 'object and SetFont')
	t.eq(left:GetFontObject(), game.env.GameTooltipText)
	t.same({ right:GetFont() }, { 'Interface\\AddOns\\Skin\\font.ttf', 11, '' }, 'SetFont alone')
end)

t.test('a tooltip without OnTooltipCleared gets the indent but keeps its font', function()
	local game, tooltips = newRegistry()
	withSupportingRow(tooltips)
	local tooltip = game.env.GameTooltip
	tooltip.scriptNames = {}
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(lines[2].left, SPACER_16 .. 'Market')
	t.same({ lineFonts(game, tooltip, 2) }, { game.env.GameTooltipText, game.env.GameTooltipText })
end)

t.group('tooltip separators')

-- The game's tooltip once blended, near-black #0b0b0b (Concord's Theme - Banneret note).
local NATIVE_TOOLTIP_BACKGROUND = { r = 0.043, g = 0.043, b = 0.043 }
local MIN_RULE_CONTRAST = 3

local function relativeLuminance(color)
	local function linear(channel)
		return channel <= 0.04045 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
end

local function blendedContrast(rgba, background)
	local blended = {
		r = rgba[1] * rgba[4] + background.r * (1 - rgba[4]),
		g = rgba[2] * rgba[4] + background.g * (1 - rgba[4]),
		b = rgba[3] * rgba[4] + background.b * (1 - rgba[4]),
	}
	local lighter = math.max(relativeLuminance(blended), relativeLuminance(background))
	local darker = math.min(relativeLuminance(blended), relativeLuminance(background))
	return (lighter + 0.05) / (darker + 0.05)
end

-- Another add-on's (or the game's) lines, added by a post-call like Haggler's own. A line is
-- its text, { left, right } for a double line, or { money = copper } for the sell-price line.
local function addOtherLines(game, otherLines, shouldShowAfter)
	game.env.TooltipDataProcessor.AddTooltipPostCall(game.env.Enum.TooltipDataType.Item, function(tooltip)
		for _, line in ipairs(otherLines) do
			if type(line) == 'string' then
				tooltip:AddLine(line)
			elseif line.money then
				tooltip:AddMoneyLine(line.money)
			else
				tooltip:AddDoubleLine(line[1], line[2])
			end
		end
		if shouldShowAfter then
			tooltip:Show()
		end
	end)
end

local function withHagglerBlock(tooltips)
	tooltips:AddProvider('haggler', function()
		return { { left = 'Haggler', right = '12 min' }, { left = 'Realistic', right = '94c' } }
	end)
end

local function leftTexts(tooltip)
	local result = {}
	for index, line in ipairs(tooltip.lines) do
		result[index] = line.left
	end
	return result
end

-- The rules shown, as the line index each sits on.
local function shownRuleLines(game, tooltip)
	local result = {}
	for _, texture in ipairs(tooltip.children) do
		if texture.isShown and texture.colorTexture then
			local _, relativeTo = texture:GetPoint(1)
			for index = 1, #tooltip.lines do
				if game.env[tooltip.name .. 'TextLeft' .. index] == relativeTo then
					result[#result + 1] = index
				end
			end
		end
	end
	table.sort(result)
	return result
end

t.test('a separator goes above the block: a blank line with a 1px rule in the strong border colour', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Haggler', 'Realistic', '' })
	t.same(shownRuleLines(game, tooltip), { 2 })
	local rule = tooltip.children[1]
	local border = theme:Color('color.border.strong')
	t.same(rule.colorTexture, { border.r, border.g, border.b, border.a })
	t.eq(rule.height, 1, 'border.hairline, a whole pixel')
	t.truthy(
		blendedContrast(rule.colorTexture, NATIVE_TOOLTIP_BACKGROUND) >= MIN_RULE_CONTRAST,
		'the rule stands at 3:1 or more on the game tooltip'
	)
	t.eq(rule.width, 220, 'the tooltip width less the line inset on both sides')
end)

t.test('a separator line between sections is a blank line with its own rule, like the outer ones', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	tooltips:AddProvider('haggler', function()
		return {
			{ left = 'Buy', right = '12 min' },
			{ left = 'Auction house (each)', right = '90c' },
			{ kind = 'separator' },
			{ left = 'Haggler', right = '3 h' },
			{ left = 'Price', right = '94c' },
		}
	end)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Buy', 'Auction house (each)', ' ', 'Haggler', 'Price', '' })
	t.same(shownRuleLines(game, tooltip), { 2, 5 })
	local border = theme:Color('color.border.strong')
	for _, rule in ipairs(tooltip.children) do
		if rule.isShown then
			t.same(rule.colorTexture, { border.r, border.g, border.b, border.a })
			t.eq(rule.height, 1, 'border.hairline, a whole pixel')
			t.eq(rule.width, 220, 'the same width as the outer rules')
		end
	end
	game:ShowItemTooltip(LINEN)
	t.same(shownRuleLines(game, tooltip), { 2, 5 }, 'a rebuild reuses the rules')
end)

t.test('leading, trailing and doubled separators collapse; only separators is no block at all', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	local sep = { kind = 'separator' }
	tooltips:AddProvider('haggler', function()
		return { sep, sep, { left = 'Buy' }, sep, sep, { left = 'Price' }, sep }
	end)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Buy', ' ', 'Price', '' })
	t.same(shownRuleLines(game, tooltip), { 2, 4 })
	local _, only = newRegistry()
	only:AddProvider('haggler', function()
		return { sep, sep }
	end)
	t.same(only:Lines(LINEN, { stackCount = 1 }), {}, 'separators alone are not a usable block')
end)

t.test('a tooltip without OnTooltipCleared draws no separator line between sections', function()
	local game, tooltips = newRegistry()
	game.env.GameTooltip.scriptNames.OnTooltipCleared = nil
	tooltips:AddProvider('haggler', function()
		return { { left = 'Buy' }, { kind = 'separator' }, { left = 'Price' } }
	end)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Buy', 'Price' })
	t.eq(#tooltip.children, 0)
end)

t.test('no doubled separator: a blank line above the block gets the rule, its text untouched', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth', ' ' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Haggler', 'Realistic', '' })
	t.same(shownRuleLines(game, tooltip), { 2 })
end)

t.test('the sell-price money line above is not blank: the block gets its own separator', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth', { money = 13 } })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', ' ', 'Haggler', 'Realistic', '' })
	t.same(shownRuleLines(game, tooltip), { 3 })
end)

t.test('a double line with only right text above is not blank either', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth', { ' ', '5 charges' } })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', ' ', 'Haggler', 'Realistic', '' })
	t.same(shownRuleLines(game, tooltip), { 3 })
end)

t.test('a money line after the block gets the separator below', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	addOtherLines(game, { { money = 13 } }, true)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Haggler', 'Realistic', ' ', ' ' })
	t.same(shownRuleLines(game, tooltip), { 2, 5 })
end)

t.test('Haggler last: no separator at the end of the tooltip', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	tooltip:Show()
	t.eq(tooltip.lines[#tooltip.lines].left, '', 'the closing separator collapses to an empty line')
	t.same(shownRuleLines(game, tooltip), { 2 }, 'only the one above shows')
end)

t.test('lines another add-on adds after the block get the separator below', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	addOtherLines(game, { 'Other add-on' }, true)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Haggler', 'Realistic', ' ', 'Other add-on' })
	t.same(shownRuleLines(game, tooltip), { 2, 5 })
end)

t.test('the separator below waits for the next Show when the later add-on does not show', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	addOtherLines(game, { 'Other add-on' })
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	tooltip:Show()
	t.same(shownRuleLines(game, tooltip), { 2, 5 })
end)

t.test('no doubled separator below: a blank line after the block gets the rule, the closing stays collapsed', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	addOtherLines(game, { ' ', 'Other add-on' }, true)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Haggler', 'Realistic', '', ' ', 'Other add-on' })
	t.same(shownRuleLines(game, tooltip), { 2, 6 })
end)

t.test('a tooltip without OnTooltipCleared gets the lines but no separators', function()
	local game, tooltips = newRegistry()
	game.env.GameTooltip.scriptNames.OnTooltipCleared = nil
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth', 'Haggler', 'Realistic' })
	t.eq(#tooltip.children, 0)
end)

t.test('a closing line that no longer holds the separator is never touched', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	game.env.GameTooltipTextLeft5:SetText('Someone else')
	tooltip:AddLine('Later line')
	tooltip:Show()
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Haggler', 'Realistic', 'Someone else', 'Later line' })
	t.same(shownRuleLines(game, tooltip), { 2 })
end)

t.test("a collapsed closing line the client reads back as nil is still Haggler's", function()
	local game, tooltips = newRegistry()
	game.env.GameTooltip.isEmptyTextNil = true
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	tooltip:AddLine('Later line')
	tooltip:Show()
	t.same(leftTexts(tooltip), { 'Linen Cloth', ' ', 'Haggler', 'Realistic', ' ', 'Later line' })
	t.same(shownRuleLines(game, tooltip), { 2, 5 })
end)

t.test('rules snap to the pixel grid where the client can', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	game:ShowItemTooltip(LINEN)
	local rule = game.env.GameTooltip.children[1]
	t.eq(rule.isSnappedToPixelGrid, true)
	t.eq(rule.texelSnappingBias, 0)
	local older, olderTooltips = newRegistry()
	older.env.GameTooltip.hasPixelSnapping = false
	addOtherLines(older, { 'Linen Cloth' })
	withHagglerBlock(olderTooltips)
	older:ShowItemTooltip(LINEN)
	t.eq(#shownRuleLines(older, older.env.GameTooltip), 1, 'a client without them still draws the rule')
end)

t.test('rules are whole physical pixels: one pixel high, width and offset snapped', function()
	local game, tooltips = newRegistry()
	game.env.GetPhysicalScreenSize = function()
		return 2560, 1440
	end
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	tooltip.width = 241
	game:ShowItemTooltip(LINEN)
	local pixel = 768 / 1440
	local rule = tooltip.children[1]
	t.eq(rule.height, pixel, 'one physical pixel')
	local function isWholePixels(value)
		local count = value / pixel
		return math.abs(count - math.floor(count + 0.5)) < 1e-9
	end
	t.truthy(isWholePixels(rule.width) and rule.width <= 221 and rule.width > 221 - pixel, 'width snapped down')
	local point, relativeTo, relativePoint, x, y = rule:GetPoint(1)
	t.eq(point, 'TOPLEFT')
	t.eq(relativeTo, game.env.GameTooltipTextLeft2)
	t.eq(relativePoint, 'TOPLEFT')
	t.eq(x, 0)
	t.truthy(y < 0 and isWholePixels(y), 'a pixel-snapped offset from the line top')
end)

t.test('a later line that widens the tooltip resizes the rules on the next Show', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	tooltip.width = 300
	tooltip:AddLine('A much wider line from another add-on')
	tooltip:Show()
	t.eq(tooltip.children[1].width, 280)
	t.eq(tooltip.children[2].width, 280)
end)

t.test('clearing the tooltip hides the rules; a rebuild reuses them', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	withHagglerBlock(tooltips)
	addOtherLines(game, { 'Other add-on' }, true)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	tooltip:ClearLines()
	t.eq(#tooltip.children, 2)
	t.eq(tooltip.children[1].isShown or tooltip.children[2].isShown, false)
	game:ShowItemTooltip(WOOL)
	t.same(shownRuleLines(game, tooltip), { 2, 5 })
	t.eq(#tooltip.children, 2, 'no new textures')
end)

t.test('no Haggler lines: no separators either', function()
	local game, tooltips = newRegistry()
	addOtherLines(game, { 'Linen Cloth' })
	tooltips:AddProvider('quiet', function()
		return {}
	end)
	local tooltip = game.env.GameTooltip
	game:ShowItemTooltip(LINEN)
	t.same(leftTexts(tooltip), { 'Linen Cloth' })
end)

t.group('wow events')

t.test('several owners can listen to one event; each is removed on its own', function()
	local game = FakeGame.new()
	local reported = {}
	local wow = ns.Wow.create(game.env, {
		onError = function(where, err)
			reported[#reported + 1] = where .. ' ' .. tostring(err)
		end,
	})
	local heard = {}
	wow:OnEvent('BAG_UPDATE', function(_, bag)
		heard[#heard + 1] = 'a' .. bag
	end, 'a')
	wow:OnEvent('BAG_UPDATE', function()
		error('broken')
	end, 'b')
	wow:OnEvent('BAG_UPDATE', function(_, bag)
		heard[#heard + 1] = 'c' .. bag
	end, 'c')
	game:Fire('BAG_UPDATE', 1)
	table.sort(heard)
	t.same(heard, { 'a1', 'c1' })
	t.eq(#reported, 1, 'the broken handler is reported, the others still run')
	wow:OffEvent('BAG_UPDATE', 'a')
	wow:OffEvent('BAG_UPDATE', 'b')
	heard = {}
	game:Fire('BAG_UPDATE', 2)
	t.same(heard, { 'c2' })
	t.eq(game.frame.events.BAG_UPDATE, true)
	wow:OffEvent('BAG_UPDATE', 'c')
	t.eq(game.frame.events.BAG_UPDATE, nil)
end)

t.test('timers, clock and replicate calls go through the env', function()
	local game = FakeGame.new({ listings = { { LINEN, 5, 500, 400 } } })
	local wow = ns.Wow.create(game.env)
	local ran = false
	t.eq(
		wow:After(2, function()
			ran = true
		end),
		true
	)
	game:Advance(2)
	t.eq(ran, true)
	t.eq(wow:CanReplicate(), true)
	t.eq(wow:RequestReplicate(), true)
	t.eq(game.replicateRequests, 1)
	t.eq(wow:NumReplicateItems(), 1)
	t.same({ wow:ReplicateItem(0) }, { LINEN, 5, 500, 400, 4 })
	for raw, band in pairs({
		[1] = 1,
		[3] = 3,
		[0] = 'none',
		[5] = 'none',
		[-1] = 'none',
		[2.5] = 'none',
		['2'] = 'none',
	}) do
		game.listings[1][5] = raw
		t.eq(select(5, wow:ReplicateItem(0)) or 'none', band, 'raw time left ' .. raw)
	end
	t.eq(wow:ReplicateItemLink(0), '|Hitem:2589|h')
	t.eq(type(wow:ClockMs()), 'number')
	local bare = ns.Wow.create({})
	t.eq(bare:After(1, function() end), false)
	t.eq(bare:CanReplicate(), false)
	t.eq(bare:NumReplicateItems(), 0)
	t.eq(select(1, bare:RequestReplicate()), false)
end)

t.group('tooltip module')

local function startWithTable(options)
	local game = FakeGame.new({
		now = NOW,
		itemInfo = { [LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 } },
		hasProcessor = options and options.hasProcessor,
	})
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 7200, rows = AHLEDGER_ROWS })
	return game, FakeGame.startAddon(t, game)
end

t.test('item tooltips get the Buy and Sell sections, no credit; a modifier change redraws', function()
	local game, addon = startWithTable()
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(lines[1].left, CART_ICON)
	t.eq(lines[1].right, PLUG_ICON .. ' 2 h', 'no scan: the listing is the price source figure')
	t.eq(lines[2].left, 'Auction house (each)')
	t.eq(lines[3].left, ' ', 'the separator line between the sections')
	t.eq(lines[4].left, HEADER_ICON)
	t.eq(lines[4].right, PLUG_ICON .. ' 2 h')
	t.eq(lines[5].left, 'Price')
	t.eq(lines[6].left, '', 'then the closing separator, collapsed as the last line')
	t.eq(#lines, 6, 'no credit line')
	game.modifiers.shift = true
	game:Fire('MODIFIER_STATE_CHANGED', 'LSHIFT', 1)
	t.eq(game.env.GameTooltip.refreshed, 1)
	local detailed = game.env.GameTooltip.lines
	t.eq(detailed[5].left, 'Price', 'Shift no longer switches to a unit view')
	t.truthy(#detailed > 6, 'Shift shows the detail block')
	t.same(addon.errors, {})
end)

t.test('the Buy section reads what a vendor charges from VendorPrices, and nothing with vendors off', function()
	local game, addon = startWithTable()
	local asked = {}
	addon.vendorPrices = {
		BuyPrice = function(_, itemId)
			asked[#asked + 1] = itemId
			return { price = 40, stackPrice = 40, stack = 1, source = 'seen' }
		end,
	}
	local lines = game:ShowItemTooltip(LINEN)
	t.same(asked, { LINEN })
	t.eq(lines[2].left, icons:Inline('store', 0, 'color.text.secondary') .. ' Vendor (each)')
	t.eq(lines[2].right, FakeGame.coins('40c'))
	t.eq(lines[3].left, 'Auction house (each)')
	addon.vendorPrices = nil
	t.eq(game:ShowItemTooltip(LINEN)[2].left, 'Auction house (each)', 'no vendor prices, no row')
	t.same(addon.errors, {})
end)

t.test('the host Tooltip class survives every feature loading', function()
	local _, addon = startWithTable()
	t.eq(type(addon.Tooltip.new), 'function', 'ns.Tooltip is still the host class')
	t.eq(addon.Tooltip.SEPARATOR_KIND, 'separator')
	t.eq(addon.Tooltip.vendorError, nil, 'the feature keeps its state on its own table')
	t.truthy(addon.TooltipFeature ~= addon.Tooltip)
end)

t.test('a vendor price lookup that fails drops only the Vendor row', function()
	local game, addon = startWithTable()
	addon.vendorPrices = {
		BuyPrice = function()
			error('vendor store broke')
		end,
	}
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(lines[2].left, 'Auction house (each)')
	t.eq(lines[4].left, HEADER_ICON, 'the Sell section still shows')
	t.truthy(addon.TooltipFeature.vendorError:find('vendor store broke', 1, true), 'the first error is kept')
	addon.vendorPrices.BuyPrice = function()
		error('second failure')
	end
	game:ShowItemTooltip(LINEN)
	t.eq(addon.TooltipFeature.vendorError:find('second failure', 1, true), nil, 'only the first')
	t.same(game.printed, {}, 'never printed')
	t.same(addon.errors, {})
end)

t.test('vendor details follow the detail block: the chosen modifier, Never and Always', function()
	local game, addon = startWithTable()
	addon.vendorPrices = {
		BuyPrice = function()
			return DISCOUNTED_READ
		end,
	}
	local function hasDetails()
		return find(game:ShowItemTooltip(LINEN), 'Sold by') ~= nil
	end
	t.eq(hasDetails(), false, 'no modifier held')
	game.modifiers.shift = true
	game:Fire('MODIFIER_STATE_CHANGED', 'LSHIFT', 1)
	t.truthy(find(game.env.GameTooltip.lines, 'Sold by'), 'Shift, the default modifier, through the redraw')
	t.truthy(find(game.env.GameTooltip.lines, 'Vendor pays'), 'with the detail vendor line beside it')
	addon.host.RunCommand('set tooltip.detailModifier ctrl')
	t.eq(hasDetails(), false, 'Shift is not the chosen modifier now')
	game.modifiers.shift, game.modifiers.ctrl = false, true
	t.eq(hasDetails(), true, 'Ctrl opens them')
	addon.host.RunCommand('set tooltip.detailModifier alt')
	t.eq(hasDetails(), false, 'Ctrl is not the chosen modifier now')
	game.modifiers.ctrl, game.modifiers.alt = false, true
	t.eq(hasDetails(), true, 'Alt opens them')
	game.modifiers.alt = false
	game:Fire('MODIFIER_STATE_CHANGED', 'LALT', 1)
	t.eq(find(game.env.GameTooltip.lines, 'Sold by'), nil, 'letting go of Alt closes them through the redraw')
	game.modifiers.alt = true
	addon.host.RunCommand('set tooltip.detailMode off')
	t.eq(hasDetails(), false, 'Never hides them, modifier or not')
	game.modifiers.alt = false
	addon.host.RunCommand('set tooltip.detailMode always')
	t.eq(hasDetails(), true, 'Always shows them with no modifier, the gamepad path')
	addon.host.RunCommand('set tooltip.detailVendorInfo off')
	t.eq(hasDetails(), false, 'the vendor details setting hides them')
	t.truthy(find(game.env.GameTooltip.lines, 'Vendor pays'), 'Vendor pays follows its own setting')
	t.same(addon.errors, {})
end)

t.test('the tooltip settings: vendor details on by default, no sell time settings', function()
	local _, addon = startWithTable()
	local byKey = {}
	for _, setting in ipairs(addon.host.Module('tooltip').definition.settings) do
		byKey[setting.key] = setting
	end
	t.eq(byKey.detailVendorInfo.label, 'Detail: vendor details')
	t.eq(byKey.detailVendorInfo.default, true)
	t.eq(byKey.detailVendor.label, 'Detail: vendor pays')
	t.eq(byKey.detailSellTime, nil)
	t.eq(byKey.sellTimeNote, nil)
end)

t.test('shown rules come from the store, default first', function()
	local game, addon = startWithTable()
	addon.store.db.shownRules.tooltip = { 'median' }
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(lines[5].left, 'Price', 'the default rule prices the Sell section')
	t.eq(#lines, 6, 'the other rules wait for the detail view')
	addon.host.RunCommand('set tooltip.detailMode always')
	lines = game:ShowItemTooltip(LINEN)
	t.eq(lines[6].left, ' ', 'the detail block opens with its own separator')
	t.eq(lines[7].left, 'Median')
	t.eq(lines[7].right, FakeGame.coins('1s 20c'))
end)

t.test('detail mode and modifier are settings', function()
	local game, addon = startWithTable()
	addon.host.RunCommand('set tooltip.detailMode always')
	t.truthy(#game:ShowItemTooltip(LINEN) > 6)
	addon.host.RunCommand('set tooltip.detailMode modifier')
	addon.host.RunCommand('set tooltip.detailModifier alt')
	game.modifiers.alt = true
	local lines = game:ShowItemTooltip(LINEN)
	t.truthy(#lines > 6)
	t.eq(lines[5].left, 'Price', 'Alt shows the detail, the Sell rows as they were')
	addon.host.RunCommand('set tooltip.detailMode off')
	t.eq(#game:ShowItemTooltip(LINEN), 6)
end)

t.test('items without data get no lines', function()
	local game = startWithTable()
	t.same(game:ShowItemTooltip(SWORD), {})
end)

t.test('switching the module off removes its lines and its event, and back on restores them', function()
	local game, addon = startWithTable()
	addon.host.Disable('tooltip')
	t.same(game:ShowItemTooltip(LINEN), {})
	t.eq(game.frame.events.MODIFIER_STATE_CHANGED, nil)
	addon.host.Enable('tooltip')
	t.eq(#game:ShowItemTooltip(LINEN), 6)
	t.eq(#game.postCalls, 1)
end)

t.test('a modifier change redraws only an item tooltip, and never in combat', function()
	local game = startWithTable()
	game:ShowItemTooltip(LINEN)
	local tooltip = game.env.GameTooltip
	game.inCombat = true
	game:Fire('MODIFIER_STATE_CHANGED', 'LSHIFT', 1)
	t.eq(tooltip.refreshed, nil, 'in combat')
	game.inCombat = false
	tooltip.itemLink = nil
	game:Fire('MODIFIER_STATE_CHANGED', 'LSHIFT', 1)
	t.eq(tooltip.refreshed, nil, 'no item shown')
end)

t.test('a tooltip hook that breaks is reported, never thrown into the client', function()
	local game, addon = startWithTable()
	local brokenData = setmetatable({}, {
		__index = function()
			error('data broke')
		end,
	})
	game.postCalls[1].handler(game.env.GameTooltip, brokenData)
	t.eq(#addon.errors, 1)
	t.truthy(addon.errors[1]:find('data broke', 1, true), addon.errors[1])
end)

t.test('secret values on a tooltip are skipped', function()
	local game, addon = startWithTable()
	game.secretValues = { [LINEN] = true }
	local tooltip = game.env.GameTooltip
	tooltip.lines, tooltip.itemLink = {}, nil
	game.postCalls[1].handler(tooltip, { id = LINEN })
	t.same(tooltip.lines, {})
	t.same(addon.errors, {})
end)

t.group('tooltip: the bag decision')

local GAVEL_PIXELS
do
	local coords, width, height = ns.Icons.texcoords.gavel, ns.Icons.atlasWidth, ns.Icons.atlasHeight
	GAVEL_PIXELS = string.format(
		':%d:%d:%d:%d:',
		math.floor(coords[1] * width + 0.5),
		math.floor(coords[2] * width + 0.5),
		math.floor(coords[3] * height + 0.5),
		math.floor(coords[4] * height + 0.5)
	)
end

local function bagSlot(bag, slot)
	return {
		GetBagID = function()
			return bag
		end,
		GetID = function()
			return slot
		end,
	}
end

t.test('lines: the Signal reads as the badge glyph next to its word, first in the Sell section', function()
	local lines = build({ stackCount = 20, advice = { decision = 'post', code = 'ah' }, icons = icons })
	t.eq(lines[5].left, 'Signal')
	t.eq(lines[5].right, ns.Badges.decisionLabel('post', icons))
	t.truthy(lines[5].right:find(GAVEL_PIXELS, 1, true), lines[5].right)
	t.truthy(lines[5].right:find('Post$'), 'the word stays next to the icon')
	t.eq(lines[6].left, 'Price (each)', 'then the prices')
	t.eq(find(lines, 'Decision'), nil, 'the old label is gone')
	t.eq(find(build({ stackCount = 20 }), 'Signal'), nil, 'no decision, no line')
	t.eq(find(build({ advice = { decision = 'nonsense' }, icons = icons }), 'Signal'), nil)
	t.eq(#build({ stackCount = 20, advice = { decision = 'post', code = 'ah' } }), 7, 'post: no reason line')
end)

local WAIT = {
	decision = 'wait',
	code = 'marketLow',
	underTypicalPercent = 32,
	gainOverVendor = 12345,
}

-- The Sell section's small reason rows, as { label, value } pairs.
local function reasonRows(lines)
	local rows = {}
	for _, line in ipairs(sellLines(lines)) do
		if line.textSize == 'small' then
			rows[#rows + 1] = { line.left, line.right }
		end
	end
	return rows
end

t.test('lines: Signal, Price (each), Price × N, then the wait reason rows last', function()
	local lines = build({ stackCount = 12, advice = WAIT, icons = icons })
	t.same(texts(sellLines(lines)), {
		HEADER_ICON .. ' | ' .. PLUG_ICON .. ' 3 h',
		'Signal | ' .. ns.Badges.decisionLabel('wait', icons),
		'Price (each) | ' .. coins('94c'),
		'Price × 12 | ' .. coins('11s 28c'),
		'Lowest listing | 32% under usual',
		'Market | Steady',
		'Over vendor × 12 | +' .. TooltipLines.money(12345),
	})
	for index = 8, 10 do
		local row = lines[index]
		t.eq(row.wrap, nil, 'a row never wraps')
		t.eq(row.left:find('[.;:·]'), nil, row.left)
		t.eq(row.right:find('[.;:·]$'), nil, row.right)
		t.eq(row.right:find(' - ', 1, true), nil, row.right)
		t.eq(row.left:find('Wait', 1, true), nil, 'the word Wait stays on the Signal line')
	end
	t.truthy(lines[10].right:find(COIN_ICONS.g, 1, true), 'money in coins')
end)

t.test('lines: a low wait keeps its reason rows, then the low-confidence line closes Sell', function()
	local reasons = { { code = 'fewSales', level = 'low', text = 'few sales' } }
	local lowQuote = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'low', reasons) } },
	})
	local sell = texts(sellLines(build({ quote = lowQuote, stackCount = 12, advice = WAIT, icons = icons })))
	t.eq(sell[3], 'Price (each) | ' .. coins('94c') .. ' ' .. LOW_ICON)
	t.eq(sell[5], 'Lowest listing | 32% under usual')
	t.eq(sell[#sell], 'Low confidence, few sales')
end)

t.test('lines: the wait reason rows are dimmer than the other rows, labels and values alike', function()
	local lines = build({ stackCount = 20, advice = WAIT, icons = icons })
	local muted = theme:Color('color.text.muted')
	for index = 8, 10 do
		t.same(lines[index].color, muted, lines[index].left)
		t.same(lines[index].rightColor, muted, lines[index].left)
	end
	t.same(lines[5].color, theme:Color('color.text.secondary'), 'the Signal row keeps its colours')
	t.same(lines[5].rightColor, theme:Color('color.text.primary'))
end)

t.test('lines: the wait reason rows hang off the Sell rows, small and indented a grid step', function()
	local lines = build({ stackCount = 20, advice = WAIT, icons = icons })
	for index = 8, 10 do
		t.eq(lines[index].textSize, 'small', lines[index].left)
		t.eq(lines[index].indent, theme:Number('space.3'), lines[index].left)
	end
	t.eq(theme:Number('space.3'), 16, 'a whole grid step')
	for index = 1, 7 do
		t.eq(lines[index].textSize, nil, texts(lines)[index])
		t.eq(lines[index].indent, nil, texts(lines)[index])
	end
end)

t.test('lines: the Sell header shows the module icon in place of the word', function()
	local lines = build({ stackCount = 20 })
	t.eq(tocIconTexture(), 'Interface\\AddOns\\Haggler\\media\\icon.png', 'the plain module icon')
	t.eq(lines[4].left, HEADER_ICON, 'only the icon, at the line text height')
	t.eq(lines[4].left:find('Haggler', 1, true) ~= nil, true, 'the path names the add-on folder')
	t.eq(lines[4].left:gsub('|T.-|t', ''), '', 'no word left beside it')
	t.eq(lines[4].right, PLUG_ICON .. ' 3 h')
	t.same(lines[4].rightColor, theme:Color('color.text.muted'))
	t.eq(lines[1].left, CART_ICON, 'the Buy header shows the shopping cart')
end)

t.test('lines: the wait gain is the stack gain, a single item without a count', function()
	t.same(reasonRows(build({ stackCount = 20, advice = WAIT, icons = icons }))[3], {
		'Over vendor × 20',
		'+' .. TooltipLines.money(12345),
	})
	local single = build({ stackCount = 1, advice = WAIT, icons = icons })
	t.same(reasonRows(single)[3], { 'Over vendor', '+' .. TooltipLines.money(12345) })
end)

t.test('lines: the wait reason shows in the detail view too, still in the Sell section', function()
	local lines = build({ stackCount = 20, advice = WAIT, icons = icons, isDetail = true })
	t.same(reasonRows(lines)[1], { 'Lowest listing', '32% under usual' })
end)

t.test('lines: a wait missing its facts still names the decision, without a reason', function()
	local lines = build({ stackCount = 20, advice = { decision = 'wait', code = 'marketLow' }, icons = icons })
	t.eq(lines[5].left, 'Signal')
	t.eq(find(lines, 'Lowest listing'), nil)
	t.eq(#lines, 7, 'no reason rows')
end)

t.test('lines: every row is one short line with no tooltip-only facts and no credit', function()
	local credited = quote()
	credited.credit = 'Prices from AHledger (ahledger.com)'
	local lines = build({ quote = credited, stackCount = 12, advice = WAIT, icons = icons })
	t.eq(find(lines, 'AHledger'), nil, 'the credit lives in the options panel and the window footer')
	for _, line in ipairs(lines) do
		if line.kind ~= TooltipLines.SEPARATOR then
			t.eq(line.wrap, nil, line.left)
			local plain = (line.left .. ' ' .. (line.right or '')):gsub('|T.-|t', 'II')
			t.truthy(#plain <= 36, plain)
			t.eq(plain:find('%.$'), nil, plain)
			t.eq(plain:find('[;·]'), nil, plain)
		end
	end
end)

t.test('module: a bag slot tooltip names the decision its badge shows', function()
	local game, addon = startWithTable()
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20 }
	game.env.GameTooltip.owner = bagSlot(0, 3)
	local line = find(game:ShowItemTooltip(LINEN), TooltipLines.SIGNAL_LABEL)
	t.truthy(line and line:find(GAVEL_PIXELS, 1, true), tostring(line))
	t.truthy(line and line:find('Post', 1, true), tostring(line))
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20, isBound = true }
	t.eq(find(game:ShowItemTooltip(LINEN), TooltipLines.SIGNAL_LABEL), nil, 'bound: no decision')
	game.env.GameTooltip.owner = nil
	t.eq(find(game:ShowItemTooltip(LINEN), TooltipLines.SIGNAL_LABEL), nil, 'not in the bags: no decision')
	t.same(addon.errors, {})
end)

t.test('module: a bag slot tooltip says why its item waits', function()
	local game, addon = startWithTable()
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20 }
	game.env.GameTooltip.owner = bagSlot(0, 3)
	local forItem = addon.Advice.forItem
	addon.Advice.forItem = function()
		return WAIT
	end
	local lines = game:ShowItemTooltip(LINEN)
	addon.Advice.forItem = forItem
	t.truthy(find(lines, 'Wait'), 'the decision')
	t.truthy(find(lines, '32% under usual'), 'and why')
	t.same(addon.errors, {})
end)

t.test('module: the wait reason rows reach the tooltip small, indented and muted', function()
	local game, addon = startWithTable()
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20 }
	local tooltip = game.env.GameTooltip
	tooltip.owner = bagSlot(0, 3)
	local forItem = addon.Advice.forItem
	addon.Advice.forItem = function()
		return WAIT
	end
	local lines = game:ShowItemTooltip(LINEN)
	addon.Advice.forItem = forItem
	local muted, secondary = theme:Color('color.text.muted'), theme:Color('color.text.secondary')
	local small, normal = game.env.GameTooltipTextSmall, game.env.GameTooltipText
	local signalIndex
	for index, line in ipairs(lines) do
		if line.left == TooltipLines.SIGNAL_LABEL then
			signalIndex = index
		end
	end
	t.truthy(signalIndex, 'a Signal line')
	t.same(
		{ lines[signalIndex].lr, lines[signalIndex].lg, lines[signalIndex].lb },
		{ secondary.r, secondary.g, secondary.b }
	)
	t.same({ lineFonts(game, tooltip, signalIndex) }, { normal, normal })
	t.same({ lineFonts(game, tooltip, signalIndex + 2) }, { normal, normal }, 'the price rows')
	for index = signalIndex + 3, signalIndex + 5 do
		local line = lines[index]
		t.eq(line.left:sub(1, #SPACER_16), SPACER_16, line.left)
		t.same(
			{ line.lr, line.lg, line.lb, line.rr, line.rg, line.rb },
			{ muted.r, muted.g, muted.b, muted.r, muted.g, muted.b },
			line.left
		)
		t.same({ lineFonts(game, tooltip, index) }, { small, small }, line.left)
		t.same(
			{ lineColors(game, tooltip, index) },
			{ { muted.r, muted.g, muted.b, 1 }, { muted.r, muted.g, muted.b, 1 } },
			'the muted colour reaches the font strings'
		)
	end
	t.same({ lineFonts(game, tooltip, signalIndex + 6) }, { normal, normal }, 'the closing line below')
	t.same(addon.errors, {})
end)
