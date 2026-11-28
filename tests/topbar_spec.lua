local t = ...
local FakeGame = require('tests.fake_game')

local ns = t.loadAddon()
local Model = ns.TopBarModel

local NOW = 1774742400
local LIB_FILES = {
	'Libs/LibStub/LibStub.lua',
	'Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua',
	'Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua',
}

-- The bundled libraries, loaded as the client would, into their own globals.
local function loadLibraries(env)
	local libEnv = setmetatable({}, { __index = _G })
	libEnv._G = libEnv
	libEnv.strmatch = string.match
	libEnv.securecallfunction = function(fn, ...)
		return fn(...)
	end
	for _, path in ipairs(LIB_FILES) do
		local chunk = assert(loadfile(path))
		setfenv(chunk, libEnv)
		chunk()
	end
	env.LibStub = libEnv.LibStub
	return libEnv.LibStub
end

local function start(options)
	options = options or {}
	local game = FakeGame.new({ now = NOW })
	game.money = options.money or 123456
	local libStub = options.withLibraries and loadLibraries(game.env) or nil
	local addon = FakeGame.startAddon(t, game, options.beforeStart)
	return game, addon, libStub
end

local function bar(game)
	return game.env.HagglerTopBar
end

-- Model -----------------------------------------------------------------------------------

t.test('visibility: always, only at a market, or hidden', function()
	t.eq(Model.isShown('always', {}), true)
	t.eq(Model.isShown('hidden', { auctionHouse = true }), false)
	t.eq(Model.isShown('market', {}), false)
	t.eq(Model.isShown('market', { merchant = true }), true)
	t.eq(Model.isShown('market', { mailbox = true }), true)
	t.eq(Model.isShown('market', { auctionHouse = true }), true)
	t.eq(Model.isShown('junk', nil), true)
end)

t.test('gold and signed session profit', function()
	t.eq(Model.goldText(123456, 2550), FakeGame.coins('12g 34s 56c  +25s 50c'))
	t.eq(Model.goldText(100, -50), FakeGame.coins('1s  -50c'))
	t.eq(Model.goldText(nil), '?')
	t.eq(Model.profitText(0 / 0), '?')
end)

t.test('the rule switcher cycles both ways and starts over on an unknown rule', function()
	local ids = { 'a', 'b', 'c' }
	t.eq(Model.nextRule(ids, 'a', 1), 'b')
	t.eq(Model.nextRule(ids, 'c', 1), 'a')
	t.eq(Model.nextRule(ids, 'a', -1), 'c')
	t.eq(Model.nextRule(ids, 'gone', 1), 'a')
	t.eq(Model.nextRule({}, 'a', 1), nil)
end)

t.test('the scan text says the state and the scan age', function()
	t.eq(Model.scanText(nil, NOW), 'Scan: off')
	t.eq(Model.scanText({ state = 'open', lastFullScanAt = NOW - 120 }, NOW), 'Scan: ready · 2 min')
end)

t.test('a fallback session start shows its note in the tooltip', function()
	local lines = Model.profitTooltip(100, 'Since the daily reset', 'daily reset unknown: since UTC midnight')
	t.eq(lines[3], 'Note: daily reset unknown: since UTC midnight')
end)

-- The bar ---------------------------------------------------------------------------------

t.test('the bar shows gold and keeps up with money changes', function()
	local game, addon = start()
	t.truthy(bar(game), 'bar made')
	t.eq(bar(game):IsShown(), true)
	game.money = 50000
	game:Fire('PLAYER_MONEY')
	t.eq(addon.topBar:Texts().gold:find(FakeGame.coins('5g'), 1, true), 1)
	t.same(addon.errors, {})
end)

t.test('market visibility shows the bar only at the auction house, a vendor or a mailbox', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('visibility', 'market')
	t.eq(bar(game):IsShown(), false)
	game:Fire('MERCHANT_SHOW')
	t.eq(bar(game):IsShown(), true)
	game:Fire('MERCHANT_CLOSED')
	t.eq(bar(game):IsShown(), false)
	game:Fire('MAIL_SHOW')
	t.eq(bar(game):IsShown(), true)
	addon.host.Module('topbar'):SetSetting('visibility', 'hidden')
	t.eq(bar(game):IsShown(), false)
end)

