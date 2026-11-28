local t = ...
local FakeGame = require('tests.fake_game')

local LINEN, SILK, UNKNOWN, QUEST_ITEM, GREY, WORTHLESS = 2589, 4306, 9999, 5000, 4000, 4001
local MARKET = 'forever/normal/alliance/us'
local NOW = 1000000
-- Linen posts on the AH (its lowest listing, 95, is 24% under its 30-day median of 125: not low
-- enough to wait); silk's AH price is under its vendor price (sell); the unknown item has no
-- price at all (undecided). The grey has only a vendor price.
-- AHledger rows: median, min buyout, quantity, 7- and 30-day median, 30-day low and high, sold a day.
local AHLEDGER_ROWS = { [2589] = { 120, 95, 500, 118, 125, 90, 160, 45 }, [4306] = { 10, 9, 500, 10, 11, 8, 12, 45 } }
-- Badges by the left and top texcoords of their icon in the atlas.
local GLYPHS = {}
do
	local addon = t.loadAddon()
	for _, styles in ipairs({ addon.Badges.DECISIONS, addon.Badges.TYPES }) do
		for kind, style in pairs(styles) do
			local coords = addon.Icons.texcoords[style.icon]
			GLYPHS[coords[1] .. ',' .. coords[3]] = kind
		end
	end
end

local function newButton(bag, slot)
	local button = FakeGame.newWidget('Button')
	function button:GetBagID()
		return bag
	end
	function button:GetBag()
		return bag
	end
	function button:GetID()
		return slot
	end
	return button
end

-- A Blizzard container frame: UpdateItems (hooked by the adapter), EnumerateValidItems yielding
-- (index, button) as Mainline does, and a money frame for the total.
local function newBagFrame(buttons)
	local frame = FakeGame.newWidget('Frame')
	frame.MoneyFrame = FakeGame.newWidget('Frame', frame)
	function frame.UpdateItems() end
	function frame.EnumerateValidItems()
		local index = 0
		return function()
			index = index + 1
			local button = buttons[index]
			if button then
				return index, button
			end
		end
	end
	return frame
end

local function newGame()
	local game = FakeGame.new({
		now = NOW,
		itemInfo = {
			[LINEN] = { name = 'Linen Cloth', maxStack = 20, vendorPrice = 13 },
			[SILK] = { name = 'Silk Cloth', maxStack = 20, vendorPrice = 50 },
		},
	})
	game.env.AHledgerAPI = FakeGame.newAHledgerAPI({ market = MARKET, updated = NOW - 7200, rows = AHLEDGER_ROWS })
	game.bagSlots[0] = 4
	game.containerItems['0:1'] = { itemID = SILK, stackCount = 1, hyperlink = 'item:4306' }
	game.containerItems['0:2'] = { itemID = UNKNOWN, stackCount = 1, hyperlink = 'item:9999' }
	game.containerItems['0:3'] = { itemID = LINEN, stackCount = 20, hyperlink = 'item:2589' }
	-- Slot 4 holds an item the client has not loaded yet.
	game.containerItems['0:4'] = { stackCount = 1 }
	return game
end

local function newButtons()
	return { newButton(0, 1), newButton(0, 2), newButton(0, 3), newButton(0, 4), newButton(0, 5) }
end

-- Outlines are the glyph in black; the glyph is the tinted copy.
local function isGlyph(texture)
	local color = texture.color
	return color ~= nil and (color[1] > 0 or color[2] > 0 or color[3] > 0)
end

local function glyphName(texture)
	return GLYPHS[texture.texcoords[1] .. ',' .. texture.texcoords[3]] or '?'
end

