local t = ...
local ns = t.loadAddon()
local ItemMarket = ns.ItemMarket

t.group('item market')

t.test('unstackable items are whole silver unless the scan saw copper', function()
	t.eq(ItemMarket.forItem({ maxStack = 1 }).step, 100)
	t.eq(ItemMarket.forItem({ maxStack = 1, copperSeen = true }).step, 1)
	t.eq(ItemMarket.forItem({ maxStack = 5 }).step, 1, 'Flash Bomb stacks to 5: copper allowed')
	t.eq(ItemMarket.forItem({}).step, 100, 'unknown max stack: whole silver until the item info arrives')
	t.eq(ItemMarket.forItem({}).isStepInferred, true)
	t.eq(ItemMarket.forItem({ copperSeen = true }).step, 1)
	t.eq(ItemMarket.forItem({ copperSeen = true }).isStepInferred, false)
	t.same(
		ItemMarket.forItem({ maxStack = 20, vendor = 13 }),
		{ step = 1, maxStack = 20, copperSeen = false, vendor = 13, isStepInferred = false }
	)
end)

t.test('copper detection reads levels and the lowest price', function()
	t.eq(ItemMarket.hasCopper({ { price = 300, qty = 1 }, { price = 1200, qty = 1 } }), false)
	t.eq(ItemMarket.hasCopper({ { price = 300, qty = 1 }, { price = 1250, qty = 1 } }), true)
	t.eq(ItemMarket.hasCopper(nil, 299), true)
	t.eq(ItemMarket.hasCopper(nil, nil), false)
end)

t.test('copper detection skips junk levels and a non-number lowest', function()
	t.eq(ItemMarket.hasCopper({ { qty = 3 }, 5, { price = '299', qty = 1 }, { price = 300, qty = 1 } }), false)
	t.eq(ItemMarket.hasCopper({ { qty = 3 }, { price = 301, qty = 1 } }), true)
	t.eq(ItemMarket.hasCopper('levels', 'abc'), false)
	t.eq(ItemMarket.hasCopper(nil, math.huge), false)
end)

t.test('snapping: sell prices round down, break-even rounds up', function()
	local silver = ItemMarket.forItem({ maxStack = 1 })
	local copper = ItemMarket.forItem({ maxStack = 20 })
	t.eq(ItemMarket.snapDown(silver, 299), 200)
	t.eq(ItemMarket.snapUp(silver, 201), 300, 'break-even 2s 1c needs 3s')
	t.eq(ItemMarket.snapUp(silver, 300), 300)
	t.eq(ItemMarket.snapUp(copper, 201), 201)
	t.eq(ItemMarket.snapPrice(silver, 99), 100, 'never under one step')
	t.eq(ItemMarket.snapPrice(copper, 0), 1)
	t.eq(ItemMarket.undercut(silver, 300, 1), 200, '3s minus 1c is 2s on a silver item')
	t.eq(ItemMarket.undercut(copper, 300, 1), 299)
	t.eq(ItemMarket.isOnStep(silver, 250), false)
	t.eq(ItemMarket.isOnStep(silver, 200), true)
end)

t.test('the worked example: 2s vendor, 3s lowest, no copper on the item', function()
	local market = ItemMarket.forItem({ maxStack = 1, vendor = 200 })
	t.eq(ItemMarket.undercut(market, 300, 1), market.vendor, 'the next step down equals the vendor price')
end)

t.group('wow wrapper')

