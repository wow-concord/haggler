local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, WOOL, SWORD = 2589, 2592, 2488
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
-- AHledger rows: median, min buyout, quantity, 7- and 30-day median, 30-day low and high, sold a day.
local AHLEDGER_ROWS = {
	[2589] = { 120, 95, 500, 118, 125, 90, 160, 45 },
	[2592] = { 300, 280, 80, 290, 310, 250, 400, 0.5 },
	[2488] = { 12345, 12000, 3, 12000, 12500, 11000, 13000, 3 },
}
local ITEM_INFO = {
	[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
	[WOOL] = { name = 'Wool Cloth', maxStack = 20, vendorPrice = 33 },
	[SWORD] = { name = 'Short Sword', maxStack = 1, vendorPrice = 500 },
}

local function start(beforeStart)
	local game = FakeGame.new({ now = NOW, itemInfo = ITEM_INFO })
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = AHLEDGER_ROWS })
	game.env.GetRealmName = function()
		return 'Realm'
	end
	game.bagSlots[0] = 16
	local addon = FakeGame.startAddon(t, game, beforeStart)
	return game, addon
end

local function carry(game, slot, itemId, count)
	game.containerItems['0:' .. slot] = { itemID = itemId, stackCount = count, hyperlink = 'item:' .. itemId }
end

local function openAuctionHouse(game)
	game.env.AuctionHouseFrame:Show()
	game:Fire('AUCTION_HOUSE_SHOW')
end

local function closeAuctionHouse(game)
	game.env.AuctionHouseFrame:Hide()
	game:Fire('AUCTION_HOUSE_CLOSED')
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

local function container(addon, key)
	return addon.window.containers[key]
end

local function linesText(lines)
	local texts = {}
	for _, line in ipairs(lines.strings) do
		texts[#texts + 1] = line:GetText() or ''
	end
	return table.concat(texts, '\n')
end

-- Window model ----------------------------------------------------------------------------

t.group('window model')

local ns = t.loadAddon()
local WindowModel = ns.WindowModel

local function newTab(key, order)
	return { key = key, label = key, order = order, build = function() end }
end

t.test('tabs list in order and refuse duplicates and bad tabs', function()
	local tabs = WindowModel.newTabs()
	tabs:Add(newTab('sell', 40))
	tabs:Add(newTab('scan', 10))
	tabs:Add(newTab('lookup', 20))
	local keys = {}
	for _, tab in ipairs(tabs:List()) do
		keys[#keys + 1] = tab.key
	end
	t.same(keys, { 'scan', 'lookup', 'sell' })
	t.eq(tabs:Get('lookup').order, 20)
	t.eq(tabs:Get('nope'), nil)
	t.raises(function()
		tabs:Add(newTab('scan', 50))
	end, 'scan')
	t.raises(function()
		tabs:Add({ key = 'x', label = 'X', order = 1 })
	end, 'build')
	t.raises(function()
		tabs:Add({ key = 'bad key', label = 'X', order = 1, build = function() end })
	end)
end)

t.test('placement: takeover unless docked by setting or by another auction add-on', function()
	t.eq(WindowModel.placement('takeover', nil), 'takeover')
	t.eq(WindowModel.placement('takeover', 'TradeSkillMaster'), 'dock')
	t.eq(WindowModel.placement('dock', nil), 'dock')
	t.eq(WindowModel.placement('manual', 'Auctionator'), 'manual')
end)

t.test('page clamps and reports the first index', function()
	local list = { 1, 2, 3, 4, 5, 6, 7 }
	t.same(WindowModel.page(list, 2, 3), { items = { 4, 5, 6 }, page = 2, pageCount = 3, first = 4 })
	t.same(WindowModel.page(list, 9, 3), { items = { 7 }, page = 3, pageCount = 3, first = 7 })
	t.same(WindowModel.page(list, 0, 3).page, 1)
	t.same(WindowModel.page({}, 1, 3), { items = {}, page = 1, pageCount = 1, first = 1 })
	t.raises(function()
		WindowModel.page(list, 1, 0)
	end)
end)

t.test('item from text: id, link, then name; empty and unknown say why', function()
	local deps = {
		itemIdFromLink = function(text)
			return tonumber(text:match('item:(%d+)'))
		end,
		itemIdsByName = function(lower)
			return lower == 'linen' and { LINEN } or {}
		end,
	}
	t.eq(WindowModel.itemIdFromText(' 2589 ', deps), LINEN)
	t.eq(WindowModel.itemIdFromText('|Hitem:2592::|h[Wool]|h', deps), WOOL)
	t.eq(WindowModel.itemIdFromText('Linen', deps), LINEN)
	local id, reason = WindowModel.itemIdFromText('   ', deps)
	t.eq(id, nil)
	t.truthy(reason:find('type'))
	id, reason = WindowModel.itemIdFromText('dragon', deps)
	t.eq(id, nil)
	t.truthy(reason:find('no item'))
	t.eq(WindowModel.itemIdFromText('2.5', deps), nil, 'not a whole id')
end)

t.test('history keeps only days with a summary, newest first', function()
	local today = math.floor(NOW / 86400)
	local scanDays = {
		[today] = { items = { [LINEN] = { sold = 12, troll = 1 } } },
		[today - 2] = { items = {} },
		[today - 9] = { items = { [LINEN] = { sold = 99 } } },
	}
	t.same(WindowModel.historyLines(scanDays, LINEN, NOW), {
		{ day = today, daysAgo = 0, sold = 12, troll = 1 },
		{ day = today - 2, daysAgo = 2, sold = 0, troll = 0 },
	})
	t.same(WindowModel.historyLines(nil, LINEN, NOW), {})
end)

local function lineWith(lines, pattern)
	for _, line in ipairs(lines) do
		if line.text:find(pattern) then
			return line
		end
	end
	return nil
end

t.test('sell lines flag a loss and a below-vendor price', function()
	local row = { listings = 1, units = 20 }
	local loss = WindowModel.sellLines(row, { price = 40, deposit = 5000, isLoss = true, action = 'post' })
	t.eq(assert(lineWith(loss, 'lose')).level, 'low')
	local vendor = WindowModel.sellLines(
		{ listings = 3, units = 1 },
		{ price = 13, isBelowVendor = true, action = 'vendor', reasons = { { text = 'Fresh', level = 'high' } } }
	)
	t.truthy(vendor[1].text:find('3 listings'))
	t.truthy(lineWith(vendor, 'Suggested: sell to the vendor'))
	for _, line in ipairs(vendor) do
		t.truthy(line.text ~= 'Fresh', 'high-confidence reasons stay out')
	end
end)

t.test('sell lines say the confidence and every reason that is not high', function()
	local lines = WindowModel.sellLines({ listings = 1, units = 5 }, {
		price = 100,
		action = 'post',
		confidence = {
			level = 'medium',
			reasons = {
				{ text = 'AHledger data is 30 hours old', level = 'medium' },
				{ text = 'Sells often', level = 'high' },
				{ text = 'Few scans', level = 'low' },
			},
		},
	})
	t.eq(assert(lineWith(lines, '^medium confidence$')).level, 'medium')
	t.truthy(lineWith(lines, '30 hours old'))
	t.truthy(lineWith(lines, 'Few scans'))
	t.eq(lineWith(lines, 'Sells often'), nil)
	local unpriced = WindowModel.sellLines(
		{ listings = 1, units = 1, reason = 'no market price yet' },
		{ action = 'hold' }
	)
	t.eq(assert(lineWith(unpriced, 'No price: no market price yet')).level, 'low')
	t.truthy(lineWith(unpriced, 'unknown confidence'))
end)

t.test('buy lines say the rule price, its confidence and reasons, or why it is unknown', function()
	local lines = WindowModel.buyLines({
		units = 40,
		unitPrice = 60,
		rulePrice = 120,
		discountPercent = 50,
		confidence = { level = 'low', reasons = { { text = 'Only your own scans', level = 'low' } } },
	})
	t.truthy(lines[1].text:find('Last scan: 40'))
	t.truthy(lineWith(lines, '50%% under'))
	t.eq(assert(lineWith(lines, '^low confidence$')).level, 'low')
	t.truthy(lineWith(lines, 'Only your own scans'))
	local unknown = WindowModel.buyLines({ units = 1, unitPrice = 5, ruleReason = 'no data' })
	t.eq(assert(lineWith(unknown, 'Rule price: unknown %(no data%)')).level, 'low')
end)

t.test('far above the rule price from one and a half times', function()
	t.eq(WindowModel.farAboveRule(149, 100), nil)
	t.eq(WindowModel.farAboveRule(150, 100), 1.5)
	t.eq(WindowModel.farAboveRule(300, nil), nil)
	t.eq(WindowModel.farAboveRule(300, 0), nil)
end)

t.test('post quantity: a commodity posts all, an item its first slot', function()
	local row = { units = 45, slots = { { bag = 0, slot = 1, count = 20 }, { bag = 0, slot = 2, count = 25 } } }
	t.eq(WindowModel.postQuantity(row, { isCommodity = true }), 45)
	t.eq(WindowModel.postQuantity(row, { isCommodity = false }), 20)
	t.eq(WindowModel.durationIndex('48'), 3)
	t.eq(WindowModel.durationIndex('bogus'), 2)
end)

-- Window against the fake game ------------------------------------------------------------

t.group('window')

t.test('/hag toggles the window away from the auction house, with posting greyed', function()
	local game, addon = start()
	carry(game, 1, LINEN, 20)
	addon.host.RunCommand('open sell')
	t.truthy(addon.window:IsOpen())
	t.truthy(game.env.HagglerFrame, 'the frame is named, so Escape closes it')
	t.truthy(game.env.UISpecialFrames[1] == 'HagglerFrame')
	local sell = container(addon, 'sell')
	t.eq(sell.state.rows[1].itemId, LINEN)
	t.eq(sell.postButton:IsEnabled(), false, 'away: no posting')
	t.truthy(linesText(sell.lines):find('needs the auction house'))
	t.eq(addon.window:Toggle(), false)
	t.eq(addon.window:IsOpen(), false)
	t.same(addon.errors, {})
end)

t.test('at the auction house it takes over and gives Blizzard back', function()
	local game, addon = start()
	openAuctionHouse(game)
	local blizzard = game.env.AuctionHouseFrame
	t.truthy(addon.window:IsOpen())
	t.eq(blizzard:GetAlpha(), 0, 'Blizzard hidden by alpha, not closed')
	t.truthy(blizzard:IsShown())
	t.truthy(addon.window.blizzardButton:IsShown())
	addon.window.blizzardButton:Click()
	t.eq(blizzard:GetAlpha(), 1)
	t.eq(addon.window:IsOpen(), false)
	t.truthy(addon.window.returnButton:IsShown(), 'a Haggler button to come back')
	addon.window.returnButton:Click()
	t.truthy(addon.window:IsOpen())
	t.eq(blizzard:GetAlpha(), 0)
	closeAuctionHouse(game)
	t.eq(blizzard:GetAlpha(), 1)
	t.eq(addon.window:IsOpen(), false)
	t.eq(addon.window.returnButton:IsShown(), false)
	t.same(addon.errors, {})
end)

t.test('docks beside the auction house when TradeSkillMaster runs it', function()
	local game, addon = start()
	game.loadedAddOns.TradeSkillMaster = true
	openAuctionHouse(game)
	t.truthy(addon.window:IsOpen())
	t.eq(game.env.AuctionHouseFrame:GetAlpha(), 1, 'never hides another add-on')
	local point = addon.window.frame.points[1]
	t.eq(point[2], game.env.AuctionHouseFrame)
	t.eq(point[3], 'TOPRIGHT')
end)

t.test('manual mode waits for /hag', function()
	local game, addon = start()
	addon.host.Settings:Set('window', 'ahMode', 'manual')
	openAuctionHouse(game)
	t.eq(addon.window:IsOpen(), false)
	t.truthy(addon.window.returnButton:IsShown())
end)

-- Remembered view ---------------------------------------------------------------------------

t.group('remembered auction house view')

-- A /reload, logout or restart: a new game and add-on over the same saved variables.
local function reload(previous)
	local game = FakeGame.new({ now = NOW, itemInfo = ITEM_INFO })
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = AHLEDGER_ROWS })
	game.env.GetRealmName = function()
		return 'Realm'
	end
	game.bagSlots[0] = 16
	game.savedDb, game.savedCharDb = previous.savedDb, previous.savedCharDb
	return game, FakeGame.startAddon(t, game)
