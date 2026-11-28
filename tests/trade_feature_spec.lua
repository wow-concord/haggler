local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, SILK, GREY = 2589, 4306, 3300
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
-- AHledger rows: median, min buyout, quantity, 7- and 30-day median, 30-day low and high, sold a day.
local AHLEDGER_ROWS = { [2589] = { 120, 95, 500, 118, 125, 90, 160, 45 }, [4306] = { 10, 9, 500, 10, 11, 8, 12, 45 } }
local PARTNER_GUID = 'Player-1-0000AAAA'
local GOLD = 10000
-- The default fee: 50 silver plus 5% of what the player gives.
local FEE_SILVER, FEE_PERCENT = 50, 5

local function newTradeFrame(env)
	local tradeFrame = FakeGame.newWidget('Frame', env.UIParent)
	env.TradeFrame = tradeFrame
	for slot = 1, 7 do
		env['TradePlayerItem' .. slot .. 'ItemButton'] = FakeGame.newWidget('Button', tradeFrame)
		env['TradeRecipientItem' .. slot .. 'ItemButton'] = FakeGame.newWidget('Button', tradeFrame)
	end
	env.TradePlayerInputMoneyFrame = FakeGame.newWidget('Frame', tradeFrame)
	env.TradeRecipientMoneyFrame = FakeGame.newWidget('Frame', tradeFrame)
	env.TradeFrameTradeButton = FakeGame.newWidget('Button', tradeFrame)
end

local function start(beforeStart)
	local game = FakeGame.new({
		now = NOW,
		itemInfo = {
			[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
			[SILK] = { name = 'Silk Cloth', maxStack = 20, vendorPrice = 50 },
			-- Sells to a vendor; no AH price in the table.
			[GREY] = { name = 'Rabbit Foot', maxStack = 20, vendorPrice = 500 },
		},
	})
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 7200, rows = AHLEDGER_ROWS })
	game.env.GetRealmName = function()
		return 'Realm'
	end
	newTradeFrame(game.env)
	game.partner = { name = 'Bob', guid = PARTNER_GUID }
	local addon = FakeGame.startAddon(t, game, beforeStart)
	return game, addon
end

local function open(game, player, target)
	game.trade.player = player or { money = 0, slots = {} }
	game.trade.target = target or { money = 0, slots = {} }
	game:Fire('TRADE_SHOW')
end

local function created(game, template, predicate)
	for _, frame in ipairs(game.createdFrames) do
		if frame.template == template and (not predicate or predicate(frame)) then
			return frame
		end
	end
	return nil
end

local function confirmButton(game)
	return created(game, 'UIPanelButtonTemplate', function(frame)
		return frame.allPoints == game.env.TradeFrameTradeButton
	end)
end

local function ruleButton(game)
	return created(game, 'UIPanelButtonTemplate', function(frame)
		return frame.allPoints == nil
	end)
end

-- Font strings Haggler put on TradeFrame: the two totals, then the warning.
local function tradeFrameTexts(game)
	return game.env.TradeFrame.children
end

local function totalText(game, side)
	local anchor = side == 'player' and game.env.TradePlayerInputMoneyFrame or game.env.TradeRecipientMoneyFrame
	for _, child in ipairs(tradeFrameTexts(game)) do
		if child.points[1] and child.points[1][2] == anchor then
			return child.isShown and child.text or nil
		end
	end
	return nil
end

local function warningText(game)
	for _, child in ipairs(tradeFrameTexts(game)) do
		if child.points[1] and child.points[1][2] == game.env.TradeFrameTradeButton then
			return child.isShown and child.text or nil
		end
	end
	return nil
end

-- The value label under a slot: Haggler's frame anchored to that slot button.
local function slotLabel(game, side, slot)
	local pattern = side == 'player' and 'TradePlayerItem%dItemButton' or 'TradeRecipientItem%dItemButton'
	local button = game.env[string.format(pattern, slot)]
	for _, frame in ipairs(game.createdFrames) do
		if frame.points[1] and frame.points[1][2] == button then
			return frame
		end
	end
	return nil
end

local function slotText(game, side, slot)
	local frame = slotLabel(game, side, slot)
	return frame and frame.isShown and frame.children[1].text or nil
end

local function ledgerOf(addon)
	return addon.store:Market(MARKET).ledger or {}
end

t.group('trade window')

t.test('values each slot and totals each side; gold at face value, the enchant slot ignored', function()
	local game, addon = start()
	open(game, {
		money = 2 * GOLD,
		slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } },
	}, {
		money = 0,
		slots = {
			[2] = { name = 'Silk Cloth', count = 1, link = 'item:4306' },
			[7] = { name = 'Linen Cloth', count = 20, link = 'item:2589' },
		},
	})
	t.truthy(slotText(game, 'player', 1), 'player slot 1 valued')
	t.eq(slotText(game, 'player', 2), nil, 'empty slot shows nothing')
	t.truthy(slotText(game, 'target', 2):find('50', 1, true))
	t.eq(slotLabel(game, 'target', 7), nil, 'no label on the enchant slot')
	t.truthy(totalText(game, 'player'):find('^Worth '))
	t.truthy(totalText(game, 'target'):find('^Worth '))
	t.same(addon.errors, {})