local function fakeEnv()
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
	return {
		GetServerTime = function()
			return 1234
		end,
		C_Item = {
			GetItemInfo = function(itemId)
				if itemId == 2589 then
					return 'Linen Cloth', 'link', 1, 5, 0, 'Trade Goods', 'Cloth', 20, '', 0, 13
				end
			end,
		},
		GetRealmName = function()
			return 'Nightslayer'
		end,
		UnitName = function()
			return 'Eilu'
		end,
		UnitFactionGroup = function()
			return 'Alliance'
		end,
		GetCurrentRegion = function()
			return 3
		end,
		CreateFrame = function()
			return frame
		end,
		DEFAULT_CHAT_FRAME = {
			AddMessage = function(_, text)
				printed[#printed + 1] = text
			end,
		},
		SlashCmdList = {},
		frame = frame,
		printed = printed,
	}
end

t.test('reads time, item info and the player through the injected env', function()
	local env = fakeEnv()
	local wow = ns.Wow.create(env)
	t.eq(wow:Now(), 1234)
	t.same(wow:ItemInfo(2589), { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 })
	t.eq(wow:ItemInfo(1), nil, 'uncached item')
	local player = wow:Player()
	t.same(player, { name = 'Eilu', realm = 'Nightslayer', faction = 'Alliance', region = 'eu' })
	t.eq(ns.Store.marketKeyFor(player), 'forever/normal/alliance/eu')
	t.raises(function()
		wow:ItemInfo('2589')
	end, 'itemId')
end)

t.test('the realm keeps its spaces, so RP and RP-PvP realms find their market', function()
	local env = fakeEnv()
	env.GetRealmName = function()
		return 'Wild Growth RP PvP'
	end
	env.GetNormalizedRealmName = function()
		return 'WildGrowthRPPvP'
	end
	local player = ns.Wow.create(env):Player()
	t.eq(player.realm, 'Wild Growth RP PvP')
	t.eq(ns.Store.marketKeyFor(player), 'forever/rppvp/alliance/eu')
end)

t.test("the player's server number comes from the GUID; an unknown name is no name", function()
	local fake = fakeEnv()
	fake.UnitGUID = function(unit)
		return unit == 'player' and 'Player-6928-00A1AEB0' or nil
	end
	t.eq(ns.Wow.create(fake):Player().server, 6928)
	fake.UnitGUID = function()
		return 'Creature-0-1-2-3-4-5'
	end
	t.eq(ns.Wow.create(fake):Player().server, nil)
	fake.UNKNOWNOBJECT = 'Unknown'
	fake.UnitName = function()
		return 'Unknown'
	end
	t.eq(ns.Wow.create(fake):Player().name, nil)
end)

t.test('client 71037 as measured: no realm from either call, the surname is not a realm, the GUID holds', function()
	local fake = fakeEnv()
	fake.GetRealmName = function()
		return ''
	end
	fake.GetNormalizedRealmName = function()
		return ''
	end
	fake.UnitName = function()
		return 'Aurelius', 'Zothari'
	end
	fake.UnitGUID = function(unit)
		return unit == 'player' and 'Player-6945-0052E899' or nil
	end
	local player = ns.Wow.create(fake):Player()
	t.eq(player.name, 'Aurelius')
	t.eq(player.realm, '')
	t.eq(player.server, 6945)
	t.eq(assert(ns.Store.open({}, {})):CharacterKey(player), 'Aurelius-Server6945')
end)

t.test(
	'client 71037 as measured, with a saved realm-named session: that key, and "Name-" records move to it',
	function()
		local fake = fakeEnv()
		fake.GetRealmName = function()
			return ''
		end
		fake.GetNormalizedRealmName = function()
			return ''
		end
		fake.UnitName = function()
			return 'Aurelius', 'Zothari'
		end
		fake.UnitFactionGroup = function()
			return 'Horde'
		end
		fake.UnitGUID = function(unit)
			return unit == 'player' and 'Player-6945-0052E899' or nil
		end
		local savedKey = 'Aurelius-CAMWOW EU5 Realm 3 PvE'
		local charDb = {}
		local store = assert(ns.Store.open({}, charDb))
		store:Session(savedKey).resetAt = 1
		local market = store:Market('forever/normal/horde/eu')
		market.auctions[1] = { itemId = 2589, qty = 1, state = 'active', char = 'Aurelius-' }
		ns.Ledger.append(market, { t = 1, kind = 'sale', itemId = 2589, qty = 1, copper = 5, char = 'Aurelius-' })
		local player = ns.Wow.create(fake):Player()
		t.eq(store:CharacterKey(player), savedKey, 'not Aurelius-Server6945')
		t.eq(charDb.realm, 'CAMWOW EU5 Realm 3 PvE')
		t.eq(market.auctions[1].char, savedKey)
		t.eq(ns.Ledger.events(market)[1].char, savedKey)
	end
)

t.test("AHledger's market is read safely", function()
	local fake = fakeEnv()
	local wow = ns.Wow.create(fake)
	t.eq(wow:AHledgerMarket(), nil, 'no AHledger')
	fake.AHledgerAPI = {
		GetMarket = function()
			return 'forever/pvp/horde/eu'
		end,
	}
	t.eq(wow:AHledgerMarket(), 'forever/pvp/horde/eu')
	fake.AHledgerAPI = {
		GetMarket = function()
			error('broke')
		end,
	}
	t.eq(wow:AHledgerMarket(), nil, 'a throwing GetMarket')
end)

t.test('falls back to time() without GetServerTime', function()
	local wow = ns.Wow.create({
		time = function()
			return 99
		end,
	})
	t.eq(wow:Now(), 99)
end)

t.test('events dispatch through one hidden frame', function()
	local env = fakeEnv()
	local wow = ns.Wow.create(env)
	local got
	wow:OnEvent('ADDON_LOADED', function(event, name)
		got = event .. ' ' .. name
	end)
	t.truthy(env.frame.events.ADDON_LOADED)
	env.frame.onEvent(env.frame, 'ADDON_LOADED', 'Haggler')
	t.eq(got, 'ADDON_LOADED Haggler')
	wow:OffEvent('ADDON_LOADED')
	t.eq(env.frame.events.ADDON_LOADED, nil)
end)

t.test('print and the slash command go through the env', function()
	local env = fakeEnv()
	local wow = ns.Wow.create(env)
	wow:Print('hello')
	t.truthy(env.printed[1]:find('Haggler|r: hello', 1, true))
	local handler = function() end
	wow:RegisterSlash(handler)
	t.eq(env.SLASH_HAGGLER1, '/hag')
	t.eq(env.SlashCmdList.HAGGLER, handler)
end)

t.group('tokens')

t.test('design tokens load into the namespace, not as a Concord global', function()
	t.eq(type(ns.Tokens), 'table')
	t.eq(type(ns.Tokens.version), 'number')
	t.eq(rawget(_G, 'Concord_Tokens'), nil)
	local header = assert(io.open('Host/Tokens.lua')):read('*l')
	t.truthy(header:find('Generated by', 1, true) and header:find('Do not edit', 1, true))
end)

t.group('wow hooks')

t.test('a hook that keeps failing is reported a limited number of times per method', function()
	local env = {
		hooksecurefunc = function(object, method, hook)
			local original = object[method]
			object[method] = function(...)
				original(...)
				hook(...)
			end
		end,
	}
	local reports = {}
	local wow = ns.Wow.create(env, {
		onError = function(where)
			reports[#reports + 1] = where
		end,
	})
	local target = { Update = function() end, Layout = function() end }
	wow:HookMethod(target, 'Update', function()
		error('broken')
	end)
	wow:HookMethod(target, 'Layout', function()
		error('broken too')
	end)
	for _ = 1, 50 do
		target.Update()
	end
	target.Layout()
	t.eq(#reports, ns.Wow.HOOK_ERROR_LIMIT + 1, 'Update capped; Layout still reported')
	t.eq(reports[#reports], 'hook Layout')
end)
