--[[
	Wow: the only door from the engine to the game's API. Everything else in Engine/ takes a wow
	object (or plain data) as an argument, so luajit tests pass a fake environment instead of _G.

	Step 1: time, item info, the player's market, printing, events and the slash command.
	Step 2: the auction house replicate list (the full scan), timers, a frame clock, modifier
	keys and item tooltips. Step 3: globals and hooks for bag hosts, containers, the trade
	window and its partner. Step 4: posting, searching and buying on the auction house (the
	Haggler frame's Sell and Buy tabs). Mail wrappers arrive with the step that uses them.

	Posting and buying are protected: PostItem, PostCommodity, ConfirmPost*, PlaceBid and
	ConfirmCommoditiesPurchase must run from a hardware event (a click). The wrappers never
	defer them to a timer; callers call them straight from an OnClick handler.

	Forever runs the Mainline UI, so these follow retail's C_AuctionHouse (AHledger 0.14, Auctionator
	and TSM make the same calls there). Each wrapper checks the API exists and answers nil / false
	when it does not, so a client without it degrades instead of erroring.

	GetReplicateItemInfo(index) is 0-based and returns, in order: name, texture, count, quality,
	usable, level, levelType, minBid, minIncrement, buyoutPrice, bidAmount, highBidder,
	bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo. buyoutPrice is for the
	whole listing (count units), 0 on a bid-only listing.
]]
local _, ns = ...

local Wow = {}
ns.Wow = Wow

-- A hooked method can run every frame: each method's handler errors are reported this often.
Wow.HOOK_ERROR_LIMIT = 3

-- GetCurrentRegion() ids to AHledger's region slugs.
local REGION_SLUGS = { [1] = 'us', [2] = 'kr', [3] = 'eu', [4] = 'tw', [5] = 'cn' }
local CHAT_PREFIX = '|cffd4a017Haggler|r: '
local DEFAULT_EVENT_OWNER = 'main'
local MODIFIER_CHECKS = { shift = 'IsShiftKeyDown', ctrl = 'IsControlKeyDown', alt = 'IsAltKeyDown' }
local ITEM_TOOLTIP_NAMES = { 'GameTooltip', 'ItemRefTooltip', 'ShoppingTooltip1', 'ShoppingTooltip2' }
-- Enum.ItemClass.Questitem, for a client without the enum.
local QUEST_ITEM_CLASS = 12

-- Helpers live at the bottom of the file; declared here so they stay local.
local dispatchEvent, itemIdFromLink, itemIdFromTooltip, stackCountFromOwner, timeLeftBand, isSecret
local isInCombat, isBnetFriendGuid, serverIdFromGuid

local WowMethods = {}
WowMethods.__index = WowMethods
-- Later files (Engine/WowTracking.lua) add their wrappers here.
Wow.Methods = WowMethods

--- Wraps a game environment.
--- @param env table|nil the global table; _G in game, a fake in tests
--- @param options table|nil { onError = fun(where, err) } for errors in event handlers
--- @return table wow
function Wow.create(env, options)
	return setmetatable({
		env = env or _G,
		eventHandlers = {},
		hookErrorCounts = {},
		onError = options and options.onError,
		tooltipHandlers = {},
	}, WowMethods)
end

--- Server time in whole seconds.
function WowMethods:Now()
	local env = self.env
	if env.GetServerTime then
		return env.GetServerTime()
	end
	return env.time()
end

--- Static item info, or nil while the client has not cached the item yet.
--- @param itemId number
--- @return table|nil { name, maxStack, vendorPrice }
function WowMethods:ItemInfo(itemId)
	if type(itemId) ~= 'number' then
		error('Wow:ItemInfo: itemId must be a number', 2)
	end
	local env = self.env
	local getItemInfo = (env.C_Item and env.C_Item.GetItemInfo) or env.GetItemInfo
	if not getItemInfo then
		return nil
	end
	local name, _, _, _, _, _, _, maxStack, _, _, vendorPrice = getItemInfo(itemId)
	if not name then
		return nil
	end
	return { name = name, maxStack = tonumber(maxStack), vendorPrice = tonumber(vendorPrice) or 0 }
end

--- Like ItemInfo, but nil for an item the client has not cached, so the client does not ask the
--- server for it. Without C_Item.IsItemDataCachedByID it is ItemInfo.
--- @param itemId number
--- @return table|nil { name, maxStack, vendorPrice }
function WowMethods:CachedItemInfo(itemId)
	if type(itemId) ~= 'number' then
		error('Wow:CachedItemInfo: itemId must be a number', 2)
	end
	local isCached = self.env.C_Item and self.env.C_Item.IsItemDataCachedByID
	if isCached and not isCached(itemId) then
		return nil
	end
	return self:ItemInfo(itemId)
end

--- The player's name, realm, faction and region, as the market and character keys need them.
--- realm is the client's name for it, '' when the client gives none (Forever build 71037 on);
--- server is the server number in the player's GUID, nil before the client knows the character.
--- Store:ResolveRealm and Store:CharacterKey make up for a missing realm name.
--- @return table { name, realm, faction, region, server }
function WowMethods:Player()
	local env = self.env
	local name = env.UnitName('player')
	return {
		-- Until the client knows the character it answers UNKNOWNOBJECT ("Unknown").
		name = name ~= env.UNKNOWNOBJECT and name or nil,
		-- GetRealmName keeps the spaces the ruleset words need ("Wild Growth RP PvP"); the
		-- normalized name drops them, as AHledger's realm parsing does not.
		realm = env.GetRealmName(),
		faction = env.UnitFactionGroup('player'),
		region = REGION_SLUGS[env.GetCurrentRegion and env.GetCurrentRegion() or 1] or 'us',
		server = serverIdFromGuid(env.UnitGUID and env.UnitGUID('player') or nil),
	}
