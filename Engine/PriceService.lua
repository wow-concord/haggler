--[[
	PriceService: prices for the rest of the add-on and for other add-ons. It owns no data: each
	call builds a fresh context (PriceContext) from the store, the price source (PriceData) and
	the latest scan of the player's market, so a new scan or table is seen at once.

	  new({ now, store, priceSource?, marketKey, itemInfo?, cachedItemInfo?, requestItemData?,
	        nextFrame?, confidence?, sales? })
	    priceSource          a PriceSource (PriceData); without one, prices come from scans only
	    now()                unix seconds
	    marketKey()          the player's market key, or nil while it is not known yet
	    itemInfo(id)         { maxStack, vendorPrice } or nil
	    cachedItemInfo(id)   the same, but nil for an item the client has not cached, without
	                         asking the server for it; itemInfo when not given
	    requestItemData(id)  asks the client to load an item it has not cached
	    nextFrame(fn)        runs fn next frame; false when it cannot. Item data requests are
	                         queued and sent ITEM_REQUESTS_PER_FRAME a frame, not in one burst
	    confidence()         { staleMediumHours, staleLowHours }
	    sales()              { minScans, minHours, trollSharePercent, windowDays } (Sales)

	Every vendor price the client shows is kept in the store (Store:VendorPrice), so the troll
	check of the own sales count knows it before the client caches the item again.

	Every item name the client shows through ItemInfo is kept for the session (KnownName,
	ItemIdsByName), so a search by name reads names Haggler has already seen and never asks the
	client to load thousands of items at once. Context({ isCacheOnly = true }) prices from cached
	item info only, for callers that price thousands of items in one go (the Buy search).

	Bad calls from other add-ons (an item id that is not a whole number, an unknown rule) are an
	expected outcome here, not a programmer error: they return nil and a reason, so a careless
	caller cannot get the provider switched off by the host's failure count.
]]
local _, ns = ...

local PriceService = {}
ns.PriceService = PriceService

PriceService.ITEM_REQUESTS_PER_FRAME = 20
-- The realized base (the price you actually got) reads the sell log this far back.
PriceService.REALIZED_DAYS = 30

-- Helpers live at the bottom of the file; declared here so they stay local.
local isItemId, ageOrNil, safeCall, rememberVendorPrice, scheduleItemRequests, sendQueuedItemRequests
local realizedLookup, readItemInfo

local ServiceMethods = {}
ServiceMethods.__index = ServiceMethods

--- @param options table see the file header
--- @return table service
function PriceService.new(options)
	if type(options) ~= 'table' or type(options.now) ~= 'function' or not options.store then
		error('PriceService.new: needs now and store', 2)
	end
	if type(options.marketKey) ~= 'function' then
		error('PriceService.new: needs marketKey', 2)
	end
	if options.priceSource ~= nil and not ns.PriceData.isSource(options.priceSource) then
		error('PriceService.new: priceSource must be a PriceSource (PriceData)', 2)
	end
	return setmetatable(
		{ options = options, requestedItems = {}, itemRequestQueue = {}, knownNames = {} },
		ServiceMethods
	)
end

--- The player's market key, or nil while it is not known.
function ServiceMethods:MarketKey()
	local key = safeCall(self.options.marketKey)
	return type(key) == 'string' and key or nil
end

--- The latest usable scan of the player's market.
function ServiceMethods:Snapshot()
	local key = self:MarketKey()
	if not key then
		return nil
	end
	return ns.ScanStore.latest(self.options.store:Market(key))
end

--- Static item info from the client, or nil while it has not cached the item. A vendor price
--- it shows is remembered.
--- @param itemId number
--- @return table|nil { name, maxStack, vendorPrice }
function ServiceMethods:ItemInfo(itemId)
	return readItemInfo(self, self.options.itemInfo, itemId)
end

--- Like ItemInfo, but nil for an item the client has not cached; never makes the client ask
--- the server for it.
--- @param itemId number
--- @return table|nil { name, maxStack, vendorPrice }
function ServiceMethods:CachedItemInfo(itemId)
	return readItemInfo(self, self.options.cachedItemInfo or self.options.itemInfo, itemId)
end

--- An item's name when Haggler has seen it this session; never asks the client.
--- @param itemId number
--- @return string|nil
function ServiceMethods:KnownName(itemId)
	return self.knownNames[itemId]
end

