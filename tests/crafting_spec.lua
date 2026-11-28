local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, BOLT = 2589, 2996
local RECIPE_ID = 3275
local SHIRT, SHIRT_RECIPE_ID = 1000, 3900
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
local AHLEDGER_ROWS = {
	[2589] = { 120, 95, 500, 118, 125, 90, 160, 45 },
	[2996] = { 400, 380, 50, 400, 410, 300, 500, 10 },
}

local function professionFrame(game)
	local env = game.env
	local frame = FakeGame.newWidget('Frame', env.UIParent)
	local form = FakeGame.newWidget('Frame', frame)
	function form.Init() end
	local scrollBox = FakeGame.newWidget('Frame', frame)
	frame.CraftingPage = { SchematicForm = form, RecipeList = { ScrollBox = scrollBox } }
	env.ProfessionsFrame = frame
	env.ScrollUtil = {
		AddInitializedFrameCallback = function(_, callback)
			game.rowCallback = callback
		end,
	}
	return frame, form, scrollBox
end

local function start()
	local game = FakeGame.new({
		now = NOW,
		itemInfo = {
			[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
			[BOLT] = { name = 'Bolt of Linen Cloth', maxStack = 20, vendorPrice = 40 },
		},
	})
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = AHLEDGER_ROWS })
	game.env.GetRealmName = function()
		return 'Realm'
	end
	game.env.UnitName = function()
		return 'Me'
	end
	game.schematics[RECIPE_ID] = {
		outputItemID = BOLT,
		quantityMin = 1,
		reagentSlotSchematics = { { reagentType = 1, quantityRequired = 2, reagents = { { itemID = LINEN } } } },
	}
	game.schematics[SHIRT_RECIPE_ID] = {
		outputItemID = SHIRT,
		quantityMin = 1,
		reagentSlotSchematics = { { reagentType = 1, quantityRequired = 2, reagents = { { itemID = BOLT } } } },
	}
	local frame, form, scrollBox = professionFrame(game)
	local addon = FakeGame.startAddon(t, game)
	game:Fire('TRADE_SKILL_SHOW')
	return game, addon, { frame = frame, form = form, scrollBox = scrollBox }
end

local function linesText(lines)
	local texts = {}
	for _, line in ipairs(lines.strings) do
		texts[#texts + 1] = line:GetText() or ''
	end
	return table.concat(texts, '\n')
end

local function recipeNode(recipeId)
	return {
		GetData = function()
			return { recipeInfo = recipeId and { recipeID = recipeId } or nil }
		end,
	}
end

local function rowText(row)
	for _, child in ipairs(row.children) do
		if child.kind == 'FontString' then
			return child
		end
	end
	return nil
end

local function withoutColor(text)
	return (text:gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''))
end

-- The feature files only load with a started add-on.
local _, ns = start()

t.group('crafting view')

t.test('a row shows profit and margin; low confidence gets a mark and its level', function()
	local text, level = ns.CraftingView.rowText({
		profit = 120,
		margin = 0.3,
		confidence = { level = 'high', reasons = {} },
	})
	t.eq(text, ns.theme:Wrap('money.gainStrong', FakeGame.coins('+1s 20c · 30%')))
	t.eq(level, nil)
	text, level = ns.CraftingView.rowText({ profit = -5, confidence = { level = 'low', reasons = {} } })
	t.eq(text, '? ' .. FakeGame.coins('-5c'))
	t.eq(level, 'low')
	t.eq(ns.CraftingView.rowText(nil), '')
end)