end

function WowMethods:Print(text)
	self.env.DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. tostring(text))
end

--- AHledger's public price API (the AHledgerAPI global), as it is; PriceData checks its shape.
--- @return any
function WowMethods:AHledgerAPI()
	return self.env.AHledgerAPI
end

--- The market AHledger prices for this character (AHledgerAPI.GetMarket), or nil. AHledger reads
--- the realm in ways Haggler cannot (its own memory, /ahl realm), so it knows the ruleset when the
--- client gives no realm name. It is also the market pinned in AHledger's options, which is one
--- setting for the whole account; callers check its faction and region.
--- @return string|nil
function WowMethods:AHledgerMarket()
	local api = self.env.AHledgerAPI
	if type(api) ~= 'table' or type(api.GetMarket) ~= 'function' then
		return nil
	end
	local ok, market = pcall(api.GetMarket)
	return ok and type(market) == 'string' and market or nil
end

--- AHledger's own settings table (AHledgerDB.settings) for reading only; nil when AHledger has
--- none. Haggler never writes it.
--- @return table|nil
function WowMethods:AHledgerSettings()
	local ok, settings = pcall(function()
		return self.env.AHledgerDB.settings
	end)
	return ok and type(settings) == 'table' and settings or nil
end

--- Opens AHledger's options through its own slash command (/ahl options).
--- @return boolean true when AHledger took the command
function WowMethods:OpenAHledgerOptions()
	local slashCommands = self.env.SlashCmdList
	local handler = type(slashCommands) == 'table' and slashCommands.AHLEDGER
	if type(handler) ~= 'function' then
		return false
	end
	return (pcall(handler, 'options'))
end

--- The client's Settings API (Settings → AddOns) when it has the calls Haggler uses; else nil.
--- @return table|nil
function WowMethods:SettingsApi()
	local api = self.env.Settings
	if type(api) ~= 'table' then
		return nil
	end
	local hasCheckbox = type(api.CreateCheckbox) == 'function' or type(api.CreateCheckBox) == 'function'
	if
		type(api.RegisterVerticalLayoutCategory) ~= 'function'
		or type(api.RegisterProxySetting) ~= 'function'
		or type(api.RegisterAddOnCategory) ~= 'function'
		or not hasCheckbox
	then
		return nil
	end
	return api
end

--- Adds a panel to the old Interface Options (clients without the Settings API).
--- @return boolean true when the client took it
function WowMethods:AddLegacyOptionsPanel(panel)
	local addCategory = self.env.InterfaceOptions_AddCategory
	if type(addCategory) ~= 'function' then
		return false
	end
	return (pcall(addCategory, panel))
end

--- Opens Settings at a category registered through SettingsApi, or the old Interface Options
--- at a legacy panel.
--- @return boolean true when something opened
function WowMethods:OpenOptionsCategory(category)
	local api = self.env.Settings
	if type(api) == 'table' and type(api.OpenToCategory) == 'function' and type(category) == 'table' then
		local getId = category.GetID
		if type(getId) == 'function' then
			return (pcall(api.OpenToCategory, getId(category)))
		end
	end
	local openLegacy = self.env.InterfaceOptionsFrame_OpenToCategory
	if type(openLegacy) == 'function' and category ~= nil then
		return (pcall(openLegacy, category))
	end
	return false
end

--- Calls handler(event, ...) for a game event. Each owner has one handler per event, so the
--- scan and the bootstrap can both listen to the same event. A handler that throws is reported
--- through onError and does not stop the others. The hidden event frame is the one frame the
--- engine owns; it draws nothing.
--- An event this client does not have (RegisterEvent throws for it) is not an error: the
--- handler is dropped and false comes back, so a module still enables on a client without it.
--- @param event string
--- @param handler function
--- @param owner string|nil default 'main'
--- @return boolean registered
--- @return string|nil reason when not registered
function WowMethods:OnEvent(event, handler, owner)
	if type(handler) ~= 'function' then
		error('Wow:OnEvent: handler must be a function', 2)
	end
	if not self.eventFrame then
		self.eventFrame = self.env.CreateFrame('Frame')
		self.eventFrame:SetScript('OnEvent', function(_, firedEvent, ...)
			dispatchEvent(self, firedEvent, ...)
		end)
	end
	local ok, err = pcall(self.eventFrame.RegisterEvent, self.eventFrame, event)
	if not ok then
		return false, tostring(err)
	end
	local handlers = self.eventHandlers[event] or {}
	self.eventHandlers[event] = handlers
	handlers[owner or DEFAULT_EVENT_OWNER] = handler
	return true
end

--- Drops an owner's handler; the frame stops listening once no owner is left.
function WowMethods:OffEvent(event, owner)
	local handlers = self.eventHandlers[event]
	if not handlers then
		return
	end
	handlers[owner or DEFAULT_EVENT_OWNER] = nil
	if next(handlers) == nil then
		self.eventHandlers[event] = nil
		if self.eventFrame then
			self.eventFrame:UnregisterEvent(event)
		end
	end
end