--- Items seen this session whose name holds the text: an exact name alone when there is one,
--- else up to limit matches by item id.
--- @param lowerText string lower case
--- @param limit number|nil default 20
--- @return number[] itemIds
function ServiceMethods:ItemIdsByName(lowerText, limit)
	if type(lowerText) ~= 'string' or lowerText == '' then
		return {}
	end
	local matches = {}
	for itemId, name in pairs(self.knownNames) do
		local lowerName = name:lower()
		if lowerName == lowerText then
			return { itemId }
		end
		if lowerName:find(lowerText, 1, true) then
			matches[#matches + 1] = itemId
		end
	end
	table.sort(matches)
	for index = #matches, (limit or 20) + 1, -1 do
		matches[index] = nil
	end
	return matches
end

--- An item's vendor price as the store remembers it (from items seen before); never asks the
--- client to load the item, so it is safe across a whole scan.
--- @param itemId number
--- @return number|nil copper
function ServiceMethods:KnownVendorPrice(itemId)
	if not isItemId(itemId) then
		return nil
	end
	return self.options.store:VendorPrice(itemId)
end

--- An item's vendor price: from the client, else the one remembered. When neither knows it,
--- the client is asked to load the item and nil is returned (try again later).
--- @param itemId number
--- @return number|nil copper
function ServiceMethods:VendorPrice(itemId)
	if not isItemId(itemId) then
		return nil
	end
	local info = self:ItemInfo(itemId)
	local fromClient = info and info.vendorPrice
	if type(fromClient) == 'number' and fromClient >= 0 and fromClient < math.huge then
		return fromClient
	end
	local remembered = self.options.store:VendorPrice(itemId)
	-- One request per item a session: the client answers it once the item has loaded.
	local isRequestable = type(self.options.requestItemData) == 'function' and not self.requestedItems[itemId]
	if remembered == nil and isRequestable then
		self.requestedItems[itemId] = true
		self:QueueItemRequest(itemId)
	end
	return remembered
end

--- Queues a request for an item's data; sent within a later frame's budget, or at once when
--- there is no frame clock.
--- @param itemId number
function ServiceMethods:QueueItemRequest(itemId)
	local queue = self.itemRequestQueue
	queue[#queue + 1] = itemId
	scheduleItemRequests(self)
end

--- The sales settings (Sales.choose and the window), or nil when they cannot be read.
--- @return table|nil { minScans, minHours, trollSharePercent, windowDays }
function ServiceMethods:SalesSettings()
	local settings = safeCall(self.options.sales)
	return type(settings) == 'table' and settings or nil
end

--- A fresh rules context.
--- @param contextOptions table|nil { isCacheOnly } item info from the client's cache only
function ServiceMethods:Context(contextOptions)
	local options = self.options
	local isCacheOnly = type(contextOptions) == 'table' and contextOptions.isCacheOnly == true
	local confidence = safeCall(options.confidence)
	local salesSettings = self:SalesSettings()
	local key = self:MarketKey()
	local market = key and options.store:Market(key) or nil
	local now = options.now()
	return ns.PriceContext.build({
		now = now,
		marketKey = self:MarketKey(),
		priceSource = options.priceSource,
		snapshot = self:Snapshot(),
		itemInfo = function(itemId)
			if isCacheOnly then
				return self:CachedItemInfo(itemId)
			end
			return self:ItemInfo(itemId)
		end,
		confidence = type(confidence) == 'table' and confidence or nil,
		scanDays = market and market.scanDays,
		salesSettings = salesSettings,
		realized = market and realizedLookup(market, now) or nil,
	})
end

--- One item's price under a rule.
--- @param itemId any
--- @param ruleId string|nil default rule when nil
--- @param ctx table|nil a context to reuse across calls
--- @return table|nil Price
--- @return string|nil reason
function ServiceMethods:Get(itemId, ruleId, ctx)
	if not isItemId(itemId) then
		return nil, 'item id must be a positive whole number'
	end
	local store = self.options.store
	local rule = store:Rule(ruleId or store:DefaultRuleId())
	if not rule then
		return nil, 'unknown rule ' .. tostring(ruleId)
	end
	return ns.Rules.evaluate(rule, itemId, ctx or self:Context())
end

--- The price contract v1: { copper, ageSeconds, source } under the default rule.
--- @return table|nil
--- @return string|nil reason
function ServiceMethods:Simple(itemId)
	local price, reason = self:Get(itemId)
	if not price then
		return nil, reason
	end
	return { copper = price.copper, ageSeconds = price.ageSeconds, source = price.source }
end

--- Every rule, default first then as the store orders them.
--- @return table { { id, name, builtIn, isDefault }... }
function ServiceMethods:Rules()
	local store = self.options.store
	local defaultId = store:DefaultRuleId()
	local rules = {}
	for _, ruleId in ipairs(store:RuleIds()) do
		local rule = store:Rule(ruleId)
		local entry = { id = ruleId, name = rule.name, builtIn = rule.builtIn == true, isDefault = ruleId == defaultId }
		table.insert(rules, entry.isDefault and 1 or #rules + 1, entry)
	end
	return rules
end

function ServiceMethods:DefaultRule()
	return self.options.store:DefaultRuleId()
end

--- Everything a tooltip shows for one item, from one context.
--- @param itemId number
--- @param ruleIds string[] rules to price, in order
--- @return table { prices = { { ruleId, name, isDefault, price?, reason? }... }, facts, ages }
function ServiceMethods:Quote(itemId, ruleIds)
	local ctx = self:Context()
	local store = self.options.store
	local defaultId = store:DefaultRuleId()
	local prices = {}
	for _, ruleId in ipairs(ruleIds) do
		local rule = store:Rule(ruleId)
		local price, reason = self:Get(itemId, ruleId, ctx)
		prices[#prices + 1] = {
			ruleId = ruleId,
			name = rule and rule.name or tostring(ruleId),
			isDefault = ruleId == defaultId,
			price = price,
			reason = reason,
		}
	end
	return {
		prices = prices,
		facts = ns.PriceContext.facts(ctx, itemId),
		ages = self:Ages(ctx.now),
	}
end

--- Whether the price source has prices for the player's market, why not, the credit to show
--- with them and the market the source is set to (PriceData.statusOf).
--- @return table { isAvailable, code?, reason?, credit?, market? }
function ServiceMethods:SourceStatus()
	return ns.PriceData.statusOf(self.options.priceSource, self:MarketKey())
end

--- The price source's table for the player's market, or nil.
--- @return table|nil { market, updated, count, isSnapshot }
function ServiceMethods:PriceTable()
	local key = self:MarketKey()
	local priceSource = self.options.priceSource
	if not key or not priceSource then
		return nil
	end
	local ok, priceTable = pcall(priceSource.Table, priceSource, key)
	return ok and type(priceTable) == 'table' and priceTable or nil
end

--- How old the market's data is: the latest scan and the price table.
--- @param now number|nil
--- @return table { scanAge?, tableAge?, isSnapshot } seconds
function ServiceMethods:Ages(now)
	now = now or self.options.now()
	local snapshot = self:Snapshot()
	local priceTable = self:PriceTable()
	return {
		scanAge = snapshot and ageOrNil(now, snapshot.at) or nil,
		tableAge = priceTable and ageOrNil(now, priceTable.updated) or nil,
		isSnapshot = priceTable ~= nil and priceTable.isSnapshot == true,
	}
end

-- Helpers ---------------------------------------------------------------------------------

function isItemId(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

function ageOrNil(now, at)
	if type(at) ~= 'number' or at ~= at or at == math.huge then
		return nil
	end
	return math.max(0, now - at)
end

function rememberVendorPrice(store, itemId, copper)
	local isUsable = type(copper) == 'number' and copper >= 0 and copper < math.huge
	if isUsable and store:VendorPrice(itemId) ~= copper then
		store:RememberVendorPrice(itemId, copper)
	end
end

function safeCall(fn)
	if type(fn) ~= 'function' then
		return nil
	end
	local ok, value = pcall(fn)
	return ok and value or nil
end

-- Sends the queue a slice per frame; with no frame clock (or one that fails) all at once.
function scheduleItemRequests(service)
	if service.isItemRequestScheduled or #service.itemRequestQueue == 0 then
		return
	end
	local nextFrame = service.options.nextFrame
	local ok, isScheduled = false, false
	if type(nextFrame) == 'function' then
		ok, isScheduled = pcall(nextFrame, function()
			service.isItemRequestScheduled = false
			sendQueuedItemRequests(service, PriceService.ITEM_REQUESTS_PER_FRAME)
			scheduleItemRequests(service)
		end)
	end
	if ok and isScheduled == true then
		service.isItemRequestScheduled = true
	else
		sendQueuedItemRequests(service, math.huge)
	end
end

function sendQueuedItemRequests(service, budget)
	local queue = service.itemRequestQueue
	local sent = math.min(budget, #queue)
	for index = 1, sent do
		pcall(service.options.requestItemData, queue[index])
	end
	local remaining = {}
	for index = sent + 1, #queue do
		remaining[#remaining + 1] = queue[index]
	end
	service.itemRequestQueue = remaining
end

-- The realized price per item, from the sell log (troll sales left out); the index is built on
-- the first lookup and shared by the rest of the context.
function realizedLookup(market, now)
	local index
	return function(itemId)
		index = index or ns.Ledger.realizedIndex(market, now - PriceService.REALIZED_DAYS * 86400)
		local entry = index[itemId]
		if entry then
			return entry.copper, entry.at
		end
		return nil
	end
end

-- Reads item info through a reader; a vendor price is remembered and a name kept.
function readItemInfo(service, reader, itemId)
	if type(reader) ~= 'function' or not isItemId(itemId) then
		return nil
	end
	local ok, info = pcall(reader, itemId)
	if not ok or type(info) ~= 'table' then
		return nil
	end
	rememberVendorPrice(service.options.store, itemId, info.vendorPrice)
	if type(info.name) == 'string' and info.name ~= '' then
		service.knownNames[itemId] = info.name
	end
	return info
end

return PriceService