end

local function isShowingBlizzard(game, addon)
	return not addon.window:IsOpen()
		and game.env.AuctionHouseFrame:GetAlpha() == 1
		and addon.window.returnButton:IsShown()
end

t.test('model: the remembered view opens Haggler only where the mode lets it open itself', function()
	t.eq(WindowModel.opensAtAuctionHouse('takeover', 'haggler'), true)
	t.eq(WindowModel.opensAtAuctionHouse('dock', 'haggler'), true)
	t.eq(WindowModel.opensAtAuctionHouse('takeover', 'blizzard'), false)
	t.eq(WindowModel.opensAtAuctionHouse('dock', 'blizzard'), false)
	t.eq(WindowModel.opensAtAuctionHouse('manual', 'haggler'), false)
	t.eq(WindowModel.opensAtAuctionHouse('takeover', nil), true, 'nothing saved: the default')
end)

t.test("the first-ever open keeps today's default: Haggler takes over", function()
	local game, addon = start()
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler')
	openAuctionHouse(game)
	t.truthy(addon.window:IsOpen())
	t.eq(addon.window.placedAs, 'takeover')
	t.eq(game.env.AuctionHouseFrame:GetAlpha(), 0)
	t.same(addon.errors, {})
end)

t.test("switching to Blizzard's window is remembered for the next visit", function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window.blizzardButton:Click()
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'blizzard')
	closeAuctionHouse(game)
	openAuctionHouse(game)
	t.truthy(isShowingBlizzard(game, addon), "Blizzard's window, with the Haggler button")
	t.same(addon.errors, {})
end)

t.test('the close button is not a switch, like Escape', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window.closeButton:Click()
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler')
	closeAuctionHouse(game)
	openAuctionHouse(game)
	t.truthy(addon.window:IsOpen(), 'the next visit opens Haggler again')
end)

t.test('a plain /hag at the auction house switches either way', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window:Toggle()
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'blizzard')
	addon.window:Toggle()
	t.truthy(addon.window:IsOpen())
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler')
end)