--- Registers /hag. The handler gets the text after the command.
function WowMethods:RegisterSlash(handler)
	self.env.SLASH_HAGGLER1 = '/hag'
	self.env.SlashCmdList.HAGGLER = handler
end

-- Timers and the frame clock ---------------------------------------------------------------

--- Runs fn after a delay (0 = next frame). Returns false when the client has no C_Timer.
function WowMethods:After(seconds, fn)
	local timer = self.env.C_Timer
	if not (timer and timer.After) then
		return false
	end
	timer.After(seconds, fn)
	return true
end

--- A millisecond clock for per-frame budgets, or nil when the client has none.
function WowMethods:ClockMs()
	local clock = self.env.debugprofilestop
	return clock and clock() or nil
end

-- Auction house ---------------------------------------------------------------------------

--- True when the client can request a full scan (C_AuctionHouse.ReplicateItems).
function WowMethods:CanReplicate()
	local auctionHouse = self.env.C_AuctionHouse
	return auctionHouse ~= nil and type(auctionHouse.ReplicateItems) == 'function'
end

--- Asks the server for the full listing. The answer is REPLICATE_ITEM_LIST_UPDATE, or
--- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED when it refuses.
--- @return boolean sent
--- @return string|nil reason when not sent
function WowMethods:RequestReplicate()
	if not self:CanReplicate() then
		return false, 'no C_AuctionHouse.ReplicateItems on this client'
	end
	local ok, err = pcall(self.env.C_AuctionHouse.ReplicateItems)
	if not ok then
		return false, tostring(err)
	end
	return true
end

--- Calls handler() after every C_AuctionHouse.ReplicateItems call, from any add-on (Haggler's
--- own included). A post-hook (hooksecurefunc): the call itself is never replaced, so nothing
--- is tainted. Call once a session; a hook cannot be removed.
--- @return boolean hooked false when the client has no ReplicateItems
function WowMethods:HookReplicateRequests(handler)
	if not self:CanReplicate() then
		return false
	end
	return self:HookMethod(self.env.C_AuctionHouse, 'ReplicateItems', handler)
end

--- Listings in the replicate list now (0 when none or no API).
function WowMethods:NumReplicateItems()
	local auctionHouse = self.env.C_AuctionHouse
	local count = auctionHouse and auctionHouse.GetNumReplicateItems and auctionHouse.GetNumReplicateItems()
	return type(count) == 'number' and count or 0
end

--- One listing of the replicate list, as raw values (no table, so a 150,000-row read makes no
--- garbage). Nothing is checked here; ScanStore drops junk.
--- @param index number 0-based
--- The seller is not read: during a replicate read the client often has not loaded it yet.
--- @return any itemId, any count, any buyout total for the listing, any bid
--- @return number|nil timeLeft the internal band, 1 (short) to 4 (very long), nil when unknown
function WowMethods:ReplicateItem(index)
	local auctionHouse = self.env.C_AuctionHouse
	local _, _, count, _, _, _, _, _, _, buyout, bid, _, _, _, _, _, itemId = auctionHouse.GetReplicateItemInfo(index)
	local getTimeLeft = auctionHouse.GetReplicateItemTimeLeft
	return itemId, count, buyout, bid, timeLeftBand(getTimeLeft and getTimeLeft(index))
end

--- Asks the client to load an item it has not cached; ItemInfo answers once it has.
--- @param itemId number
--- @return boolean requested
function WowMethods:RequestItemData(itemId)
	local requestLoad = self.env.C_Item and self.env.C_Item.RequestLoadItemDataByID
	if not requestLoad or type(itemId) ~= 'number' then
		return false
	end
	return (pcall(requestLoad, itemId))
end

--- The item link of one listing, or nil.
function WowMethods:ReplicateItemLink(index)
	local auctionHouse = self.env.C_AuctionHouse
	local getLink = auctionHouse and auctionHouse.GetReplicateItemLink
	return getLink and getLink(index) or nil
end

-- Input -----------------------------------------------------------------------------------

--- True while a modifier is held. A gamepad modifier counts when the client maps it to Shift,
--- Ctrl or Alt (the GamePadEmulateShift / Ctrl / Alt settings).
--- @param name string 'shift' | 'ctrl' | 'alt'
function WowMethods:IsModifierDown(name)
	local check = MODIFIER_CHECKS[name] and self.env[MODIFIER_CHECKS[name]]
	return check ~= nil and check() == true
end

-- Tooltips --------------------------------------------------------------------------------

--- Calls handler(tooltip, itemId, stackCount) after every item tooltip is built. The client
--- cannot unhook, so the hook is installed once and later calls only add handlers; a removed
--- handler is simply not called.
--- TooltipDataProcessor (Forever and Classic Era 1.15+) is preferred; OnTooltipSetItem is the
--- fallback on older clients.
--- @param owner string
--- @param handler function|nil nil removes the owner's handler
--- @return string|nil hook 'processor' | 'script', or nil when the client has neither
function WowMethods:HookItemTooltips(owner, handler)
	self.tooltipHandlers[owner] = handler
	if not self.tooltipHook then
		self.tooltipHook = self:InstallTooltipHook()
	end
	return self.tooltipHook
end