end)

t.test('the hover shows the raw rule price and the value after cut and deposit risk', function()
	local game = start()
	open(game, { money = 0, slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } } })
	local label = slotLabel(game, 'player', 1)
	t.eq(label.isMouseEnabled, true)
	label.scripts.OnEnter(label)
	local tooltip = game.env.GameTooltip
	t.eq(tooltip.owner, label)
	t.truthy(tooltip.lines[1].left:find('^Rule price: '), tooltip.lines[1].left)
	t.truthy(tooltip.lines[2].left:find('^Worth .*5%% cut'), tooltip.lines[2].left)
	label.scripts.OnLeave(label)
	t.eq(tooltip.isShown, false)
end)

t.test('a vendor-only item reads "no price (vendor X)"; given away, the verdict is uncertain', function()
	local game = start()
	local grey = { name = 'Rabbit Foot', count = 1, link = 'item:3300' }
	open(game, { money = 0, slots = { [1] = grey } }, { money = 0, slots = { [1] = grey } })
	local given = slotText(game, 'player', 1)
	t.truthy(given:find('no price (vendor ' .. FakeGame.coins('5s') .. ')', 1, true), given)
	t.truthy(given:find('Haggler\\media\\icons', 1, true), 'low icon on the side the player gives')
	local got = slotText(game, 'target', 1)
	t.truthy(got:find('no price (vendor ' .. FakeGame.coins('5s') .. ')', 1, true), got)
	t.eq(got:find('Haggler\\media\\icons', 1, true), nil, 'what the player gets keeps its confidence')
	local warning = warningText(game)
	t.truthy(warning and warning:find('uncertain', 1, true), warning)
end)

t.test('an item not loaded yet is marked unpriced with the low icon', function()
	local game = start()
	open(game, { money = 0, slots = { [3] = { name = 'Mystery', count = 1 } } })
	local text = slotText(game, 'player', 3)
	t.truthy(text:find('no price', 1, true), text)
	t.truthy(text:find('|T', 1, true), 'low icon')
	t.truthy(totalText(game, 'player'):find('|T', 1, true), 'the side total is low too')
end)

t.test('no warning exactly at the fee; one copper more warns', function()
	local fee = FEE_SILVER * 100 + GOLD * FEE_PERCENT / 100
	local game = start()
	open(game, { money = GOLD, slots = {} }, { money = GOLD - fee, slots = {} })
	t.eq(warningText(game), nil, 'gap == fee')
	game.trade.target.money = GOLD - fee - 1
	game:Fire('TRADE_MONEY_CHANGED')
	local warning = warningText(game)
	t.truthy(warning and warning:find('You give', 1, true), tostring(warning))
end)

t.test('the fee settings are read live (silver and percent)', function()
	local game, addon = start()
	open(game, { money = GOLD, slots = {} })
	t.truthy(warningText(game))
	addon.trade:SetSetting('feeSilver', 1000)
	t.eq(warningText(game), nil, '10g fee covers a 1g gift')
	addon.trade:SetSetting('feeSilver', 0)
	addon.trade:SetSetting('feePercent', 50)
	t.truthy(warningText(game), '50% of 1g is less than 1g')
end)

t.test('confirm mode: the overlay button arms on the first click and accepts on the second', function()
	local game, addon = start()
	addon.trade:SetSetting('mode', 'confirm')
	open(game, { money = GOLD, slots = {} })
	local button = confirmButton(game)
	t.truthy(button and button.isShown, 'covers the Trade button')
	t.truthy(button.frameLevel > game.env.TradeFrameTradeButton.frameLevel)
	button:Click()
	t.eq(button.text, 'Confirm loss')
	t.eq(game.acceptCount, 0)
	button:Click()
	t.eq(game.acceptCount, 1)
	for _, hook in ipairs(game.hooks) do
		t.truthy(hook.object ~= game.env.TradeFrameTradeButton, "Blizzard's Trade button is never hooked")
	end
	t.eq(game:HookCount(), 1, 'only the scan request hook')
end)

t.test('confirm mode: an arm expires, and any change disarms it', function()
	local game, addon = start()
	addon.trade:SetSetting('mode', 'confirm')
	open(game, { money = GOLD, slots = {} })
	local button = confirmButton(game)
	button:Click()
	game:Advance(6)
	button:Click()
	t.eq(game.acceptCount, 0, 'expired: armed again instead')
	game.trade.target.money = 10
	game:Fire('TRADE_MONEY_CHANGED')
	t.eq(button.text, 'Trade', 'the gap changed')
	button:Click()
	t.eq(game.acceptCount, 0)
end)