t.test("any explicit open of Haggler's window at the auction house chooses Haggler", function()
	local game, addon = start()
	addon.host.Settings:Set('window', 'ahView', 'blizzard')
	openAuctionHouse(game)
	addon.host.RunCommand('open sell')
	t.truthy(addon.window:IsOpen())
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler', '/hag open')
	addon.window.blizzardButton:Click()
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'blizzard')
	-- The top bar, the options entry and the crafting window all open it this way.
	addon.window:Open('ventures')
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler', 'an open from another feature')
	t.same(addon.errors, {})
end)

t.test('an open that fails saves nothing', function()
	local game, addon = start()
	addon.host.Settings:Set('window', 'ahView', 'blizzard')
	openAuctionHouse(game)
	local createFrame = addon.wow.CreateFrame
	addon.wow.CreateFrame = function(wow, frameType, parent, template, name, ...)
		if name == 'HagglerFrame' then
			error('frame build failed')
		end
		return createFrame(wow, frameType, parent, template, name, ...)
	end
	t.raises(function()
		addon.window.returnButton:Click()
	end, 'frame build failed')
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'blizzard')
end)

t.test('with Blizzard remembered, an auction house window that loads late still gets the Haggler button', function()
	local game, addon = start()
	addon.host.Settings:Set('window', 'ahView', 'blizzard')
	local blizzard = game.env.AuctionHouseFrame
	game.env.AuctionHouseFrame = nil
	game:Fire('AUCTION_HOUSE_SHOW')
	t.eq(addon.window.returnButton, nil, 'no window to sit on yet')
	game.env.AuctionHouseFrame = blizzard
	game:RunTimers()
	blizzard:Show()
	t.truthy(addon.window.returnButton, 'made once the window exists')
	t.truthy(isShowingBlizzard(game, addon))
	t.same(addon.errors, {})
end)

t.test('with Blizzard remembered, the OnShow hook makes the Haggler button', function()
	local game, addon = start()
	addon.host.Settings:Set('window', 'ahView', 'blizzard')
	openAuctionHouse(game)
	closeAuctionHouse(game)
	-- The hook is in place from the first visit; next time the window exists only on show.
	local blizzard = game.env.AuctionHouseFrame
	addon.window.returnButton = nil
	game.env.AuctionHouseFrame = nil
	game:Fire('AUCTION_HOUSE_SHOW')
	game.env.AuctionHouseFrame = blizzard
	blizzard:Show()
	t.truthy(addon.window.returnButton, 'made by the hook')
	t.truthy(addon.window.returnButton:IsShown())
	t.same(addon.errors, {})
end)

t.test('the settings row reads as the remembered window, with its note, hidden in manual mode', function()
	local _, addon = start()
	local lines = table.concat(addon.host.RunCommand('list window'), '\n')
	t.truthy(lines:find('window.ahView = haggler  (Auction house opens in)', 1, true), lines)
	t.truthy(lines:find('the last one you switched to', 1, true), lines)
	addon.host.Settings:Set('window', 'ahMode', 'manual')
	lines = table.concat(addon.host.RunCommand('list window'), '\n')
	t.eq(lines:find('ahView', 1, true), nil, 'nothing remembered in manual mode')
	t.truthy(lines:find('ahMode', 1, true))
end)

t.test('switching back to Haggler is remembered for the next visit', function()
	local game, addon = start()
	addon.host.Settings:Set('window', 'ahView', 'blizzard')
	openAuctionHouse(game)
	t.truthy(isShowingBlizzard(game, addon))
	addon.window.returnButton:Click()
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler')
	closeAuctionHouse(game)
	openAuctionHouse(game)
	t.truthy(addon.window:IsOpen())
	t.eq(game.env.AuctionHouseFrame:GetAlpha(), 0)
	t.same(addon.errors, {})
end)

t.test('closing the auction house or opening /hag away remembers nothing', function()
	local game, addon = start()
	openAuctionHouse(game)
	closeAuctionHouse(game)
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler')
	addon.host.Settings:Set('window', 'ahView', 'blizzard')
	addon.window:Open()
	addon.window:Close()
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'blizzard', 'away from the auction house')
end)

t.test('the remembered view survives a reload of the saved variables', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window.blizzardButton:Click()
	closeAuctionHouse(game)
	local reloadedGame, reloadedAddon = reload(game)
	openAuctionHouse(reloadedGame)
	t.truthy(isShowingBlizzard(reloadedGame, reloadedAddon))
	reloadedAddon.window.returnButton:Click()
	closeAuctionHouse(reloadedGame)
	local thirdGame, thirdAddon = reload(reloadedGame)
	openAuctionHouse(thirdGame)
	t.truthy(thirdAddon.window:IsOpen(), 'Haggler again after the next reload')
	t.same(thirdAddon.errors, {})
end)

t.test('in combat Haggler still opens: it makes no secure frames', function()
	local game, addon = start()
	game.inCombat = true
	openAuctionHouse(game)
	t.truthy(addon.window:IsOpen())
	t.eq(game.env.AuctionHouseFrame:GetAlpha(), 0)
	t.same(addon.errors, {})
end)