function WowMethods:InstallTooltipHook()
	local env = self.env
	-- Runs inside the client's tooltip code: nothing may escape it.
	local onTooltip = function(tooltip, data)
		local ok, err = pcall(self.HandleItemTooltip, self, tooltip, data)
		if not ok and self.onError then
			self.onError('tooltip hook', err)
		end
	end
	local processor = env.TooltipDataProcessor
	local dataTypes = env.Enum and env.Enum.TooltipDataType
	if processor and processor.AddTooltipPostCall and dataTypes and dataTypes.Item then
		processor.AddTooltipPostCall(dataTypes.Item, onTooltip)
		return 'processor'
	end
	local isHooked = false
	for _, name in ipairs(ITEM_TOOLTIP_NAMES) do
		local tooltip = env[name]
		if tooltip and tooltip.HookScript then
			tooltip:HookScript('OnTooltipSetItem', onTooltip)
			isHooked = true
		end
	end
	return isHooked and 'script' or nil
end

--- Finds the item and stack of a built tooltip and runs every handler on it as
--- handler(tooltip, itemId, stackCount, location?); location = { bag, slot } when the tooltip
--- belongs to a bag slot holding the item. Secret values (issecretvalue) are never read.
function WowMethods:HandleItemTooltip(tooltip, data)
	if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then
		return
	end
	local env = self.env
	local itemId = itemIdFromTooltip(env, tooltip, data)
	if not itemId then
		return
	end
	local stackCount, location = stackCountFromOwner(env, tooltip, itemId)
	for handlerOwner, handler in pairs(self.tooltipHandlers) do
		local ok, err = pcall(handler, tooltip, itemId, stackCount, location)
		if not ok and self.onError then
			self.onError('tooltip ' .. handlerOwner, err)
		end
	end
end

--- Rebuilds the shown item tooltip so a modifier change shows at once. Uses the tooltip's own
--- RefreshData (Mainline UI), which re-runs the data and the post-calls without calling the
--- owner's OnEnter: running another frame's OnEnter from add-on code taints protected buttons.
--- Only an item tooltip is rebuilt, and never in combat.
--- @return boolean refreshed
function WowMethods:RefreshItemTooltip()
	local env = self.env
	local tooltip = env.GameTooltip
	if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) or isInCombat(env) then
		return false
	end
	if type(tooltip.GetItem) ~= 'function' then
		return false
	end
	local _, link = tooltip:GetItem()
	if link == nil or isSecret(env, link) then
		return false
	end
	if not (tooltip.IsShown and tooltip:IsShown()) or type(tooltip.RefreshData) ~= 'function' then
		return false
	end
	local ok = pcall(tooltip.RefreshData, tooltip)
	return ok
end

-- Frames, hooks and other add-ons (step 3) ------------------------------------------------

--- A global the UI defines (a Blizzard frame, another add-on's table), or nil. Bag hosts and
--- the trade window find their frames through this, so tests can serve fakes.
--- @param name string
--- @return any
function WowMethods:Global(name)
	return self.env[name]
end

--- True when another add-on is loaded (C_AddOns on Mainline, the old global elsewhere).
function WowMethods:IsAddOnLoaded(name)
	local env = self.env
	local isLoaded = (env.C_AddOns and env.C_AddOns.IsAddOnLoaded) or env.IsAddOnLoaded
	if not isLoaded then
		return false
	end
	local ok, loaded = pcall(isLoaded, name)
	return ok and loaded == true
end

--- Post-hooks object[method] with hooksecurefunc, which never taints the original. The client
--- cannot unhook, so callers install a hook once and gate it with their own flag. The handler
--- runs under pcall: an error is reported (at most Wow.HOOK_ERROR_LIMIT times per method), never
--- raised into Blizzard's code.
--- @return boolean hooked false when the client has no hooksecurefunc or no such method
function WowMethods:HookMethod(object, method, handler)
	local hook = self.env.hooksecurefunc
	if not hook or type(object) ~= 'table' or type(object[method]) ~= 'function' then
		return false
	end
	hook(object, method, function(...)
		local ok, err = pcall(handler, ...)
		if not ok then
			self:ReportHookError(method, err)
		end
	end)
	return true
end

--- Post-hooks a global function (hooksecurefunc on the globals table): never taints it.
--- @return boolean hooked false when there is no such function
function WowMethods:HookGlobalFunction(name, handler)
	return self:HookMethod(self.env, name, handler)
end

--- Hooks a frame's script (HookScript runs after the frame's own); the handler runs under
--- pcall like a method hook. Call once a frame; a script hook cannot be removed.
--- @return boolean hooked false when the frame cannot be hooked
function WowMethods:HookFrameScript(frame, script, handler)
	if type(frame) ~= 'table' or type(frame.HookScript) ~= 'function' then
		return false
	end
	local ok = pcall(frame.HookScript, frame, script, function(...)
		local isDone, err = pcall(handler, ...)
		if not isDone then
			self:ReportHookError(script, err)
		end
	end)
	return ok
end

--- Reports a hook handler's error unless that method used up its reports; the last report says
--- the rest are muted.
function WowMethods:ReportHookError(method, err)
	local key = tostring(method)
	local count = (self.hookErrorCounts[key] or 0) + 1
	self.hookErrorCounts[key] = count
	if not self.onError or count > Wow.HOOK_ERROR_LIMIT then
		return
	end
	local suffix = count == Wow.HOOK_ERROR_LIMIT and ' (further errors from this hook are muted)' or ''
	self.onError('hook ' .. key, tostring(err) .. suffix)
end

