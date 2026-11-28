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
		ageSeconds = 60,
		source = 'scan',
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
		result[index] = line.right and (line.left .. ' | ' .. line.right) or line.left
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

t.test('compact: the age header, then one line per rule with the stack price', function()
	t.same(texts(build({ stackCount = 20 })), {
		HEADER_ICON .. ' | scan 12 min · table 3 h',
		'Realistic ×20 | ' .. coins('18s 80c'),
		'Median ×20 | ' .. coins('24s'),
	})
end)

t.test('a single item shows no count; the unit view shows the price each', function()
	t.same(texts(build({ stackCount = 1 }))[2], 'Realistic | ' .. coins('94c'))
	t.same(texts(build({ stackCount = 20, isUnitView = true }))[2], 'Realistic (each) | ' .. coins('94c'))
end)

t.test('low confidence is marked on the line itself; medium is not', function()
	local lines = build({
		quote = quote({
			prices = {
				{ ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'low') },
				{ ruleId = 'median', name = 'Median', isDefault = false, price = price(120, 'medium') },
			},
		}),
	})
	t.eq(lines[2].right, coins('94c') .. ' ' .. LOW_ICON, 'the caution triangle, no text mark')
	t.eq(lines[3].left, 'Low confidence', 'the word goes on its own line below')
	t.eq(lines[4].right, coins('1s 20c'), 'medium is not marked')
end)

t.test('with the detail off, the top low reason wraps on its own line under the price', function()
	local reasons = {
		{ code = 'trollBuys', level = 'low', text = '81% of vanished units were troll buys and are left out' },
	}
	local lowQuote = quote({
		prices = { { ruleId = 'minimum', name = 'Minimum', isDefault = true, price = price(24, 'low', reasons) } },
	})
	local lines = build({ quote = lowQuote, stackCount = 2 })
	t.same(texts(lines), {
		HEADER_ICON .. ' | scan 12 min · table 3 h',
		'Minimum ×2 | ' .. coins('48c') .. ' ' .. LOW_ICON,
		'Low confidence, 81% of vanished units were troll buys and are left out',
	})
	t.eq(lines[3].wrap, true, 'wraps at the tooltip width instead of widening it')
	t.same(lines[3].color, theme:Color('color.state.caution'))
end)

t.test('with the detail off, a low line names its top reason inline', function()
	local reasons = {
		{ code = 'stale', level = 'medium', text = 'scan is 3 h old' },
		{ code = 'fewSales', level = 'low', text = 'few sales' },
	}
	local lowQuote = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, price = price(94, 'low', reasons) } },
	})
	t.same({ unpack(texts(build({ quote = lowQuote })), 2, 3) }, {
		'Realistic | ' .. coins('94c') .. ' ' .. LOW_ICON,
		'Low confidence, few sales',
	})
	local detailed = texts(build({ quote = lowQuote, isDetail = true, options = { detailTrace = false } }))
	t.eq(detailed[2], 'Realistic | ' .. coins('94c') .. ' ' .. LOW_ICON)
	t.eq(detailed[3], MEDIUM_ICON .. ' Medium confidence, scan is 3 h old', 'the detail block lists every reason')
end)

t.test('a rule without a price says so', function()
	local lines = build({
		quote = quote({
			prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, reason = 'no data' } },
		}),
	})
	t.eq(lines[2].right, 'no price')
end)

t.test('missing data is named in the header', function()
	local lines = build({ quote = quote({ ages = {} }) })
	t.eq(lines[1].right, 'no scan · no table')
end)

t.test('an item Haggler knows nothing about gets no lines', function()
	local unknown = quote({
		prices = { { ruleId = 'realistic', name = 'Realistic', isDefault = true, reason = 'no data' } },
		facts = { vendor = 50 },
	})
	t.same(build({ quote = unknown, isDetail = true }), {})
end)