-- The badges a button shows, by name, sorted: 'post', 'quest,sell'...
local function badgesOf(button)
	local result = {}
	for _, child in ipairs(button.children) do
		if child.kind == 'Texture' and child.isShown and isGlyph(child) then
			result[#result + 1] = glyphName(child)
		end
	end
	table.sort(result)
	return table.concat(result, ',')
end

local function valueTextOf(button)
	for _, child in ipairs(button.children) do
		if child.kind == 'FontString' and child.isShown then
			return child.text
		end
	end
	return nil
end

-- Hooks on bag hosts (the scan module also hooks ReplicateItems).
local function bagHookCount(game)
	local count = 0
	for _, hook in ipairs(game.hooks) do
		if hook.method ~= 'ReplicateItems' and not FakeGame.TRACKING_HOOKS[hook.method] then
			count = count + 1
		end
	end
	return count
end

local function badgeRow(buttons)
	local row = {}
	for index, button in ipairs(buttons) do
		row[index] = badgesOf(button)
	end
	return row
end

local function startWithBlizzard(game)
	local buttons = newButtons()
	local frame = newBagFrame(buttons)
	game.env.ContainerFrameCombinedBags = frame
	local addon = FakeGame.startAddon(t, game)
	return addon, frame, buttons
end

t.group('bag hosts: Blizzard')

t.test('buttons get the vendor and low badges at start; empty and unloaded slots get none', function()
	local game = newGame()
	local addon, _, buttons = startWithBlizzard(game)
	t.same(badgeRow(buttons), { 'sell', 'undecided', 'post', '', '' })
	t.eq(valueTextOf(buttons[3]), nil, 'values are off by default')
	t.eq(bagHookCount(game), 1, 'UpdateItems is post-hooked once')
	t.same(addon.errors, {})
end)

t.test('UpdateItems repaints: a slot that changed item changes badge', function()
	local game = newGame()
	local _, frame, buttons = startWithBlizzard(game)
	game.containerItems['0:1'] = { itemID = LINEN, stackCount = 5, hyperlink = 'item:2589' }
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	frame:UpdateItems()
	t.same(badgeRow(buttons), { 'post', 'undecided', 'sell', '', '' })
end)

t.test('the bag total sits above the money frame, flagged low when a stack is a guess', function()
	local game = newGame()
	local _, frame = startWithBlizzard(game)
	local total = frame.children[#frame.children]
	t.eq(total.kind, 'FontString')
	t.eq(total.points[1][2], frame.MoneyFrame)
	t.truthy(total.isShown)
	t.truthy(total.text:find('^Bags: '), total.text)
	t.truthy(total.text:find('|T', 1, true), 'low confidence icon')
	game.containerItems['0:2'] = nil
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(total.text:find('Haggler\\media\\icons', 1, true), nil, 'no guess left')
end)

t.test('the value setting adds a short value; the total setting hides the total', function()
	local game = newGame()
	local addon, frame, buttons = startWithBlizzard(game)
	addon.bags:SetSetting('showValue', true)
	addon.bags:SetSetting('showTotal', false)
	game:RunTimers()
	t.eq(valueTextOf(buttons[1]), '50c')
	t.eq(valueTextOf(buttons[2]), nil, 'nothing for a 0 value')
	t.eq(frame.children[#frame.children].isShown, false)
end)

t.test('switching the module off clears every overlay and the total; hooks stay quiet', function()
	local game = newGame()
	local addon, frame, buttons = startWithBlizzard(game)
	addon.host.Disable('bags')
	t.same(badgeRow(buttons), { '', '', '', '', '' })
	t.eq(frame.children[#frame.children].isShown, false)
	frame:UpdateItems()
	t.same(badgeRow(buttons), { '', '', '', '', '' })
	addon.host.Enable('bags')
	t.same(badgeRow(buttons), { 'sell', 'undecided', 'post', '', '' })
	t.eq(bagHookCount(game), 1, 'not hooked twice')
end)

t.test('in combat a slot that changed or emptied drops its badge; prices wait for the end', function()
	local game = newGame()
	local _, frame, buttons = startWithBlizzard(game)
	game.inCombat = true
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	game.containerItems['0:1'] = nil
	frame:UpdateItems()
	t.same(badgeRow(buttons), { '', 'undecided', '', '', '' }, 'no old badge on a changed or empty slot')
	game.inCombat = false
	game:Fire('PLAYER_REGEN_ENABLED')
	game:RunTimers()
	t.same(badgeRow(buttons), { '', 'undecided', 'sell', '', '' })
end)

t.test('a Blizzard button showing its junk coin or upgrade arrow gets no decision badge', function()
	local game = newGame()
	local _, frame, buttons = startWithBlizzard(game)
	buttons[3].JunkIcon = FakeGame.newWidget('Texture', buttons[3])
	frame:UpdateItems()
	t.eq(badgesOf(buttons[3]), '', 'the coin keeps the top left')
	buttons[3].JunkIcon:Hide()
	buttons[1].UpgradeIcon = FakeGame.newWidget('Texture', buttons[1])
	frame:UpdateItems()
	t.same(badgeRow(buttons), { '', 'undecided', 'post', '', '' })
end)

t.test('a saved vendorBadge off carries over to the decision badge, then is dropped', function()
	local game = newGame()
	local addon, _, buttons = startWithBlizzard(game)
	t.eq(addon.bags:Setting('decisionBadge'), true, 'nothing saved: on')
	local function startWith(saved)
		local reloaded = newGame()
		local reloadedButtons = newButtons()
		reloaded.env.ContainerFrameCombinedBags = newBagFrame(reloadedButtons)
		local reloadedAddon = FakeGame.startAddon(t, reloaded, function(ns)
			ns.store:Settings().bags = saved
		end)
		return reloadedAddon, reloadedButtons, saved
	end
	local off, offButtons, saved = startWith({ vendorBadge = false })
	t.eq(off.bags:Setting('decisionBadge'), false)
	t.eq(saved.vendorBadge, nil, 'the old key is gone')
	t.same(badgeRow(offButtons), { '', '', '', '', '' })
	local kept = startWith({ vendorBadge = false, decisionBadge = true })
	t.eq(kept.bags:Setting('decisionBadge'), true, 'a decision badge already chosen wins')
	local on, _, onSaved = startWith({ vendorBadge = true })
	t.eq(on.bags:Setting('decisionBadge'), true)
	t.eq(onSaved.vendorBadge, nil)
	t.same(badgeRow(buttons), { 'sell', 'undecided', 'post', '', '' })
	t.same(off.errors, {})
end)

t.test('a hidden bag frame is not repainted by a refresh', function()
	local game = newGame()
	local _, frame, buttons = startWithBlizzard(game)
	frame:Hide()
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(badgesOf(buttons[3]), 'post', 'not repainted')
end)

local function withTypedItems(game)
	game.itemInfo[QUEST_ITEM] = { name = 'Sealed Letter', maxStack = 1, vendorPrice = 0, classID = 12 }
	game.itemInfo[GREY] = { name = 'Broken Fang', maxStack = 20, vendorPrice = 25 }
	game.containerItems['0:1'] = { itemID = QUEST_ITEM, stackCount = 1, quality = 1, hyperlink = 'item:5000' }
	game.questItems['0:1'] = { isQuestItem = true, isActive = false }
	game.containerItems['0:2'] = { itemID = GREY, stackCount = 3, quality = 0, hyperlink = 'item:4000' }
	game.itemInfo[WORTHLESS] = { name = 'Torn Rag', maxStack = 20, vendorPrice = 0 }
	game.containerItems['0:4'] = { itemID = WORTHLESS, stackCount = 1, quality = 0, hasNoValue = true }
end

t.test('a quest item gets the quest badge; a grey worth vendoring the junk badge alone', function()
	local game = newGame()
	withTypedItems(game)
	local addon, _, buttons = startWithBlizzard(game)
	t.same(badgeRow(buttons), { 'quest', 'junk', 'post', 'undecided', '' }, 'a grey with no value is not junk')
	t.same(addon.errors, {})
end)

t.test('the quest badge falls back to the item class when the client has no quest info', function()
	local game = newGame()
	withTypedItems(game)
	game.questItems['0:1'] = nil
	game.env.C_Container.GetContainerItemQuestInfo = nil
	local _, _, buttons = startWithBlizzard(game)
	t.eq(badgesOf(buttons[1]), 'quest')
end)

t.test('the type badge sits top right, the decision top left, both clear of the stack count', function()
	local game = newGame()
	withTypedItems(game)
	game.containerItems['0:2'] = { itemID = LINEN, stackCount = 20, quality = 0, hyperlink = 'item:2589' }
	local _, _, buttons = startWithBlizzard(game)
	t.eq(badgesOf(buttons[2]), 'junk,post', 'a grey that sells better on the AH')
	for _, child in ipairs(buttons[2].children) do
		if child.kind == 'Texture' and child.isShown and isGlyph(child) then
			local point = child:GetPoint(1)
			t.eq(point, glyphName(child) == 'junk' and 'TOPRIGHT' or 'TOPLEFT', glyphName(child))
		end
	end
end)

t.test('the decision and type badge settings hide their badges', function()
	local game = newGame()
	withTypedItems(game)
	local addon, _, buttons = startWithBlizzard(game)
	addon.bags:SetSetting('decisionBadge', false)
	game:RunTimers()
	t.same(badgeRow(buttons), { 'quest', 'junk', '', '', '' }, 'the decisions are hidden')
	addon.bags:SetSetting('typeBadge', false)
	game:RunTimers()
	t.same(badgeRow(buttons), { '', '', '', '', '' })
end)

t.group('bag hosts: BagPad')

t.test('BagPad: its NATIVE_UPDATE message repaints the native frame', function()
	local game = newGame()
	local buttons = newButtons()
	local listeners = {}
	game.env.BagPad = {
		Events = {
			Listen = function(_, message, owner, fn)
				listeners[#listeners + 1] = { message = message, owner = owner, fn = fn }
			end,
		},
		Native = { frame = newBagFrame(buttons) },
	}
	local addon = FakeGame.startAddon(t, game)
	t.eq(#listeners, 1)
	t.eq(listeners[1].message, 'NATIVE_UPDATE')
	t.eq(listeners[1].owner, 'Haggler')
	t.same(badgeRow(buttons), { 'sell', 'undecided', 'post', '', '' }, 'painted by the first refresh')
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	listeners[1].fn()
	t.eq(badgesOf(buttons[3]), 'sell')
	t.same(addon.errors, {})
end)

t.group('bag hosts: Bagnon')

local function newBagnon(inventoryFrame)
	local itemGroup = { Layout = function() end, ForBag = function() end }
	return {
		InventoryItemGroup = itemGroup,
		Frames = {
			Get = function(_, id)
				return id == 'inventory' and inventoryFrame or nil
			end,
		},
	}
end

t.test('Bagnon loaded later: attached on ADDON_LOADED, groups painted after Layout and ForBag', function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game)
	local inventory = newBagFrame({})
	game.env.Bagnon = newBagnon(inventory)
	game:Fire('ADDON_LOADED', 'Bagnon')
	game:RunTimers()
	t.eq(bagHookCount(game), 2)
	local list = newButtons()
	-- Kept in a local to the end, as Bagnon keeps its live groups.
	local group = { buttons = list }
	game.env.Bagnon.InventoryItemGroup.Layout(group)
	t.same(badgeRow(list), { 'sell', 'undecided', 'post', '', '' })
	-- Some versions keep buttons as a bag -> slot map.
	local mapped = { newButton(0, 1), newButton(0, 2) }
	game.env.Bagnon.InventoryItemGroup.ForBag({ buttons = { [0] = { [1] = mapped[1], [2] = mapped[2] } } })
	t.same(badgeRow(mapped), { 'sell', 'undecided' })
	local total = inventory.children[#inventory.children]
	t.truthy(total.text:find('^Bags: '))
	game.containerItems['0:3'] = { itemID = SILK, stackCount = 2, hyperlink = 'item:4306' }
	-- Bagnon's adapter holds groups weakly, as Bagnon holds them; collect now so the test
	-- does not depend on when the collector runs.
	collectgarbage()
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(badgesOf(list[3]), 'sell', 'known groups repaint on bag updates')
	t.eq(group.buttons, list)
	t.same(addon.errors, {})
end)

local function fontStringCount(frame)
	local count = 0
	for _, child in ipairs(frame.children) do
		count = count + (child.kind == 'FontString' and 1 or 0)
	end
	return count
end

t.test('Bagnon: the money frame class table is never used; the total attaches once to the real one', function()
	local game = newGame()
	local inventory = FakeGame.newWidget('Frame')
	-- Before PlaceMoney (or with money hidden) MoneyFrame is only the PlayerMoney class.
	local playerMoneyClass = {
		SetPoint = function()
			error('SetPoint on a class table')
		end,
	}
	setmetatable(inventory, { __index = { MoneyFrame = playerMoneyClass } })
	game.env.Bagnon = newBagnon(inventory)
	local addon = FakeGame.startAddon(t, game)
	for _ = 1, 3 do
		game.env.Bagnon.InventoryItemGroup.Layout({ buttons = newButtons() })
	end
	t.eq(fontStringCount(inventory), 0, 'nothing created before the money frame exists')
	rawset(inventory, 'MoneyFrame', FakeGame.newWidget('Frame', inventory))
	game.env.Bagnon.InventoryItemGroup.Layout({ buttons = newButtons() })
	game.env.Bagnon.InventoryItemGroup.Layout({ buttons = newButtons() })
	t.eq(fontStringCount(inventory), 1, 'one total, created once')
	t.same(addon.errors, {})
	t.eq(#game.printed, 0, table.concat(game.printed, '\n'))
end)

t.test("Bagnon: another character's cached bags are not painted, and old paint is cleared", function()
	local game = newGame()
	game.env.Bagnon = newBagnon(newBagFrame({}))
	local addon = FakeGame.startAddon(t, game)
	local list = newButtons()
	local group = { buttons = list, isCached = false }
	function group:IsCached()
		return self.isCached
	end
	game.env.Bagnon.InventoryItemGroup.Layout(group)
	t.same(badgeRow(list), { 'sell', 'undecided', 'post', '', '' })
	group.isCached = true
	game.env.Bagnon.InventoryItemGroup.Layout(group)
	t.same(badgeRow(list), { '', '', '', '', '' }, 'an alt is shown from the cache')
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.same(badgeRow(list), { '', '', '', '', '' }, 'a repaint skips it too')
	t.same(addon.errors, {})
end)

t.group('bag hosts: Baganator')

local function newBaganator()
	local api = { widgets = {}, regions = {}, refreshes = 0, layouts = 0 }
	api.RegisterCornerWidget = function(label, id, onUpdate, onInit, defaults, isFast)
		api.widgets[id] = { label = label, onUpdate = onUpdate, onInit = onInit, defaults = defaults, isFast = isFast }
	end
	api.RegisterRegion = function(label, id, view, position, frame)
		api.regions[id] = { label = label, view = view, position = position, frame = frame }
	end
	api.RequestItemButtonsRefresh = function()
		api.refreshes = api.refreshes + 1
	end
	api.RequestLayoutUpdate = function()
		api.layouts = api.layouts + 1
	end
	return { API = api }
end

local function widgetRegion(api, id)
	return api.widgets[id].onInit(FakeGame.newWidget('Button'))
end

t.test('Baganator: three corner widgets answer show, hide or not ready', function()
	local game = newGame()
	game.env.Baganator = newBaganator()
	local addon = FakeGame.startAddon(t, game)
	local api = game.env.Baganator.API
	t.eq(api.widgets.haggler_decision.defaults.corner, 'top_left')
	t.eq(api.widgets.haggler_type.defaults.corner, 'top_right')
	t.eq(api.widgets.haggler_value.defaults.corner, 'bottom_left')
	t.eq(api.widgets.haggler_vendor, nil, 'the old widgets are gone')
	t.eq(api.widgets.haggler_low, nil)
	for _, widget in pairs(api.widgets) do
		t.truthy(widget.defaults.priority >= 100, 'appended after the user widgets, never inserted ahead')
	end
	local decision, itemType = widgetRegion(api, 'haggler_decision'), widgetRegion(api, 'haggler_type')
	t.eq(decision.kind, 'Frame', 'a frame holds the glyph and its outline')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, { itemID = SILK, itemCount = 3 }), true)
	t.eq(badgesOf(decision), 'sell')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, { itemID = LINEN, itemCount = 3 }), true)
	t.eq(badgesOf(decision), 'post', 'the same frame shows the new badge')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, { itemID = UNKNOWN }), true)
	t.eq(badgesOf(decision), 'undecided')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, {}), nil, 'item data not ready')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, { itemID = SILK, isBound = true }), false, 'bound')
	t.eq(api.widgets.haggler_type.onUpdate(itemType, { itemID = LINEN, itemCount = 3 }), false, 'no type')
	withTypedItems(game)
	t.eq(api.widgets.haggler_type.onUpdate(itemType, { itemID = QUEST_ITEM, quality = 1 }), true)
	t.eq(badgesOf(itemType), 'quest')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, { itemID = QUEST_ITEM, quality = 1 }), false)
	t.eq(api.widgets.haggler_type.onUpdate(itemType, { itemID = GREY, itemCount = 3, quality = 0 }), true)
	t.eq(badgesOf(itemType), 'junk')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, { itemID = GREY, quality = 0 }), false, 'junk sells')
	local value = widgetRegion(api, 'haggler_value')
	t.eq(value.kind, 'FontString')
	t.eq(api.widgets.haggler_value.onUpdate(value, { itemID = LINEN, itemCount = 20 }), false, 'values off')
	addon.bags:SetSetting('showValue', true)
	t.eq(api.widgets.haggler_value.onUpdate(value, { itemID = LINEN, itemCount = 20 }), true)
	t.eq(value.text, '17s')
	addon.host.Disable('bags')
	t.eq(api.widgets.haggler_decision.onUpdate(decision, { itemID = SILK }), false, 'module off')
	t.eq(api.widgets.haggler_type.onUpdate(itemType, { itemID = QUEST_ITEM }), false, 'module off')
	t.same(addon.errors, {})
