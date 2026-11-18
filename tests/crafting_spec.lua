local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, BOLT = 2589, 2996
local RECIPE_ID = 3275
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

-- The feature files only load with a started add-on.
local _, ns = start()

t.group('crafting view')

t.test('a row shows profit and margin; low confidence gets a mark and its level', function()
	local text, level = ns.CraftingView.rowText({
		profit = 120,
		margin = 0.3,
		confidence = { level = 'high', reasons = {} },
	})
	t.eq(text, '+1s 20c · 30%')
	t.eq(level, nil)
	text, level = ns.CraftingView.rowText({ profit = -5, confidence = { level = 'low', reasons = {} } })
	t.eq(text, '? -5c')
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
	t.eq(all[1].text, 'Cost 1s')
	t.eq(all[3].level, 'low', 'a loss is flagged')
	t.truthy(all[4].text:find('Known 50%%'))
	local none = ns.CraftingView.detailLines(craft, { figures = false, share = false })
	t.eq(#none, 2)
	t.eq(none[1].text, 'Confidence low')
	t.truthy(none[2].text:find('no price for the output'))
	craft.usesPriceSource = true
	local credited = ns.CraftingView.detailLines(craft, { credit = 'Prices from AHledger' })
	t.eq(credited[#credited].text, 'Prices from AHledger', 'an AHledger figure is credited')
	craft.usesPriceSource = false
	credited = ns.CraftingView.detailLines(craft, { credit = 'Prices from AHledger' })
	t.eq(credited[#credited].text:find('AHledger'), nil)
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

t.group('crafting on the profession frame')

t.test('recipe rows get profit text; headers and the setting hide it', function()
	local game, addon, parts = start()
	t.truthy(game.rowCallback, 'the recipe list callback is registered')
	local row = FakeGame.newWidget('Button', parts.scrollBox)
	game.rowCallback(nil, row, recipeNode(RECIPE_ID))
	local text = rowText(row)
	t.truthy(text and text:IsShown())
	t.truthy(text:GetText():find('^[%+%-?]'))
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
	t.truthy(lines[6].text:find('%-10s'))
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
	t.truthy(summary:find('Gold in  11s'), 'the sale and the deposit back')
	t.truthy(summary:find('Gold out 1s 50c'), 'the deposit and the cut')
	ledger.viewPicker.forward:Click()
	t.truthy(linesText(ledger.lines):find('net'))
	ledger.viewPicker.forward:Click()
	t.truthy(linesText(ledger.lines):find('Linen Cloth ×10'))
	ledger.viewPicker.forward:Click()
	t.truthy(linesText(ledger.lines):find('No purchases'))
	t.same(addon.errors, {})
end)
