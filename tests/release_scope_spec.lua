local t = ...
local FakeGame = require('tests.fake_game')

-- The release package leaves V2 out (Flips, Ventures: v2/). These run in both passes of
-- tests/run.lua: the dev set must show V2, the V1 release set (--v1) must load and work without it.

local NOW = 1774742400
local MARKET = 'forever/normal/alliance/us'
local V2_FILES = {
	'v2/Engine/Ventures.lua',
	'v2/Engine/Flips.lua',
	'v2/Features/Window/FlipsTab.lua',
	'v2/Features/Window/VenturesTab.lua',
}
-- Globals only V2 files define; no file of the release set may read them.
local V2_ONLY_NAMES = { 'ns%.Flips%f[^%w]', 'ns%.FlipsTab', 'ns%.VenturesTab' }

local function readFile(path)
	local file = io.open(path, 'r')
	if not file then
		return nil
	end
	local text = file:read('*a')
	file:close()
	return text
end

-- The TOC's file lines, dev (all) and release (the packager strips do-not-package blocks).
local function tocFiles()
	local dev, release = {}, {}
	local isStripped, isBalanced = false, true
	for line in assert(readFile('Haggler.toc')):gmatch('[^\n]+') do
		if line == '#@do-not-package@' then
			isBalanced = isBalanced and not isStripped
			isStripped = true
		elseif line == '#@end-do-not-package@' then
			isBalanced = isBalanced and isStripped
			isStripped = false
		elseif not line:find('^#') and line:find('%S') then
			local path = line:gsub('\\', '/'):gsub('%s+$', '')
			dev[#dev + 1] = path
			if not isStripped then
				release[#release + 1] = path
			end
		end
	end
	return dev, release, isBalanced and not isStripped
end

local function contains(list, value)
	for _, entry in ipairs(list) do
		if entry == value then
			return true
		end
	end
	return false
end

local function start(game, beforeStart)
	game = game or FakeGame.new({ now = NOW })
	return game, FakeGame.startAddon(t, game, beforeStart)
end

local function tabKeys(addon)
	local keys = {}
	for _, tab in ipairs(addon.window.tabs:List()) do
		keys[tab.key] = true
	end
	return keys
end

local function deepCopy(value)
	if type(value) ~= 'table' then
		return value
	end
	local copy = {}
	for key, entry in pairs(value) do
		copy[key] = deepCopy(entry)
	end
	return copy
end

t.test('the release TOC lists only files that ship, and V2 only inside do-not-package blocks', function()
	local dev, release, isBalanced = tocFiles()
	t.truthy(isBalanced, 'every do-not-package block is closed')
	for _, path in ipairs(release) do
		t.truthy(readFile(path), 'release file exists: ' .. path)
		t.eq(path:find('^v2/'), nil, 'no V2 file in the release TOC: ' .. path)
	end
	for _, path in ipairs(V2_FILES) do
		t.truthy(contains(dev, path), 'the dev TOC loads ' .. path)
		t.truthy(readFile(path), path .. ' stays in the repo')
	end
	t.eq(#dev, #release + #V2_FILES, 'the blocks hold the V2 files and nothing else')
	t.truthy(contains(release, 'Engine/VentureRecords.lua'), 'saved ventures stay readable in V1')
end)

t.test('.pkgmeta leaves v2 out of the release zip', function()
	t.truthy(assert(readFile('.pkgmeta')):find('\nignore:.-\n%s+%- v2\n'))
end)

t.test('no release file reads a name only V2 defines', function()
	local _, release = tocFiles()
	for _, path in ipairs(release) do
		if path:find('%.lua$') then
			local text = assert(readFile(path))
			for _, pattern in ipairs(V2_ONLY_NAMES) do
				t.eq(text:find(pattern), nil, path .. ' reads ' .. pattern)
			end
		end
	end
end)

t.test('the window, top bar and profession settings show V2 only when it is loaded', function()
	local _, addon = start()
	local hasV2 = not t.isV1Only
	t.eq(addon.Ventures.hasPlanner, hasV2)
	local tabs = tabKeys(addon)
	t.eq(tabs.flips == true, hasV2, 'Flips tab')
	t.eq(tabs.ventures == true, hasV2, 'Ventures tab')
	t.truthy(tabs.sell and tabs.ledger and tabs.auctions, 'the V1 tabs')
	local hasFlipsShortcut = false
	for _, shortcut in ipairs(addon.TopBarModel.SHORTCUTS) do
		hasFlipsShortcut = hasFlipsShortcut or shortcut.key == 'flips'
	end
	t.eq(hasFlipsShortcut, hasV2, 'Flips shortcut')
	t.eq(#addon.topBar.shortcuts, #addon.TopBarModel.SHORTCUTS)
	local hasVenturesChoice = false
	for _, choice in ipairs(addon.host.Settings:Entry('window', 'lastTab').choices) do
		hasVenturesChoice = hasVenturesChoice or choice.value == 'ventures'
	end
	t.eq(hasVenturesChoice, hasV2, 'Ventures as the opening tab')
	t.eq(pcall(addon.host.Settings.Entry, addon.host.Settings, 'crafting', 'showPlan'), hasV2, 'Plan venture setting')
	t.same(addon.errors, {})
end)

t.test('without V2, saved ventures, their ledger rows and settings are kept, never dropped', function()
	local venture = {
		id = 1,
		name = 'Old venture',
		valuation = 'opportunity',
		status = 'selling',
		createdAt = NOW - 3600,
		lines = {
			{
				recipeId = 5,
				itemId = 6,
				perCraft = 1,
				plannedCrafts = 2,
				planned = 2,
				crafted = 2,
				posted = 2,
				sold = 1,
				returned = 0,
			},
		},
		materials = {},
		totals = { gross = 100, cut = 5, depositPaid = 10, depositRefunded = 0, trollUnits = 0 },
	}
	local game, addon = start(nil, function(ns)
		local settings = ns.store:Settings()
		settings.window = { lastTab = 'ventures' }
		settings.crafting = { showPlan = false }
	end)
	local market = addon.store:Market(MARKET)
	market.ventures[1] = deepCopy(venture)
	addon.Ledger.append(
		market,
		{ t = NOW, kind = 'sale', itemId = 6, qty = 1, copper = 100, char = 'A', ventureId = 1 }
	)
	if t.isV1Only then
		t.eq(addon.books:CheckVentures(), 0, 'nothing closes without the planner')
		t.raises(function()
			addon.books:CreateVenture({})
		end, 'planner is not loaded')
		t.eq(addon.host.Module('window'):Setting('lastTab'), 'sell', 'reads as the default')
	end

	local _, reloaded = start(game)
	local reloadedMarket = reloaded.store:Market(MARKET)
	if t.isV1Only then
		t.same(reloadedMarket.ventures[1], venture, 'the venture is kept as it was')
	else
		t.truthy(reloadedMarket.ventures[1], 'the venture is kept')
	end
	local events = reloaded.Ledger.events(reloadedMarket)
	t.eq(events[#events].ventureId, 1, 'the ledger row keeps its ventureId')
	local saved = reloaded.store:Settings()
	t.eq(saved.window.lastTab, 'ventures', 'the saved opening tab is kept')
	t.eq(saved.crafting.showPlan, false, 'the saved Plan venture setting is kept')
	t.same(reloaded.errors, {})
end)
