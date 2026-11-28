--[[
	VendorStore: what merchants charged the player, kept per vendor, for vendor buy prices and
	a future Concord data network (which carries auction house and vendor item data). Only the
	player's own observations go in, read from the merchant window when it opens or changes;
	nothing from another add-on's data is stored. Prices and stock differ between vendors, so
	each vendor keeps its own list.

	Saved beside the scan history in HagglerArchiveDB (account-wide), under its own schema:

	  HagglerArchiveDB.vendors = { schema = 2, byNpc = { [npcId] = Vendor } }
	  Vendor  = { name?, mapId?, zone?, faction?, reaction?, firstSeenAt, seenAt, items = Packed }
	  Packed  = 'Record;Record;...'   in no set order, each item id once
	  Record  = 'itemId,price,stack,available,seenAt,goneAt,reaction,costs'
	            or the same with ',basePrice,baseStack,baseSeenAt' after costs
	  costs   = '' | 'Cost+Cost...',  Cost = 'c<currencyId>x<count>' | 'i<itemId>x<count>'

	npcId is the creature id in the merchant's GUID; the same NPC sells the same list wherever it
	stands. price is the copper asked for stack units, exactly as the client gave it (whole
	numbers); the unit price is price / stack. available is the stock left (-1 unlimited).
	seenAt is unix seconds of the last read that listed the item; goneAt, when set, the first
	complete read that did not: the item is kept, marked unavailable, never deleted for it.
	A read that missed a slot, held a slot that is no record (price 0 with no other cost reads
	as a slot not filled yet) or ran under a merchant filter marks nothing gone. Currency id 0
	is a currency the client named but gave no link for.

	reaction is the standing of the character that made the read with the vendor's faction
	(UnitReaction: 4 neutral, 5 friendly .. 8 exalted). Reputation discounts change the price
	asked, and which step gives how much is not certain on Forever, so the raw price and the
	standing are kept; a read is at base price only up to BASE_PRICE_MAX_REACTION. price, stack
	and reaction are the latest read's. When that read was discounted or of unknown standing
	and an earlier read of the item was at base price, basePrice, baseStack and baseSeenAt
	keep that base read, so a discounted read never erases it; a later base read replaces it.
	A kept base is dropped when it is stale: the latest read asks more per unit than the base
	(a discount never raises a price, so the base price went up), the base is more than
	BASE_MAX_AGE_SECONDS older than the latest read, or the latest read asks a currency or item
	beside copper. Then the latest read or the seed answers.

	Schema 2 added the base fields; a schema 1 store opens as it is (its records have none).
	A kept base is dropped when it is stale: the latest read asks more per unit than the base
	(a discount never raises a price, so the base price went up), the base is more than
	BASE_MAX_AGE_SECONDS older than the latest read, or the latest read asks a currency or item
	beside copper. Then the latest read or the seed answers.

	Schema 2 added the base fields; a schema 1 store opens as it is (its records have none).

	A record that does not parse strictly reads as nothing; a broken vendor reads as none; never
	an error. open never raises, whatever the saved table holds. It refuses, untouched, a store of
	a newer schema and a whole HagglerArchiveDB of a newer schema than ScanArchive's. Its size
	cap is its own: prune counts only byNpc, ScanArchive's 32 MB budget only markets.

	Size: measured on a 30-item vendor, a vendor costs about 1.0 KB (30 bytes a record, about
	120 for name, zone and the rest). The store is capped (default 512 KB, some 500 vendors):
	prune drops the vendors seen longest ago first, never the newest one. An item record
	beyond MAX_ITEMS_PER_VENDOR drops the longest-gone ones first.

	  VendorStore.open(archiveDb)                      -> db | nil, reason
	  VendorStore.record(db, observation, now)         -> saved, reason | { added, changed, gone }
	  VendorStore.vendorItems(db, npcId)               -> { [itemId] = Record } (parsed)
	  VendorStore.offers(db, itemId)                   -> { Offer... }
	  VendorStore.prune(db, { maxBytes? })             -> vendors dropped
	  VendorStore.export(db, fromAt?, toAt?)           -> { schema, vendors = { ... } }
	  VendorStore.bytes(db), VendorStore.vendorBytes(vendor), VendorStore.summary(db)

	observation = { vendor = { npcId, name?, mapId?, zone?, faction?, reaction? },
	                slots = { { itemId, price, stack, available, costs? }... }, isComplete }
	(Wow:MerchantVendor and Wow:MerchantSlots.) Offer = { npcId, name?, zone?, mapId?, faction?,
	itemId, price, stack, unitPrice, available, isLimited, seenAt, priceSeenAt, goneAt?,
	reaction?, hasExtendedCost, costs, isBasePrice, priceFromBase, latestPrice, latestStack }.
	price, stack and unitPrice are the vendor's kept base price when it has one (priceFromBase
	true), else the latest read's; priceSeenAt is when that price was read; reaction,
	latestPrice and latestStack are the latest read's.

	export is the entry point a network would call: pure, nothing leaves the machine. It gives
	the raw records (ExportRecord), not offers, so a receiver can apply its own rules.
]]
local _, ns = ...