t.test('detail parts switch off, but low confidence and its reasons always show', function()
	local craft = {
		cost = 100,
		value = 0,
		profit = -100,
		made = 1,
		knownShare = 0.5,
		knownCopper = 50,
		estimatedCopper = 50,
		confidence = { level = 'low', reasons = { { code = 'noPrice', text = 'no price for the output' } } },
	}
	local all = ns.CraftingView.detailLines(craft, { figures = true, share = true })
	t.eq(all[1].text, FakeGame.coins('Cost 1s'))
	t.eq(all[3].level, 'low', 'a loss is flagged')
	t.truthy(all[4].text:find('Known 50%%'))
	local none = ns.CraftingView.detailLines(craft, { figures = false, share = false })
	t.eq(#none, 2)
	t.eq(none[1].text, 'Confidence low')
	t.truthy(none[2].text:find('no price for the output'))
	craft.usesPriceSource = true
	local credited = ns.CraftingView.detailLines(craft, { credit = 'Prices from AHledger' })
	t.eq(credited[1].text, 'Prices from AHledger', 'an AHledger figure is credited, ahead of the confidence')
	t.eq(#credited, 3)
	craft.usesPriceSource = false
	credited = ns.CraftingView.detailLines(craft, { credit = 'Prices from AHledger' })
	t.eq(credited[1].text:find('AHledger'), nil)
	t.eq(#credited, 2)
end)

t.v2test('the ventures tab shows a low forecast confidence and its reasons', function()
	local venture = {
		name = 'V',
		status = 'planning',
		valuation = 'opportunity',
		lines = {},
		materials = {},
		totals = { depositPaid = 0 },
	}
	local profit = ns.Ventures.profit
	ns.Ventures.profit = function()
		return { net = 0, cash = 0, overMaterials = 0, materialsCost = 0, knownCopper = 0, estimatedCopper = 0 }
	end
	local lines = ns.VenturesTab.detailLines(venture, {
		income = 0,
		cost = 0,
		profit = 0,
		days = 1,
		note = '',
		isComplete = false,
		confidence = { level = 'low', reasons = { { level = 'low', text = 'no price for Bolt' } } },
	}, tostring)
	ns.Ventures.profit = profit
	local text = {}
	for _, line in ipairs(lines) do
		text[#text + 1] = line.text
	end
	text = table.concat(text, '\n')
	t.truthy(text:find('Forecast confidence low'))
	t.truthy(text:find('no price for Bolt'))
end)

t.test('a schematic becomes a venture recipe', function()
	local recipe = ns.CraftingView.ventureRecipe({
		recipeId = 1,
		outputItemId = 2,
		quantity = 3,
		reagents = { { itemId = 4, qty = 5 } },
	})
	t.same(recipe, { recipeId = 1, itemId = 2, perCraft = 3, reagents = { { itemId = 4, qty = 5 } } })
	t.eq(ns.CraftingView.ventureRecipe({ recipeId = 1 }), nil, 'no output, no venture')
end)

t.group('crafting margin bands')

local function craftWithMargin(margin)
	return { cost = 1000, value = 2000, profit = 1000, made = 1, margin = margin, confidence = { level = 'high' } }
end

t.test('each band edge takes the band above it; under -25% is a loss', function()
	local cases = {
		{ -0.5, 'money.loss' },
		{ -0.26, 'money.loss' },
		{ -0.25, 'color.state.caution' },
		{ -0.11, 'color.state.caution' },
		{ -0.10, 'money.lossTint' },
		{ -0.01, 'money.lossTint' },
		{ 0, 'money.gainTint' },
		{ 0.09, 'money.gainTint' },
		{ 0.10, 'money.gain' },
		{ 0.24, 'money.gain' },
		{ 0.25, 'money.gainStrong' },
		{ 3, 'money.gainStrong' },
	}
	for _, case in ipairs(cases) do
		t.eq(ns.CraftingView.marginToken(case[1]), case[2], 'margin ' .. case[1])
	end
end)

t.test('the band follows the unrounded margin; a loss never takes a gain band', function()
	t.eq(ns.CraftingView.marginToken(-0.004), 'money.lossTint', 'a loss shown as 0%')
	t.eq(ns.CraftingView.marginToken(-0.2504), 'money.loss', 'past -25%, shown as -25%')
	t.eq(ns.CraftingView.marginToken(0.0996), 'money.gainTint', 'short of 10%, shown as 10%')
	t.eq(ns.CraftingView.marginToken(-0.0001), 'money.lossTint')
	t.eq(select(1, ns.CraftingView.rowText(craftWithMargin(-0.10))):find('-10%', 1, true) ~= nil, true)
end)

t.test('a recipe with no margin stays uncoloured', function()
	t.eq(ns.CraftingView.marginToken(nil), nil)
	local text = ns.CraftingView.rowText({ profit = 0, confidence = { level = 'high' } })
	t.eq(text, FakeGame.coins('+0c'))
	local lines = ns.CraftingView.detailLines({ cost = 100, value = 0, profit = -100, made = 1 }, { figures = true })
	t.eq(lines[1].text, FakeGame.coins('Cost 1s'))
	t.eq(lines[2].text, FakeGame.coins('Value 0c after the cut and deposit risk'))
	t.eq(lines[3].text, FakeGame.coins('Profit -1s'))
	t.eq(lines[3].level, 'low', 'a loss with no margin still reads as low')
end)

t.test('every price of a banded recipe takes its colour, in the row and the detail', function()
	local wrap = function(text)
		return ns.theme:Wrap('color.state.caution', text)
	end
	local craft = { cost = 1200, value = 1000, profit = -200, made = 2, margin = -0.2, confidence = { level = 'high' } }
	t.eq(ns.CraftingView.rowText(craft), wrap(FakeGame.coins('-2s') .. ' · -20%'))
	local lines = ns.CraftingView.detailLines(craft, { figures = true })
	t.eq(lines[1].text, 'Cost ' .. wrap(FakeGame.coins('12s')) .. ' for 2')
	t.eq(lines[2].text, 'Value ' .. wrap(FakeGame.coins('10s')) .. ' after the cut and deposit risk')
	t.eq(lines[3].text, 'Profit ' .. wrap(FakeGame.coins('-2s')) .. ' · margin ' .. wrap('-20%'))
	t.eq(lines[3].level, nil, 'the band colour replaces the low level')
end)

t.test('a loss is red and a low-confidence mark stays outside the colour', function()
	local craft = { cost = 1000, value = 500, profit = -500, made = 1, margin = -1, confidence = { level = 'low' } }
	t.eq(ns.CraftingView.rowText(craft), '? ' .. ns.theme:Wrap('money.loss', FakeGame.coins('-5s') .. ' · -100%'))
end)

t.test('every theme defines the margin colours', function()
	for key in pairs(ns.Tokens.themes) do
		local theme = ns.Theme.new(ns.Tokens, key)
		for _, band in ipairs(ns.CraftingView.MARGIN_BANDS) do
			t.truthy(theme:Color(band.token) ~= ns.Theme.FALLBACK_COLOR, key .. ' ' .. band.token)
		end
	end
end)

t.group('crafting nested reagents')

local BOLT_SCHEMATIC = { recipeId = 200, outputItemId = BOLT, quantity = 1, reagents = { { itemId = LINEN, qty = 2 } } }
local SHIRT_SCHEMATIC =
	{ recipeId = 300, outputItemId = SHIRT, quantity = 1, reagents = { { itemId = BOLT, qty = 2 } } }

local function nestedView(knownRecipes)
	local schematics = { [200] = BOLT_SCHEMATIC, [300] = SHIRT_SCHEMATIC }
	local buy = { [LINEN] = { copper = 10 }, [BOLT] = { copper = 50 } }
	return ns.CraftingView.new({
		schematic = function(recipeId)
			return schematics[recipeId]
		end,
		held = function()
			return 0
		end,
		prices = {
			Context = function()
				return {}
			end,
			Get = function(_, itemId)
				return buy[itemId]
			end,
		},
		knownRecipes = knownRecipes,
	})
end

t.test('the craft window crafts a known reagent; a view without known recipes buys it', function()
	local known = nestedView(function()
		return { 200, 300 }
	end)
	t.eq(known:Craft(300).reagents[1].source, 'crafted')
	t.eq(known:Craft(300).cost, 40)
	t.eq(nestedView(false):Craft(300).reagents[1].source, 'buy', 'the venture forecast opts out')
end)

t.test("known recipes are the open profession's learned ones", function()
	local game, addon = start()
	t.same(addon.wow:KnownRecipeIds(), { RECIPE_ID, SHIRT_RECIPE_ID })
	game.unlearned = { [RECIPE_ID] = true }
	t.same(addon.wow:KnownRecipeIds(), { SHIRT_RECIPE_ID })
	game.env.C_TradeSkillUI.GetAllRecipeIDs = nil
	t.same(addon.wow:KnownRecipeIds(), {}, 'a client without the API')
end)

t.test('the crafted reagents share one detail line', function()
	local craft = {
		cost = 40,
		value = 300,
		profit = 260,
		made = 1,
		margin = 260 / 300,
		confidence = { level = 'high' },
		reagents = {
			{ itemId = BOLT, qty = 2, held = 0, source = 'crafted', craftedUnits = 2 },
			{ itemId = LINEN, qty = 1, held = 0, source = 'buy' },
			{ itemId = 77, qty = 1, held = 0, source = 'crafted', craftedUnits = 1 },
		},
	}
	local lines = ns.CraftingView.detailLines(craft, { figures = true })
	t.eq(lines[4].text, 'Crafted: Bolt of Linen Cloth × 2, item 77 × 1')
	t.eq(#lines, 4, 'a bought reagent is not named')
	t.eq(#ns.CraftingView.detailLines(craft, { figures = false }), 0, 'the line is part of the figures')
end)

t.test('a full panel with crafted reagents still credits AHledger', function()
	local reasons = {}
	for index = 1, 3 do
		reasons[index] = { code = 'r' .. index, text = 'reason ' .. index }
	end
	local craft = {
		cost = 40,
		value = 300,
		profit = 260,
		made = 1,
		margin = 260 / 300,
		knownShare = 0.5,
		knownCopper = 20,
		estimatedCopper = 20,
		usesPriceSource = true,
		confidence = { level = 'low', reasons = reasons },
		reagents = {
			{ itemId = BOLT, qty = 2, held = 0, source = 'crafted', craftedUnits = 2 },
			{ itemId = 77, qty = 1, held = 0, source = 'crafted', craftedUnits = 1 },
		},
	}
	local lines = ns.CraftingView.detailLines(craft, { figures = true, share = true, credit = 'Prices from AHledger' })
	local PANEL_LINES = 9
	local shown = {}
	for index = 1, PANEL_LINES do
		shown[#shown + 1] = lines[index] and lines[index].text or ''
	end
	t.truthy(table.concat(shown, '\n'):find('Prices from AHledger', 1, true), 'the credit fits the 9-line panel')
end)

t.group('crafting on the profession frame')

t.test('recipe rows get profit text; headers and the setting hide it', function()
	local game, addon, parts = start()
	t.truthy(game.rowCallback, 'the recipe list callback is registered')
	local row = FakeGame.newWidget('Button', parts.scrollBox)
	game.rowCallback(nil, row, recipeNode(RECIPE_ID))
	local text = rowText(row)
	t.truthy(text and text:IsShown())
	t.truthy(withoutColor(text:GetText()):find('^[%+%-?]'))
	game.rowCallback(nil, row, recipeNode(nil))
	t.eq(text:IsShown(), false, 'a recycled row that became a header')
	addon.host.Module('crafting'):SetSetting('showList', false)
	game.rowCallback(nil, row, recipeNode(RECIPE_ID))
	t.eq(text:IsShown(), false)
	t.same(addon.errors, {})
end)

t.test('the selected recipe gets a panel; Plan venture starts one and opens the tab', function()
	local game, addon, parts = start()
	parts.form:Init({ recipeID = RECIPE_ID })
	local panel
	for _, frame in ipairs(game.createdFrames) do
		if frame.parent == parts.frame and frame.lines then
			panel = frame
		end
	end
	t.truthy(panel and panel:IsShown())
	t.truthy(linesText(panel.lines):find('Cost'))
	parts.form:Init({ recipeID = SHIRT_RECIPE_ID })
	t.truthy(linesText(panel.lines):find('Crafted: Bolt of Linen Cloth × 2', 1, true), 'a bolt is cheaper to craft')
	parts.form:Init({ recipeID = RECIPE_ID })
	t.truthy(linesText(panel.lines):find(addon.window:Credit(), 1, true), 'the panel credits AHledger')
	if t.isV1Only then
		t.eq(panel.plan, nil, 'no Plan venture button without the V2 planner')
		t.same(addon.errors, {})
		return
	end
	panel.plan:Click()
	local market = addon.store:Market(MARKET)
	local venture = addon.Ventures.get(market, 1)
	t.eq(venture.name, 'Bolt of Linen Cloth')
	t.eq(venture.lines[1].plannedCrafts, 1)
	t.eq(venture.materials[LINEN].need, 2)
	t.truthy(addon.window:IsOpen())
	local ventures = addon.window.containers.ventures
	t.truthy(linesText(ventures.lines):find('Bolt of Linen Cloth'))
	t.truthy(addon.window.creditText:IsShown(), 'the forecast credits AHledger')
	ventures.crafts.forward:Click()
	t.eq(venture.lines[1].plannedCrafts, 2, 'the tab plans more')
	ventures.writeOff:Click()
	t.eq(venture.status, 'closed')
	t.eq(venture.closeReason, 'manual')
	t.truthy(linesText(ventures.lines):find('closed by hand'))
	t.same(addon.errors, {})
end)

-- Screen edges for a fake frame: the client reports them once the frame is laid out.
local function placeAt(widget, left, right, top, bottom)
	widget.left, widget.right, widget.top, widget.bottom = left, right, top, bottom
	return widget
end

local function craftingPanel(game, hostFrame)
	for _, frame in ipairs(game.createdFrames) do
		if frame.parent == hostFrame and frame.lines then
			return frame
		end
	end
	return nil
end

-- A profession frame laid out on a 1600-wide screen, its recipe selected; tabs(frame) adds the side column.
local function panelBeside(frameLeft, frameRight, tabs)
	local game, addon, parts = start()
	placeAt(game.env.UIParent, 0, 1600, 900, 0)
	placeAt(parts.frame, frameLeft, frameRight, 800, 200)
	if tabs then
		tabs(parts.frame)
	end
	parts.form:Init({ recipeID = RECIPE_ID })
	return craftingPanel(game, parts.frame), parts.frame, addon, game
end

-- A point with its relative frame named, so a mismatch never deep-compares two frames.
local function pointOf(region, relativeName, relativeFrame)
	local point, relativeTo, relativePoint, x, y = region:GetPoint(1)
	return { point, relativeTo == relativeFrame and relativeName or tostring(relativeTo), relativePoint, x, y }
end

local function sideTab(parent, left, right, top)
	return placeAt(FakeGame.newWidget('CheckButton', parent), left, right, top, top - 44)
end

t.test('the panel sits right of the side tab column, measured from the frames', function()
	local panel, frame, addon = panelBeside(400, 1000, function(hostFrame)
		sideTab(hostFrame, 997, 1040, 760)
		sideTab(hostFrame, 997, 1040, 710)
		-- The gamepad hint under the tabs, a region of a holder that spans the whole frame.
		local holder = placeAt(FakeGame.newWidget('Frame', hostFrame), 400, 1000, 800, 200)
		placeAt(holder:CreateTexture(nil, 'ARTWORK'), 1000, 1044, 660, 640)
	end)
	t.truthy(panel and panel:IsShown())
	t.same(
		pointOf(panel, 'frame', frame),
		{ 'TOPLEFT', 'frame', 'TOPRIGHT', 52, 0 },
		'tabs end at 1044, then the 8 gap'
	)
	t.eq(#panel.points, 1)
	t.eq(panel.isClampedToScreen, true)
	t.same(addon.errors, {})
end)

t.test('without side tabs the panel sits at the frame edge; hidden tabs and wide panels do not count', function()
	local panel, frame = panelBeside(400, 1000, function(hostFrame)
		sideTab(hostFrame, 997, 1040, 760):Hide()
		placeAt(FakeGame.newWidget('Frame', hostFrame), 1004, 1304, 800, 200)
		placeAt(FakeGame.newWidget('Frame', hostFrame), 1004, 1040, 1200, 1000)
	end)
	t.same(pointOf(panel, 'frame', frame), { 'TOPLEFT', 'frame', 'TOPRIGHT', 8, 0 })
end)

t.test('with no room on the right the panel flips left of the frame', function()
	local panel, frame = panelBeside(800, 1400, function(hostFrame)
		sideTab(hostFrame, 1397, 1440, 760)
	end)
	t.same(pointOf(panel, 'frame', frame), { 'TOPRIGHT', 'frame', 'TOPLEFT', -8, 0 })
end)

t.test('with no room on either side the panel stays right of the tabs, clamped to the screen', function()
	local panel, frame = panelBeside(100, 1500)
	t.same(pointOf(panel, 'frame', frame), { 'TOPLEFT', 'frame', 'TOPRIGHT', 8, 0 })
	t.eq(panel.isClampedToScreen, true)
end)

t.test('a scaled profession frame measures in screen pixels', function()
	local panel, frame = panelBeside(400, 1000, function(hostFrame)
		hostFrame.scale = 0.5
		sideTab(hostFrame, 997, 1040, 760).scale = 0.5
	end)
	-- 40 frame units past the edge, at half scale on a screen at scale 1: offsets stay in frame units.
	t.same(pointOf(panel, 'frame', frame), { 'TOPLEFT', 'frame', 'TOPRIGHT', 48, 0 })
end)

t.test('tabs that show or appear after the first paint move the panel', function()
	local lateTab
	local panel, frame, addon, game = panelBeside(400, 1000, function(hostFrame)
		lateTab = sideTab(hostFrame, 997, 1040, 760)
		lateTab:Hide()
	end)
	t.same(pointOf(panel, 'frame', frame), { 'TOPLEFT', 'frame', 'TOPRIGHT', 8, 0 })
	lateTab:Show()
	game:RunFrames()
	t.same(pointOf(panel, 'frame', frame), { 'TOPLEFT', 'frame', 'TOPRIGHT', 48, 0 }, 'a hidden tab shows')
	sideTab(frame, 997, 1060, 700)
	frame:Hide()
	frame:Show()
	game:RunFrames()
	t.same(pointOf(panel, 'frame', frame), { 'TOPLEFT', 'frame', 'TOPRIGHT', 68, 0 }, 'the frame shows with a new tab')
	placeAt(frame, 400, 1020, 800, 200)
	frame.scripts.OnSizeChanged(frame)
	game:RunFrames()
	t.same(pointOf(panel, 'frame', frame), { 'TOPLEFT', 'frame', 'TOPRIGHT', 48, 0 }, 'the frame resizes')
	t.same(addon.errors, {})
end)

t.test('the panel keeps to the 8-point grid', function()
	local panel = panelBeside(400, 1000)
	t.eq(panel.width % 8, 0, 'width on the grid')
	t.eq(panel.height % 8, 0, 'height on the grid')
	if t.isV1Only then
		t.eq(panel.plan, nil, 'no Plan venture button without the planner')
		return
	end
	t.same(pointOf(panel.plan, 'panel', panel), { 'BOTTOMLEFT', 'panel', 'BOTTOMLEFT', 8, 8 })
end)

t.group('ledger tab')

t.test('session starts: each mode, and a fallback says so', function()
	local LedgerTab = ns.LedgerTab
	local facts = { now = 200000, loginAt = 190000, resets = { daily = 180000, weekly = 100000, localDay = 172000 } }
	t.eq(LedgerTab.sessionStart('login', facts), 190000)
	t.eq(LedgerTab.sessionStart('daily', facts), 180000)
	t.eq(LedgerTab.sessionStart('today', facts), 172000)
	t.eq(LedgerTab.sessionStart('week', facts), 100000)
	local sessionStart, note = LedgerTab.sessionStart('ahVisit', facts)
	t.eq(sessionStart, 190000)
	t.truthy(note:find('since login'))
	facts.resetAt = 195000
	t.eq(LedgerTab.sessionStart('manual', facts), 195000)
	sessionStart, note = LedgerTab.sessionStart('daily', { now = 200000 })
	t.eq(sessionStart, 172800, 'UTC midnight')
	t.truthy(note)
end)

t.test('day labels and the summary lines', function()
	t.eq(ns.LedgerTab.dayLabel(0), '1970-01-01')
	t.eq(ns.LedgerTab.dayLabel(19723), '2024-01-01')
	t.eq(ns.LedgerTab.dayLabel(19782), '2024-02-29')
	local lines = ns.LedgerTab.summaryLines(
		{ income = 1000, spent = 1500, net = -500, byKind = { sale = 1000, deposit = -500, buy = -1000 } },
		'Since login'
	)
	t.eq(lines[4].level, 'low')
	t.truthy(lines[6].text:find('Auction buys'))
	t.truthy(lines[6].text:find('-' .. FakeGame.coins('10s'), 1, true))
end)

t.test('the tab shows a sale booked from mail, in every view', function()
	local game, addon = start()
	game.containerItems['0:1'] = { itemID = LINEN, stackCount = 10 }
	game.itemCounts[LINEN] = 10
	game.env.C_AuctionHouse.PostCommodity({ bag = 0, slot = 1 }, 1, 10, 100)
	game:Fire('AUCTION_HOUSE_AUCTION_CREATED', 5)
	game.mail[1] = {
		subject = 'Auction successful: Linen Cloth',
		money = 1050,
		invoice = { type = 'seller', itemName = 'Linen Cloth', bid = 1000, deposit = 100, cut = 50, count = 10 },
	}
	game.env.TakeInboxMoney(1)
	table.remove(game.mail, 1)
	game:Fire('MAIL_INBOX_UPDATE')
	addon.window:Open('ledger')
	local ledger = addon.window.containers.ledger
	local summary = linesText(ledger.lines)
	t.truthy(summary:find(FakeGame.coins('Gold in  11s'), 1, true), 'the sale and the deposit back')
	t.truthy(summary:find(FakeGame.coins('Gold out 1s 50c'), 1, true), 'the deposit and the cut')
	ledger.viewPicker.forward:Click()
	t.truthy(linesText(ledger.lines):find('net'))
	ledger.viewPicker.forward:Click()
	t.truthy(linesText(ledger.lines):find('Linen Cloth ×10'))
	ledger.viewPicker.forward:Click()
	t.truthy(linesText(ledger.lines):find('No purchases'))
	t.same(addon.errors, {})
end)
