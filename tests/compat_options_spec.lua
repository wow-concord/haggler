local t = ...
local FakeGame = require('tests.fake_game')

local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000

local function start(prepare)
	local game = FakeGame.new({ now = NOW })
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = {} })
	if prepare then
		prepare(game)
	end
	local addon = FakeGame.startAddon(t, game)
	return game, addon
end

local function readOnly(settings)
	return setmetatable({}, {
		__index = settings,
		__newindex = function()
			error('Haggler wrote AHledger settings', 2)
		end,
	})
end

local function noticeShown(addon)
	return addon.Compat.notice ~= nil and addon.Compat.notice:IsShown()
end

-- Compat ----------------------------------------------------------------------------------

t.group('compat')

local _, ns = start()

t.test('overlapping features: a missing key is on, only false is off', function()
	local Compat = ns.Compat
	t.eq(#Compat.overlappingFeatures(nil), #Compat.AHLEDGER_FEATURES)
	t.eq(#Compat.overlappingFeatures({}), 9)
	local keys = {}
	for _, feature in ipairs(Compat.overlappingFeatures({ tooltip = false, bar = false, ledger = true, junk = false })) do
		keys[#keys + 1] = feature.key
	end
	t.same(keys, {
		'crafting',
		'craftDots',
		'bagDots',
		'postingHelper',
		'postingPlan',
		'vendorFlips',
		'ledger',
	})
	local allOff = {}
	for _, feature in ipairs(Compat.AHLEDGER_FEATURES) do
		allOff[feature.key] = false
	end
	t.same(Compat.overlappingFeatures(allOff), {})
end)

t.test('shows once at login, lists what is on, never writes AHledger', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = readOnly({ tooltip = false }) }
	end)
	t.eq(noticeShown(addon), false, 'not before login')
	game:Fire('PLAYER_LOGIN')
	t.truthy(noticeShown(addon))
	local text = addon.Compat.notice.list:GetText()
	t.truthy(text:find('Ledger bar'))
	t.eq(text:find('Prices in item tooltips'), nil, 'off in AHledger: not listed')
	t.same(addon.errors, {})
end)

t.test('the options button runs /ahl options', function()
	local opened = {}
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
		g.env.SlashCmdList.AHLEDGER = function(args)
			opened[#opened + 1] = args
		end
	end)
	game:Fire('PLAYER_LOGIN')
	addon.Compat.notice.openButton:Click()
	t.same(opened, { 'options' })
end)

t.test('closing the notice in any way dismisses it for good; /hag compat reopens it', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	t.eq(addon.Compat.notice.dismissButton, nil, 'one Close button only')
	addon.Compat.notice.closeButton:Click()
	t.eq(noticeShown(addon), false)
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), true)
	local reloaded = FakeGame.startAddon(t, game)
	game:Fire('PLAYER_LOGIN')
	t.eq(noticeShown(reloaded), false)
	t.same(reloaded.host.RunCommand('compat'), {}, '/hag compat still shows it on demand')
	t.truthy(noticeShown(reloaded))
end)

t.test('Escape closes the notice and counts as dismissing it', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	local isListed = false
	for _, name in ipairs(game.env.UISpecialFrames) do
		isListed = isListed or name == 'HagglerCompatNotice'
	end
	t.truthy(isListed, 'listed for Escape')
	addon.Compat.notice:Hide()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), true)
end)

t.test('the interface hiding for Alt+Z or a cinematic does not dismiss the notice', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	game.env.UIParent:Hide()
	addon.Compat.notice:Hide()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), false)
	game.env.UIParent:Show()
	addon.Compat.notice:Show()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), false)
	addon.Compat.notice:Hide()
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), true)
end)

t.test('turning the module off hides the notice without dismissing it', function()
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
	end)
	game:Fire('PLAYER_LOGIN')
	addon.host.Disable('compat')
	t.eq(noticeShown(addon), false)
	t.eq(addon.host.Settings:Get('compat', 'noticeDismissed'), false)
end)

t.test('nothing overlapping or no AHledger settings: no notice', function()
	local allOff = {}
	for _, feature in ipairs(ns.Compat.AHLEDGER_FEATURES) do
		allOff[feature.key] = false
	end
	local game, addon = start(function(g)
		g.env.AHledgerDB = { settings = allOff }
	end)
	game:Fire('PLAYER_LOGIN')
	t.eq(noticeShown(addon), false)
	t.same(addon.host.RunCommand('compat'), { 'No AHledger feature overlaps Haggler right now.' })
	local otherGame, other = start()
	otherGame:Fire('PLAYER_LOGIN')
	t.eq(noticeShown(other), true, 'no saved settings: every feature is at its default, on')
end)