--- A frame of the add-on's own. A secure template is refused: Haggler never makes protected
--- frames, so nothing it adds can be blocked or spread taint in combat.
--- @param kind string 'Frame' | 'Button'
--- @param parent table|nil default UIParent
--- @param template string|nil a plain template such as 'UIPanelButtonTemplate'
--- @param name string|nil a global name, only for frames the client must find by name (Escape
---   closes frames listed by name in UISpecialFrames)
function WowMethods:CreateFrame(kind, parent, template, name)
	if type(template) == 'string' and template:find('Secure', 1, true) then
		error('Wow:CreateFrame: secure templates are not used', 2)
	end
	return self.env.CreateFrame(kind, name, parent or self.env.UIParent, template)
end

--- The item id in an item link (or any text holding one), or nil.
function WowMethods:ItemIdFromLink(text)
	return type(text) == 'string' and itemIdFromLink(text) or nil
end

function WowMethods:IsInCombat()
	return isInCombat(self.env)
end

-- Containers ------------------------------------------------------------------------------

--- One bag slot, or nil when it is empty. itemId is nil while the client has not loaded the
--- item (or when the client hides it as a secret value).
--- @return table|nil { itemId?, count, isBound, link?, quality?, hasNoValue }
function WowMethods:ContainerItem(bag, slot)
	local container = self.env.C_Container
	if not (container and container.GetContainerItemInfo) then
		return nil
	end
	local ok, info = pcall(container.GetContainerItemInfo, bag, slot)
	if not ok or type(info) ~= 'table' then
		return nil
	end
	local env = self.env
	local itemId = not isSecret(env, info.itemID) and info.itemID or nil
	local count = not isSecret(env, info.stackCount) and info.stackCount or nil
	return {
		itemId = type(itemId) == 'number' and itemId or nil,
		count = type(count) == 'number' and count >= 1 and count or 1,
		isBound = info.isBound == true,
		link = not isSecret(env, info.hyperlink) and info.hyperlink or nil,
		quality = info.quality,
		hasNoValue = info.hasNoValue == true,
	}
end

--- True when a bag slot holds a quest item: the client's quest info for the slot (the call
--- Forever's ContainerFrame uses for its quest border), else the item's class.
--- @return boolean
function WowMethods:IsQuestSlot(bag, slot, itemId)
	local container = self.env.C_Container
	local getQuestInfo = container and container.GetContainerItemQuestInfo
	if getQuestInfo then
		local ok, questInfo = pcall(getQuestInfo, bag, slot)
		if ok and type(questInfo) == 'table' then
			return questInfo.isQuestItem == true or type(questInfo.questID) == 'number'
		end
	end
	return self:IsQuestItemClass(itemId)
end

--- True when an item's class is Quest (Enum.ItemClass.Questitem, 12), from the instant item
--- info that needs no cache.
--- @return boolean
function WowMethods:IsQuestItemClass(itemId)
	local env = self.env
	local getInstant = (env.C_Item and env.C_Item.GetItemInfoInstant) or env.GetItemInfoInstant
	if type(itemId) ~= 'number' or not getInstant then
		return false
	end
	local ok, _, _, _, _, _, classId = pcall(getInstant, itemId)
	local itemClass = env.Enum and env.Enum.ItemClass
	local questClass = itemClass and itemClass.Questitem or QUEST_ITEM_CLASS
	return ok and classId == questClass
end

--- Slots in a bag (0 when the bag is empty or unknown).
function WowMethods:ContainerSlots(bag)
	local container = self.env.C_Container
	local getSlots = container and container.GetContainerNumSlots
	local ok, slots = pcall(getSlots or function()
		return 0
	end, bag)
	return ok and type(slots) == 'number' and slots or 0
end