end)

t.test('Baganator: the total region follows its text width; repaints ask for a refresh', function()
	local game = newGame()
	game.env.Baganator = newBaganator()
	FakeGame.startAddon(t, game)
	local api = game.env.Baganator.API
	local region = api.regions.haggler_total
	t.eq(region.view, 'backpack')
	t.eq(region.position, 'bottom_left')
	local text = region.frame.children[1]
	t.truthy(text.text:find('^Bags: '))
	t.eq(region.frame.width, text:GetStringWidth() + 4)
	t.truthy(api.layouts >= 1)
	local refreshes = api.refreshes
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.eq(api.refreshes, refreshes + 1)
end)

t.test('a saved scan repaints the bags (SCAN_READY)', function()
	local game = newGame()
	game.env.Baganator = newBaganator()
	local addon = FakeGame.startAddon(t, game)
	local api = game.env.Baganator.API
	local refreshes = api.refreshes
	addon.host.Bus:Send('SCAN_READY', MARKET, { at = NOW, source = 'scan', count = 2 })
	game:RunTimers()
	t.eq(api.refreshes, refreshes + 1)
	addon.host.Disable('bags')
	refreshes = api.refreshes
	addon.host.Bus:Send('SCAN_READY', MARKET, { at = NOW, source = 'scan', count = 2 })
	game:RunTimers()
	t.eq(api.refreshes, refreshes, 'no repaint while the module is off')
end)

t.test('a host that throws is reported and skipped, never fatal', function()
	local game = newGame()
	game.env.Baganator = { API = {
		RegisterCornerWidget = function()
			error('API changed')
		end,
	} }
	local addon, _, buttons = startWithBlizzard(game)
	t.same(badgeRow(buttons), { 'sell', 'undecided', 'post', '', '' }, 'Blizzard still painted')
	local printed = table.concat(game.printed, '\n')
	t.truthy(printed:find('bag host Baganator failed', 1, true), printed)
	t.same(addon.errors, {})
end)

t.test('no bag host at all is a no-op', function()
	local game = newGame()
	local addon = FakeGame.startAddon(t, game)
	game:Fire('BAG_UPDATE_DELAYED')
	game:RunTimers()
	t.same(addon.errors, {})
	t.eq(bagHookCount(game), 0)
end)