t.test('a hidden bar is never built', function()
	local game = start({
		beforeStart = function(addon)
			addon.store:Settings().topbar = { visibility = 'hidden' }
		end,
	})
	t.eq(bar(game), nil)
end)

t.test('the rule widget moves the default rule and tells the add-on', function()
	local game, addon = start()
	local sent = {}
	addon.host.Bus:Listen('spec', 'DEFAULT_RULE_CHANGED', function(_, ruleId)
		sent[#sent + 1] = ruleId
	end)
	local before = addon.store:DefaultRuleId()
	local ids = addon.store:RuleIds()
	addon.topBar.buttons.rule:Click()
	local expected = Model.nextRule(ids, before, 1)
	t.eq(addon.store:DefaultRuleId(), expected)
	t.same(sent, { expected })
	t.truthy(addon.topBar:Texts().rule:find(addon.store:Rule(expected).name, 1, true), 'bar shows the new rule')
	return game
end)

t.test('switching a widget off takes it off the bar', function()
	local _, addon = start()
	addon.host.Module('topbar'):SetSetting('showScan', false)
	t.eq(addon.topBar.buttons.scan:IsShown(), false)
	addon.host.Module('topbar'):SetSetting('showShortcuts', false)
	t.eq(addon.topBar.shortcuts[1]:IsShown(), false)
	t.eq(#addon.topBar.order, 2)
end)

t.test('a shortcut opens the window on its tab', function()
	local _, addon = start()
	addon.topBar.shortcuts[2]:Click()
	t.eq(addon.window:IsOpen(), true)
	t.eq(addon.window.currentTabKey, 'sell')
end)

t.v2test('the V2 Flips tab adds its shortcut before Settings', function()
	local _, addon = start()
	addon.topBar.shortcuts[3]:Click()
	t.eq(addon.window.currentTabKey, 'flips')
	t.eq(addon.TopBarModel.SHORTCUTS[4].key, 'settings')
end)

t.test('a dragged bar keeps its place', function()
	local game, addon = start()
	local frame = bar(game)
	frame.scripts.OnDragStart(frame)
	frame:ClearAllPoints()
	frame:SetPoint('TOPLEFT', game.env.UIParent, 'TOPLEFT', 40, -10)
	frame.scripts.OnDragStop(frame)
	t.same(addon.store:Ui().topBar, { point = 'TOPLEFT', relativePoint = 'TOPLEFT', x = 40, y = -10 })
end)

t.test('the focus binding gives the bar the pad; B leaves', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	t.truthy(game:PressKey('PADLSHOULDER'), 'focus key bound')
	t.eq(addon.input:HasFocus('topbar'), true)
	t.eq(addon.topBar.order[1].isFocused, true)
	t.truthy(game:PressKey('PADDRIGHT'), 'd-pad bound')
	t.eq(addon.topBar.order[2].isFocused, true)
	t.eq(addon.topBar.order[1].isFocused, false)
	t.truthy(game:PressKey('PAD2'), 'B bound')
	t.eq(addon.input:HasFocus('topbar'), false)
	t.eq(game:PressKey('PADDRIGHT'), false, 'd-pad given back')
	t.eq(game:PressKey('PADLSHOULDER'), true, 'focus key stays')
end)

-- Compares one anchor field by field: a point holds its relative frame, which t.same would walk.
local function expectPoint(region, index, expected)
	local point = { region:GetPoint(index) }
	for field = 1, #expected do
		t.eq(point[field], expected[field], 'point ' .. index .. ' field ' .. field)
	end
end

t.test('the focused widget shows the focus ring outside its edge (ring theme)', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	local first, second = addon.topBar.order[1], addon.topBar.order[2]
	local ring = first.focusRing
	t.truthy(ring and ring:IsShown(), 'the ring shows on the focused widget')
	local reach = 2 + 2 + 1 -- focus.ringWidth + focus.ringOffset + focus.ringGap (Banneret)
	expectPoint(ring, 1, { 'TOPLEFT', first, 'TOPLEFT', -reach, reach })
	expectPoint(ring, 2, { 'BOTTOMRIGHT', first, 'BOTTOMRIGHT', reach, -reach })
	local ringColor = addon.theme:Color('color.focus.ring')
	t.same(ring.edges[1].colorTexture, { ringColor.r, ringColor.g, ringColor.b, ringColor.a })
	t.eq(second.focusRing == nil or not second.focusRing:IsShown(), true, 'one focus only')
	game:PressKey('PADDRIGHT')
	t.eq(ring:IsShown(), false, 'the ring leaves the old widget')
	t.eq(second.focusRing:IsShown(), true, 'and moves to the next')
	game:PressKey('PAD2')
	t.eq(second.focusRing:IsShown(), false, 'leaving clears the ring')
end)

t.test("the focused widget also shows the chevron, its right edge on the widget's left edge", function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	local first, second = addon.topBar.order[1], addon.topBar.order[2]
	local widthBefore = first:GetWidth()
	game:PressKey('PADLSHOULDER')
	local chevron = first.focusChevron
	t.truthy(chevron and chevron:IsShown(), 'the chevron shows on the focused widget')
	t.truthy(first.focusRing and first.focusRing:IsShown(), 'beside the ring')
	expectPoint(chevron, 1, { 'RIGHT', first, 'LEFT', 0, 0 })
	t.eq(chevron.width, 12)
	t.eq(chevron.height, 28)
	t.eq(first:GetWidth(), widthBefore, 'it overhangs: no gutter')
	game:PressKey('PADDRIGHT')
	t.eq(chevron:IsShown(), false, 'the chevron leaves the old widget')
	t.eq(second.focusChevron:IsShown(), true, 'and moves to the next')
	game:PressKey('PAD2')
	t.eq(second.focusChevron:IsShown(), false, 'leaving clears the chevron')
end)

-- Every top-bar widget that shows a focus mark, shown or not.
local function markedWidgets(topBar)
	local marked = {}
	local all = { topBar.buttons.gold, topBar.buttons.rule, topBar.buttons.scan }
	for _, button in ipairs(topBar.shortcuts) do
		all[#all + 1] = button
	end
	for _, button in ipairs(all) do
		local isRingShown = button.focusRing ~= nil and button.focusRing:IsShown()
		local isChevronShown = button.focusChevron ~= nil and button.focusChevron:IsShown()
		if button.isFocused or isRingShown or isChevronShown then
			marked[#marked + 1] = button
		end
	end
	return marked
end

t.test('hiding the bar clears the focus mark, so showing it again shows none', function()
	local game, addon = start()
	local module = addon.host.Module('topbar')
	module:SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	module:SetSetting('visibility', 'hidden')
	module:SetSetting('visibility', 'always')
	t.eq(addon.input:HasFocus('topbar'), false)
	t.eq(#markedWidgets(addon.topBar), 0, 'no mark without the focus')
end)

t.test('switching the module off clears the focus mark, so switching it on shows none', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	addon.host.Disable('topbar')
	addon.host.Enable('topbar')
	t.eq(addon.input:HasFocus('topbar'), false)
	t.eq(#markedWidgets(addon.topBar), 0, 'no mark without the focus')
end)

t.test('switching the focused widget off moves the focus to a shown one, and A presses it', function()
	local game, addon = start()
	local module = addon.host.Module('topbar')
	module:SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	local gold = addon.topBar.buttons.gold
	module:SetSetting('showGold', false)
	local marked = markedWidgets(addon.topBar)
	t.eq(#marked, 1, 'one mark')
	t.eq(marked[1], addon.topBar.order[1], 'on the first shown widget')
	t.eq(gold.isFocused, false, 'the hidden widget keeps no mark')
	local pressed
	marked[1]:OnClick(function()
		pressed = true
	end)
	game:PressKey('PAD1')
	t.eq(pressed, true, 'A presses the marked widget')
	module:SetSetting('showGold', true)
	t.eq(#markedWidgets(addon.topBar), 1, 'showing it again brings no stale mark')
end)

t.test('switching off the widgets after the focus clamps it to the last shown one', function()
	local game, addon = start()
	local module = addon.host.Module('topbar')
	module:SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	game:PressKey('PADDLEFT') -- wraps to the last shortcut
	module:SetSetting('showShortcuts', false)
	local order = addon.topBar.order
	local marked = markedWidgets(addon.topBar)
	t.eq(#marked, 1, 'one mark')
	t.eq(marked[1], order[#order], 'on the last shown widget')
end)

t.test('a disabled widget does not dim its focus mark', function()
	local game, addon = start()
	local ui = addon.Widgets.new(addon.wow, addon.theme)
	local button = ui:Button(game.env.UIParent, 'Scan', 'ghost')
	button:SetEnabled(false)
	button:SetFocused(true)
	t.eq(button:GetEffectiveAlpha(), addon.Widgets.DISABLED_ALPHA, 'the button dims')
	t.eq(button.focusChevron:GetEffectiveAlpha(), 1, 'the chevron does not')
	t.eq(button.focusRing:GetEffectiveAlpha(), 1, 'nor the ring')
end)

t.test('A presses the focused widget', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'CTRL-SHIFT-H')
	game:PressKey('CTRL-SHIFT-H')
	local before = addon.store:DefaultRuleId()
	game:PressKey('PADDRIGHT')
	game:PressKey('PAD1')
	t.truthy(addon.store:DefaultRuleId() ~= before, 'the rule widget ran')
end)

t.test('a binding asked for in combat waits for combat to end', function()
	local game, addon = start()
	game.inCombat = true
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	t.eq(game:PressKey('PADLSHOULDER'), false)
	game.inCombat = false
	game:Fire('PLAYER_REGEN_ENABLED')
	t.eq(game:PressKey('PADLSHOULDER'), true)
end)

local function endCombat(game)
	game.inCombat = false
	game:Fire('PLAYER_REGEN_ENABLED')
end

t.test('leaving the focus in combat frees the keys when combat ends', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	game.inCombat = true
	game:PressKey('PAD2')
	t.eq(addon.input:HasFocus('topbar'), false)
	local focusedBefore = addon.topBar.order[1].isFocused
	game:PressKey('PADDRIGHT')
	t.eq(addon.topBar.order[2].isFocused, focusedBefore, 'a releasing focus ignores the d-pad')
	endCombat(game)
	t.eq(game:PressKey('PADDRIGHT'), false, 'd-pad freed')
	t.eq(game:PressKey('ESCAPE'), false, 'Escape freed')
	t.eq(game:PressKey('PADLSHOULDER'), true, 'focus key kept')
	t.eq(addon.input:HasFocus('topbar'), true, 'focus works again')
end)

t.test('combat starting ends the focus while the keys can still change', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	-- The client still allows binding changes while PLAYER_REGEN_DISABLED runs.
	game:Fire('PLAYER_REGEN_DISABLED')
	t.eq(addon.input:HasFocus('topbar'), false)
	t.eq(game:PressKey('PADDRIGHT'), false)
	t.eq(addon.topBar.order[1].isFocused, false, 'the bar heard the leave')
end)

t.test('a bar hidden in combat frees the focus keys when combat ends', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	game:PressKey('PADLSHOULDER')
	game.inCombat = true
	addon.host.Module('topbar'):SetSetting('visibility', 'hidden')
	endCombat(game)
	t.eq(game:PressKey('ESCAPE'), false)
	t.eq(game:PressKey('PAD1'), false)
end)

t.test('unbinding in combat takes effect when combat ends', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	game.inCombat = true
	addon.host.Module('topbar'):SetSetting('focusKey', '')
	endCombat(game)
	t.eq(game:PressKey('PADLSHOULDER'), false)
end)

t.test('rebinding in combat leaves only the new key', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	game.inCombat = true
	addon.host.Module('topbar'):SetSetting('focusKey', '')
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADRSHOULDER')
	endCombat(game)
	t.eq(game:PressKey('PADLSHOULDER'), false)
	t.eq(game:PressKey('PADRSHOULDER'), true)
end)

t.test('clearing the binding unbinds it', function()
	local game, addon = start()
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	addon.host.Module('topbar'):SetSetting('focusKey', '')
	t.eq(game:PressKey('PADLSHOULDER'), false)
end)

local function marketOf(addon)
	return addon.store:Market(addon.prices:MarketKey())
end

local function addSale(addon, t0, char, copper)
	addon.Ledger.append(
		marketOf(addon),
		{ t = t0, kind = 'sale', itemId = 2589, qty = 1, copper = copper, char = char }
	)
end

t.test("session profit is this character's, like the gold beside it", function()
	local game, addon = start()
	addSale(addon, game.now, 'Eilu-Nightslayer', 500)
	addSale(addon, game.now, 'Alt-Nightslayer', 70000)
	game:Fire('PLAYER_MONEY')
	t.truthy(addon.topBar:Texts().gold:find(FakeGame.coins('+5s'), 1, true))
	t.eq(addon.topBar:Texts().gold:find(FakeGame.coins('7g'), 1, true), nil, "the alt's sale left out")
end)

t.test('a session reaching past the days the ledger keeps says those count every character', function()
	local game, addon = start()
	local function goldTooltip()
		return table.concat(addon.topBar:TooltipLines('gold'), '\n')
	end
	addon.sessions:Reset()
	t.eq(goldTooltip():find('every character', 1, true), nil, 'a fresh session: no note')
	game.now = game.now + (addon.Ledger.KEEP_DAYS + 1) * addon.Ledger.SECONDS_PER_DAY
	t.truthy(goldTooltip():find('days over 90 back count every character', 1, true))
end)

t.test('session profit is read once per ledger change, and not at all with nothing shown', function()
	local game, addon = start()
	local reads = 0
	local netSince = addon.Ledger.netSince
	addon.Ledger.netSince = function(...)
		reads = reads + 1
		return netSince(...)
	end
	game:Fire('PLAYER_MONEY')
	game:Fire('PLAYER_MONEY')
	t.eq(reads, 0, 'cached since the bar first showed')
	addSale(addon, game.now, 'Eilu-Nightslayer', 500)
	game:Fire('PLAYER_MONEY')
	t.eq(reads, 1, 'a new event reads again')
	addon.host.Module('topbar'):SetSetting('visibility', 'hidden')
	addon.host.Module('topbar'):SetSetting('feed', false)
	addSale(addon, game.now, 'Eilu-Nightslayer', 500)
	game:Fire('PLAYER_MONEY')
	t.eq(reads, 1, 'nothing shows: nothing read')
	addon.Ledger.netSince = netSince
end)

t.test('a ticker keeps the scan age current while the bar shows, and stops when nothing shows', function()
	local game, addon = start()
	local before = addon.topBar:Texts().scan
	local refreshes = 0
	local refresh = addon.topBar.Refresh
	addon.topBar.Refresh = function(...)
		refreshes = refreshes + 1
		return refresh(...)
	end
	game.now = game.now + 61
	game:RunTimers()
	t.eq(refreshes, 1, 'ticked')
	game.now = game.now + 61
	game:RunTimers()
	t.eq(refreshes, 2, 'ticks again')
	addon.host.Module('topbar'):SetSetting('visibility', 'hidden')
	addon.host.Module('topbar'):SetSetting('feed', false)
	local afterOff = refreshes
	for _ = 1, 3 do
		game.now = game.now + 61
		game:RunTimers()
	end
	t.eq(refreshes, afterOff + 1, 'one last tick, then none')
	addon.topBar.Refresh = refresh
	t.truthy(before, 'scan text')
end)

t.test('switching the module off blanks the feed, drops its events and frees its key', function()
	local game, addon, libStub = start({ withLibraries = true })
	addon.host.Module('topbar'):SetSetting('focusKey', 'PADLSHOULDER')
	local gold = libStub:GetLibrary('LibDataBroker-1.1'):GetDataObjectByName('Haggler: Gold')
	local topBar = addon.topBar
	addon.host.Disable('topbar')
	t.eq(gold.text, '')
	t.eq(bar(game):IsShown(), false)
	t.eq(game:PressKey('PADLSHOULDER'), false, 'focus key unbound')
	game.money = 990000
	game:Fire('PLAYER_MONEY')
	game:Fire('MERCHANT_SHOW')
	t.eq(gold.text, '', 'no updates while off')
	t.eq(bar(game):IsShown(), false)
	t.eq(addon.topBar, nil)
	t.truthy(topBar, 'was on')
	t.same(addon.errors, {})
end)

-- The broker feed -------------------------------------------------------------------------

t.test('the widgets go out as LibDataBroker objects and follow the bar', function()
	local game, addon, libStub = start({ withLibraries = true })
	local ldb = libStub:GetLibrary('LibDataBroker-1.1')
	local gold = ldb:GetDataObjectByName('Haggler: Gold')
	t.truthy(gold, 'gold object')
	t.eq(gold.type, 'data source')
	t.eq(ldb:GetDataObjectByName('Haggler').type, 'launcher')
	local changes = {}
	ldb.RegisterCallback(changes, 'LibDataBroker_AttributeChanged_Haggler: Gold_text', function(_, _, _, value)
		changes[#changes + 1] = value
	end)
	game.money = 10000
	game:Fire('PLAYER_MONEY')
	t.eq(gold.text:find(FakeGame.coins('1g'), 1, true), 1)
	t.eq(#changes, 1)
	ldb:GetDataObjectByName('Haggler: Rule').OnClick(nil, 'LeftButton')
	t.truthy(ldb:GetDataObjectByName('Haggler: Rule').text:find('Rule: ', 1, true), 'rule text')
	ldb:GetDataObjectByName('Haggler').OnClick(nil, 'LeftButton')
	t.eq(addon.window:IsOpen(), true)
	t.same(addon.errors, {})
end)

t.test('the feed keeps working with the bar hidden, and stops when switched off', function()
	local game, addon, libStub = start({ withLibraries = true })
	local gold = libStub:GetLibrary('LibDataBroker-1.1'):GetDataObjectByName('Haggler: Gold')
	addon.host.Module('topbar'):SetSetting('visibility', 'hidden')
	game.money = 20000
	game:Fire('PLAYER_MONEY')
	t.eq(gold.text:find(FakeGame.coins('2g'), 1, true), 1)
	addon.host.Module('topbar'):SetSetting('feed', false)
	t.eq(gold.text, '')
end)

t.test('with the feed off the launcher tooltip offers no clicks', function()
	local _, addon, libStub = start({ withLibraries = true })
	local launcher = libStub:GetLibrary('LibDataBroker-1.1'):GetDataObjectByName('Haggler')
	local function tooltipText()
		local lines = {}
		launcher.OnTooltipShow({
			AddLine = function(_, line)
				lines[#lines + 1] = line
			end,
		})
		return table.concat(lines, '\n')
	end
	t.truthy(tooltipText():find('Click', 1, true), 'clicks offered while on')
	addon.host.Module('topbar'):SetSetting('feed', false)
	t.eq(tooltipText():find('Click', 1, true), nil)
	t.truthy(tooltipText():find('off', 1, true), 'says why')
	t.same(addon.errors, {})
end)

t.test('without LibDataBroker the bar still works', function()
	local game, addon = start()
	t.eq(game.env.LibStub, nil)
	t.truthy(addon.topBar.feed, 'feed object')
	t.same(addon.errors, {})
end)