--- The bags the player carries: backpack, the bag slots and the reagent bag when the client has
--- one. Bank bags are not included.
--- @return table bag ids
function WowMethods:CarriedBags()
	local env = self.env
	local last = tonumber(env.NUM_TOTAL_EQUIPPED_BAG_SLOTS) or tonumber(env.NUM_BAG_SLOTS) or 4
	local bags = {}
	for bag = 0, last do
		bags[#bags + 1] = bag
	end
	return bags
end

--- Every loaded stack in the carried bags, as Value:Total takes them.
--- @return table { { itemId, count, isBound, hasNoValue, bag, slot }... }
function WowMethods:CarriedItems()
	local entries = {}
	for _, bag in ipairs(self:CarriedBags()) do
		for slot = 1, self:ContainerSlots(bag) do
			local item = self:ContainerItem(bag, slot)
			if item and item.itemId then
				entries[#entries + 1] = {
					itemId = item.itemId,
					count = item.count,
					isBound = item.isBound,
					hasNoValue = item.hasNoValue,
					bag = bag,
					slot = slot,
				}
			end
		end
	end
	return entries
end

-- Auction house actions (step 4) ---------------------------------------------------------

Wow.DURATION_HOURS = { [1] = 12, [2] = 24, [3] = 48 }

--- The retail auction house API when this client has posting (C_AuctionHouse.PostItem).
--- @return table|nil
function WowMethods:AuctionHouseApi()
	local api = self.env.C_AuctionHouse
	return type(api) == 'table' and type(api.PostItem) == 'function' and api or nil
end

--- Whether prices may carry copper (false: whole silver only).
function WowMethods:SupportsCopperValues()
	local api = self:AuctionHouseApi()
	if not (api and api.SupportsCopperValues) then
		return true
	end
	local ok, supports = pcall(api.SupportsCopperValues)
	return not ok or supports ~= false
end

--- The item in a bag slot as the auction house takes it: a location, whether it is a
--- commodity, and whether the auction house accepts it.
--- @param bag number
--- @param slot number
--- @param itemId number the item expected there (a moved item reads as gone)
--- @return table|nil { location, isCommodity, itemId, bag, slot }
--- @return string|nil reason 'no auction house' | 'item moved' | 'cannot be auctioned'
function WowMethods:SellableItem(bag, slot, itemId)
	local env, api = self.env, self:AuctionHouseApi()
	local itemLocation = env.ItemLocation
	if not api or type(itemLocation) ~= 'table' or not itemLocation.CreateFromBagAndSlot then
		return nil, 'no auction house'
	end
	local ok, location = pcall(itemLocation.CreateFromBagAndSlot, itemLocation, bag, slot)
	if not ok or type(location) ~= 'table' then
		return nil, 'item moved'
	end
	local item = self:ContainerItem(bag, slot)
	if not item or item.itemId ~= itemId then
		return nil, 'item moved'
	end
	local isValidOk, isValid = pcall(api.IsSellItemValid, location, false)
	if not isValidOk or not isValid then
		return nil, 'cannot be auctioned'
	end
	local statusOk, status = pcall(api.GetItemCommodityStatus, location)
	local commodityStatus = env.Enum and env.Enum.ItemCommodityStatus
	local commodity = commodityStatus and commodityStatus.Commodity or 2
	return {
		location = location,
		isCommodity = statusOk and status == commodity,
		itemId = itemId,
		bag = bag,
		slot = slot,
	}
end

--- The deposit the client asks for a listing, or nil when it cannot say.
--- @param sellable table from SellableItem
--- @param duration number 1, 2 or 3 (12, 24, 48 hours)
--- @param quantity number
--- @return number|nil copper
function WowMethods:AuctionDeposit(sellable, duration, quantity)
	local api = self:AuctionHouseApi()
	if not api or type(sellable) ~= 'table' then
		return nil
	end
	local ok, deposit
	if sellable.isCommodity then
		ok, deposit = pcall(api.CalculateCommodityDeposit, sellable.itemId, duration, quantity)
	else
		ok, deposit = pcall(api.CalculateItemDeposit, sellable.location, duration, quantity)
	end
	return ok and type(deposit) == 'number' and deposit >= 0 and deposit or nil
end

--- Posts a listing. Protected: call it only from a click. When the client warns about the
--- price it answers 'needsConfirm'; ConfirmAuction with the same arguments, from the next click,
--- posts it anyway.
--- @param sellable table from SellableItem (checked again: the item may have moved)
--- @param duration number 1, 2 or 3
--- @param quantity number
--- @param unitPrice number copper per unit
--- @return string|nil 'posted' | 'needsConfirm'
--- @return string|nil reason
function WowMethods:PostAuction(sellable, duration, quantity, unitPrice)
	return self:CallPost(sellable, duration, quantity, unitPrice, false)
end

--- Posts a listing the client warned about. Protected: call it only from a click.
function WowMethods:ConfirmAuction(sellable, duration, quantity, unitPrice)
	return self:CallPost(sellable, duration, quantity, unitPrice, true)
end

function WowMethods:CallPost(sellable, duration, quantity, unitPrice, isConfirm)
	if type(sellable) ~= 'table' or not Wow.DURATION_HOURS[duration] then
		error('Wow:PostAuction: needs a sellable item and a duration of 1, 2 or 3', 3)
	end
	if self:IsInCombat() then
		return nil, 'in combat'
	end
	local still, reason = self:SellableItem(sellable.bag, sellable.slot, sellable.itemId)
	if not still then
		return nil, reason
	end
	local api = self:AuctionHouseApi()
	local name
	if sellable.isCommodity then
		name = isConfirm and 'ConfirmPostCommodity' or 'PostCommodity'
	else
		name = isConfirm and 'ConfirmPostItem' or 'PostItem'
	end
	local ok, needsConfirm
	if sellable.isCommodity then
		ok, needsConfirm = pcall(api[name], still.location, duration, quantity, unitPrice)
	else
		ok, needsConfirm = pcall(api[name], still.location, duration, quantity, nil, unitPrice)
	end
	if not ok then
		return nil, 'the auction house refused: ' .. tostring(needsConfirm)
	end
	return (needsConfirm == true and not isConfirm) and 'needsConfirm' or 'posted'
end

--- Asks the server for one item's live listings (AUCTION_HOUSE_BROWSE / *_SEARCH_RESULTS_UPDATED
--- follow).
--- @return boolean sent
function WowMethods:SearchItem(itemId)
	local api = self:AuctionHouseApi()
	if not (api and api.MakeItemKey and api.SendSearchQuery) then
		return false
	end
	local ok, itemKey = pcall(api.MakeItemKey, itemId)
	if not ok or itemKey == nil then
		return false
	end
	local sortOrder = self.env.Enum and self.env.Enum.AuctionHouseSortOrder
	local sorts = { { sortOrder = sortOrder and sortOrder.Price or 0, reverseSort = false } }
	return (pcall(api.SendSearchQuery, itemKey, sorts, true))
end

