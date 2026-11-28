--[[
	ScanArchive: the history of Haggler's own scans, kept for a future Haggler price network.
	ScanStore keeps only each market's latest scan; this keeps a compact record of every saved
	one, so price history survives the next scan and the 30-day stale-market drop.

	Only Haggler's own observations go in: scans whose source is 'own' (Haggler asked) or
	'passive' (another add-on asked; Haggler read the listing itself), built from the packed
	listing strings ScanStore saved. Nothing read from a price source (AHledger) ever enters:
	AHledger's terms forbid presenting its data as one's own scan or reselling it. An entry of
	any other source, or a table item (not a packed listing), is refused.

	Saved in its own SavedVariables, HagglerArchiveDB (account-wide), not in HagglerDB: the
	archive grows to tens of MB, and apart it never rides through Store's migrations or the
	stale-market drop, a broken archive file cannot cost the settings or the ledger, and it can
	be deleted on its own.

	  HagglerArchiveDB = { schema = 1, markets = { [marketKey] = { Entry... } } }
	  Entry            = { at, source = 'own'|'passive', listings, count, skipped, items = PackedItems }
	  PackedItems      = 'Record;Record;...'   in no set order, each item id once
	  Record           = 'itemId,min,units,d10,d25,d50,d75'

	marketKey is Store's (forever/<ruleset>/<faction>/<region>); entries are oldest first. at is
	unix seconds the listing arrived; listings counts the rows read, count the items kept and
	skipped the items whose saved string was broken. min is the cheapest unit price, units every
	unit listed (copper, whole numbers). d10..d75 are the unit-weighted price quantiles at 10, 25,
	50 and 75 % of units, each written as its step from the one before (d10 from min), so a flat
	market costs one digit a field. A quantile whose unit lies past the levels ScanStore kept (an
	item with more than MAX_LEVELS prices) is unknown, written empty, and every one after it too.

	Why quantiles rather than the cheapest N levels: a record stays seven numbers however deep
	the listing. Measured on a 30k-item scan of 226k listings (ScanStore's copy 2.2 MB), an entry
	is 0.78 MB, 27 bytes an item; the cheapest 10 levels came to 1.40 MB. Weighting by units
	means one undercut stack moves min but not q10; and min, q10, q25 and the median are what
	market-value methods take (the cheap end, without outliers), while q75 shows the spread. Exact depth stays with ScanStore's latest scan.

	A record that does not parse strictly (whole numbers without leading zeros, item id from 1 to
	MAX_ITEM_ID, units from 1 to MAX_UNITS, min and every quantile from 1 to MAX_COPPER, no known
	step after an unknown one) reads as nothing and counts in the read's
	skipped; a broken entry reads as none; never an error.

	Retention (prune, after each save): an entry dated more than FUTURE_TOLERANCE_SECONDS after
	now (a clock that ran ahead) is dropped. Within recentDays the fullest scan of each six-hour
	slot is kept, older ones the fullest scan of each day (ties go to the later scan), then the
	oldest entries go first until the archive fits maxBytes. Each market's newest entry at or
	before now (the newest of all when none is) always stays, and the size cap never takes it.
	It takes part in its bucket's contest like any other scan; when it does not win, it is kept
	as an extra entry beside the winner. Once a later scan arrives, its bucket keeps only its
	fullest scan. A now that is not a finite positive number changes nothing. Days and slots are UTC, as Sales counts days. At the default 32 MB one
	market holds the 12 slot scans of the last 3 days (about 9.4 MB) and about 29 days before
	that, daily.

	  ScanArchive.open(db)                          -> db | nil, 'newer schema' | 'not a table'
	  ScanArchive.newEntryBuilder(snapshot)         -> builder | nil, reason; :Step, :Result
	  ScanArchive.record(db, marketKey, entry)      -> saved, reason
	  ScanArchive.prune(db, now, { recentDays?, maxBytes? }) -> entries dropped
	  ScanArchive.export(db, marketKey, fromAt?, toAt?)      -> { schema, market, records, skipped }
	  ScanArchive.bytes(db), ScanArchive.entryBytes(entry), ScanArchive.summary(db)

	export is the entry point a network would call: pure, records oldest scan first, nothing
	leaves the machine.
]]
local _, ns = ...

local ScanArchive = {}
ns.ScanArchive = ScanArchive

ScanArchive.SCHEMA = 1
ScanArchive.SOURCES = { own = true, passive = true }
-- Percent of units; whole numbers, so a rank is exact (0.1 * 30 is not 3 in floating point).
ScanArchive.QUANTILE_PERCENTS = { 10, 25, 50, 75 }
ScanArchive.QUANTILE_FIELDS = { 'q10', 'q25', 'q50', 'q75' }
ScanArchive.SLOT_SECONDS = 6 * 3600
ScanArchive.DEFAULT_RECENT_DAYS = 3
ScanArchive.DEFAULT_MAX_MB = 32
ScanArchive.BYTES_PER_MB = 1024 * 1024
-- What an entry's other fields and its SavedVariables lines cost beside the packed items.
ScanArchive.ENTRY_OVERHEAD_BYTES = 128
-- An entry dated further ahead than this is a clock that ran ahead, not a scan.
ScanArchive.FUTURE_TOLERANCE_SECONDS = 86400
-- No item id comes near this; a bigger one is a broken record.
ScanArchive.MAX_ITEM_ID = 10000000
-- ScanStore.MAX_STACK units in each of 100,000 listings of one item.
ScanArchive.MAX_UNITS = 1000000000

local DAY_SECONDS = 86400

-- Helpers live at the bottom of the file; declared here so they stay local.
local isFinitePositive, isPositiveInteger, isUsableEntry, recordFromItem, packRecord, parseRecord
local downsample, newestOf, bucketOf, isBetterEntry, enforceBudget, isOpened, wholeNumber, usableEntriesByTime

local BuilderMethods = {}
BuilderMethods.__index = BuilderMethods

--- Opens the archive's saved table: fills the layout, refuses a newer schema untouched.
--- @param db table HagglerArchiveDB
--- @return table|nil db
--- @return string|nil reason 'newer schema' | 'not a table' (saved data; never an error)
function ScanArchive.open(db)
	if type(db) ~= 'table' then
		return nil, 'not a table'
	end
	local schema = tonumber(db.schema)
	if schema and schema > ScanArchive.SCHEMA then
		return nil, 'newer schema'
	end
	db.schema = ScanArchive.SCHEMA
	if type(db.markets) ~= 'table' then
		db.markets = {}
	end
	return db
end

--- A builder that turns a saved snapshot into an archive entry, a few items at a time.
--- @param snapshot table a ScanStore snapshot (packed items)
--- @return table|nil builder with :Step(shouldContinue) -> isDone and :Result()
--- @return string|nil reason 'not an own scan' | 'not a packed scan'
function ScanArchive.newEntryBuilder(snapshot)
	if type(snapshot) ~= 'table' or not ScanArchive.SOURCES[snapshot.source] then
		return nil, 'not an own scan'
	end
	if snapshot.isPacked ~= true or type(snapshot.items) ~= 'table' or not isFinitePositive(snapshot.at) then
		return nil, 'not a packed scan'
	end
	return setmetatable({
		at = snapshot.at,
		source = snapshot.source,
		listings = isPositiveInteger(snapshot.count) and snapshot.count or 0,
		items = snapshot.items,
		lastItemId = nil,
		isDone = false,
		parts = {},
		skipped = 0,
	}, BuilderMethods)
end

--- Packs items while shouldContinue allows. The snapshot must not change until it is done.
--- @param shouldContinue function|nil called before each item; false stops this slice
--- @return boolean isDone
function BuilderMethods:Step(shouldContinue)
	while not self.isDone do
		if shouldContinue and not shouldContinue() then
			return false
		end
		local itemId, saved = next(self.items, self.lastItemId)
		if itemId == nil then
			self.isDone = true
		else
			self.lastItemId = itemId
			-- Only a packed listing string is an observation; a table item could be anything.
			local record = type(saved) == 'string'
				and isPositiveInteger(itemId)
				and recordFromItem(ns.ScanStore.unpackItem(saved))
			if record then
				self.parts[#self.parts + 1] = packRecord(itemId, record)
			else
				self.skipped = self.skipped + 1
			end
		end
	end
	return true
end

--- The finished entry; call after Step returned true.
--- @return table|nil Entry; nil when no item could be archived
function BuilderMethods:Result()
	if not self.isDone then
		error('ScanArchive builder: Step has not finished', 2)
	end
	if #self.parts == 0 then
		return nil
	end
	return {
		at = self.at,
		source = self.source,
		listings = self.listings,
		count = #self.parts,
		skipped = self.skipped,
		items = table.concat(self.parts, ';'),
	}
end

--- Adds an entry to a market's history, in time order.
--- @param db table an opened archive (ScanArchive.open)
--- @param marketKey string Store's market key
--- @param entry table Entry from a builder
--- @return boolean saved
--- @return string|nil reason 'not an own scan' | 'empty' | 'already archived'
function ScanArchive.record(db, marketKey, entry)
	if not isOpened(db) then
		error('ScanArchive.record: open the archive first', 2)
	end
	if not ns.Store.isMarketKey(marketKey) then
		error(string.format('ScanArchive.record: bad market key %q', tostring(marketKey)), 2)
	end
	if type(entry) ~= 'table' then
		error('ScanArchive.record: entry must be a table', 2)
	end
	if not ScanArchive.SOURCES[entry.source] then
		return false, 'not an own scan'
	end
	if not isUsableEntry(entry) or entry.items == '' or not isPositiveInteger(entry.count) then
		return false, 'empty'
	end
	local entries = db.markets[marketKey]
	if type(entries) ~= 'table' then
		entries = {}
		db.markets[marketKey] = entries
	end
	local position = #entries + 1
	for index, saved in ipairs(entries) do
		if type(saved) == 'table' and saved.at == entry.at and saved.source == entry.source then
			return false, 'already archived'
		end
		if type(saved) == 'table' and isFinitePositive(saved.at) and saved.at > entry.at and position > index then
			position = index
		end
	end
	table.insert(entries, position, entry)
	return true
end

--- Applies the retention: downsamples each market and fits the archive into maxBytes. Drops
--- broken entries and markets.
--- @param db table an opened archive (changed in place)
--- @param now any unix seconds; anything but a finite positive number changes nothing
--- @param options table|nil { recentDays?, maxBytes? }
--- @return number entries dropped
function ScanArchive.prune(db, now, options)
	if not isOpened(db) then
		error('ScanArchive.prune: open the archive first', 2)
	end
	-- A broken clock must never wipe the history.
	if not isFinitePositive(now) then
		return 0
	end
	options = options or {}
	local recentDays = isFinitePositive(options.recentDays) and options.recentDays or ScanArchive.DEFAULT_RECENT_DAYS
	local maxBytes = isFinitePositive(options.maxBytes) and options.maxBytes
		or ScanArchive.DEFAULT_MAX_MB * ScanArchive.BYTES_PER_MB
	local dropped, newestByMarket = 0, {}
	for marketKey, entries in pairs(db.markets) do
		local kept, droppedHere, newest = downsample(entries, now, now - recentDays * DAY_SECONDS)
		db.markets[marketKey] = #kept > 0 and kept or nil
		newestByMarket[marketKey] = newest
		dropped = dropped + droppedHere
	end
	return dropped + enforceBudget(db.markets, maxBytes, newestByMarket)
end

--- Every record of a market between two times, one table per item per scan, oldest scan
--- first. Pure: the archive is not changed. Broken entries and records are left out.
--- @param db any an archive
--- @param marketKey string
--- @param fromAt number|nil unix seconds, inclusive; nil for the start
--- @param toAt number|nil unix seconds, inclusive; nil for now
--- @return table { schema, market, skipped, records = { { at, market, source, itemId, min,
---   units, q10?, q25?, q50?, q75? }... } }
function ScanArchive.export(db, marketKey, fromAt, toAt)
	local export = { schema = ScanArchive.SCHEMA, market = marketKey, records = {}, skipped = 0 }
	local entries = type(db) == 'table' and type(db.markets) == 'table' and db.markets[marketKey] or nil
	if type(entries) ~= 'table' then
		return export
	end
	for _, entry in ipairs(usableEntriesByTime(entries)) do
		local isInRange = (type(fromAt) ~= 'number' or entry.at >= fromAt)
			and (type(toAt) ~= 'number' or entry.at <= toAt)
		if isInRange then
			for text in entry.items:gmatch('[^;]+') do
				local record = parseRecord(text)
				if record then
					record.at, record.market, record.source = entry.at, marketKey, entry.source
					export.records[#export.records + 1] = record
				else
					export.skipped = export.skipped + 1
				end
			end
		end
	end
	return export
end

--- What one entry costs in the saved file, roughly.
--- @param entry any
--- @return number bytes, 0 for a broken entry
function ScanArchive.entryBytes(entry)
	if not isUsableEntry(entry) then
		return 0
	end
	return #entry.items + ScanArchive.ENTRY_OVERHEAD_BYTES
end

--- What the whole archive costs in the saved file, roughly.
--- @param db any
--- @return number bytes
function ScanArchive.bytes(db)
	local total = 0
	if type(db) ~= 'table' or type(db.markets) ~= 'table' then
		return total
	end
	for _, entries in pairs(db.markets) do
		if type(entries) == 'table' then
			for _, entry in ipairs(entries) do
				total = total + ScanArchive.entryBytes(entry)
			end
		end
	end
	return total
end

--- How many scans the archive holds and what they cost, for status lines.
--- @param db any
--- @return table { scans, markets, bytes }
function ScanArchive.summary(db)
	local summary = { scans = 0, markets = 0, bytes = ScanArchive.bytes(db) }
	if type(db) ~= 'table' or type(db.markets) ~= 'table' then
		return summary
	end
	for _, entries in pairs(db.markets) do
		if type(entries) == 'table' then
			summary.markets = summary.markets + 1
			for _, entry in ipairs(entries) do
				summary.scans = summary.scans + (isUsableEntry(entry) and 1 or 0)
			end
		end
	end
	return summary
end

-- Helpers ---------------------------------------------------------------------------------

function isOpened(db)
	return type(db) == 'table' and db.schema == ScanArchive.SCHEMA and type(db.markets) == 'table'
end

function isUsableEntry(entry)
	return type(entry) == 'table'
		and isFinitePositive(entry.at)
		and ScanArchive.SOURCES[entry.source] == true
		and type(entry.items) == 'string'
end

-- min, units and the quantiles of a ScanStore item, or nil when it has no usable levels.
function recordFromItem(item)
	if type(item) ~= 'table' or item.isMalformed or type(item.levels) ~= 'table' or not item.levels[1] then
		return nil
	end
	local units = item.units
	local record = { min = item.levels[1].price, units = units }
	local levelIndex, unitsSoFar = 1, item.levels[1].qty
	for index, percent in ipairs(ScanArchive.QUANTILE_PERCENTS) do
		local rank = math.max(1, math.ceil(units * percent / 100))
		while unitsSoFar < rank and item.levels[levelIndex + 1] do
			levelIndex = levelIndex + 1
			unitsSoFar = unitsSoFar + item.levels[levelIndex].qty
		end
		if unitsSoFar < rank then
			break
		end
		record[ScanArchive.QUANTILE_FIELDS[index]] = item.levels[levelIndex].price
	end
	return record
end

function packRecord(itemId, record)
	-- %.0f, not %d: WoW's %d may go through a 32-bit long on Windows (see ScanStore.packItem).
	local fields = { string.format('%.0f,%.0f,%.0f', itemId, record.min, record.units) }
	local previous = record.min
	for _, field in ipairs(ScanArchive.QUANTILE_FIELDS) do
		local price = record[field]
		fields[#fields + 1] = price and string.format('%.0f', price - previous) or ''
		previous = price or previous
	end
	return table.concat(fields, ',')
end

function parseRecord(text)
	local idText, minText, unitsText, d10, d25, d50, d75 = text:match('^(%d+),(%d+),(%d+),(%d*),(%d*),(%d*),(%d*)$')
	local itemId, min, units = wholeNumber(idText), wholeNumber(minText), wholeNumber(unitsText)
	local isHeaderValid = isPositiveInteger(itemId)
		and itemId <= ScanArchive.MAX_ITEM_ID
		and isPositiveInteger(min)
		and min <= ns.PriceData.MAX_COPPER
		and isPositiveInteger(units)
		and units <= ScanArchive.MAX_UNITS
	if not isHeaderValid then
		return nil
	end
	local record = { itemId = itemId, min = min, units = units }
	local previous, isUnknown = min, false
	for index, stepText in ipairs({ d10, d25, d50, d75 }) do
		if stepText == '' then
			isUnknown = true
		elseif isUnknown then
			return nil
		else
			local step = wholeNumber(stepText)
			if not step then
				return nil
			end
			previous = previous + step
			if previous > ns.PriceData.MAX_COPPER then
				return nil
			end
			record[ScanArchive.QUANTILE_FIELDS[index]] = previous
		end
	end
	return record
end

-- The entries worth keeping, oldest first, how many went, and the protected newest entry.
-- Each bucket keeps its fullest scan; the newest is added beside it only when it did not win.
function downsample(entries, now, recentFrom)
	if type(entries) ~= 'table' then
		return {}, 0, nil
	end
	local latestAllowed = now + ScanArchive.FUTURE_TOLERANCE_SECONDS
	local newest = newestOf(entries, now) or newestOf(entries, latestAllowed)
	local bestByBucket, total = {}, 0
	for _, entry in ipairs(entries) do
		total = total + 1
		if isUsableEntry(entry) and entry.at <= latestAllowed then
			local bucket = bucketOf(entry.at, recentFrom)
			if isBetterEntry(entry, bestByBucket[bucket]) then
				bestByBucket[bucket] = entry
			end
		end
	end
	local kept, isNewestKept = {}, false
	for _, entry in pairs(bestByBucket) do
		kept[#kept + 1] = entry
		isNewestKept = isNewestKept or entry == newest
	end
	if newest and not isNewestKept then
		kept[#kept + 1] = newest
	end
	table.sort(kept, function(a, b)
		return a.at < b.at
	end)
	return kept, total - #kept, newest
end

-- The newest usable entry dated at or before latestAllowed, or nil.
function newestOf(entries, latestAllowed)
	local newest
	for _, entry in ipairs(entries) do
		local isCandidate = isUsableEntry(entry) and entry.at <= latestAllowed
		if isCandidate and (newest == nil or entry.at >= newest.at) then
			newest = entry
		end
	end
	return newest
end

-- A market's usable entries sorted by time (saved data may be out of order); a new list.
function usableEntriesByTime(entries)
	local usable = {}
	for _, entry in ipairs(entries) do
		if isUsableEntry(entry) then
			usable[#usable + 1] = entry
		end
	end
	table.sort(usable, function(a, b)
		return a.at < b.at
	end)
	return usable
end

-- A whole number written without leading zeros ('0' itself is fine), else nil.
function wholeNumber(text)
	if type(text) ~= 'string' or not text:find('^%d+$') or (#text > 1 and text:sub(1, 1) == '0') then
		return nil
	end
	return tonumber(text)
end

function bucketOf(at, recentFrom)
	if at >= recentFrom then
		return 'slot ' .. math.floor(at / ScanArchive.SLOT_SECONDS)
	end
	return 'day ' .. math.floor(at / DAY_SECONDS)
end

function isBetterEntry(entry, best)
	if not best then
		return true
	end
	local count, bestCount = tonumber(entry.count) or 0, tonumber(best.count) or 0
	if count ~= bestCount then
		return count > bestCount
	end
	return entry.at > best.at
end

-- Drops the oldest entries, never a market's protected newest, until the archive fits;
-- returns how many.
function enforceBudget(markets, maxBytes, newestByMarket)
	local total = 0
	for _, entries in pairs(markets) do
		for _, entry in ipairs(entries) do
			total = total + ScanArchive.entryBytes(entry)
		end
	end
	local dropped = 0
	while total > maxBytes do
		local oldestEntries, oldestIndex
		for marketKey, entries in pairs(markets) do
			-- Entries are oldest first, so the oldest one that may go is the first or second.
			local index = entries[1] == newestByMarket[marketKey] and 2 or 1
			local entry = entries[index]
			if entry and (oldestEntries == nil or entry.at < oldestEntries[oldestIndex].at) then
				oldestEntries, oldestIndex = entries, index
			end
		end
		if not oldestEntries then
			break
		end
		total = total - ScanArchive.entryBytes(table.remove(oldestEntries, oldestIndex))
		dropped = dropped + 1
	end
	return dropped
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

function isPositiveInteger(value)
	return isFinitePositive(value) and value % 1 == 0
end

return ScanArchive