local VendorStore = {}
ns.VendorStore = VendorStore

VendorStore.SCHEMA = 2
VendorStore.UNLIMITED = -1
-- The highest standing (UnitReaction) at which a vendor asks its base price: 4 is Neutral.
-- Whether Friendly (5) already gets a discount on Forever is unconfirmed: the server applies
-- the discount and the 71037 client holds no rule for it (client facts register V7, probe 55).
-- The value stays at Neutral, the one standing known to pay base price.
VendorStore.BASE_PRICE_MAX_REACTION = 4
-- A kept base price older than this before the latest read is stale.
VendorStore.BASE_MAX_AGE_SECONDS = 30 * 24 * 60 * 60
-- No merchant sells more units in one slot; a larger stack is a broken read or record.
VendorStore.MAX_STACK = 10000
VendorStore.MAX_ITEMS_PER_VENDOR = 255
VendorStore.DEFAULT_MAX_KB = 512
VendorStore.BYTES_PER_KB = 1024
-- What a vendor's other fields and its SavedVariables lines cost beside the packed items.
VendorStore.VENDOR_OVERHEAD_BYTES = 96
VendorStore.MAX_TEXT_LENGTH = 64

-- Revision per opened store, so a lookup index knows when to rebuild; never saved.
local revisions = setmetatable({}, { __mode = 'k' })
local indexes = setmetatable({}, { __mode = 'k' })

-- Helpers live at the bottom of the file; declared here so they stay local.
local isOpened, isUsableVendor, isWhole, isWholePositive, isFinitePositive, cleanText
local packRecord, parseRecord, packCosts, parseCosts, parseItems, packItems, recordFromSlot
local trimItems, offerOf, exportRecord, buildIndex, bump, sortedNpcIds, isBaseReaction, keepBasePrice
local isStack, isFreshBase, parseBase

--- Opens the vendor store inside the archive's saved table. Never raises: a missing or broken
--- store is replaced with an empty one; a schema 1 store opens as schema 2 (its records read
--- as they are); a newer schema is left untouched.
--- @param archiveDb any HagglerArchiveDB
--- @return table|nil db
--- @return string|nil reason 'not a table' | 'newer archive' (the whole file) | 'newer schema'
function VendorStore.open(archiveDb)
	if type(archiveDb) ~= 'table' then
		return nil, 'not a table'
	end
	-- A whole file from a newer Haggler stays untouched, as the scan history leaves it.
	local archiveSchema = tonumber(archiveDb.schema)
	if archiveSchema and archiveSchema > ns.ScanArchive.SCHEMA then
		return nil, 'newer archive'
	end
	local db = archiveDb.vendors
	if type(db) ~= 'table' then
		db = {}
		archiveDb.vendors = db
	end
	local schema = tonumber(db.schema)
	if schema and schema > VendorStore.SCHEMA then
		return nil, 'newer schema'
	end
	db.schema = VendorStore.SCHEMA
	if type(db.byNpc) ~= 'table' then
		db.byNpc = {}
	end
	return db
end