--- One item's live listings from the last search, cheapest first.
--- @return table { { auctionId, unitPrice, quantity, isOwn, isCommodity }... }
function WowMethods:SearchResults(itemId)
	local api = self:AuctionHouseApi()
	local results = {}
	if not api then
		return results
	end
	local countOk, commodityCount = pcall(api.GetNumCommoditySearchResults or error, itemId)
	if countOk and type(commodityCount) == 'number' and commodityCount > 0 then
		for index = 1, commodityCount do
			local ok, info = pcall(api.GetCommoditySearchResultInfo, itemId, index)
			if ok and type(info) == 'table' and type(info.unitPrice) == 'number' then
				results[#results + 1] = {
					auctionId = info.auctionID,
					unitPrice = info.unitPrice,
					quantity = info.quantity or 1,
					isOwn = (info.numOwnerItems or 0) > 0 or info.containsOwnerItem == true,
					isCommodity = true,
				}
			end
		end
		return results
	end
	local keyOk, itemKey = pcall(api.MakeItemKey or error, itemId)
	local itemCountOk, itemCount = pcall(api.GetNumItemSearchResults or error, keyOk and itemKey or nil)
	for index = 1, (itemCountOk and type(itemCount) == 'number') and itemCount or 0 do
		local ok, info = pcall(api.GetItemSearchResultInfo, itemKey, index)
		local quantity = ok and type(info) == 'table' and (info.quantity or 1) or nil
		if quantity and type(info.buyoutAmount) == 'number' and info.buyoutAmount > 0 then
			results[#results + 1] = {
				auctionId = info.auctionID,
				unitPrice = math.floor(info.buyoutAmount / quantity),
				buyout = info.buyoutAmount,
				quantity = quantity,
				isOwn = info.containsOwnerItem == true,
				isCommodity = false,
			}
		end
	end
	table.sort(results, function(a, b)
		return a.unitPrice < b.unitPrice
	end)
	return results
end

--- Starts a commodity purchase; COMMODITY_PRICE_UPDATED (unitPrice, total) answers with the
--- price the server will charge, and ConfirmCommodityPurchase (from a click) buys.
--- @return boolean sent
function WowMethods:StartCommodityPurchase(itemId, quantity)
	local api = self:AuctionHouseApi()
	return api ~= nil
		and api.StartCommoditiesPurchase ~= nil
		and (pcall(api.StartCommoditiesPurchase, itemId, quantity))
end

--- Buys the commodity purchase started before. Protected: call it only from a click.
function WowMethods:ConfirmCommodityPurchase(itemId, quantity)
	local api = self:AuctionHouseApi()
	if self:IsInCombat() or not (api and api.ConfirmCommoditiesPurchase) then
		return false
	end
	return (pcall(api.ConfirmCommoditiesPurchase, itemId, quantity))
end

function WowMethods:CancelCommodityPurchase()
	local api = self:AuctionHouseApi()
	if api and api.CancelCommoditiesPurchase then
		pcall(api.CancelCommoditiesPurchase)
	end
end

--- Buys one item auction outright. Protected: call it only from a click.
--- @param auctionId number
--- @param buyout number copper for the whole auction
--- @return boolean sent
function WowMethods:BuyAuction(auctionId, buyout)
	local api = self:AuctionHouseApi()
	if self:IsInCombat() or not (api and api.PlaceBid) then
		return false
	end
	return (pcall(api.PlaceBid, auctionId, buyout))
end

-- Trade window ----------------------------------------------------------------------------

--- One trade slot of a side, or nil when it is empty. itemId is nil while the client has not
--- loaded the item's link yet.
--- @param side string 'player' | 'target'
--- @param slot number 1..7
--- @return table|nil { itemId?, qty, name? }
function WowMethods:TradeSlot(side, slot)
	local env = self.env
	local getInfo = side == 'player' and env.GetTradePlayerItemInfo or env.GetTradeTargetItemInfo
	local getLink = side == 'player' and env.GetTradePlayerItemLink or env.GetTradeTargetItemLink
	if not getInfo then
		return nil
	end
	local ok, name, _, count = pcall(getInfo, slot)
	local link = getLink and select(2, pcall(getLink, slot)) or nil
	local itemId = not isSecret(env, link) and itemIdFromLink(link) or nil
	if not ok or (name == nil and itemId == nil) then
		return nil
	end
	return { itemId = itemId, qty = type(count) == 'number' and count >= 1 and count or 1, name = name }
end

--- Copper a side has put in, or nil when the client cannot say.
function WowMethods:TradeMoney(side)
	local env = self.env
	local getMoney = side == 'player' and env.GetPlayerTradeMoney or env.GetTargetTradeMoney
	if not getMoney then
		return nil
	end
	local ok, copper = pcall(getMoney)
	return ok and tonumber(copper) or nil
end

