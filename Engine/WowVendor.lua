--[[
	WowVendor: the game reads that merchant recording needs, added to the wow object
	(Engine/Wow.lua). Like the rest of Wow, every wrapper checks the API exists, calls it under
	pcall and answers nil / {} when the client cannot say.

	  MerchantVendor()        { npcId, name, mapId?, zone?, faction?, reaction? } | nil
	                          the open merchant; reaction is UnitReaction('npc', 'player'), the
	                          player's standing with the vendor's faction (4 neutral .. 8 exalted)
	  MerchantSlots()         { slots = { MerchantSlot... }, isComplete }
	  QuestieItemVendors(itemId)  true | nil   true when Questie's item data lists a vendor

	  MerchantSlot = { index, itemId, price, stack, available, hasExtendedCost, costs = { Cost... } }
	  Cost         = { kind = 'currency'|'item', id?, count }

	price is copper for stack units (C_MerchantFrame.GetItemInfo, or GetMerchantItemInfo on an
	older client); available is numAvailable, -1 for unlimited stock. A slot priced 0 with no
	extended cost counts as not read, so a real 0-copper item without an extended cost makes
	every read of that vendor incomplete (nothing of it is marked gone). isComplete is false
	when a slot could not be read, the list is empty (not loaded yet) or the merchant's filter
	hides items (GetMerchantFilter is not "all"), so a caller does not take an unread item for
	one the vendor stopped selling.
]]
local _, ns = ...

local Methods = ns.Wow.Methods

local UNLIMITED = -1
local LOOT_FILTER_ALL = 1

-- Helpers live at the bottom of the file; declared here so they stay local.
local call, callResults, isWholePositive, npcIdFromGuid, slotInfo, slotCosts, idFromLink, isFilteredMerchant

--- The merchant the player talks to, nil when none is open or the client cannot say.
--- @return table|nil { npcId, name, mapId?, zone?, faction?, reaction? }
function Methods:MerchantVendor()
	local env = self.env
	local npcId = npcIdFromGuid(call(env.UnitGUID, 'npc'))
	if not npcId then
		return nil
	end
	local name = call(env.UnitName, 'npc')
	local mapApi = env.C_Map
	local mapId = mapApi and call(mapApi.GetBestMapForUnit, 'player')
	local zone = call(env.GetRealZoneText) or call(env.GetZoneText)
	local faction = call(env.UnitFactionGroup, 'npc')
	local reaction = call(env.UnitReaction, 'npc', 'player')
	return {
		npcId = npcId,
		name = type(name) == 'string' and name ~= '' and name or nil,
		mapId = isWholePositive(mapId) and mapId or nil,
		zone = type(zone) == 'string' and zone ~= '' and zone or nil,
		faction = (faction == 'Alliance' or faction == 'Horde') and faction or nil,
		reaction = isWholePositive(reaction) and reaction <= 8 and reaction or nil,
	}
end