--- Records one read of a merchant: every listed item is seen now; on a complete read, every
--- item the vendor no longer lists is marked gone.
--- @param db table an opened store
--- @param observation table see the header
--- @param now number unix seconds
--- @return boolean saved
--- @return string|table reason ('no vendor' | 'no items') or { added, changed, gone }
function VendorStore.record(db, observation, now)
	if not isOpened(db) then
		error('VendorStore.record: open the store first', 2)
	end
	if not isFinitePositive(now) then
		error('VendorStore.record: now must be unix seconds', 2)
	end
	local seller = type(observation) == 'table' and observation.vendor
	if type(seller) ~= 'table' or not isWholePositive(seller.npcId) then
		return false, 'no vendor'
	end
	local slots = type(observation.slots) == 'table' and observation.slots or {}
	local reaction = isWholePositive(seller.reaction) and seller.reaction or nil
	local listed = {}
	-- A slot that does not read as a record could be any item, so the read marks nothing gone.
	local isComplete = observation.isComplete == true
	for _, slot in ipairs(slots) do
		local record = recordFromSlot(slot, now, reaction)
		if not record then
			isComplete = false
		end
		local previous = record and listed[record.itemId]
		-- One item in two slots (two stack sizes): keep the cheaper unit price.
		if record and (not previous or record.price / record.stack < previous.price / previous.stack) then
			listed[record.itemId] = record
		end
	end
	if next(listed) == nil and not isComplete then
		return false, 'no items'
	end
	local vendor = db.byNpc[seller.npcId]
	if not isUsableVendor(vendor) then
		vendor = { firstSeenAt = now, seenAt = now, items = '' }
		db.byNpc[seller.npcId] = vendor
	end
	local items = parseItems(vendor.items)
	local summary = { added = 0, changed = 0, gone = 0 }
	for itemId, record in pairs(listed) do
		local previous = items[itemId]
		if not previous then
			summary.added = summary.added + 1
		elseif previous.price ~= record.price or previous.stack ~= record.stack or previous.goneAt then
			summary.changed = summary.changed + 1
		end
		keepBasePrice(record, previous)
		items[itemId] = record
	end
	if isComplete then
		for itemId, record in pairs(items) do
			if not listed[itemId] and not record.goneAt then
				record.goneAt = now
				summary.gone = summary.gone + 1
			end
		end
	end
	vendor.items = packItems(trimItems(items))
	vendor.seenAt = now
	vendor.name = cleanText(seller.name) or vendor.name
	vendor.zone = cleanText(seller.zone) or vendor.zone
	vendor.mapId = isWholePositive(seller.mapId) and seller.mapId or vendor.mapId
	vendor.faction = (seller.faction == 'Alliance' or seller.faction == 'Horde') and seller.faction or vendor.faction
	vendor.reaction = reaction or vendor.reaction
	bump(db)
	return true, summary
end

--- A vendor's item records, parsed; {} for an unknown or broken vendor.
--- @param db any a store
--- @param npcId number
--- @return table { [itemId] = { itemId, price, stack, available, seenAt, goneAt?, reaction?, costs,
---   basePrice?, baseStack?, baseSeenAt? } }, price, stack and reaction from the latest read and
---   the base fields a fresh kept base price (see the header)
function VendorStore.vendorItems(db, npcId)
	local vendor = type(db) == 'table' and type(db.byNpc) == 'table' and db.byNpc[npcId] or nil
	if not isUsableVendor(vendor) then
		return {}
	end
	return parseItems(vendor.items)
end

--- Every vendor's offer of an item, gone ones included; cheapest unit price first.
--- @param db any a store
--- @param itemId number
--- @return table { Offer... }
function VendorStore.offers(db, itemId)
	if type(db) ~= 'table' or type(db.byNpc) ~= 'table' then
		return {}
	end
	local index = indexes[db]
	if not index or index.revision ~= (revisions[db] or 0) then
		index = buildIndex(db)
		indexes[db] = index
	end
	local offers = {}
	for position, offer in ipairs(index.byItem[itemId] or {}) do
		offers[position] = offer
	end
	return offers
end