--- Accepts the trade (the same call Blizzard's Trade button makes). Only from a hardware click.
function WowMethods:AcceptTrade()
	local accept = self.env.AcceptTrade
	if accept then
		accept()
		return true
	end
	return false
end

--- Who the trade is with: the trade partner is the 'NPC' unit while the window is open.
--- @return table { name?, guid?, isFriend, isBnetFriend, isGuild }
function WowMethods:TradePartner()
	local env = self.env
	local name = env.UnitName and env.UnitName('NPC') or nil
	local guid = env.UnitGUID and env.UnitGUID('NPC') or nil
	if isSecret(env, name) then
		name = nil
	end
	if isSecret(env, guid) then
		guid = nil
	end
	local friendList = env.C_FriendList
	local isFriend = false
	if friendList and guid and friendList.IsFriend then
		local ok, result = pcall(friendList.IsFriend, guid)
		isFriend = ok and result == true
	end
	local isGuild = false
	if env.UnitIsInMyGuild then
		local ok, result = pcall(env.UnitIsInMyGuild, 'NPC')
		isGuild = ok and result == true
	end
	return {
		name = name,
		guid = guid,
		isFriend = isFriend,
		isBnetFriend = isBnetFriendGuid(env, guid),
		isGuild = isGuild,
	}
end

-- Helpers ---------------------------------------------------------------------------------

function dispatchEvent(wow, event, ...)
	local handlers = wow.eventHandlers[event]
	if not handlers then
		return
	end
	-- Copied first: a handler may unregister itself (ADDON_LOADED does).
	local snapshot = {}
	for owner, handler in pairs(handlers) do
		snapshot[#snapshot + 1] = { owner = owner, handler = handler }
	end
	for _, entry in ipairs(snapshot) do
		local ok, err = pcall(entry.handler, event, ...)
		if not ok then
			if not wow.onError then
				error(err, 0)
			end
			wow.onError(entry.owner .. ' ' .. event, err)
		end
	end
end

function itemIdFromLink(link)
	local id = type(link) == 'string' and link:match('item:(%d+)')
	return id and tonumber(id) or nil
end

-- The item of a tooltip: the post-call's data block first (comparison tooltips have no
-- GetItem), else the tooltip's own item link.
function itemIdFromTooltip(env, tooltip, data)
	local fromData = type(data) == 'table' and data.id
	if type(fromData) == 'number' and not isSecret(env, fromData) and fromData > 0 then
		return fromData
	end
	if tooltip.GetItem then
		local _, link = tooltip:GetItem()
		local fromLink = not isSecret(env, link) and itemIdFromLink(link) or nil
		if fromLink then
			return fromLink
		end
	end
	local guid = type(data) == 'table' and data.guid
	local getLinkByGuid = env.C_Item and env.C_Item.GetItemLinkByGUID
	if guid and getLinkByGuid and not isSecret(env, guid) then
		return itemIdFromLink(getLinkByGuid(guid))
	end
	return nil
end

-- How many units the hovered stack holds: from the bag slot the tooltip is anchored to, when
-- that slot holds the same item (and then the slot, { bag, slot }), else 1. Reads only
-- (GetBagID / GetID / container info), never calls the owner's scripts. The item check guards
-- against an owner whose ids are not a bag slot.
function stackCountFromOwner(env, tooltip, itemId)
	local owner = tooltip.GetOwner and tooltip:GetOwner()
	if type(owner) ~= 'table' then
		return 1
	end
	local container = env.C_Container
	local slot = owner.GetID and owner:GetID()
	local bag = owner.GetBagID and owner:GetBagID()
	if bag == nil and owner.GetParent then
		local parent = owner:GetParent()
		bag = type(parent) == 'table' and parent.GetID and parent:GetID() or nil
	end
	if not (container and container.GetContainerItemInfo and type(bag) == 'number' and type(slot) == 'number') then
		return 1
	end
	local ok, info = pcall(container.GetContainerItemInfo, bag, slot)
	local isSameItem = ok and type(info) == 'table' and not isSecret(env, info.itemID) and info.itemID == itemId
	if not isSameItem then
		return 1
	end
	local count = info.stackCount
	count = type(count) == 'number' and not isSecret(env, count) and count >= 1 and count or 1
	return count, { bag = bag, slot = slot }
end

-- The client's time-left value as the internal band, 1 (short) to 4 (very long). Forever's
-- GetReplicateItemTimeLeft gives 1 to 4 (AHledger's saved scans hold only 1 to 4, and
-- AuctionSellSpeed notes it is one more than Enum.AuctionHouseTimeLeftBand); anything else is
-- unknown.
function timeLeftBand(raw)
	if type(raw) == 'number' and raw >= 1 and raw <= 4 and raw % 1 == 0 then
		return raw
	end
	return nil
end

function isSecret(env, value)
	local check = env.issecretvalue
	return check ~= nil and check(value) == true
end

function isInCombat(env)
	local check = env.InCombatLockdown
	return check ~= nil and check() == true
end

-- True when a character GUID is one of a Battle.net friend's game accounts. Walks the friend
-- list through C_BattleNet (Mainline); any missing API or junk answer reads as not a friend.
function isBnetFriendGuid(env, guid)
	local battleNet = env.C_BattleNet
	if not (guid and env.BNGetNumFriends and battleNet and battleNet.GetFriendNumGameAccounts) then
		return false
	end
	local getAccount = battleNet.GetFriendGameAccountInfo
	local ok, friends = pcall(env.BNGetNumFriends)
	if not ok or type(friends) ~= 'number' or not getAccount then
		return false
	end
	for friend = 1, friends do
		local hasAccounts, accounts = pcall(battleNet.GetFriendNumGameAccounts, friend)
		for account = 1, (hasAccounts and tonumber(accounts) or 0) do
			local hasInfo, info = pcall(getAccount, friend, account)
			if hasInfo and type(info) == 'table' and info.playerGuid == guid then
				return true
			end
		end
	end
	return false
end

-- The server number in a player GUID ("Player-6928-00A1AEB0" -> 6928), or nil.
function serverIdFromGuid(guid)
	local id = type(guid) == 'string' and tonumber(guid:match('^Player%-(%d+)%-')) or nil
	return id and id > 0 and id or nil
end

return Wow