t.test("a window that fails to build falls back to the game's and keeps the choice", function()
	local game, addon = start()
	local createFrame = addon.wow.CreateFrame
	addon.wow.CreateFrame = function(wow, frameType, parent, template, name, ...)
		if name == 'HagglerFrame' then
			error('frame build failed')
		end
		return createFrame(wow, frameType, parent, template, name, ...)
	end
	openAuctionHouse(game)
	t.truthy(isShowingBlizzard(game, addon))
	t.eq(addon.host.Settings:Get('window', 'ahView'), 'haggler', 'not overwritten')
	t.eq(#addon.errors, 1, 'the failure is reported')
	t.truthy(addon.errors[1]:find('frame build failed', 1, true))
end)

t.group('window')

t.test('switching the window off closes it and restores Blizzard', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.host.Disable('window')
	t.eq(addon.window:IsOpen(), false)
	t.eq(game.env.AuctionHouseFrame:GetAlpha(), 1)
	t.eq(addon.window:Open(), false)
end)

t.group('sell tab')

t.test('posts a commodity stack at the default rule price in one click', function()
	local game, addon = start()
	carry(game, 1, LINEN, 20)
	game.auctionHouse.commodities[LINEN] = true
	openAuctionHouse(game)
	addon.window:Open('sell')
	local sell = container(addon, 'sell')
	local row = sell.state.rows[1]
	t.eq(row.itemId, LINEN)
	t.truthy(sell.postButton:IsEnabled())
	sell.postButton:Click()
	local posts = callsNamed(game, 'PostCommodity')
	t.eq(#posts, 1)
	t.same(posts[1][2], { bag = 0, slot = 1 })
	t.eq(posts[1][3], 2, '24 hours')
	t.eq(posts[1][4], 20, 'every unit carried')
	t.eq(posts[1][5], row.verdict.price)
	t.truthy(addon.window.footerText:GetText():find('Posted 20'))
	t.same(addon.errors, {})
end)

t.test('a losing price needs a second click; the client warning a third', function()
	local game, addon = start()
	carry(game, 1, WOOL, 20)
	game.auctionHouse.commodities[WOOL] = true
	game.auctionHouse.deposit = 2000000
	game.auctionHouse.needsConfirm = true
	openAuctionHouse(game)
	addon.window:Open('sell')
	local sell = container(addon, 'sell')
	t.truthy(sell.state.rows[1].verdict.isLoss, 'the deposit eats the sale')
	sell.postButton:Click()
	t.eq(#game.auctionHouse.calls, 0, 'first click only arms')
	t.truthy(sell.postButton.label:GetText():find('loss'))
	sell.postButton:Click()
	t.eq(#callsNamed(game, 'PostCommodity'), 1)
	t.eq(sell.state.armed, 'clientWarning')
	sell.postButton:Click()
	t.eq(#callsNamed(game, 'ConfirmPostCommodity'), 1)
	t.eq(sell.state.armed, nil)
end)

t.test('guardrail off posts a loss in one click', function()
	local game, addon = start()
	addon.host.Settings:Set('window', 'guardrail', 'off')
	carry(game, 1, WOOL, 20)
	game.auctionHouse.commodities[WOOL] = true
	game.auctionHouse.deposit = 2000000
	openAuctionHouse(game)
	addon.window:Open('sell')
	container(addon, 'sell').postButton:Click()
	t.eq(#callsNamed(game, 'PostCommodity'), 1)
end)

t.test('an item that moved is not posted and says why', function()
	local game, addon = start()
	carry(game, 1, SWORD, 1)
	openAuctionHouse(game)
	addon.window:Open('sell')
	game.containerItems['0:1'] = nil
	container(addon, 'sell').postButton:Click()
	t.eq(#game.auctionHouse.calls, 0)
	t.truthy(addon.window.footerText:GetText():find('item moved'))
end)

t.test('posting is refused in combat', function()
	local game, addon = start()
	carry(game, 1, SWORD, 1)
	openAuctionHouse(game)
	addon.window:Open('sell')
	game.inCombat = true
	container(addon, 'sell').postButton:Click()
	t.eq(#callsNamed(game, 'PostItem'), 0)
	t.truthy(addon.window.footerText:GetText():find('combat'))
end)

t.group('buy tab')

t.test('buys an item auction from a live search: arm, then confirm', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.state.rows = { { itemId = SWORD, unitPrice = 9000, units = 1 } }
	buy.state.selected = 1
	addon.window:Refresh()
	buy.liveButton:Click()
	t.same(callsNamed(game, 'SendSearchQuery')[1], { 'SendSearchQuery', SWORD })
	game.auctionHouse.itemResults = {
		{ auctionID = 77, buyoutAmount = 9000, quantity = 1 },
		{ auctionID = 78, buyoutAmount = 8000, quantity = 1, containsOwnerItem = true },
	}
	game:Fire('ITEM_SEARCH_RESULTS_UPDATED')
	t.eq(#buy.state.live, 1, 'own auctions left out')
	buy.liveButtons[1]:Click()
	t.eq(#callsNamed(game, 'PlaceBid'), 0, 'the first click only arms')
	t.truthy(buy.liveButtons[1].label:GetText():find('^Confirm: buy 1'))
	buy.liveButtons[1]:Click()
	t.same(callsNamed(game, 'PlaceBid')[1], { 'PlaceBid', 77, 9000 })
	t.same(addon.errors, {})
end)

t.test('a commodity buy starts, waits for the price, then confirms', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.state.rows = { { itemId = LINEN, unitPrice = 90, units = 50 } }
	buy.state.selected = 1
	addon.window:Refresh()
	buy.liveButton:Click()
	game.auctionHouse.commodityResults = {
		{ auctionID = 1, unitPrice = 90, quantity = 3 },
		{ auctionID = 2, unitPrice = 95, quantity = 10 },
	}
	game:Fire('COMMODITY_SEARCH_RESULTS_UPDATED')
	buy.quantityPicker.forward:Click()
	t.truthy(buy.buyButton.label:GetText():find('Buy 5'))
	buy.buyButton:Click()
	t.same(callsNamed(game, 'StartCommoditiesPurchase')[1], { 'StartCommoditiesPurchase', LINEN, 5 })
	t.eq(buy.buyButton:IsEnabled(), false, 'waits for the server price')
	buy.buyButton:Click()
	t.eq(#callsNamed(game, 'ConfirmCommoditiesPurchase'), 0)
	game:Fire('COMMODITY_PRICE_UPDATED', 100, 500)
	t.truthy(buy.buyButton.label:GetText():find('dearer'), '500 is over the 460 listed')
	buy.buyButton:Click()
	t.same(callsNamed(game, 'ConfirmCommoditiesPurchase')[1], { 'ConfirmCommoditiesPurchase', LINEN, 5 })
	game:Fire('COMMODITY_PURCHASE_SUCCEEDED')
	t.eq(buy.state.purchase, nil)
	t.same(addon.errors, {})
end)

t.test('away from the auction house nothing can be bought', function()
	local _, addon = start()
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	t.eq(buy.liveButton:IsEnabled(), false)
	t.eq(buy.buyButton:IsEnabled(), false)
end)

t.group('other tabs')

t.test('every tab opens and refreshes without errors', function()
	local game, addon = start()
	carry(game, 1, LINEN, 20)
	for _, key in ipairs({ 'scan', 'lookup', 'rules', 'sell', 'buy' }) do
		addon.host.RunCommand('open ' .. key)
		t.truthy(container(addon, key):IsShown(), key)
	end
	addon.window:Refresh()
	openAuctionHouse(game)
	t.same(addon.errors, {})
	t.same(addon.host.RunCommand('open nope'), { 'No tab called nope.' })
end)

t.test('lookup shows every rule for an item id', function()
	local _, addon = start()
	addon.window:Open('lookup')
	local lookup = container(addon, 'lookup')
	lookup.input:Submit(tostring(LINEN))
	t.eq(lookup.itemId, LINEN)
	t.truthy(lookup.title:GetText():find('Linen'))
	t.truthy(#linesText(lookup.lines) > 0)
end)

t.test('rules: copy to new and save adds a rule; set as default sends the message', function()
	local _, addon = start()
	addon.window:Open('rules')
	local rules = container(addon, 'rules')
	local before = #addon.prices:Rules()
	rules.copyButton:Click()
	rules.saveButton:Click()
	t.eq(#addon.prices:Rules(), before + 1)
	local changed
	addon.host.Bus:Listen('test', 'DEFAULT_RULE_CHANGED', function(_, ruleId)
		changed = ruleId
	end)
	rules.defaultButton:Click()
	t.eq(changed, addon.prices:DefaultRule())
	t.same(addon.errors, {})
end)

t.group('wow auction house wrappers')

local function newWow()
	local game = FakeGame.new({ now = NOW, itemInfo = ITEM_INFO })
	game.bagSlots[0] = 16
	return game, ns.Wow.create(game.env)
end

t.test('sellable item: says why not', function()
	local game, wow = newWow()
	carry(game, 1, SWORD, 1)
	game.auctionHouse.unsellable[SWORD] = true
	t.same({ wow:SellableItem(0, 1, SWORD) }, { nil, 'cannot be auctioned' })
	t.same({ wow:SellableItem(0, 1, LINEN) }, { nil, 'item moved' })
	game.auctionHouse.unsellable[SWORD] = nil
	local sellable = wow:SellableItem(0, 1, SWORD)
	t.eq(sellable.isCommodity, false)
	t.eq(wow:AuctionDeposit(sellable, 2, 1), 100)
	game.env.C_AuctionHouse.PostItem = nil
	t.same({ wow:SellableItem(0, 1, SWORD) }, { nil, 'no auction house' })
end)

t.test('post: a bad duration is a programmer error', function()
	local game, wow = newWow()
	carry(game, 1, SWORD, 1)
	local sellable = wow:SellableItem(0, 1, SWORD)
	t.raises(function()
		wow:PostAuction(sellable, 4, 1, 100)
	end, 'duration')
	t.eq(wow:PostAuction(sellable, 1, 1, 100), 'posted')
	t.same(game.auctionHouse.calls[1], { 'PostItem', { bag = 0, slot = 1 }, 1, 1, nil, 100 })
end)

t.test('search results: own listings flagged, items sorted by unit price', function()
	local game, wow = newWow()
	game.auctionHouse.itemResults = {
		{ auctionID = 1, buyoutAmount = 900, quantity = 3 },
		{ auctionID = 2, buyoutAmount = 500, quantity = 1, containsOwnerItem = true },
		{ auctionID = 3, quantity = 1 },
	}
	local results = wow:SearchResults(SWORD)
	t.eq(#results, 2, 'bid-only listings left out')
	t.eq(results[1].auctionId, 1)
	t.eq(results[1].unitPrice, 300)
	t.eq(results[2].isOwn, true)
	game.auctionHouse.commodityResults = { { auctionID = 9, unitPrice = 50, quantity = 20, numOwnerItems = 0 } }
	t.same(wow:SearchResults(LINEN), {
		{ auctionId = 9, unitPrice = 50, quantity = 20, isOwn = false, isCommodity = true },
	})
end)

t.test('buying is refused in combat', function()
	local game, wow = newWow()
	game.inCombat = true
	t.eq(wow:BuyAuction(1, 100), false)
	t.eq(wow:ConfirmCommodityPurchase(LINEN, 5), false)
	t.eq(#game.auctionHouse.calls, 0)
end)

-- Review fixes (step 4) -------------------------------------------------------------------

t.group('window placement')

local function blizzardEdges(game, left, right, screenWidth)
	game.env.UIParent:SetSize(screenWidth, 1080)
	game.env.AuctionHouseFrame.left, game.env.AuctionHouseFrame.right = left, right
end

t.test('takeover cannot be dragged aside; dock can', function()
	local game, addon = start()
	openAuctionHouse(game)
	local frame = addon.window.frame
	t.truthy(frame.isClampedToScreen)
	frame.scripts.OnDragStart(frame)
	t.eq(frame.isMoving, nil, 'Blizzard stays covered')
	closeAuctionHouse(game)
	game.loadedAddOns.TradeSkillMaster = true
	openAuctionHouse(game)
	frame.scripts.OnDragStart(frame)
	t.eq(frame.isMoving, true)
end)

t.test('dock falls back to the left, then the centre, when the right has no room', function()
	local game, addon = start()
	game.loadedAddOns.TradeSkillMaster = true
	blizzardEdges(game, 960, 1700, 1920)
	openAuctionHouse(game)
	local point = addon.window.frame.points[1]
	t.same({ point[1], point[2], point[3] }, { 'TOPRIGHT', game.env.AuctionHouseFrame, 'TOPLEFT' })
	closeAuctionHouse(game)
	blizzardEdges(game, 100, 900, 1280)
	openAuctionHouse(game)
	point = addon.window.frame.points[1]
	t.same({ point[1], point[2], point[3] }, { 'CENTER', game.env.UIParent, 'CENTER' })
end)

t.test('a dragged position is kept per mode and used next time', function()
	local game, addon = start()
	game.loadedAddOns.TradeSkillMaster = true
	openAuctionHouse(game)
	local frame = addon.window.frame
	frame:ClearAllPoints()
	frame:SetPoint('TOPLEFT', game.env.UIParent, 'TOPLEFT', 100, -50)
	frame.scripts.OnDragStop(frame)
	t.same(addon.store:Ui().windowPositions.dock, { point = 'TOPLEFT', relativePoint = 'TOPLEFT', x = 100, y = -50 })
	t.eq(addon.store:Ui().windowPositions.away, nil, 'only the mode it was dragged in')
	closeAuctionHouse(game)
	openAuctionHouse(game)
	t.same(frame.points[1], { 'TOPLEFT', game.env.UIParent, 'TOPLEFT', 100, -50 })
end)

t.test('hiding and showing the interface puts the takeover back', function()
	local game, addon = start()
	openAuctionHouse(game)
	local blizzard = game.env.AuctionHouseFrame
	addon.window.frame:Hide()
	t.eq(blizzard:GetAlpha(), 1, 'hidden with the interface: Blizzard back')
	addon.window.frame:Show()
	t.eq(blizzard:GetAlpha(), 0, 'shown again: covered again')
	addon.window:Close()
	addon.window.frame:Show()
	t.eq(blizzard:GetAlpha(), 1, 'closed by the player: stays Blizzard')
end)

t.test('the auction house event before its window shows: placed once the window shows', function()
	local game, addon = start()
	local blizzard = game.env.AuctionHouseFrame
	blizzard:Hide()
	game:Fire('AUCTION_HOUSE_SHOW')
	t.eq(addon.window:IsOpen(), false, 'waits for the window')
	blizzard:Show()
	t.truthy(addon.window:IsOpen())
	t.eq(blizzard:GetAlpha(), 0, 'took over')
	game:RunTimers()
	t.same(addon.errors, {})
end)

t.test('the next-frame fallback opens; the window showing later still takes over', function()
	local game, addon = start()
	local blizzard = game.env.AuctionHouseFrame
	blizzard:Hide()
	game:Fire('AUCTION_HOUSE_SHOW')
	game:RunTimers()
	t.truthy(addon.window:IsOpen())
	t.eq(addon.window.placedAs, 'away')
	blizzard:Show()
	t.eq(addon.window.placedAs, 'takeover')
	t.eq(blizzard:GetAlpha(), 0)
end)

t.test('the footer credits AHledger only for a view with an AHledger figure', function()
	local _, addon = start()
	addon.window:Open('lookup')
	t.eq(addon.window.creditText:IsShown(), false, 'nothing looked up')
	container(addon, 'lookup').input:Submit(tostring(LINEN))
	t.truthy(addon.window.creditText:IsShown())
	addon.window:Open('scan')
	t.eq(addon.window.creditText:IsShown(), false)
end)

t.test('the footer falls back to the default credit when the source gives none', function()
	local _, addon = start()
	addon.prices.SourceStatus = function()
		return { credit = nil }
	end
	addon.window:Open('lookup')
	container(addon, 'lookup').input:Submit(tostring(LINEN))
	t.eq(addon.window.creditText:GetText(), addon.PriceData.DEFAULT_CREDIT)
	t.truthy(addon.window.creditText:IsShown())
end)

-- Records the keepsPage argument of each SetLines call on a tab's paged lines.
local function spyKeepsPage(lines)
	local calls = {}
	local setLines = lines.SetLines
	lines.SetLines = function(self, list, keepsPage)
		calls[#calls + 1] = keepsPage == true
		return setLines(self, list, keepsPage)
	end
	return calls
end

t.test('redrawing the same item keeps the page; another item starts on the first', function()
	local game, addon = start()
	carry(game, 1, LINEN, 20)
	carry(game, 2, WOOL, 20)

	addon.window:Open('lookup')
	local lookup = container(addon, 'lookup')
	local lookupCalls = spyKeepsPage(lookup.lines)
	lookup.input:Submit(tostring(LINEN))
	lookup.input:Submit(tostring(LINEN))
	lookup.input:Submit(tostring(WOOL))
	t.same(lookupCalls, { false, true, false }, 'lookup')

	addon.window:Open('sell')
	local sell = container(addon, 'sell')
	local sellCalls = spyKeepsPage(sell.lines)
	addon.window:Refresh()
	t.eq(sellCalls[#sellCalls], true, 'sell: the same row redrawn')
	sell.rowButtons[sell.state.selected == 1 and 2 or 1]:Click()
	t.eq(sellCalls[#sellCalls], false, 'sell: another item')

	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.state.rows = { { itemId = SWORD, unitPrice = 9000, units = 1 }, { itemId = LINEN, unitPrice = 90, units = 5 } }
	buy.state.selected = 1
	local buyCalls = spyKeepsPage(buy.lines)
	addon.window:Refresh()
	addon.window:Refresh()
	buy.state.selected = 2
	addon.window:Refresh()
	t.same({ buyCalls[#buyCalls - 2], buyCalls[#buyCalls - 1], buyCalls[#buyCalls] }, { false, true, false }, 'buy')
	t.same(addon.errors, {})
end)

t.group('wow events')

t.test('an event the client does not have is refused, not raised', function()
	local game, addon = start()
	game.unknownEvents.NOT_AN_EVENT = true
	local isRegistered, reason = addon.wow:OnEvent('NOT_AN_EVENT', function() end, 'test')
	t.eq(isRegistered, false)
	t.truthy(reason:find('unknown event'))
	t.eq(addon.wow:OnEvent('BAG_UPDATE_DELAYED', function() end, 'test'), true)
end)

t.group('sell tab selection')

local function rowIndexOf(sell, itemId)
	for index, row in ipairs(sell.state.rows) do
		if row.itemId == itemId then
			return index
		end
	end
	return nil
end

t.test('the selection follows the item through a reload and keeps its stepped price', function()
	local game, addon = start()
	carry(game, 1, LINEN, 20)
	carry(game, 2, SWORD, 1)
	carry(game, 3, WOOL, 20)
	openAuctionHouse(game)
	addon.window:Open('sell')
	local sell = container(addon, 'sell')
	t.eq(#sell.state.rows, 3)
	-- The middle row: an item above it goes, one stays below, so the index alone would land on
	-- the wrong item.
	local itemId = sell.state.rows[2].itemId
	local aboveItemId = sell.state.rows[1].itemId
	local belowItemId = sell.state.rows[3].itemId
	sell.rowButtons[2]:Click()
	sell.pricePicker.forward:Click()
	local stepped = sell.state.priceOverride
	t.truthy(stepped)
	for slot = 1, 3 do
		local item = game.containerItems['0:' .. slot]
		if item and item.itemID == aboveItemId then
			game.containerItems['0:' .. slot] = nil
		end
	end
	game:Fire('BAG_UPDATE_DELAYED')
	t.eq(#sell.state.rows, 2)
	t.eq(sell.state.rows[2].itemId, belowItemId, 'a row still below the selection')
	t.eq(sell.state.selected, 1)
	t.eq(sell.state.rows[sell.state.selected].itemId, itemId, 'same item, new index')
	t.eq(sell.state.priceOverride, stepped)
	sell.rowButtons[2]:Click()
	t.eq(sell.state.priceOverride, nil, 'another item drops the stepped price')
end)

t.test('the client warning is dropped on another item and when the auction house closes', function()
	local game, addon = start()
	carry(game, 1, WOOL, 20)
	carry(game, 2, SWORD, 1)
	game.auctionHouse.commodities[WOOL] = true
	game.auctionHouse.deposit = 2000000
	game.auctionHouse.needsConfirm = true
	openAuctionHouse(game)
	addon.window:Open('sell')
	local sell = container(addon, 'sell')
	local wool = assert(rowIndexOf(sell, WOOL))
	sell.rowButtons[wool]:Click()
	sell.postButton:Click()
	sell.postButton:Click()
	t.eq(sell.state.armed, 'clientWarning')
	sell.rowButtons[wool == 1 and 2 or 1]:Click()
	t.eq(sell.state.armed, nil, 'another item')
	sell.rowButtons[assert(rowIndexOf(sell, WOOL))]:Click()
	sell.postButton:Click()
	sell.postButton:Click()
	t.eq(sell.state.armed, 'clientWarning')
	closeAuctionHouse(game)
	t.eq(sell.state.armed, nil, 'auction house closed')
	openAuctionHouse(game)
	sell.postButton:Click()
	t.eq(#callsNamed(game, 'ConfirmPostCommodity'), 0, 'no confirm of a post from before')
end)

t.test('the sell rule picker keeps the rule by id', function()
	local game, addon = start()
	carry(game, 1, LINEN, 20)
	addon.window:Open('sell')
	local sell = container(addon, 'sell')
	t.eq(sell.state.ruleId, nil, 'the default')
	sell.rulePicker.forward:Click()
	t.eq(sell.state.ruleId, addon.prices:Rules()[2].id)
	t.truthy(sell.rulePicker.value:GetText():find(addon.prices:Rules()[2].name, 1, true))
end)

t.group('buy tab review')

t.test('opening Buy prices nothing until a search', function()
	local _, addon = start()
	local asked = 0
	local get = addon.prices.Get
	addon.prices.Get = function(...)
		asked = asked + 1
		return get(...)
	end
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	t.same(buy.state.rows, {})
	t.eq(asked, 0)
	t.eq(buy.state.hasSearched, nil)
	t.eq(buy.pager.value:GetText():find('Page'), nil)
	addon.prices.Get = get
end)

t.test('a live listing far above the rule price says so', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.state.rows = { { itemId = SWORD, unitPrice = 9000, units = 1, rulePrice = 3000 } }
	buy.state.selected = 1
	addon.window:Refresh()
	buy.liveButton:Click()
	game.auctionHouse.itemResults = { { auctionID = 77, buyoutAmount = 9000, quantity = 1 } }
	game:Fire('ITEM_SEARCH_RESULTS_UPDATED')
	t.truthy(buy.liveButtons[1].label:GetText():find('3.0x the rule price'))
end)

t.test('a commodity price update after Confirm changes nothing', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.state.rows = { { itemId = LINEN, unitPrice = 90, units = 50, rulePrice = 40 } }
	buy.state.selected = 1
	addon.window:Refresh()
	buy.liveButton:Click()
	game.auctionHouse.commodityResults = { { auctionID = 1, unitPrice = 90, quantity = 3 } }
	game:Fire('COMMODITY_SEARCH_RESULTS_UPDATED')
	buy.buyButton:Click()
	game:Fire('COMMODITY_PRICE_UPDATED', 100, 100)
	t.truthy(buy.buyButton.label:GetText():find('2.5x the rule price'))
	buy.buyButton:Click()
	t.eq(#callsNamed(game, 'ConfirmCommoditiesPurchase'), 1)
	game:Fire('COMMODITY_PRICE_UPDATED', 999, 999)
	t.eq(buy.state.purchase.isSent, true)
	t.eq(buy.state.purchase.total, nil, 'a sent purchase takes no new total')
	buy.buyButton:Click()
	t.eq(#callsNamed(game, 'ConfirmCommoditiesPurchase'), 1, 'nothing to confirm twice')
end)

t.group('lookup review')

t.test('a name search reads only names already seen and asks the client for nothing', function()
	local game, addon = start()
	addon.window:Open('lookup')
	local lookup = container(addon, 'lookup')
	local before = #game.itemDataRequests
	lookup.input:Submit('linen')
	t.eq(lookup.itemId, nil, 'not seen yet')
	t.truthy(addon.window.footerText:GetText():find('seen this session'))
	t.eq(#game.itemDataRequests, before)
	addon.prices:ItemInfo(LINEN)
	lookup.input:Submit('linen')
	t.eq(lookup.itemId, LINEN)
end)

t.test('lookup lines page instead of cutting off', function()
	local _, addon = start()
	local ui = addon.Widgets.new(addon.wow, addon.theme)
	local parent = addon.wow:CreateFrame('Frame', addon.wow:Global('UIParent'))
	local paged = ui:PagedLines(parent, 3, 13, 400)
	local list = {}
	for index = 1, 7 do
		list[index] = { text = 'line ' .. index }
	end
	paged:SetLines(list)
	t.eq(paged.strings[1]:GetText(), 'line 1')
	t.truthy(paged.pager:IsShown())
	t.eq(paged.pager.value:GetText(), 'Lines 1-3 of 7')
	paged:Scroll(1)
	paged:Scroll(1)
	t.eq(paged.strings[1]:GetText(), 'line 5')
	t.eq(paged.pager.value:GetText(), 'Lines 5-7 of 7')
	paged:SetLines({ { text = 'one' } })
	t.eq(paged.pager:IsShown(), false)
end)

t.test('a shift-clicked item fills the focused Lookup box and looks it up', function()
	local game, addon = start()
	-- The chat box takes a link only while it is open; here it never is. The window hooks the
	-- function when it is switched on, so it is switched on again once the function exists.
	game.env.ChatEdit_InsertLink = function()
		return false
	end
	addon.host.Disable('window')
	addon.host.Enable('window')
	addon.window:Open('lookup')
	local lookup = container(addon, 'lookup')
	game.env.ChatEdit_InsertLink('|Hitem:2589::|h[Linen Cloth]|h')
	t.eq(lookup.itemId, nil, 'no focus: chat keeps the link')
	lookup.input:SetFocus()
	game.env.ChatEdit_InsertLink('|Hitem:2589::|h[Linen Cloth]|h')
	t.eq(lookup.itemId, LINEN)
	t.same(addon.errors, {})
end)

t.group('widgets review')

t.test('a button shrinks to a shorter label but not under a set width', function()
	local _, addon = start()
	local ui = addon.Widgets.new(addon.wow, addon.theme)
	local parent = addon.wow:CreateFrame('Frame', addon.wow:Global('UIParent'))
	local button = ui:Button(parent, 'A rather long label for a button', 'secondary')
	local wide = button:GetWidth()
	button:SetLabel('OK')
	t.truthy(button:GetWidth() < wide)
	button:SetWidth(200)
	button:SetLabel('X')
	t.eq(button:GetWidth(), 200)
end)

t.test('the window title and a detail title read the heading face; body text does not', function()
	local game, addon = start()
	carry(game, 1, LINEN, 20)
	addon.host.RunCommand('open sell')
	local heading = addon.theme:Face('font.face.heading')
	t.eq(addon.window.titleText.font[1], addon.theme:Face('window.titleFace'))
	t.eq(container(addon, 'sell').title.font[1], heading)
	t.truthy(addon.window.modeText.font[1] ~= heading, 'the mode line is body text')
end)

t.group('rules review')

t.test('saving or deleting a rule sends RULES_CHANGED; delete asks for a second click', function()
	local _, addon = start()
	addon.window:Open('rules')
	local rules = container(addon, 'rules')
	local sent = {}
	addon.host.Bus:Listen('test', 'RULES_CHANGED', function(_, ruleId)
		sent[#sent + 1] = ruleId
	end)
	local before = #addon.prices:Rules()
	rules.copyButton:Click()
	rules.saveButton:Click()
	t.eq(#sent, 1)
	local saved = addon.prices:Rules()[rules.state.ruleIndex]
	t.eq(saved.id, sent[1])
	rules.deleteButton:Click()
	t.eq(#addon.prices:Rules(), before + 1, 'first click only asks')
	t.truthy(rules.deleteButton.label:GetText():find('Click again'))
	rules.rulePicker.forward:Click()
	rules.rulePicker.back:Click()
	t.eq(rules.deleteButton.label:GetText(), 'Delete', 'moving away drops the ask')
	rules.deleteButton:Click()
	rules.deleteButton:Click()
	t.eq(#addon.prices:Rules(), before)
	t.eq(sent[2], saved.id)
	t.same(addon.errors, {})
end)

t.test('bags repaint on a rules change', function()
	local game, addon = start()
	game:RunTimers()
	local waiting = #game.timers
	addon.host.Bus:Send('RULES_CHANGED', 'x')
	t.eq(#game.timers, waiting + 1)
	game:RunTimers()
	addon.host.Bus:Send('DEFAULT_RULE_CHANGED', 'x')
	t.eq(#game.timers, waiting + 1)
end)

t.group('step 4 follow-up')

local SILK = 4306

local function saveSnapshot(items)
	return function(started)
		started.ScanStore.save(
			started.store:Market(MARKET),
			{ at = NOW - 60, source = 'own', count = 3, items = items }
		)
	end
end

local SNAPSHOT_ITEMS = {
	[LINEN] = { min = 60, units = 400, levels = { { price = 60, qty = 400 } } },
	[SWORD] = { min = 400, units = 1, levels = { { price = 400, qty = 1 } } },
	[SILK] = { min = 50, units = 10, levels = { { price = 50, qty = 10 } } },
}

t.test('a Buy search prices from cached item info; only the names shown are read', function()
	local game, addon = start(saveSnapshot(SNAPSHOT_ITEMS))
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	local requestsBefore = #game.itemDataRequests
	-- Each step may read the names of the rows it shows, and nothing else.
	local function expectOnlyShownNamesRead(step)
		local missesBefore = #game.itemInfoMisses
		step()
		local shown = {}
		for _, row in ipairs(buy.state.rows) do
			shown[row.itemId] = true
		end
		for index = missesBefore + 1, #game.itemInfoMisses do
			t.truthy(shown[game.itemInfoMisses[index]], 'an uncached item read only for its shown name')
		end
	end
	expectOnlyShownNamesRead(function()
		buy.input:Submit('')
	end)
	t.eq(#buy.state.rows, 3, 'every scanned item, uncached silk too')
	expectOnlyShownNamesRead(function()
		buy.discountPicker.forward:Click()
	end)
	expectOnlyShownNamesRead(function()
		buy.vendorPicker.forward:Click()
	end)
	expectOnlyShownNamesRead(function()
		buy.input:Submit('silk')
	end)
	t.eq(#game.itemDataRequests, requestsBefore, 'no item data requested')
	t.same(addon.errors, {})
end)

t.test('a capped discount search says to narrow it', function()
	local _, addon = start(saveSnapshot(SNAPSHOT_ITEMS))
	local cap = addon.Buy.MAX_FILTERED_CANDIDATES
	addon.Buy.MAX_FILTERED_CANDIDATES = 2
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.discountPicker.forward:Click()
	t.eq(buy.state.isCapped, true)
	t.truthy(addon.window.footerText:GetText():find('narrow your search'))
	addon.Buy.MAX_FILTERED_CANDIDATES = cap
end)

t.test('the Buy detail shows the row lines and credits AHledger only for its figure', function()
	local _, addon = start()
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.state.rows = {
		{ itemId = LINEN, unitPrice = 60, units = 400, rulePrice = 120, usesPriceSource = true },
		{ itemId = SILK, unitPrice = 50, units = 10, ruleReason = 'no market price' },
	}
	buy.state.selected = 1
	addon.window:Refresh()
	t.truthy(linesText(buy.lines):find('Last scan: 400'))
	t.truthy(linesText(buy.lines):find('Rule price: '))
	t.truthy(addon.window.creditText:IsShown())
	t.eq(addon.window.creditText:GetText(), addon.window:Credit())
	buy.state.selected = 2
	addon.window:Refresh()
	t.truthy(linesText(buy.lines):find('Rule price: unknown'))
	t.eq(addon.window.creditText:IsShown(), false)
end)

t.test('Sell credits AHledger only for a price from it', function()
	local game, addon = start()
	game.itemInfo[SILK] = { name = 'Silk Cloth', maxStack = 20, vendorPrice = 38 }
	carry(game, 1, LINEN, 20)
	carry(game, 2, SILK, 20)
	addon.window:Open('sell')
	local sell = container(addon, 'sell')
	sell.rowButtons[assert(rowIndexOf(sell, LINEN))]:Click()
	t.truthy(addon.window.creditText:IsShown())
	t.eq(addon.window.creditText:GetText(), addon.window:Credit())
	sell.rowButtons[assert(rowIndexOf(sell, SILK))]:Click()
	t.eq(addon.window.creditText:IsShown(), false, 'no AHledger row, no scan')
end)

t.test('a live listing without an auction id is left out and cannot be bought', function()
	local game, addon = start()
	openAuctionHouse(game)
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	buy.state.rows = { { itemId = SWORD, unitPrice = 9000, units = 1 } }
	buy.state.selected = 1
	addon.window:Refresh()
	buy.liveButton:Click()
	game.auctionHouse.itemResults = {
		{ buyoutAmount = 8000, quantity = 1 },
		{ auctionID = 77, buyoutAmount = 9000, quantity = 1 },
	}
	game:Fire('ITEM_SEARCH_RESULTS_UPDATED')
	t.eq(#buy.state.live, 1)
	t.eq(buy.state.live[1].auctionId, 77)
	buy.state.live = { { unitPrice = 8000, buyout = 8000, units = 1, quantity = 1 } }
	addon.window:Refresh()
	buy.liveButtons[1]:Click()
	buy.liveButtons[1]:Click()
	t.eq(#callsNamed(game, 'PlaceBid'), 0, 'no id, no buy')
end)

t.test('a failed lookup clears the item shown; the credit is the window credit', function()
	local game, addon = start()
	game.itemInfo[SILK] = { name = 'Silk Cloth', maxStack = 20, vendorPrice = 38 }
	addon.window:Open('lookup')
	local lookup = container(addon, 'lookup')
	lookup.input:Submit(tostring(LINEN))
	t.eq(addon.window.creditText:GetText(), addon.window:Credit())
	lookup.input:Submit('no such thing')
	t.eq(lookup.itemId, nil)
	t.eq(lookup.title:GetText(), '')
	t.truthy(linesText(lookup.lines):match('^%s*$'), 'no lines')
	t.eq(addon.window.creditText:IsShown(), false)
	lookup.input:Submit(tostring(SILK))
	t.eq(lookup.itemId, SILK)
	t.eq(addon.window.creditText:IsShown(), false, 'no AHledger figure for silk')
end)

t.test('a shift-clicked item fills the Buy box only while it has focus and the window is open', function()
	local game, addon = start(saveSnapshot(SNAPSHOT_ITEMS))
	game.env.ChatEdit_InsertLink = function()
		return false
	end
	addon.host.Disable('window')
	addon.host.Enable('window')
	addon.window:Open('buy')
	local buy = container(addon, 'buy')
	local link = '|Hitem:2589::|h[Linen Cloth]|h'
	game.env.ChatEdit_InsertLink(link)
	t.eq(buy.input:GetText(), '', 'no focus')
	buy.input:SetFocus()
	addon.window:Close()
	game.env.ChatEdit_InsertLink(link)
	t.eq(buy.input:GetText(), '', 'window closed')
	addon.window:Open('buy')
	buy.input:SetFocus()
	game.env.ChatEdit_InsertLink(link)
	t.eq(buy.input:GetText(), 'Linen Cloth')
	t.eq(buy.state.hasSearched, true)
	t.same(addon.errors, {})
end)

t.test('lines keep their page for the same item and start over for a new one', function()
	local _, addon = start()
	local ui = addon.Widgets.new(addon.wow, addon.theme)
	local parent = addon.wow:CreateFrame('Frame', addon.wow:Global('UIParent'))
	local paged = ui:PagedLines(parent, 3, 13, 400)
	local list = {}
	for index = 1, 7 do
		list[index] = { text = 'line ' .. index }
	end
	paged:SetLines(list)
	paged:Scroll(1)
	t.eq(paged.strings[1]:GetText(), 'line 4')
	paged:SetLines(list, true)
	t.eq(paged.strings[1]:GetText(), 'line 4', 'same item: same page')
	paged:SetLines({ list[1], list[2], list[3], list[4] }, true)
	t.eq(paged.strings[1]:GetText(), 'line 2', 'a shorter list clamps to its last page')
	paged:SetLines(list)
	t.eq(paged.strings[1]:GetText(), 'line 1', 'new item: page one')
end)

t.test('Edit, Copy, Save, Set default and coming back to the tab drop an armed Delete', function()
	local _, addon = start()
	addon.window:Open('rules')
	local rules = container(addon, 'rules')
	local function armDelete()
		rules.deleteButton:Click()
		t.truthy(rules.deleteButton.label:GetText():find('Click again'))
	end
	armDelete()
	rules.editButton:Click()
	t.eq(rules.state.deleteArmedFor, nil, 'edit')
	rules.editor = nil
	armDelete()
	rules.copyButton:Click()
	t.eq(rules.state.deleteArmedFor, nil, 'copy')
	armDelete()
	rules.saveButton:Click()
	t.eq(rules.state.deleteArmedFor, nil, 'save')
	armDelete()
	rules.defaultButton:Click()
	t.eq(rules.state.deleteArmedFor, nil, 'set default')
	armDelete()
	addon.window:Open('scan')
	addon.window:Open('rules')
	t.eq(rules.deleteButton.label:GetText(), 'Delete', 'back on the tab')
	t.same(addon.errors, {})
end)
