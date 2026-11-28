local t = ...

-- Loads Haggler.lua with a fake game: the event frame, chat and slash table live in _G, as in
-- the client. Everything set here is removed again afterwards.
-- The files the TOC loads after the Engine, in its order.
local BOOT_FILES = {
	'Init.lua',
	'Features/Pricing.lua',
	'Features/Scan.lua',
	'Features/Tooltip/Tooltip.lua',
	'Haggler.lua',
}

local FAKE_GLOBALS = { 'CreateFrame', 'DEFAULT_CHAT_FRAME', 'SlashCmdList', 'GetServerTime' }

local function withFakeGame(run)
	local frame = { events = {} }
	function frame:SetScript(_, handler)
		self.onEvent = handler
	end
	function frame:RegisterEvent(event)
		self.events[event] = true
	end
	function frame:UnregisterEvent(event)
		self.events[event] = nil
	end
	local printed = {}
	rawset(_G, 'CreateFrame', function()
		return frame
	end)
	rawset(_G, 'DEFAULT_CHAT_FRAME', {
		AddMessage = function(_, text)
			printed[#printed + 1] = text
		end,
	})
	rawset(_G, 'SlashCmdList', {})
	rawset(_G, 'GetServerTime', function()
		return 1
	end)
	local ok, err = pcall(run, frame, printed)
	for _, name in ipairs(FAKE_GLOBALS) do
		rawset(_G, name, nil)
	end
	rawset(_G, 'SLASH_HAGGLER1', nil)
	rawset(_G, 'HagglerDB', nil)
	rawset(_G, 'HagglerCharDB', nil)
	rawset(_G, 'HagglerArchiveDB', nil)
	if not ok then
		error(err, 0)
	end
end

local function loadWithBootstrap()
	local ns = t.loadAddon()
	for _, path in ipairs(BOOT_FILES) do
		assert(loadfile(path))('Haggler', ns)
	end
	return ns
end

t.test('starts on ADDON_LOADED, builds saved data and answers /hag', function()
	withFakeGame(function(frame)
		local ns = loadWithBootstrap()
		t.eq(ns.host.IsStarted(), false)
		frame.onEvent(frame, 'ADDON_LOADED', 'SomeOtherAddon')
		t.eq(ns.host.IsStarted(), false)
		frame.onEvent(frame, 'ADDON_LOADED', 'Haggler')
		t.truthy(ns.host.IsStarted())
		t.eq(frame.events.ADDON_LOADED, nil)
		t.eq(rawget(_G, 'HagglerDB').version, ns.Store.SCHEMA_VERSION)
		t.eq(rawget(_G, 'SLASH_HAGGLER1'), '/hag')
		local lines = ns.host.RunCommand('list')
		t.eq(lines[1], 'pricing.staleMediumHours = 24  (Prices older than this many hours are medium confidence)')
		t.eq(lines[2], 'pricing.staleLowHours = 72  (Prices older than this many hours are low confidence)')
		local listed = table.concat(lines, '\n')
		t.truthy(listed:find('scan.autoScan = on', 1, true), listed)
		t.truthy(listed:find('tooltip.detailMode = modifier', 1, true), listed)
		t.truthy(ns.host.Get('price'), 'price provided')
		t.truthy(ns.host.Get('haggler.price'), 'haggler.price provided')
		t.eq(frame.events.AUCTION_HOUSE_SHOW, true, 'the scanner listens')
		t.eq(ns.pricing:Setting('staleLowHours'), 72)
		rawget(_G, 'SlashCmdList').HAGGLER('help')
	end)
end)

t.test('a scan history that is not a table is replaced, never raised', function()
	withFakeGame(function(frame)
		rawset(_G, 'HagglerArchiveDB', 'junk')
		local ns = loadWithBootstrap()
		frame.onEvent(frame, 'ADDON_LOADED', 'Haggler')
		t.truthy(ns.host.IsStarted())
		t.same(rawget(_G, 'HagglerArchiveDB'), { schema = 1, markets = {}, vendors = { schema = 2, byNpc = {} } })
		t.eq(ns.archiveDb, rawget(_G, 'HagglerArchiveDB'))
		t.eq(ns.vendorDb, rawget(_G, 'HagglerArchiveDB').vendors)
	end)
end)

t.test('a newer scan history is kept as it is and the add-on still starts', function()
	withFakeGame(function(frame, printed)
		rawset(_G, 'HagglerArchiveDB', { schema = 9 })
		local ns = loadWithBootstrap()
		frame.onEvent(frame, 'ADDON_LOADED', 'Haggler')
		t.truthy(ns.host.IsStarted())
		t.eq(ns.archiveDb, nil)
		t.eq(ns.vendorDb, nil)
		t.same(rawget(_G, 'HagglerArchiveDB'), { schema = 9 })
		t.truthy(
			table
				.concat(printed, '\n')
				:find(
					"Haggler's scan history is from a newer Haggler. Update the add-on. It is kept as it is.",
					1,
					true
				)
		)
	end)
end)

t.test('newer saved data is left alone and reported', function()
	withFakeGame(function(frame, printed)
		rawset(_G, 'HagglerDB', { version = 999 })
		local ns = loadWithBootstrap()
		frame.onEvent(frame, 'ADDON_LOADED', 'Haggler')
		t.eq(ns.host.IsStarted(), false)
		t.truthy(printed[1]:find('newer Haggler', 1, true))
		local message = printed[1]:match('|r: (.*)$') or printed[1]
		t.eq(message:find('[;:\194\183]'), nil, 'no joined sentences: ' .. message)
		t.same(rawget(_G, 'HagglerDB'), { version = 999 })
	end)
end)