t.test('confirm mode: a redraw with the same gap and items keeps the arm (the partner accepts)', function()
	local game, addon = start()
	addon.trade:SetSetting('mode', 'confirm')
	open(game, { money = GOLD, slots = {} })
	local button = confirmButton(game)
	button:Click()
	game:Fire('TRADE_ACCEPT_UPDATE', 0, 1)
	t.eq(button.text, 'Confirm loss')
	button:Click()
	t.eq(game.acceptCount, 1)
	game.trade.player.slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } }
	button:Click()
	game:Fire('TRADE_PLAYER_ITEM_CHANGED', 1)
	t.eq(button.text, 'Trade', 'the items changed')
end)

t.test('both sides accepted: the trade is frozen, so slots the client clears are still logged', function()
	local game, addon = start()
	open(
		game,
		{ money = 0, slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } } },
		{ money = GOLD, slots = {} }
	)
	game:Fire('TRADE_ACCEPT_UPDATE', 1, 0)
	game.trade.player.money = 5
	game:Fire('TRADE_MONEY_CHANGED')
	t.truthy(totalText(game, 'player'), 'one side accepted: still read')
	game:Fire('TRADE_ACCEPT_UPDATE', 1, 1)
	game.trade.player = { money = 0, slots = {} }
	game.trade.target = { money = 0, slots = {} }
	game:Fire('TRADE_PLAYER_ITEM_CHANGED', 1)
	game:Fire('TRADE_MONEY_CHANGED')
	game:Fire('UI_INFO_MESSAGE', 226, 'Trade complete.')
	local kinds = {}
	for _, event in ipairs(addon.Ledger.events(addon.store:Market(MARKET))) do
		kinds[#kinds + 1] = event.kind .. ':' .. tostring(event.itemId)
	end
	table.sort(kinds)
	t.same(kinds, { 'tradeIn:nil', 'tradeOut:2589', 'tradeOut:nil' })
end)

t.test('both sides accepted reported as true (not 1) also freezes the trade', function()
	local game, addon = start()
	open(
		game,
		{ money = 0, slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } } },
		{ money = GOLD, slots = {} }
	)
	game:Fire('TRADE_ACCEPT_UPDATE', true, true)
	game.trade.player = { money = 0, slots = {} }
	game.trade.target = { money = 0, slots = {} }
	game:Fire('TRADE_PLAYER_ITEM_CHANGED', 1)
	game:Fire('UI_INFO_MESSAGE', 226, 'Trade complete.')
	local kinds = {}
	for _, event in ipairs(addon.Ledger.events(addon.store:Market(MARKET))) do
		kinds[#kinds + 1] = event.kind .. ':' .. tostring(event.itemId)
	end
	table.sort(kinds)
	t.same(kinds, { 'tradeIn:nil', 'tradeOut:2589' })
end)

t.test('confirm mode: no overlay when the trade is fine; warn mode never shows it', function()
	local game, addon = start()
	addon.trade:SetSetting('mode', 'confirm')
	open(game, { money = 0, slots = {} }, { money = GOLD, slots = {} })
	t.eq(confirmButton(game).isShown, false)
	addon.trade:SetSetting('mode', 'warn')
	game.trade.player.money = GOLD
	game.trade.target.money = 0
	game:Fire('TRADE_MONEY_CHANGED')
	t.truthy(warningText(game))
	t.eq(confirmButton(game).isShown, false)
	addon.trade:SetSetting('mode', 'off')
	t.eq(warningText(game), nil, 'off shows values only')
	t.truthy(totalText(game, 'player'))
end)

t.test('the rule button cycles the rule and is remembered', function()
	local game, addon = start()
	open(game, { money = 0, slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } } })
	local button = ruleButton(game)
	local before = button.text
	t.truthy(before:find('^Rule: '))
	local ruleIds = addon.store:RuleIds()
	local defaultIndex
	for index, ruleId in ipairs(ruleIds) do
		if before == 'Rule: ' .. addon.store:Rule(ruleId).name then
			defaultIndex = index
		end
	end
	local nextRuleId = ruleIds[defaultIndex % #ruleIds + 1]
	button:Click()
	t.eq(addon.store:Ui().tradeRuleId, nextRuleId)
	t.eq(button.text, 'Rule: ' .. addon.store:Rule(nextRuleId).name)
	game:Fire('TRADE_CLOSED')
	open(game)
	t.eq(button.text, 'Rule: ' .. addon.store:Rule(nextRuleId).name, 'kept for the next trade')
end)