--- Fits the store into maxBytes, dropping the vendors seen longest ago; drops broken vendors.
--- @param db table an opened store (changed in place)
--- @param options table|nil { maxBytes? }
--- @return number vendors dropped
function VendorStore.prune(db, options)
	if not isOpened(db) then
		error('VendorStore.prune: open the store first', 2)
	end
	local maxBytes = options and isFinitePositive(options.maxBytes) and options.maxBytes
		or VendorStore.DEFAULT_MAX_KB * VendorStore.BYTES_PER_KB
	local dropped, total, kept = 0, 0, {}
	for npcId, vendor in pairs(db.byNpc) do
		if isWholePositive(npcId) and isUsableVendor(vendor) then
			total = total + VendorStore.vendorBytes(vendor)
			kept[#kept + 1] = npcId
		else
			db.byNpc[npcId] = nil
			dropped = dropped + 1
		end
	end
	table.sort(kept, function(a, b)
		local seenA, seenB = db.byNpc[a].seenAt, db.byNpc[b].seenAt
		if seenA ~= seenB then
			return seenA < seenB
		end
		return a < b
	end)
	local position = 1
	while total > maxBytes and position < #kept do
		total = total - VendorStore.vendorBytes(db.byNpc[kept[position]])
		db.byNpc[kept[position]] = nil
		dropped = dropped + 1
		position = position + 1
	end
	if dropped > 0 then
		bump(db)
	end
	return dropped
end

--- Every vendor seen between two times with the items seen or gone in that span, oldest vendor
--- first. Pure: the store is not changed. Broken vendors and records are left out.
--- @param db any a store
--- @param fromAt number|nil unix seconds, inclusive; nil for the start
--- @param toAt number|nil unix seconds, inclusive; nil for now
--- @return table { schema, skipped, vendors = { { npcId, name?, mapId?, zone?, faction?,
---   reaction?, firstSeenAt, seenAt, items = { ExportRecord... } }... } }, ExportRecord =
---   { itemId, price, stack, available, seenAt, goneAt?, reaction?, costs, basePrice?,
---   baseStack?, baseSeenAt? }: the latest read, and a kept base price beside it
function VendorStore.export(db, fromAt, toAt)
	local export = { schema = VendorStore.SCHEMA, vendors = {}, skipped = 0 }
	if type(db) ~= 'table' or type(db.byNpc) ~= 'table' then
		return export
	end
	local function isInRange(at)
		return isFinitePositive(at)
			and (type(fromAt) ~= 'number' or at >= fromAt)
			and (type(toAt) ~= 'number' or at <= toAt)
	end
	for _, npcId in ipairs(sortedNpcIds(db.byNpc)) do
		local vendor = db.byNpc[npcId]
		local items = {}
		local recordsById, skipped = parseItems(vendor.items)
		export.skipped = export.skipped + skipped
		for _, record in pairs(recordsById) do
			if isInRange(record.seenAt) or isInRange(record.goneAt) then
				items[#items + 1] = exportRecord(record)
			end
		end
		if #items > 0 then
			table.sort(items, function(a, b)
				return a.itemId < b.itemId
			end)
			export.vendors[#export.vendors + 1] = {
				npcId = npcId,
				name = vendor.name,
				mapId = vendor.mapId,
				zone = vendor.zone,
				faction = vendor.faction,
				reaction = vendor.reaction,
				firstSeenAt = isFinitePositive(vendor.firstSeenAt) and vendor.firstSeenAt or vendor.seenAt,
				seenAt = vendor.seenAt,
				items = items,
			}
		end
	end
	return export
end

--- What one vendor costs in the saved file, roughly.
--- @param vendor any
--- @return number bytes, 0 for a broken vendor
function VendorStore.vendorBytes(vendor)
	if not isUsableVendor(vendor) then
		return 0
	end
	return #vendor.items + #(vendor.name or '') + #(vendor.zone or '') + VendorStore.VENDOR_OVERHEAD_BYTES
end

--- What the whole store costs in the saved file, roughly.
--- @param db any
--- @return number bytes
function VendorStore.bytes(db)
	local total = 0
	if type(db) ~= 'table' or type(db.byNpc) ~= 'table' then
		return total
	end
	for _, vendor in pairs(db.byNpc) do
		total = total + VendorStore.vendorBytes(vendor)
	end
	return total
end

--- How many vendors and item records the store holds and what they cost, for status lines.
--- @param db any
--- @return table { vendors, items, bytes }
function VendorStore.summary(db)
	local summary = { vendors = 0, items = 0, bytes = VendorStore.bytes(db) }
	if type(db) ~= 'table' or type(db.byNpc) ~= 'table' then
		return summary
	end
	for _, vendor in pairs(db.byNpc) do
		if isUsableVendor(vendor) then
			summary.vendors = summary.vendors + 1
			for _ in vendor.items:gmatch('[^;]+') do
				summary.items = summary.items + 1
			end
		end
	end
	return summary
end

-- Helpers ---------------------------------------------------------------------------------

function isOpened(db)
	return type(db) == 'table' and db.schema == VendorStore.SCHEMA and type(db.byNpc) == 'table'
end

function isUsableVendor(vendor)
	return type(vendor) == 'table' and isFinitePositive(vendor.seenAt) and type(vendor.items) == 'string'
end

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function isWholePositive(value)
	return isWhole(value) and value > 0
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

-- A name or zone fit to save: a non-empty string, cut to a sane length.
function cleanText(text)
	if type(text) ~= 'string' or text == '' then
		return nil
	end
	return text:sub(1, VendorStore.MAX_TEXT_LENGTH)
end

function recordFromSlot(slot, now, reaction)
	if type(slot) ~= 'table' or not isWholePositive(slot.itemId) or not isWhole(slot.price) then
		return nil
	end
	if slot.price > ns.PriceData.MAX_COPPER then
		return nil
	end
	-- A missing or broken stack reads as 1; a stack past the cap is a broken read.
	if isWholePositive(slot.stack) and not isStack(slot.stack) then
		return nil
	end
	local available = slot.available
	if not isWhole(available) then
		available = VendorStore.UNLIMITED
	end
	local costs = {}
	for _, cost in ipairs(type(slot.costs) == 'table' and slot.costs or {}) do
		if type(cost) == 'table' and isWholePositive(cost.count) then
			costs[#costs + 1] = {
				kind = cost.kind == 'item' and 'item' or 'currency',
				id = isWholePositive(cost.id) and cost.id or 0,
				count = cost.count,
			}
		end
	end
	-- A slot flagged with an extended cost the client did not detail still costs more than copper.
	if #costs == 0 and slot.hasExtendedCost == true then
		costs[1] = { kind = 'currency', id = 0, count = 1 }
	end
	-- Price 0 with no other cost is a slot the client has not filled yet, not a free item; it
	-- must never overwrite a price kept from an earlier read.
	if slot.price == 0 and #costs == 0 then
		return nil
	end
	return {
		itemId = slot.itemId,
		price = slot.price,
		stack = isWholePositive(slot.stack) and slot.stack or 1,
		available = available,
		seenAt = now,
		reaction = reaction,
		costs = costs,
	}
end

function packRecord(record)
	local base = ''
	if record.basePrice then
		base = string.format(',%.0f,%.0f,%.0f', record.basePrice, record.baseStack, record.baseSeenAt)
	end
	-- %.0f, not %d: WoW's %d may go through a 32-bit long on Windows (see ScanStore.packItem).
	return string.format(
		'%.0f,%.0f,%.0f,%s,%.0f,%s,%s,%s%s',
		record.itemId,
		record.price,
		record.stack,
		record.available == VendorStore.UNLIMITED and '-1' or string.format('%.0f', record.available),
		record.seenAt,
		record.goneAt and string.format('%.0f', record.goneAt) or '',
		record.reaction and string.format('%.0f', record.reaction) or '',
		packCosts(record.costs),
		base
	)
end

function parseRecord(text)
	-- The eight fields of the latest read, then a base tail that only the base depends on.
	local idText, priceText, stackText, availableText, seenText, goneText, reactionText, costsText, baseTail =
		text:match('^(%d+),(%d+),(%d+),(%-?%d+),(%d+),(%d*),(%d*),([%dcix+]*)(.*)$')
	-- Anything after the costs that is not a comma-led tail is a broken costs field.
	if baseTail and baseTail ~= '' and baseTail:sub(1, 1) ~= ',' then
		return nil
	end
	local itemId, price, stack = tonumber(idText), tonumber(priceText), tonumber(stackText)
	local available, seenAt = tonumber(availableText), tonumber(seenText)
	local isValid = isWholePositive(itemId)
		and isWhole(price)
		and price <= ns.PriceData.MAX_COPPER
		and isStack(stack)
		and (available == VendorStore.UNLIMITED or isWhole(available))
		and isWholePositive(seenAt)
	if not isValid then
		return nil
	end
	local costs = parseCosts(costsText)
	if not costs then
		return nil
	end
	local goneAt = goneText ~= '' and tonumber(goneText) or nil
	local reaction = reactionText ~= '' and tonumber(reactionText) or nil
	local record = {
		itemId = itemId,
		price = price,
		stack = stack,
		available = available,
		seenAt = seenAt,
		goneAt = isWholePositive(goneAt) and goneAt or nil,
		reaction = isWholePositive(reaction) and reaction <= 8 and reaction or nil,
		costs = costs,
	}
	-- A broken or stale base tail drops only the base price, never the read.
	local basePrice, baseStack, baseSeenAt = parseBase(baseTail)
	if basePrice and isFreshBase(record, basePrice, baseStack, baseSeenAt) then
		record.basePrice, record.baseStack, record.baseSeenAt = basePrice, baseStack, baseSeenAt
	end
	return record
end

-- '' or ',basePrice,baseStack,baseSeenAt'; anything else is no base.
function parseBase(tail)
	local priceText, stackText, seenText = tail:match('^,(%d+),(%d+),(%d+)$')
	local price, stack, seenAt = tonumber(priceText), tonumber(stackText), tonumber(seenText)
	if isWholePositive(price) and price <= ns.PriceData.MAX_COPPER and isStack(stack) and isWholePositive(seenAt) then
		return price, stack, seenAt
	end
	return nil
end

function packCosts(costs)
	local parts = {}
	for _, cost in ipairs(costs or {}) do
		parts[#parts + 1] = string.format('%s%.0fx%.0f', cost.kind == 'item' and 'i' or 'c', cost.id or 0, cost.count)
	end
	return table.concat(parts, '+')
end

function parseCosts(text)
	local costs = {}
	if text == '' then
		return costs
	end
	for part in (text .. '+'):gmatch('([^+]*)%+') do
		local kind, idText, countText = part:match('^([ci])(%d+)x(%d+)$')
		local count = tonumber(countText)
		if not kind or not isWholePositive(count) then
			return nil
		end
		costs[#costs + 1] = { kind = kind == 'i' and 'item' or 'currency', id = tonumber(idText), count = count }
	end
	return costs
end

-- Parsed records by item id and how many did not parse.
function parseItems(packed)
	local items, skipped = {}, 0
	if type(packed) ~= 'string' then
		return items, skipped
	end
	for text in packed:gmatch('[^;]+') do
		local record = parseRecord(text)
		if record and not items[record.itemId] then
			items[record.itemId] = record
		else
			skipped = skipped + 1
		end
	end
	return items, skipped
end

function packItems(records)
	local parts = {}
	for _, record in ipairs(records) do
		parts[#parts + 1] = packRecord(record)
	end
	return table.concat(parts, ';')
end

-- The records to keep, sorted by item id: listed ones first, then the most recently gone.
function trimItems(items)
	local records = {}
	for _, record in pairs(items) do
		records[#records + 1] = record
	end
	table.sort(records, function(a, b)
		local goneA, goneB = a.goneAt or math.huge, b.goneAt or math.huge
		if goneA ~= goneB then
			return goneA > goneB
		end
		return a.itemId < b.itemId
	end)
	for position = #records, VendorStore.MAX_ITEMS_PER_VENDOR + 1, -1 do
		records[position] = nil
	end
	table.sort(records, function(a, b)
		return a.itemId < b.itemId
	end)
	return records
end

function offerOf(npcId, vendor, record)
	local hasExtendedCost = #record.costs > 0
	local isLatestBase = isBaseReaction(record.reaction)
	local hasKeptBase = not isLatestBase
		and record.basePrice ~= nil
		and isFreshBase(record, record.basePrice, record.baseStack, record.baseSeenAt)
	local price = hasKeptBase and record.basePrice or record.price
	local stack = hasKeptBase and record.baseStack or record.stack
	return {
		npcId = npcId,
		name = vendor.name,
		zone = vendor.zone,
		mapId = vendor.mapId,
		faction = vendor.faction,
		itemId = record.itemId,
		price = price,
		stack = stack,
		unitPrice = price / stack,
		available = record.available,
		isLimited = record.available ~= VendorStore.UNLIMITED,
		seenAt = record.seenAt,
		priceSeenAt = hasKeptBase and record.baseSeenAt or record.seenAt,
		goneAt = record.goneAt,
		reaction = record.reaction,
		hasExtendedCost = hasExtendedCost,
		costs = record.costs,
		isBasePrice = isLatestBase or hasKeptBase,
		priceFromBase = hasKeptBase,
		latestPrice = record.price,
		latestStack = record.stack,
	}
end

function buildIndex(db)
	local byItem = {}
	for npcId, vendor in pairs(db.byNpc) do
		if isWholePositive(npcId) and isUsableVendor(vendor) then
			for itemId, record in pairs(parseItems(vendor.items)) do
				local offers = byItem[itemId] or {}
				offers[#offers + 1] = offerOf(npcId, vendor, record)
				byItem[itemId] = offers
			end
		end
	end
	for _, offers in pairs(byItem) do
		table.sort(offers, function(a, b)
			if a.unitPrice ~= b.unitPrice then
				return a.unitPrice < b.unitPrice
			end
			if a.isLimited ~= b.isLimited then
				return not a.isLimited
			end
			return a.npcId < b.npcId
		end)
	end
	return { revision = revisions[db] or 0, byItem = byItem }
end

function bump(db)
	revisions[db] = (revisions[db] or 0) + 1
end

function isBaseReaction(reaction)
	return reaction ~= nil and reaction <= VendorStore.BASE_PRICE_MAX_REACTION
end

-- A discounted or unknown-standing read keeps the base price an earlier read left, unless it
-- is stale (isFreshBase); a base read needs none beside its own price.
function keepBasePrice(record, previous)
	if isBaseReaction(record.reaction) or not previous then
		return
	end
	local price, stack, seenAt
	if isBaseReaction(previous.reaction) and #previous.costs == 0 and previous.price > 0 then
		price, stack, seenAt = previous.price, previous.stack, previous.seenAt
	elseif previous.basePrice then
		price, stack, seenAt = previous.basePrice, previous.baseStack, previous.baseSeenAt
	end
	if price and isFreshBase(record, price, stack, seenAt) then
		record.basePrice, record.baseStack, record.baseSeenAt = price, stack, seenAt
	end
end

-- Whether a base price may stand beside the latest read: read no later than it, at most
-- BASE_MAX_AGE_SECONDS before it, the latest read in copper only and asking no more per unit
-- (a discount never raises a price, so a dearer read means the base price went up).
function isFreshBase(record, basePrice, baseStack, baseSeenAt)
	return #record.costs == 0
		and baseSeenAt <= record.seenAt
		and record.seenAt - baseSeenAt <= VendorStore.BASE_MAX_AGE_SECONDS
		and record.price / record.stack <= basePrice / baseStack
end

function isStack(value)
	return isWholePositive(value) and value <= VendorStore.MAX_STACK
end

function exportRecord(record)
	local costs = {}
	for position, cost in ipairs(record.costs) do
		costs[position] = { kind = cost.kind, id = cost.id, count = cost.count }
	end
	return {
		itemId = record.itemId,
		price = record.price,
		stack = record.stack,
		available = record.available,
		seenAt = record.seenAt,
		goneAt = record.goneAt,
		reaction = record.reaction,
		costs = costs,
		basePrice = record.basePrice,
		baseStack = record.baseStack,
		baseSeenAt = record.baseSeenAt,
	}
end

-- Usable vendors' ids, the one seen longest ago first.
function sortedNpcIds(byNpc)
	local ids = {}
	for npcId, vendor in pairs(byNpc) do
		if isWholePositive(npcId) and isUsableVendor(vendor) then
			ids[#ids + 1] = npcId
		end
	end
	table.sort(ids, function(a, b)
		if byNpc[a].seenAt ~= byNpc[b].seenAt then
			return byNpc[a].seenAt < byNpc[b].seenAt
		end
		return a < b
	end)
	return ids
end

return VendorStore