--- Every item the open merchant offers.
--- @return table { slots = { MerchantSlot... }, isComplete }
function Methods:MerchantSlots()
	local env = self.env
	local count = call(env.GetMerchantNumItems)
	if type(count) ~= 'number' or count < 0 or count % 1 ~= 0 then
		return { slots = {}, isComplete = false }
	end
	-- An empty list is a merchant whose items have not arrived yet, not one that sells nothing.
	local slots, isComplete = {}, count > 0 and not isFilteredMerchant(env)
	for index = 1, count do
		local slot = slotInfo(env, index)
		if slot then
			slots[#slots + 1] = slot
		else
			isComplete = false
		end
	end
	return { slots = slots, isComplete = isComplete }
end

--- Whether Questie's item data says a vendor sells the item; nil without Questie or an answer.
--- Read only: nothing of Questie's is kept.
--- @param itemId number
--- @return boolean|nil true, or nil when Questie cannot say
function Methods:QuestieItemVendors(itemId)
	local loader = self.env.QuestieLoader
	if type(loader) ~= 'table' or type(loader.ImportModule) ~= 'function' then
		return nil
	end
	local ok, questieDb = pcall(loader.ImportModule, loader, 'QuestieDB')
	if not ok or type(questieDb) ~= 'table' or type(questieDb.QueryItemSingle) ~= 'function' then
		return nil
	end
	local isRead, vendors = pcall(questieDb.QueryItemSingle, itemId, 'vendors')
	if not isRead then
		return nil
	end
	-- An empty list and no answer look the same in Questie, so both read as "cannot say".
	if type(vendors) == 'table' and next(vendors) ~= nil then
		return true
	end
	return nil
end

-- Helpers ---------------------------------------------------------------------------------

function call(fn, ...)
	if type(fn) ~= 'function' then
		return nil
	end
	return callResults(pcall(fn, ...))
end

function callResults(ok, ...)
	if not ok then
		return nil
	end
	return ...
end

function isWholePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

-- Creature-0-<server>-<instance>-<zone>-<npcId>-<spawn>; a player or pet has no npc id.
function npcIdFromGuid(guid)
	if type(guid) ~= 'string' then
		return nil
	end
	local kind, npcId = guid:match('^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-')
	if kind ~= 'Creature' and kind ~= 'Vehicle' then
		return nil
	end
	npcId = tonumber(npcId)
	return isWholePositive(npcId) and npcId or nil
end

function slotInfo(env, index)
	local itemId = call(env.GetMerchantItemID, index) or idFromLink(call(env.GetMerchantItemLink, index))
	if not isWholePositive(itemId) then
		return nil
	end
	local price, stack, available, hasExtendedCost
	local merchant = env.C_MerchantFrame
	local info = merchant and call(merchant.GetItemInfo, index)
	if type(info) == 'table' then
		price, stack, available, hasExtendedCost = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
	else
		local _, _, legacyPrice, quantity, numAvailable, _, _, extendedCost = call(env.GetMerchantItemInfo, index)
		price, stack, available, hasExtendedCost = legacyPrice, quantity, numAvailable, extendedCost
	end
	if type(price) ~= 'number' or price < 0 or price % 1 ~= 0 or price == math.huge then
		return nil
	end
	local costs = hasExtendedCost and slotCosts(env, index) or {}
	-- Price 0 with no other cost is a slot the client has not filled yet, not a free item.
	if price == 0 and hasExtendedCost ~= true and #costs == 0 then
		return nil
	end
	return {
		index = index,
		itemId = itemId,
		price = price,
		stack = isWholePositive(stack) and stack or 1,
		available = (type(available) == 'number' and available >= 0 and available % 1 == 0) and available or UNLIMITED,
		hasExtendedCost = hasExtendedCost == true or #costs > 0,
		costs = costs,
	}
end

-- The currency and item costs beside the copper price (GetMerchantItemCostItem).
function slotCosts(env, index)
	local costs = {}
	local costCount = call(env.GetMerchantItemCostInfo, index)
	if not isWholePositive(costCount) then
		return costs
	end
	for costIndex = 1, costCount do
		local _, value, link = call(env.GetMerchantItemCostItem, index, costIndex)
		if isWholePositive(value) then
			local kind, id = 'currency', nil
			if type(link) == 'string' then
				local itemId = link:match('|Hitem:(%d+)')
				local currencyId = link:match('|Hcurrency:(%d+)')
				kind = itemId and 'item' or 'currency'
				id = tonumber(itemId or currencyId)
			end
			costs[#costs + 1] = { kind = kind, id = id, count = value }
		end
	end
	return costs
end

function idFromLink(link)
	return type(link) == 'string' and tonumber(link:match('|Hitem:(%d+)')) or nil
end

function isFilteredMerchant(env)
	local filter = call(env.GetMerchantFilter)
	if filter == nil then
		return false
	end
	return filter ~= (env.LE_LOOT_FILTER_ALL or LOOT_FILTER_ALL)
end