t.test('detail: the trace, reasons, sales, listings, vendor and sell time with its note', function()
	local reasons = {
		{ code = 'stale', level = 'medium', text = 'AHledger data is 30 hours old' },
	}
	local trace = {
		{ kind = 'base', label = 'scan first price with 5 units', copper = 99 },
		{ kind = 'skip', label = 'cap skipped: no median' },
		{ kind = 'step', label = 'undercut by 1c', copper = 98 },
		{ kind = 'snap', label = 'price step 1c', copper = 98 },
		{ kind = 'confidence', label = 'medium confidence: AHledger data is 30 hours old' },
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
		HEADER_ICON .. ' | scan 12 min · table 3 h',
		'Realistic ×20 | ' .. coins('19s 60c'),
		'Median ×20 | ' .. coins('24s') .. ' ' .. LOW_ICON,
		'Realistic, each:',
		'  scan first price with 5 units | ' .. coins('99c'),
		'  cap skipped: no median',
		'  undercut by 1c | ' .. coins('98c'),
		'  price step 1c | ' .. coins('98c'),
		MEDIUM_ICON .. ' Medium confidence, AHledger data is 30 hours old',
		LOW_ICON .. ' Median: low confidence, under 1 sale a day',
		'Sold a day | 45',
		'Listed | 60 units · 2 prices',
		'Vendor | ' .. coins('2s 60c'),
		'Sell time | ~21 h', -- (20 listed under 98c + 20) / 45 a day
		'  ' .. TooltipLines.SELL_TIME_NOTE,
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
		detailSellTime = false,
	}
	t.same(texts(build({ quote = lowQuote, isDetail = true, options = options })), {
		HEADER_ICON .. ' | scan 12 min · table 3 h',
		'Realistic | ' .. coins('94c') .. ' ' .. LOW_ICON,
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
	for _, text in ipairs({ 'old data', 'no price, too few sales', 'under 1 sale a day', TooltipLines.SELL_TIME_NOTE }) do
		local isFound = false
		for _, line in ipairs(lines) do
			if line.left:find(text, 1, true) then
				isFound = true
				t.eq(line.wrap, true, text)
				t.eq(line.right, nil, text)
			end
		end
		t.truthy(isFound, text)
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
	t.eq(find(lines, 'Sold a day'), 'Sold a day | 12.5 · own scans')
end)

t.test('the sell-time note can be switched off', function()
	local lines = build({ isDetail = true, options = { sellTimeNote = false } })
	t.truthy(find(lines, 'Sell time'))
	t.eq(find(lines, TooltipLines.SELL_TIME_NOTE), nil)
end)

t.test('without sales data the sell time is unknown and has no note', function()
	local lines = build({
		isDetail = true,
		quote = quote({ facts = { listedUnits = 3, levelCount = 1, levels = { { price = 90, qty = 3 } } } }),
	})
	t.eq(find(lines, 'Sell time'), 'Sell time | unknown, no sales data')
	t.eq(find(lines, 'Sold a day'), 'Sold a day | unknown')
	t.eq(find(lines, TooltipLines.SELL_TIME_NOTE), nil)
	t.eq(find(lines, 'Vendor'), nil)
end)

t.test('sell time counts the units at or under the price plus the stack', function()
	local facts =
		{ salesPerDay = 10, levels = { { price = 90, qty = 20 }, { price = 94, qty = 5 }, { price = 99, qty = 40 } } }
	t.eq((TooltipLines.sellTimeDays(facts, 94, 5)), 3)
	t.eq((TooltipLines.sellTimeDays(facts, 89, 5)), 0.5)
	local days, isLow = TooltipLines.sellTimeDays({ salesPerDay = 0.5, levels = {} }, 94, 1)
	t.eq(days, 2)
	t.eq(isLow, true, 'under one sale a day')
	t.eq(select(2, TooltipLines.sellTimeDays(facts, 94, 5)), false)
	t.eq(TooltipLines.sellTimeDays({ salesPerDay = 0 }, 94, 1), nil)
	t.eq(TooltipLines.sellTimeDays({ levels = { 'junk', { price = '1', qty = 2 } }, salesPerDay = 1 }, 94, 1), 1)
end)

t.test('a slow sell time is marked low, with the reason wrapped below', function()
	local lines = build({ isDetail = true, quote = quote({ facts = { salesPerDay = 0.2, levels = {} } }) })
	local texted = texts(lines)
	for index, text in ipairs(texted) do
		if text:find('Sell time', 1, true) then
			t.eq(text, 'Sell time | ~5.0 days ' .. LOW_ICON)
			t.eq(texted[index + 1], 'Low confidence, under 1 sale a day')
		end
	end
	t.truthy(find(lines, 'Sell time'))
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

t.test('item tooltips get the header and the default rule; a modifier change redraws', function()
	local game, addon = startWithTable()
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(lines[1].left, HEADER_ICON)
	t.eq(lines[1].right, 'no scan · table 2 h')
	t.eq(lines[2].left, 'Realistic')
	t.eq(lines[3].left, 'Prices from AHledger (ahledger.com)', 'the credit closes the block')
	t.eq(lines[4].left, '', 'then the closing separator, collapsed as the last line')
	t.eq(#lines, 4)
	game.modifiers.shift = true
	game:Fire('MODIFIER_STATE_CHANGED', 'LSHIFT', 1)
	t.eq(game.env.GameTooltip.refreshed, 1)
	local detailed = game.env.GameTooltip.lines
	t.eq(detailed[2].left, 'Realistic (each)')
	t.truthy(#detailed > 4, 'Shift shows the detail block too')
	t.same(addon.errors, {})
end)

t.test('shown rules come from the store, default first', function()
	local game, addon = startWithTable()
	addon.store.db.shownRules.tooltip = { 'median' }
	local lines = game:ShowItemTooltip(LINEN)
	t.eq(lines[2].left, 'Realistic')
	t.eq(lines[3].left, 'Median')
	t.eq(lines[3].right, FakeGame.coins('1s 20c'))
end)

t.test('detail mode and modifier are settings', function()
	local game, addon = startWithTable()
	addon.host.RunCommand('set tooltip.detailMode always')
	t.truthy(#game:ShowItemTooltip(LINEN) > 4)
	addon.host.RunCommand('set tooltip.detailMode modifier')
	addon.host.RunCommand('set tooltip.detailModifier alt')
	game.modifiers.alt = true
	local lines = game:ShowItemTooltip(LINEN)
	t.truthy(#lines > 4)
	t.eq(lines[2].left, 'Realistic', 'Alt shows the detail but not the unit view')
	addon.host.RunCommand('set tooltip.detailMode off')
	t.eq(#game:ShowItemTooltip(LINEN), 4)
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
	t.eq(#game:ShowItemTooltip(LINEN), 4)
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

t.test('lines: the decision reads as the badge glyph next to its word, after the prices', function()
	local lines = build({ stackCount = 20, advice = { decision = 'post', code = 'ah' }, icons = icons })
	t.eq(lines[4].left, TooltipLines.DECISION_LABEL)
	t.eq(lines[4].right, ns.Badges.decisionLabel('post', icons))
	t.truthy(lines[4].right:find(GAVEL_PIXELS, 1, true), lines[4].right)
	t.truthy(lines[4].right:find('Post$'), 'the word stays next to the icon')
	t.eq(find(build({ stackCount = 20 }), TooltipLines.DECISION_LABEL), nil, 'no decision, no line')
	t.eq(find(build({ advice = { decision = 'nonsense' }, icons = icons }), TooltipLines.DECISION_LABEL), nil)
	t.eq(#build({ stackCount = 20, advice = { decision = 'post', code = 'ah' } }), 4, 'post: no reason line')
end)

local WAIT = {
	decision = 'wait',
	code = 'marketLow',
	underTypicalPercent = 32,
	gainOverVendor = 12345,
	gainOverVendorEach = 617,
}

-- The reason rows under the Decision line, as { label, value } pairs.
local function reasonRows(lines)
	local rows = {}
	for index = 5, #lines do
		local line = lines[index]
		if line.right == nil then
			break
		end
		rows[#rows + 1] = { line.left, line.right }
	end
	return rows
end

t.test('lines: a wait says why in label and value rows right under the decision', function()
	local lines = build({ stackCount = 20, advice = WAIT, icons = icons })
	t.eq(lines[4].left, TooltipLines.DECISION_LABEL)
	t.eq(lines[4].right, ns.Badges.decisionLabel('wait', icons))
	t.same(reasonRows(lines), {
		{ 'Lowest listing', '32% under usual' },
		{ 'Market', 'Steady' },
		{ 'Over vendor ×20', '+' .. TooltipLines.money(12345) },
	})
	for index = 5, 7 do
		local row = lines[index]
		t.eq(row.wrap, nil, 'a row never wraps')
		t.eq(row.left:find('[.;:·]'), nil, row.left)
		t.eq(row.right:find('[.;:·]$'), nil, row.right)
		t.eq(row.right:find(' - ', 1, true), nil, row.right)
		t.eq(row.left:find('Wait', 1, true), nil, 'the word Wait stays on the Decision line')
	end
	t.truthy(lines[7].right:find(COIN_ICONS.g, 1, true), 'money in coins')
end)

t.test('lines: the wait reason rows are dimmer than the other rows, labels and values alike', function()
	local lines = build({ stackCount = 20, advice = WAIT, icons = icons })
	local muted = theme:Color('color.text.muted')
	for index = 5, 7 do
		t.same(lines[index].color, muted, lines[index].left)
		t.same(lines[index].rightColor, muted, lines[index].left)
	end
	t.same(lines[4].color, theme:Color('color.text.secondary'), 'the Decision row keeps its colours')
	t.same(lines[4].rightColor, theme:Color('color.text.primary'))
end)

t.test('lines: the wait reason rows hang off the decision, small and indented a grid step', function()
	local lines = build({ stackCount = 20, advice = WAIT, icons = icons })
	for index = 5, 7 do
		t.eq(lines[index].textSize, 'small', lines[index].left)
		t.eq(lines[index].indent, theme:Number('space.3'), lines[index].left)
	end
	t.eq(theme:Number('space.3'), 16, 'a whole grid step')
	for index = 1, 4 do
		t.eq(lines[index].textSize, nil, lines[index].left)
		t.eq(lines[index].indent, nil, lines[index].left)
	end
end)

t.test('lines: the header shows the module icon in place of the word, its right column as before', function()
	local lines = build({ stackCount = 20 })
	t.eq(tocIconTexture(), 'Interface\\AddOns\\Haggler\\media\\icon.png', 'the plain module icon')
	t.eq(lines[1].left, HEADER_ICON, 'only the icon, at the line text height')
	t.eq(lines[1].left:find('Haggler', 1, true) ~= nil, true, 'the path names the add-on folder')
	t.eq(lines[1].left:gsub('|T.-|t', ''), '', 'no word left beside it')
	t.eq(lines[1].right, 'scan 12 min · table 3 h')
	t.same(lines[1].rightColor, theme:Color('color.text.muted'))
end)

t.test('lines: the wait gain follows the view, a unit in the unit view as the prices do', function()
	local each = build({ stackCount = 20, advice = WAIT, icons = icons, isUnitView = true })
	t.same(reasonRows(each)[3], { 'Over vendor' .. TooltipLines.EACH_SUFFIX, '+' .. TooltipLines.money(617) })
	local single = build({ stackCount = 1, advice = WAIT, icons = icons })
	t.same(reasonRows(single)[3], { 'Over vendor', '+' .. TooltipLines.money(12345) })
end)

t.test('lines: a unit gain under a copper shows the stack gain, labelled as the stack', function()
	local small = {
		decision = 'wait',
		code = 'marketLow',
		underTypicalPercent = 32,
		gainOverVendor = 15,
		gainOverVendorEach = 0,
	}
	local rows = reasonRows(build({ stackCount = 20, advice = small, icons = icons, isUnitView = true }))
	t.same(rows[3], { 'Over vendor ×20', '+' .. TooltipLines.money(15) })
	t.eq(rows[3][1]:find(TooltipLines.EACH_SUFFIX, 1, true), nil, 'a stack gain never says each')
end)

t.test('lines: the wait reason shows in the detail view too', function()
	local lines = build({ stackCount = 20, advice = WAIT, icons = icons, isDetail = true })
	t.same(reasonRows(lines)[1], { 'Lowest listing', '32% under usual' })
end)

t.test('lines: a wait missing its facts still names the decision, without a reason', function()
	local lines = build({ stackCount = 20, advice = { decision = 'wait', code = 'marketLow' }, icons = icons })
	t.eq(lines[4].left, TooltipLines.DECISION_LABEL)
	t.eq(find(lines, 'Lowest listing'), nil)
	t.eq(#lines, 4, 'no reason rows')
end)

t.test('module: a bag slot tooltip names the decision its badge shows', function()
	local game, addon = startWithTable()
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20 }
	game.env.GameTooltip.owner = bagSlot(0, 3)
	local line = find(game:ShowItemTooltip(LINEN), TooltipLines.DECISION_LABEL)
	t.truthy(line and line:find(GAVEL_PIXELS, 1, true), tostring(line))
	t.truthy(line and line:find('Post', 1, true), tostring(line))
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20, isBound = true }
	t.eq(find(game:ShowItemTooltip(LINEN), TooltipLines.DECISION_LABEL), nil, 'bound: no decision')
	game.env.GameTooltip.owner = nil
	t.eq(find(game:ShowItemTooltip(LINEN), TooltipLines.DECISION_LABEL), nil, 'not in the bags: no decision')
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
	local decisionIndex
	for index, line in ipairs(lines) do
		if line.left == TooltipLines.DECISION_LABEL then
			decisionIndex = index
		end
	end
	t.truthy(decisionIndex, 'a Decision line')
	t.same(
		{ lines[decisionIndex].lr, lines[decisionIndex].lg, lines[decisionIndex].lb },
		{ secondary.r, secondary.g, secondary.b }
	)
	t.same({ lineFonts(game, tooltip, decisionIndex) }, { normal, normal })
	t.same({ lineFonts(game, tooltip, decisionIndex - 1) }, { normal, normal }, 'the price row above')
	for index = decisionIndex + 1, decisionIndex + 3 do
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
	t.same({ lineFonts(game, tooltip, decisionIndex + 4) }, { normal, normal }, 'the credit below')
	t.same(addon.errors, {})
end)