t.test('enabled after login shows it at once', function()
	local _, addon = start(function(g)
		g.env.AHledgerDB = { settings = {} }
		g.isLoggedIn = true
	end)
	t.truthy(noticeShown(addon))
end)

-- Options ---------------------------------------------------------------------------------

t.group('options')

local function findSetting(game, variable)
	return game.settingsApi.settings[variable]
end

t.test('registers a Settings → AddOns category with every switch and an open button', function()
	local game, addon = start(FakeGame.addSettingsApi)
	local registered = game.settingsApi
	t.eq(registered.category.name, 'Haggler')
	t.eq(registered.addOnCategories[1], registered.category)
	t.eq(addon.Options.kind, 'settings')
	local entries = addon.Options.toggleEntries(addon.host.Settings, function(key)
		return key
	end)
	t.eq(#registered.checkboxes, #entries)
	local scanEnabled = findSetting(game, 'HAGGLER_SCAN_ENABLED')
	t.truthy(scanEnabled, 'each module has its Enabled switch')
	t.eq(scanEnabled.label, 'Auction house scan')
	t.eq(scanEnabled.GetValue(), true)
	scanEnabled.SetValue(false)
	t.eq(addon.host.IsEnabled('scan'), false, 'the checkbox turns the module off')
	t.eq(scanEnabled.GetValue(), false)
	t.eq(findSetting(game, 'HAGGLER_PRICING_ENABLED'), nil, 'an always-on module has no switch')
	t.truthy(findSetting(game, 'HAGGLER_COMPAT_NOTICEDISMISSED'))
	local button = registered.initializers[1]:GetData()
	t.eq(button.buttonText, 'Open Haggler')
	t.eq(button.name, '', 'with the section header for the credit, the button row has no label')
	button.buttonClick()
	t.truthy(addon.window:IsOpen())
	t.same(addon.host.RunCommand('options'), {})
	t.eq(registered.openedId, 42)
	t.same(addon.errors, {})
end)

t.test('a failing Settings API falls back to the legacy panel', function()
	local added = {}
	local game, addon = start(function(g)
		FakeGame.addSettingsApi(g)
		g.env.Settings.RegisterProxySetting = function()
			error('client changed')
		end
		g.env.InterfaceOptions_AddCategory = function(panel)
			added[#added + 1] = panel
		end
	end)
	t.eq(addon.Options.kind, 'legacy')
	t.eq(added[1], game.env.HagglerOptionsPanel)
	t.eq(added[1].name, 'Haggler')
	local message = game.printed[#game.printed]:gsub('^.-|r: ', '')
	t.eq(message:find('[;:]'), nil, message)
	t.eq(message, 'The Settings entry failed, so Haggler uses the old options panel', 'one sentence, no stop')
	t.truthy(addon.Options.registrationError:find('client changed', 1, true), 'the error is kept, not printed')
	t.same(addon.errors, {})
end)

t.test('switch labels and chat lines join nothing with a colon or semicolon', function()
	local game, addon = start(FakeGame.addSettingsApi)
	local entries = addon.Options.toggleEntries(addon.host.Settings, function(key)
		return key == 'bags' and 'Bags' or key
	end)
	local badge
	for _, entry in ipairs(entries) do
		t.eq(entry.label:find('Bags: ', 1, true), nil, entry.label)
		if entry.key == 'decisionBadge' then
			badge = entry
		end
	end
	t.eq(badge.label:sub(-#' (Bags)'), ' (Bags)', 'the module follows the switch in brackets')
	game.env.Settings.OpenToCategory = function()
		error('closed')
	end
	local reply = addon.host.RunCommand('options')
	t.eq(#reply, 1)
	t.eq(reply[1]:find(';', 1, true), nil, reply[1])
end)

t.test('every switch label in the entry carries at most one bracket, and never repeats its module', function()
	local _, addon = start(FakeGame.addSettingsApi)
	local function labelOf(key)
		return addon.host.Module(key).definition.label
	end
	for _, entry in ipairs(addon.Options.toggleEntries(addon.host.Settings, labelOf)) do
		local _, brackets = entry.label:gsub('%(', '')
		t.truthy(brackets <= 1, entry.label)
		local moduleName = labelOf(entry.moduleKey)
		local _, mentions = entry.label:lower():gsub(moduleName:lower():gsub('%p', '%%%0'), '')
		t.truthy(mentions <= 1, entry.label)
	end
	local repeated = addon.Options.toggleEntries({
		Modules = function()
			return { 'm' }
		end,
		Schema = function()
			return { { key = 'enabled', type = 'toggle' }, { key = 'dots', type = 'toggle', label = 'Bag dots' } }
		end,
	}, function()
		return 'Bag'
	end)
	t.eq(repeated[2].label, 'Bag dots', 'the module suffix is dropped when the label names it')
end)

t.test('the module suffix is dropped only when the label names the module as a whole word', function()
	local _, addon = start(FakeGame.addSettingsApi)
	local function entriesFor(label, moduleName)
		return addon.Options.toggleEntries({
			Modules = function()
				return { 'm' }
			end,
			Schema = function()
				return { { key = 'dots', type = 'toggle', label = label } }
			end,
		}, function()
			return moduleName
		end)
	end
	t.eq(entriesFor('Bagsy dots', 'Bag')[1].label, 'Bagsy dots (Bag)', 'a longer word is not the module')
	t.eq(entriesFor('Show the bag value', 'Bag')[1].label, 'Show the bag value', 'any case')
	t.eq(entriesFor('Mark vendor prices here', 'Vendor prices')[1].label, 'Mark vendor prices here')
	t.eq(entriesFor('Vendor pricesheet', 'Vendor prices')[1].label, 'Vendor pricesheet (Vendor prices)')
	t.eq(entriesFor('Total value of the bags', 'Bags')[1].label, 'Total value of the bags')
	local mail = 'Auctions, mail and ledger'
	t.eq(entriesFor('Sync auctions, mail and ledger now', mail)[1].label, 'Sync auctions, mail and ledger now')
	t.eq(
		entriesFor('Sync auctions, mail and ledgers', mail)[1].label,
		'Sync auctions, mail and ledgers (Auctions, mail and ledger)',
		'a longer last word is not the module'
	)
end)

t.test('a module name that ends in punctuation still matches as a whole', function()
	local _, addon = start(FakeGame.addSettingsApi)
	local function entriesFor(label, moduleName)
		return addon.Options.toggleEntries({
			Modules = function()
				return { 'm' }
			end,
			Schema = function()
				return { { key = 'dots', type = 'toggle', label = label } }
			end,
		}, function()
			return moduleName
		end)
	end
	local thirdParty = 'Sorter (by Author)'
	t.eq(entriesFor('Run sorter (by Author) on open', thirdParty)[1].label, 'Run sorter (by Author) on open')
	t.eq(entriesFor('Sorter (by Author)', thirdParty)[1].label, 'Sorter (by Author)', 'the whole label')
	t.eq(entriesFor('Run Sorter (by Author)s', thirdParty)[1].label, 'Run Sorter (by Author)s', 'no frontier after )')
	t.eq(entriesFor('Presorter (by Author)', thirdParty)[1].label, 'Presorter (by Author) (Sorter (by Author))')
end)

t.test('legacy panel switches flip settings and open the window', function()
	local added = {}
	local _, addon = start(function(g)
		g.env.InterfaceOptions_AddCategory = function(panel)
			added[#added + 1] = panel
		end
	end)
	local panel = added[1]
	t.eq(addon.Options.kind, 'legacy')
	local scanToggle
	for _, toggle in ipairs(panel.toggles) do
		if toggle.entry.moduleKey == 'scan' and toggle.entry.key == 'enabled' then
			scanToggle = toggle
		end
	end
	t.eq(scanToggle.button.label:GetText(), 'Auction house scan, on')
	scanToggle.button:Click()
	t.eq(addon.host.IsEnabled('scan'), false)
	t.eq(scanToggle.button.label:GetText(), 'Auction house scan, off')
	panel.openButton:Click()
	t.truthy(addon.window:IsOpen())
end)

local OWN_CREDIT = 'Prices from AHledger (ahledger.com), test feed'

local function startWithCredit(prepare)
	local game = FakeGame.new({ now = NOW })
	game.env.AHledgerAPI =
		FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = {}, credit = OWN_CREDIT })
	prepare(game)
	return game, FakeGame.startAddon(t, game)
end

local function initializerOf(game, kind)
	for _, initializer in ipairs(game.settingsApi.initializers) do
		if initializer.kind == kind then
			return initializer
		end
	end
	return nil
end

t.test("the Settings entry shows AHledger's own credit", function()
	local game, addon = startWithCredit(FakeGame.addSettingsApi)
	t.eq(initializerOf(game, 'sectionHeader'):GetData().name, OWN_CREDIT, 'read from AHledgerAPI.CREDIT')
	t.same(addon.errors, {})
end)

t.test('the Settings entry reads the credit again each time the Settings panel shows', function()
	local game, addon = startWithCredit(FakeGame.addSettingsApi)
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({
		market = MARKET,
		updated = NOW - 3600,
		rows = {},
		credit = 'Prices from AHledger (ahledger.com), synced',
	})
	game.env.SettingsPanel:Show()
	t.eq(initializerOf(game, 'sectionHeader'):GetData().name, 'Prices from AHledger (ahledger.com), synced')
	t.same(addon.errors, {})
end)

t.test('the credit is current before Settings draws: a loaded price table and /hag options refresh it', function()
	local game, addon = startWithCredit(FakeGame.addSettingsApi)
	local function swapCredit(credit)
		game.env.AHledgerAPI =
			FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = {}, credit = credit })
	end
	swapCredit('Prices from AHledger (ahledger.com), loaded')
	addon.host.Bus:Send('PRICE_TABLE_LOADED', { MARKET })
	t.eq(initializerOf(game, 'sectionHeader'):GetData().name, 'Prices from AHledger (ahledger.com), loaded')
	swapCredit('Prices from AHledger (ahledger.com), opened')
	addon.host.RunCommand('options')
	t.eq(initializerOf(game, 'sectionHeader'):GetData().name, 'Prices from AHledger (ahledger.com), opened')
	t.same(addon.errors, {})
end)

t.test('without the section header the credit goes on the open button row, as its plain label', function()
	local game, addon = startWithCredit(function(g)
		FakeGame.addSettingsApi(g)
		g.env.CreateSettingsListSectionHeaderInitializer = nil
	end)
	t.eq(initializerOf(game, 'sectionHeader'), nil)
	local button = initializerOf(game, 'button')
	t.eq(button:GetData().name, OWN_CREDIT)
	t.eq(button:GetData().buttonText, 'Open Haggler')
	t.eq(addon.Options.kind, 'settings')
	t.same(addon.errors, {})
end)

t.test('with neither initializer the old panel takes over, so the credit still shows', function()
	local added = {}
	local _, addon = startWithCredit(function(g)
		FakeGame.addSettingsApi(g)
		g.env.CreateSettingsListSectionHeaderInitializer = nil
		g.env.CreateSettingsButtonInitializer = nil
		g.env.InterfaceOptions_AddCategory = function(panel)
			added[#added + 1] = panel
		end
	end)
	t.eq(addon.Options.kind, 'legacy')
	t.eq(added[1].credit:GetText(), OWN_CREDIT)
end)

t.test('the legacy panel shows the credit too, read again each time it shows', function()
	local added = {}
	local game, addon = startWithCredit(function(g)
		g.env.InterfaceOptions_AddCategory = function(panel)
			added[#added + 1] = panel
		end
	end)
	local panel = added[1]
	t.eq(panel.credit:GetText(), OWN_CREDIT)
	game.env.AHledgerAPI = nil
	panel:Hide()
	panel:Show()
	t.eq(panel.credit:GetText(), addon.PriceData.DEFAULT_CREDIT, 'the rendered panel falls back to the default line')
	t.same(addon.errors, {})
end)

t.test('without a usable credit the options fall back to the default line', function()
	local game = FakeGame.new({ now = NOW })
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 3600, rows = {}, credit = '' })
	FakeGame.addSettingsApi(game)
	local addon = FakeGame.startAddon(t, game)
	t.eq(addon.Options.credit(), addon.PriceData.DEFAULT_CREDIT)
	t.same(addon.errors, {})
end)

t.test('toggleEntries refuses missing arguments', function()
	t.raises(function()
		ns.Options.toggleEntries(nil, tostring)
	end, 'required')
	t.raises(function()
		ns.Options.toggleEntries(ns.host.Settings, nil)
	end, 'required')
end)