t.test('friends and guild: values only drops the warning, off shows nothing', function()
	local game, addon = start()
	game.friendGuids[PARTNER_GUID] = true
	addon.trade:SetSetting('friends', 'values')
	open(game, { money = GOLD, slots = {} })
	t.eq(warningText(game), nil)
	t.truthy(totalText(game, 'player'))
	addon.trade:SetSetting('friends', 'off')
	t.eq(totalText(game, 'player'), nil)
	t.eq(ruleButton(game).isShown, false)
	game.friendGuids[PARTNER_GUID] = nil
	game.partner.isGuild = true
	addon.trade:SetSetting('guild', 'values')
	open(game, { money = GOLD, slots = {} })
	t.eq(warningText(game), nil, 'guild member, values only')
	t.truthy(totalText(game, 'player'))
end)

t.test('a Battle.net friend counts as a friend', function()
	local game, addon = start()
	game.bnetFriends = { 'Player-1-0000BBBB', PARTNER_GUID }
	addon.trade:SetSetting('friends', 'off')
	open(game, { money = GOLD, slots = {} })
	t.eq(totalText(game, 'player'), nil)
end)

t.test('a completed trade is logged once as tradeOut and tradeIn events', function()
	local game, addon = start()
	open(
		game,
		{ money = GOLD, slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } } },
		{ money = 0, slots = { [1] = { name = 'Silk Cloth', count = 2, link = 'item:4306' } } }
	)
	game:Fire('TRADE_CLOSED')
	game:Advance(1)
	game:Fire('UI_INFO_MESSAGE', 226, 'Trade complete.')
	game:Fire('UI_INFO_MESSAGE', 226, 'Trade complete.')
	local events = addon.Ledger.events(addon.store:Market(MARKET))
	local kinds = {}
	for _, event in ipairs(events) do
		kinds[#kinds + 1] = event.kind
		t.eq(event.char, 'Eilu-Realm')
		t.eq(event.t, NOW + 1)
	end
	table.sort(kinds)
	t.same(kinds, { 'tradeIn', 'tradeOut', 'tradeOut' })
	t.same(addon.errors, {})
end)

t.test('a completion by message text alone is accepted', function()
	local game, addon = start()
	open(game, { money = GOLD, slots = {} })
	game:Fire('UI_INFO_MESSAGE', nil, 'Trade complete.')
	t.eq(#ledgerOf(addon), 1)
end)

t.test('cancelled, late and unlogged trades write nothing', function()
	local game, addon = start()
	open(game, { money = GOLD, slots = {} })
	game:Fire('TRADE_CLOSED')
	game:Fire('UI_INFO_MESSAGE', 1, 'Something else.')
	t.eq(#ledgerOf(addon), 0, 'cancelled')
	open(game, { money = GOLD, slots = {} })
	game:Fire('TRADE_CLOSED')
	game:Advance(6)
	game:Fire('UI_INFO_MESSAGE', 226, 'Trade complete.')
	t.eq(#ledgerOf(addon), 0, 'after the grace period')
	addon.trade:SetSetting('logTrades', false)
	open(game, { money = GOLD, slots = {} })
	game:Fire('UI_INFO_MESSAGE', 226, 'Trade complete.')
	t.eq(#ledgerOf(addon), 0, 'logging off')
end)

t.test('a trade with a values-off partner is still logged', function()
	local game, addon = start()
	game.partner.isGuild = true
	addon.trade:SetSetting('guild', 'off')
	open(game, { money = GOLD, slots = {} })
	game:Fire('UI_INFO_MESSAGE', 226, 'Trade complete.')
	t.eq(#ledgerOf(addon), 1)
end)

t.test('closing the window or switching the module off hides everything', function()
	local game, addon = start()
	open(game, { money = GOLD, slots = { [1] = { name = 'Linen Cloth', count = 20, link = 'item:2589' } } })
	game:Fire('TRADE_CLOSED')
	t.eq(totalText(game, 'player'), nil)
	t.eq(slotText(game, 'player', 1), nil)
	t.eq(warningText(game), nil)
	open(game, { money = GOLD, slots = {} })
	addon.host.Disable('trade')
	t.eq(totalText(game, 'player'), nil)
	game:Fire('TRADE_MONEY_CHANGED')
	t.eq(totalText(game, 'player'), nil, 'events dropped')
end)

t.test('no TradeFrame yet: nothing is drawn and nothing fails', function()
	local game, addon = start()
	game.env.TradeFrame = nil
	local framesBefore = #game.createdFrames
	open(game, { money = GOLD, slots = {} })
	t.same(addon.errors, {})
	t.eq(#game.createdFrames, framesBefore)
end)

t.test('the silver fee goes up to at least 100g', function()
	local _, addon = start()
	addon.trade:SetSetting('feeSilver', 10000)
	t.eq(addon.trade:Setting('feeSilver'), 10000)
end)
