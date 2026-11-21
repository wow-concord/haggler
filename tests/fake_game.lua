-- A fake game environment for Engine/Wow.lua: a clock, timers that run when the test says so,
-- an event frame, the auction house replicate list, modifier keys and item tooltips; since
-- step 3 also widgets (frames, textures, font strings), hooksecurefunc, bags, the trade window
-- and its partner.
local FakeGame = {}

-- Helpers live further down; declared here so they stay local.
local addAuctionHouseActions, addTrackingApi

-- Widgets ---------------------------------------------------------------------------------

--- A region that records what the add-on did to it: points, size, text, texture, colour,
--- shown state, scripts and children. Only methods the client really has are defined, so a
--- typo fails the test instead of passing silently.
function FakeGame.newWidget(kind, parent, template)
	local widget = {
		kind = kind,
		parent = parent,
		template = template,
		points = {},
		children = {},
		scripts = {},
		isShown = true,
		alpha = 1,
		isEnabled = true,
		frameLevel = parent and parent.frameLevel and parent.frameLevel + 1 or 1,
	}
	-- A real region keeps its C object at [0]; adapters tell a region from a class table by it.
	widget[0] = newproxy(false)
	function widget:SetPoint(...)
		self.points[#self.points + 1] = { ... }
	end
	function widget:SetAllPoints(target)
		self.allPoints = target
	end
	function widget:ClearAllPoints()
		self.points = {}
	end
	function widget:GetPoint(index)
		return unpack(self.points[index or 1] or {})
	end
	-- Screen edges are what a test sets in left / right; nil, as for a frame not laid out yet.
	function widget:GetLeft()
		return self.left
	end
	function widget:GetRight()
		return self.right
	end
	function widget:SetSize(width, height)
		self.width, self.height = width, height
	end
	function widget:SetWidth(width)
		self.width = width
	end
	function widget:SetHeight(height)
		self.height = height
	end
	function widget:GetWidth()
		return self.width or 0
	end
	-- Like the client, a change of shown state runs OnShow / OnHide.
	function widget:Show()
		local wasShown = self.isShown
		self.isShown = true
		if not wasShown and self.scripts and self.scripts.OnShow then
			self.scripts.OnShow(self)
		end
	end
	function widget:Hide()
		local wasShown = self.isShown
		self.isShown = false
		if wasShown and self.scripts and self.scripts.OnHide then
			self.scripts.OnHide(self)
		end
	end
	function widget:SetShown(isShown)
		if isShown then
			self:Show()
		else
			self:Hide()
		end
	end
	function widget:SetAlpha(alpha)
		self.alpha = alpha
	end
	function widget:GetAlpha()
		return self.alpha
	end
	-- Like the client, a region's drawn alpha is its own times every parent's.
	function widget:GetEffectiveAlpha()
		local parentAlpha = self.parent and self.parent.GetEffectiveAlpha and self.parent:GetEffectiveAlpha() or 1
		return (self.alpha or 1) * parentAlpha
	end
	function widget:IsShown()
		return self.isShown
	end
	function widget:GetParent()
		return self.parent
	end
	if kind == 'FontString' then
		function widget:SetText(text)
			self.text = text
		end
		function widget:GetText()
			return self.text
		end
		function widget:GetStringWidth()
			return self.text and #tostring(self.text) * 6 or 0
		end
		function widget:SetFont(path, size, flags)
			self.font = { path, size, flags }
			return true
		end
		function widget:SetJustifyH(justify)
			self.justifyH = justify
		end
		function widget:SetTextColor(r, g, b, a)
			self.textColor = { r, g, b, a }
		end
		return widget
	end
	if kind == 'Texture' then
		function widget:SetTexture(path)
			self.texture = path
		end
		function widget:SetTexCoord(left, right, top, bottom)
			self.texcoords = { left, right, top, bottom }
		end
		function widget:SetVertexColor(r, g, b, a)
			self.color = { r, g, b, a }
		end
		function widget:SetColorTexture(r, g, b, a)
			self.colorTexture = { r, g, b, a }
		end
		return widget
	end
	function widget:CreateTexture(_, layer)
		local texture = FakeGame.newWidget('Texture', self)
		texture.layer = layer
		self.children[#self.children + 1] = texture
		return texture
	end
	function widget:CreateFontString(_, layer, fontTemplate)
		local text = FakeGame.newWidget('FontString', self)
		text.layer, text.fontTemplate = layer, fontTemplate
		self.children[#self.children + 1] = text
		return text
	end
	function widget:SetScript(script, handler)
		self.scripts[script] = handler
	end
	-- Runs after the script already set, as the client chains hooks.
	function widget:HookScript(script, handler)
		local previous = self.scripts[script]
		self.scripts[script] = function(...)
			if previous then
				previous(...)
			end
			handler(...)
		end
	end
	function widget:SetClampedToScreen(isClamped)
		self.isClampedToScreen = isClamped
	end
	function widget:GetScript(script)
		return self.scripts[script]
	end
	function widget:EnableMouse(isEnabled)
		self.isMouseEnabled = isEnabled
	end
	function widget:SetFrameLevel(level)
		self.frameLevel = level
	end
	function widget:GetFrameLevel()
		return self.frameLevel
	end
	function widget:SetFrameStrata(strata)
		self.strata = strata
	end
	function widget:GetFrameStrata()
		return self.strata
	end
	function widget:SetMovable(isMovable)
		self.isMovable = isMovable
	end
	function widget:RegisterForDrag(...)
		self.dragButtons = { ... }
	end
	function widget:StartMoving()
		self.isMoving = true
	end
	function widget:StopMovingOrSizing()
		self.isMoving = false
	end
	if kind == 'EditBox' then
		function widget:SetText(text)
			self.text = text
		end
		function widget:GetText()
			return self.text or ''
		end
		function widget:SetAutoFocus(isAutoFocus)
			self.isAutoFocus = isAutoFocus
		end
		function widget:ClearFocus()
			self.hasFocus = false
		end
		function widget:SetFocus()
			self.hasFocus = true
		end
		function widget:HasFocus()
			return self.hasFocus == true
		end
		--- The player types text and presses Enter.
		function widget:Submit(text)
			self.text = text
			if self.scripts.OnEnterPressed then
				self.scripts.OnEnterPressed(self)
			end
		end
	end
	if kind == 'Button' then
		function widget:SetText(text)
			self.text = text
		end
		function widget:GetText()
			return self.text
		end
		function widget:Enable()
			self.isEnabled = true
		end
		function widget:Disable()
			self.isEnabled = false
		end
		function widget:IsEnabled()
			return self.isEnabled
		end
		--- A hardware click, as the player makes it; a disabled button takes none.
		function widget:Click()
			if self.isEnabled and self.scripts.OnClick then
				self.scripts.OnClick(self, 'LeftButton')
			end
		end
	end
	return widget
end

-- An event in unknownEvents is one this client does not have: RegisterEvent raises, as it does.
local function newFrame(unknownEvents)
	local frame = { events = {} }
	function frame:SetScript(_, handler)
		self.onEvent = handler
	end
	function frame:RegisterEvent(event)
		if unknownEvents and unknownEvents[event] then
			error('Attempt to register unknown event "' .. event .. '"')
		end
		self.events[event] = true
	end
	function frame:UnregisterEvent(event)
		self.events[event] = nil
	end
	return frame
end

local function newTooltip(game, name)
	local tooltip = { name = name, lines = {}, shownCount = 0, isShown = true, scripts = {} }
	function tooltip:SetOwner(owner, anchor)
		self.owner, self.anchor = owner, anchor
	end
	function tooltip:ClearLines()
		self.lines = {}
	end
	function tooltip:Hide()
		self.isShown = false
		self.hiddenCount = (self.hiddenCount or 0) + 1
	end
	function tooltip:AddLine(text, r, g, b, wrap)
		self.lines[#self.lines + 1] = { left = text, r = r, g = g, b = b, wrap = wrap }
	end
	function tooltip:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
		self.lines[#self.lines + 1] =
			{ left = left, right = right, lr = lr, lg = lg, lb = lb, rr = rr, rg = rg, rb = rb }
	end
	function tooltip:Show()
		self.shownCount = self.shownCount + 1
	end
	function tooltip:IsShown()
		return self.isShown
	end
	function tooltip:IsForbidden()
		return self.isForbidden == true
	end
	function tooltip:GetItem()
		return self.itemName, self.itemLink
	end
	function tooltip:GetOwner()
		return self.owner
	end
	function tooltip:HookScript(script, handler)
		self.scripts[script] = handler
	end
	function tooltip:RefreshData()
		self.refreshed = (self.refreshed or 0) + 1
		self.lines = {}
		game:ShowItemTooltip(self.shownItemId, self)
	end
	return tooltip
end

--- A new fake game. Options: { now, listings, itemInfo, hasProcessor = true, hasClock = true }.
--- listings: { { itemId, count, buyout, bid?, timeLeft?, seller?, isLoaded? }... } served by
--- GetReplicateItemInfo and GetReplicateItemTimeLeft (0-based index). timeLeft is the raw
--- client value, 1 (short) to 4 (very long) as AHledger's saved scans show; it defaults to 4.
--- As in the client, some rows come back before their seller is loaded: every third row, and
--- any row with isLoaded = false, has no owner and hasAllInfo false.
--- game.unknownEvents[event] makes RegisterEvent raise for it, as for an event the client lacks.
--- game.inCombat drives InCombatLockdown; game.secretValues[value] marks a secret value;
--- RequestLoadItemDataByID calls are recorded in game.itemDataRequests; GetItemInfo of an item
--- not in itemInfo (the client then asks the server for it) in game.itemInfoMisses.
--- Bags: game.containerItems['bag:slot'] = { itemID?, stackCount, isBound, hyperlink } (itemID
--- nil models an item the client has not loaded), game.bagSlots[bag] = slots.
--- Trade: game.trade.player / .target = { money, slots = { [slot] = { name?, count, link? } } }
--- (a slot with a name and no link is an item not loaded yet); game.partner = { name, guid,
--- isGuild }; game.friendGuids[guid] marks a friend, game.bnetFriends lists Battle.net friends'
--- character GUIDs (one game account each). AcceptTrade
--- calls are counted in game.acceptCount. Frames the add-on creates go to game.createdFrames.
-- The auction house's post, search and buy calls (step 4): every call is recorded in
-- game.auctionHouse.calls as { name, ... }; the answers come from game.auctionHouse.
function addAuctionHouseActions(game, env)
	local auctionHouse = game.auctionHouse
	local api = env.C_AuctionHouse
	local function record(name, ...)
		auctionHouse.calls[#auctionHouse.calls + 1] = { name, ... }
	end
	function api.IsSellItemValid(location)
		local item = game.containerItems[location.bag .. ':' .. location.slot]
		return item ~= nil and not auctionHouse.unsellable[item.itemID]
	end
	function api.GetItemCommodityStatus(location)
		local item = game.containerItems[location.bag .. ':' .. location.slot]
		return item and auctionHouse.commodities[item.itemID] and 2 or 1
	end
	function api.CalculateCommodityDeposit()
		return auctionHouse.deposit
	end
	function api.CalculateItemDeposit()
		return auctionHouse.deposit
	end
	for _, name in ipairs({ 'PostCommodity', 'PostItem', 'ConfirmPostCommodity', 'ConfirmPostItem' }) do
		api[name] = function(...)
			record(name, ...)
			return not name:find('^Confirm') and auctionHouse.needsConfirm or nil
		end
	end
	function api.MakeItemKey(itemId)
		return { itemID = itemId }
	end
	function api.SendSearchQuery(itemKey)
		record('SendSearchQuery', itemKey.itemID)
	end
	function api.GetNumCommoditySearchResults()
		return #auctionHouse.commodityResults
	end
	function api.GetCommoditySearchResultInfo(_, index)
		return auctionHouse.commodityResults[index]
	end
	function api.GetNumItemSearchResults()
		return #auctionHouse.itemResults
	end
	function api.GetItemSearchResultInfo(_, index)
		return auctionHouse.itemResults[index]
	end
	for _, name in ipairs({
		'StartCommoditiesPurchase',
		'ConfirmCommoditiesPurchase',
		'CancelCommoditiesPurchase',
		'PlaceBid',
	}) do
		api[name] = function(...)
			record(name, ...)
		end
	end
	env.Enum = env.Enum or {}
	env.Enum.ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 }
	env.Enum.AuctionHouseSortOrder = { Price = 0 }
	-- Blizzard's auction house window: hidden until the test opens the auction house.
	env.AuctionHouseFrame = FakeGame.newWidget('Frame', env.UIParent)
	env.AuctionHouseFrame:Hide()
end

FakeGame.TRACKING_HOOKS = {}
for _, method in ipairs({
	'PostItem',
	'ConfirmPostItem',
	'PostCommodity',
	'ConfirmPostCommodity',
	'CancelAuction',
	'ConfirmCommoditiesPurchase',
	'PlaceBid',
	'TakeInboxMoney',
	'TakeInboxItem',
	'AutoLootMailItem',
	'BuyMerchantItem',
	'UseContainerItem',
	'PickupContainerItem',
	'DeleteCursorItem',
	'CraftRecipe',
}) do
	FakeGame.TRACKING_HOOKS[method] = true
end

--- Step 5's bookkeeping APIs: owned auctions, the mailbox, the merchant, destroying, crafting.
--- game.owned = { { auctionID, itemKey, quantity, status } }; game.mail = { { subject, money,
--- daysLeft, invoice = { type, itemName, bid, deposit, cut, count }, items = { { itemId, count } } } };
--- game.merchant = { [index] = { itemId, price, stack, hasExtendedCost } }; game.itemCounts;
--- game.schematics = { [recipeId] = schematic }, all learned unless game.unlearned[recipeId];
--- game.cursorItem; game.isMerchantOpen.
function addTrackingApi(game, env)
	--- Hooks other than the tracking module's (Features/Tracking.lua), which every start installs.
	function game:HookCount()
		local count = 0
		for _, hook in ipairs(self.hooks) do
			if not FakeGame.TRACKING_HOOKS[hook.method] then
				count = count + 1
			end
		end
		return count
	end
	game.owned, game.mail, game.merchant, game.itemCounts, game.schematics = {}, {}, {}, {}, {}
	local api = env.C_AuctionHouse
	local function record(name, ...)
		game.auctionHouse.calls[#game.auctionHouse.calls + 1] = { name, ... }
	end
	function api.GetNumOwnedAuctions()
		return #game.owned
	end
	function api.GetOwnedAuctionInfo(index)
		return game.owned[index]
	end
	function api.GetAuctionInfoByID(auctionId)
		return game.auctionHouse.byId and game.auctionHouse.byId[auctionId]
	end
	function api.CancelAuction(...)
		record('CancelAuction', ...)
	end
	env.Enum.AuctionStatus = { Active = 0, Sold = 1 }
	env.C_Item.GetItemID = function(location)
		local item = game.containerItems[location.bag .. ':' .. location.slot]
		return item and item.itemID
	end
	env.C_Item.GetItemCount = function(itemId)
		return game.itemCounts[itemId] or 0
	end
	env.GetInboxNumItems = function()
		return #game.mail, #game.mail
	end
	env.GetInboxHeaderInfo = function(index)
		local mail = game.mail[index]
		if mail then
			return nil,
				nil,
				'Auction House',
				mail.subject,
				mail.money or 0,
				0,
				mail.daysLeft or 30,
				mail.items and #mail.items or nil
		end
	end
	env.GetInboxInvoiceInfo = function(index)
		local invoice = game.mail[index] and game.mail[index].invoice
		if invoice then
			return invoice.type,
				invoice.itemName,
				'Buyer',
				invoice.bid,
				invoice.bid,
				invoice.deposit or 0,
				invoice.cut or 0,
				0,
				0,
				0,
				invoice.count
		end
	end
	env.GetInboxItem = function(index, attachment)
		local item = game.mail[index] and game.mail[index].items and game.mail[index].items[attachment]
		if item then
			return 'Item', item.itemId, 'icon', item.count
		end
	end
	env.ATTACHMENTS_MAX_RECEIVE = 4
	for _, name in ipairs({
		'TakeInboxMoney',
		'TakeInboxItem',
		'AutoLootMailItem',
		'BuyMerchantItem',
		'DeleteCursorItem',
	}) do
		env[name] = function(...)
			record(name, ...)
		end
	end
	env.GetMerchantItemID = function(index)
		return game.merchant[index] and game.merchant[index].itemId
	end
	env.C_MerchantFrame = {
		GetItemInfo = function(index)
			local item = game.merchant[index]
			return item and { price = item.price, stackCount = item.stack or 1, hasExtendedCost = item.hasExtendedCost }
		end,
	}
	env.MerchantFrame = FakeGame.newWidget('Frame', env.UIParent)
	env.MerchantFrame:Hide()
	env.C_Container.UseContainerItem = function(...)
		record('UseContainerItem', ...)
	end
	env.C_Container.PickupContainerItem = function(...)
		record('PickupContainerItem', ...)
	end
	env.GetCursorInfo = function()
		if game.cursorItem then
			return 'item', game.cursorItem
		end
	end
	env.C_TradeSkillUI = {
		GetRecipeSchematic = function(recipeId)
			return game.schematics[recipeId]
		end,
		GetAllRecipeIDs = function()
			local recipeIds = {}
			for recipeId in pairs(game.schematics) do
				recipeIds[#recipeIds + 1] = recipeId
			end
			table.sort(recipeIds)
			return recipeIds
		end,
		GetRecipeInfo = function(recipeId)
			if not game.schematics[recipeId] then
				return nil
			end
			return { recipeID = recipeId, learned = not (game.unlearned and game.unlearned[recipeId]) }
		end,
		CraftRecipe = function(...)
			record('CraftRecipe', ...)
		end,
	}
end

--- The client's Settings API (Settings → AddOns) as far as Haggler uses it; what was
--- registered is kept in game.settingsApi.
function FakeGame.addSettingsApi(game)
	local registered = { settings = {}, checkboxes = {}, initializers = {}, addOnCategories = {} }
	game.settingsApi = registered
	local layout = {}
	function layout.AddInitializer(_, initializer)
		registered.initializers[#registered.initializers + 1] = initializer
	end
	game.env.Settings = {
		VarType = { Boolean = 'boolean' },
		RegisterVerticalLayoutCategory = function(name)
			registered.category = {
				name = name,
				GetID = function()
					return 42
				end,
			}
			return registered.category, layout
		end,
		RegisterProxySetting = function(category, variable, varType, label, default, getValue, setValue)
			local setting = {
				category = category,
				variable = variable,
				varType = varType,
				label = label,
				default = default,
				GetValue = getValue,
				SetValue = setValue,
			}
			registered.settings[variable] = setting
			return setting
		end,
		CreateCheckbox = function(_, setting)
			registered.checkboxes[#registered.checkboxes + 1] = setting
		end,
		RegisterAddOnCategory = function(category)
			registered.addOnCategories[#registered.addOnCategories + 1] = category
		end,
		OpenToCategory = function(id)
			registered.openedId = id
		end,
	}
	game.env.CreateSettingsButtonInitializer = function(name, buttonText, onClick, tooltip, addSearchTags)
		return { name = name, buttonText = buttonText, onClick = onClick, tooltip = tooltip, tags = addSearchTags }
	end
end

function FakeGame.new(options)
	options = options or {}
	local unknownEvents = {}
	local game = {
		unknownEvents = unknownEvents,
		now = options.now or 1000000,
		clockMs = 0,
		timers = {},
		listings = options.listings or {},
		modifiers = {},
		printed = {},
		replicateRequests = 0,
		frame = newFrame(unknownEvents),
		postCalls = {},
		containerItems = {},
		itemInfo = options.itemInfo or {},
		itemDataRequests = {},
		itemInfoMisses = {},
		inCombat = false,
		secretValues = {},
		bagSlots = {},
		createdFrames = {},
		overrideBindings = {},
		hooks = {},
		trade = { player = { money = 0, slots = {} }, target = { money = 0, slots = {} } },
		friendGuids = {},
		bnetFriends = {},
		acceptCount = 0,
		loadedAddOns = {},
		auctionHouse = {
			calls = {},
			unsellable = {},
			commodities = {},
			deposit = 100,
			needsConfirm = false,
			commodityResults = {},
			itemResults = {},
		},
	}
	local uiParent = FakeGame.newWidget('Frame')
	local env = {
		GetServerTime = function()
			return game.now
		end,
		time = function()
			return game.now
		end,
		-- The engine's hidden event frame is the one created without a parent; every other frame
		-- is a recorded widget.
		CreateFrame = function(kind, name, parent, template)
			if parent == nil then
				return game.frame
			end
			local widget = FakeGame.newWidget(kind, parent, template)
			widget.name = name
			game.createdFrames[#game.createdFrames + 1] = widget
			if name then
				game.env[name] = widget
			end
			return widget
		end,
		UISpecialFrames = {},
		IsLoggedIn = function()
			return game.isLoggedIn == true
		end,
		C_AddOns = {
			IsAddOnLoaded = function(name)
				return game.loadedAddOns[name] == true
			end,
		},
		ItemLocation = {
			CreateFromBagAndSlot = function(_, bag, slot)
				return { bag = bag, slot = slot }
			end,
		},
		UIParent = uiParent,
		hooksecurefunc = function(object, method, hook)
			local original = object[method]
			game.hooks[#game.hooks + 1] = { object = object, method = method }
			object[method] = function(...)
				local results = { original(...) }
				hook(...)
				return unpack(results)
			end
		end,
		NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5,
		LE_GAME_ERR_TRADE_COMPLETE = 226,
		ERR_TRADE_COMPLETE = 'Trade complete.',
		GetTradePlayerItemInfo = function(slot)
			local entry = game.trade.player.slots[slot]
			if entry then
				return entry.name, 'icon', entry.count, 1, true, nil
			end
		end,
		GetTradeTargetItemInfo = function(slot)
			local entry = game.trade.target.slots[slot]
			if entry then
				return entry.name, 'icon', entry.count, 1, true, nil
			end
		end,
		GetTradePlayerItemLink = function(slot)
			local entry = game.trade.player.slots[slot]
			return entry and entry.link or nil
		end,
		GetTradeTargetItemLink = function(slot)
			local entry = game.trade.target.slots[slot]
			return entry and entry.link or nil
		end,
		GetPlayerTradeMoney = function()
			return game.trade.player.money
		end,
		GetTargetTradeMoney = function()
			return game.trade.target.money
		end,
		AcceptTrade = function()
			game.acceptCount = game.acceptCount + 1
		end,
		UnitGUID = function(unit)
			return unit == 'NPC' and game.partner and game.partner.guid or nil
		end,
		UnitIsInMyGuild = function(unit)
			return unit == 'NPC' and game.partner ~= nil and game.partner.isGuild == true
		end,
		C_FriendList = {
			IsFriend = function(guid)
				return game.friendGuids[guid] == true
			end,
		},
		BNGetNumFriends = function()
			return #game.bnetFriends
		end,
		C_BattleNet = {
			GetFriendNumGameAccounts = function(friend)
				return game.bnetFriends[friend] and 1 or 0
			end,
			GetFriendGameAccountInfo = function(friend)
				local guid = game.bnetFriends[friend]
				return guid and { playerGuid = guid } or nil
			end,
		},
		DEFAULT_CHAT_FRAME = {
			AddMessage = function(_, text)
				game.printed[#game.printed + 1] = text
			end,
		},
		SlashCmdList = {},
		GetRealmName = function()
			return 'Nightslayer'
		end,
		UnitName = function(unit)
			if unit == 'NPC' then
				return game.partner and game.partner.name or nil
			end
			return 'Eilu'
		end,
		UnitFactionGroup = function()
			return 'Alliance'
		end,
		GetCurrentRegion = function()
			return 1
		end,
		C_Item = {
			-- Like the client, asking for an item it has not cached sends a request for it.
			GetItemInfo = function(itemId)
				local info = game.itemInfo[itemId]
				if info then
					return info.name or 'Item', 'link', 1, 1, 0, 'Type', 'Sub', info.maxStack, '', 0, info.vendorPrice
				end
				game.itemInfoMisses[#game.itemInfoMisses + 1] = itemId
			end,
			IsItemDataCachedByID = function(itemId)
				return game.itemInfo[itemId] ~= nil
			end,
			RequestLoadItemDataByID = function(itemId)
				game.itemDataRequests[#game.itemDataRequests + 1] = itemId
			end,
		},
		InCombatLockdown = function()
			return game.inCombat == true
		end,
		GetMoney = function()
			return game.money or 0
		end,
		-- game.overrideBindings[owner][key] = button name; game:PressKey(key) clicks it.
		SetOverrideBindingClick = function(owner, _, key, buttonName)
			game.overrideBindings[owner] = game.overrideBindings[owner] or {}
			game.overrideBindings[owner][key] = buttonName
		end,
		ClearOverrideBindings = function(owner)
			game.overrideBindings[owner] = nil
		end,
		issecretvalue = function(value)
			return value ~= nil and game.secretValues[value] == true
		end,
		C_Timer = {
			After = function(seconds, fn)
				game.timers[#game.timers + 1] = { at = game.now + seconds, fn = fn, isNextFrame = seconds == 0 }
			end,
		},
		C_AuctionHouse = {
			ReplicateItems = function()
				game.replicateRequests = game.replicateRequests + 1
			end,
			GetNumReplicateItems = function()
				return #game.listings
			end,
			GetReplicateItemInfo = function(index)
				game.rowsRead = (game.rowsRead or 0) + 1
				game.clockMs = game.clockMs + (game.msPerRow or 0)
				local listing = game.listings[index + 1]
				if not listing then
					return nil
				end
				if listing.throws then
					error('client error')
				end
				local hasAllInfo = listing.isLoaded ~= false and index % 3 ~= 2
				local owner = hasAllInfo and (listing[6] or 'Seller') or nil
				return 'Item',
					1,
					listing[2],
					1,
					true,
					1,
					0,
					0,
					0,
					listing[3],
					listing[4] or 0,
					false,
					nil,
					owner,
					owner,
					0,
					listing[1],
					hasAllInfo
			end,
			GetReplicateItemTimeLeft = function(index)
				local listing = game.listings[index + 1]
				return listing and (listing[5] or 4) or nil
			end,
			GetReplicateItemLink = function(index)
				local listing = game.listings[index + 1]
				return listing and ('|Hitem:' .. listing[1] .. '|h') or nil
			end,
		},
		IsShiftKeyDown = function()
			return game.modifiers.shift == true
		end,
		IsControlKeyDown = function()
			return game.modifiers.ctrl == true
		end,
		IsAltKeyDown = function()
			return game.modifiers.alt == true
		end,
		C_Container = {
			GetContainerItemInfo = function(bag, slot)
				return game.containerItems[bag .. ':' .. slot]
			end,
			GetContainerNumSlots = function(bag)
				return game.bagSlots[bag] or 0
			end,
		},
	}
	if options.hasClock ~= false then
		env.debugprofilestop = function()
			return game.clockMs
		end
	end
	if options.hasProcessor ~= false then
		env.Enum = { TooltipDataType = { Item = 0 } }
		env.TooltipDataProcessor = {
			AddTooltipPostCall = function(dataType, handler)
				game.postCalls[#game.postCalls + 1] = { dataType = dataType, handler = handler }
			end,
		}
	end
	env.GameTooltip = newTooltip(game, 'GameTooltip')
	env.ItemRefTooltip = newTooltip(game, 'ItemRefTooltip')
	game.env = env
	addAuctionHouseActions(game, env)
	addTrackingApi(game, env)

	--- Fires a game event at the event frame.
	function game:Fire(event, ...)
		if self.frame.events[event] and self.frame.onEvent then
			self.frame.onEvent(self.frame, event, ...)
		end
	end

	--- Runs the timers due now or earlier, in order (one pass; timers they add wait).
	function game:RunTimers()
		local due, waiting = {}, {}
		for _, timer in ipairs(self.timers) do
			if timer.at <= self.now then
				due[#due + 1] = timer
			else
				waiting[#waiting + 1] = timer
			end
		end
		self.timers = waiting
		for _, timer in ipairs(due) do
			timer.fn()
		end
		return #due
	end

	--- One frame: the clock moves on and next-frame timers run.
	function game:NextFrame()
		self.clockMs = self.clockMs + 16
		return self:RunTimers()
	end

	--- Runs frames until no timer is due; returns how many frames ran.
	function game:RunFrames(limit)
		local frames = 0
		while frames < (limit or 10000) and self:NextFrame() > 0 do
			frames = frames + 1
		end
		return frames
	end

	--- Presses a key as the client would: the newest override binding for it clicks its button.
	function game:PressKey(key)
		for _, keys in pairs(self.overrideBindings) do
			local buttonName = keys[key]
			local button = buttonName and env[buttonName]
			if button and button.scripts.OnClick then
				button.scripts.OnClick(button, 'LeftButton')
				return true
			end
		end
		return false
	end
	function game:Advance(seconds)
		self.now = self.now + seconds
		return self:RunTimers()
	end

	--- Builds an item tooltip: clears it and runs the post-calls (or the script hook).
	function game:ShowItemTooltip(itemId, tooltip)
		tooltip = tooltip or self.env.GameTooltip
		tooltip.lines = {}
		tooltip.shownItemId = itemId
		tooltip.itemLink = '|cffffffff|Hitem:' .. itemId .. '::::|h[Item]|h|r'
		for _, postCall in ipairs(self.postCalls) do
			postCall.handler(tooltip, { id = itemId })
		end
		if tooltip.scripts.OnTooltipSetItem then
			tooltip.scripts.OnTooltipSetItem(tooltip)
		end
		return tooltip.lines
	end

	return game
end

-- The files the TOC loads after the Engine (Init.lua aside), in its order.
FakeGame.FEATURE_FILES = {
	'Features/Pricing.lua',
	'Features/Value.lua',
	'Features/Scan.lua',
	'Features/Tooltip/Tooltip.lua',
	'Features/Bags/Bags.lua',
	'Features/Trade/Trade.lua',
	'Features/Tracking.lua',
	'Features/Sessions.lua',
	'Features/Crafting/View.lua',
	'Features/Crafting/Crafting.lua',
	'Features/TopBar/TopBar.lua',
	'Features/Window/Window.lua',
	'Features/Window/ScanTab.lua',
	'Features/Window/LookupTab.lua',
	'Features/Window/RulesTab.lua',
	'Features/Window/SellTab.lua',
	'Features/Window/AuctionsTab.lua',
	'Features/Window/BuyTab.lua',
	'Features/Window/FlipsTab.lua',
	'Features/Window/LedgerTab.lua',
	'Features/Window/VenturesTab.lua',
	'Features/Compat.lua',
	'Features/Options.lua',
}

-- AHledger --------------------------------------------------------------------------------

-- AHledgerAPI's price fields, in the order a fake row lists them.
FakeGame.AHLEDGER_FIELDS =
	{ 'median', 'minBuyout', 'quantity', 'median7d', 'median30d', 'low30d', 'high30d', 'soldPerDay' }

--- A stand-in for AHledger's AHledgerAPI v1 (AHledger's API.lua), read-only like the real one.
--- options = { market, pinnedMarket, updated, snapshot, version, credit, mode,
---             rows = { [itemId] = { median, minBuyout, quantity, median7d, median30d, low30d,
---                                   high30d, soldPerDay } } }
--- market is the player's market (and the only one priced); pinnedMarket is a market pinned in
--- AHledger's options, which GetMarket then returns. Like the real API, a key that is not
--- shaped like a market key falls back to GetMarket's. version defaults to 1. mode 'broken'
--- makes every call throw (the real API never does; Haggler must not trust that), mode
--- 'priceBroken' only GetPrice; mode 'junk' answers with strings where numbers belong. Calls
--- are counted in state.calls.
--- @return table api, table state (change state.rows, state.snapshot... between calls)
function FakeGame.newAHledgerAPI(options)
	options = options or {}
	local state = {
		market = options.market or 'forever/normal/alliance/us',
		pinnedMarket = options.pinnedMarket,
		updated = options.updated,
		snapshot = options.snapshot == true,
		rows = options.rows or {},
		mode = options.mode,
		-- AHledger with no synced table that still answers GetPrice from the player's own scan.
		ownScanOverlay = options.ownScanOverlay == true,
		calls = 0,
	}
	local function marketOf(market)
		if type(market) == 'string' and market:match('^[%w%-]+/[%w%-]+/[%w%-]+/[%w%-]+$') then
			return market
		end
		return state.pinnedMarket or state.market
	end
	local api = {
		VERSION = options.version or 1,
		CREDIT = options.credit or 'Prices from AHledger (ahledger.com)',
	}
	function api.GetMarket()
		return state.pinnedMarket or state.market
	end
	function api.GetTableInfo(market)
		state.calls = state.calls + 1
		if state.mode == 'broken' then
			error('AHledger broke')
		end
		local m = marketOf(market)
		if m ~= state.market or state.ownScanOverlay then
			return nil
		end
		local count = 0
		for _ in pairs(state.rows) do
			count = count + 1
		end
		return { market = m, updated = state.updated, count = count, snapshot = state.snapshot }
	end
	function api.GetPrice(item, market)
		state.calls = state.calls + 1
		if state.mode == 'broken' or state.mode == 'priceBroken' then
			error('AHledger broke')
		end
		local m = marketOf(market)
		local row = m == state.market and state.rows[item] or nil
		if not row then
			return nil
		end
		local price = { itemID = item, market = m, updated = state.updated, snapshot = state.snapshot }
		for index, field in ipairs(FakeGame.AHLEDGER_FIELDS) do
			price[field] = row[index]
		end
		if state.mode == 'junk' then
			price.median, price.soldPerDay, price.updated = 'lots', 'many', 'yesterday'
		end
		return price
	end
	function api.GetMedian(item, market)
		local price = api.GetPrice(item, market)
		return price and price.median
	end
	local proxy = setmetatable({}, {
		__index = api,
		__newindex = function()
			error('AHledgerAPI is read-only', 2)
		end,
		__metatable = false,
	})
	return proxy, state
end

--- Starts the add-on's features on a fake game, as Init.lua and Haggler.lua do in the client.
--- @param t table the harness
--- @param game table FakeGame.new(...)
--- @param beforeStart function|nil fun(ns), run after the store opens and before the host starts
--- @return table ns
function FakeGame.startAddon(t, game, beforeStart)
	local ns = t.loadAddon()
	local errors = {}
	ns.wow = ns.Wow.create(game.env, {
		onError = function(where, err)
			errors[#errors + 1] = where .. ': ' .. tostring(err)
		end,
	})
	ns.host = ns.Host.create({
		onError = function(owner, where, err)
			errors[#errors + 1] = owner .. ' ' .. where .. ': ' .. tostring(err)
		end,
	})
	ns.theme = ns.Theme.new(ns.Tokens)
	ns.tooltips = ns.Tooltip.new({
		wow = ns.wow,
		onError = function(owner, err)
			errors[#errors + 1] = 'tooltip ' .. owner .. ': ' .. tostring(err)
		end,
	})
	for _, path in ipairs(FakeGame.FEATURE_FILES) do
		assert(loadfile(path))('Haggler', ns)
	end
	-- game.savedDb / game.savedCharDb carry saved variables across a simulated /reload.
	game.savedDb = game.savedDb or {}
	game.savedCharDb = game.savedCharDb or {}
	ns.store = assert(ns.Store.open(game.savedDb, game.savedCharDb))
	if beforeStart then
		beforeStart(ns)
	end
	ns.host.Start(ns.store:Settings())
	ns.errors = errors
	return ns
end

return FakeGame
