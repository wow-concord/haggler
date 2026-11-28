--[[
	WindowModel: the Haggler frame's logic that needs no frames, so tests can drive it.

	  WindowModel.newTabs() -> tabs   the tab registry later steps add to:
	      tabs:Add{ key, label, order, build(container, ctx), refresh?(container, ctx),
	                events? = { event... }, onEvent?(container, ctx, event, ...) }
	      tabs:List() -> tabs by order then key · tabs:Get(key) -> tab|nil
	  WindowModel.placement(ahMode, otherAddon) -> 'takeover'|'dock'|'manual'
	      how the frame shows when the auction house opens: it takes over Blizzard's window,
	      docks beside it (always when TradeSkillMaster or Auctionator runs the auction house),
	      or waits for /hag
  WindowModel.opensAtAuctionHouse(placement, ahView) -> boolean
      whether Haggler's frame opens by itself when the auction house opens: the placement
      lets it (not manual) and the view the player last switched to is Haggler's
	  WindowModel.page(list, pageIndex, pageSize) -> { items, page, pageCount, first }
	  WindowModel.itemIdFromText(text, deps) -> itemId | nil, reason
	  WindowModel.lookupLines(quote) -> { { text, level? }... }
	  WindowModel.historyLines(scanDays, itemId, now, days) -> { { day, sold, troll }... }
	  WindowModel.sellLines(row, verdict) -> { { text, level? }... }   with the confidence
	  WindowModel.buyLines(row) -> { { text, level? }... }               rule price and confidence
	  WindowModel.farAboveRule(unitPrice, rulePrice) -> ratio | nil
	  WindowModel.postQuantity(row, sellable) -> units for one post
	  WindowModel.durationIndex(hoursText) -> 1|2|3

	A bad tab definition is a programmer error and throws.
]]
local _, ns = ...

local WindowModel = {}
ns.WindowModel = WindowModel

WindowModel.AH_MODES = {
	{ value = 'takeover', label = "Replace Blizzard's auction house window" },
	{ value = 'dock', label = "Open beside Blizzard's window" },
	{ value = 'manual', label = 'Only when opened with /hag' },
}
-- The window the player last switched to at the auction house; Haggler's is today's default.
WindowModel.AH_VIEWS = {
	{ value = 'haggler', label = "Haggler's window" },
	{ value = 'blizzard', label = "Blizzard's window" },
}
WindowModel.DEFAULT_AH_VIEW = 'haggler'
-- Add-ons that take over the auction house themselves; Haggler docks instead of fighting them.
WindowModel.OTHER_AH_ADDONS = { 'TradeSkillMaster', 'Auctionator' }
WindowModel.DURATIONS = {
	{ value = '12', label = '12 hours' },
	{ value = '24', label = '24 hours' },
	{ value = '48', label = '48 hours' },
}
WindowModel.HISTORY_DAYS = 7
-- A buy at this many times the rule price or more is called out before it is confirmed.
WindowModel.FAR_ABOVE_RULE = 1.5

local SECONDS_PER_DAY = 86400
local DURATION_INDEX = { ['12'] = 1, ['24'] = 2, ['48'] = 3 }
local KEY_PATTERN = '^%a[%w_]*$'

-- Helpers live at the bottom of the file; declared here so they stay local.
local validateTab, money, percentText, confidenceText

local TabsMethods = {}
TabsMethods.__index = TabsMethods

--- An empty tab registry.
function WindowModel.newTabs()
	return setmetatable({ byKey = {}, list = {} }, TabsMethods)
end

--- Adds a tab; a key used twice or a bad definition throws.
--- @param tab table see the file header
function TabsMethods:Add(tab)
	validateTab(tab)
	if self.byKey[tab.key] then
		error(string.format('WindowModel tabs: %q is added twice', tab.key), 2)
	end
	self.byKey[tab.key] = tab
	self.list[#self.list + 1] = tab
	table.sort(self.list, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.key < b.key
	end)
end

function TabsMethods:List()
	return self.list
end

function TabsMethods:Get(key)
	return self.byKey[key]
end

--- How the frame shows when the auction house opens.
--- @param ahMode string 'takeover'|'dock'|'manual'
--- @param otherAddon string|nil the add-on that runs the auction house, when one does
--- @return string 'takeover'|'dock'|'manual'
function WindowModel.placement(ahMode, otherAddon)
	if ahMode == 'manual' then
		return 'manual'
	end
	if ahMode == 'dock' or otherAddon ~= nil then
		return 'dock'
	end
	return 'takeover'
end

--- Whether Haggler's frame opens by itself at the auction house.
--- @param placement string WindowModel.placement's answer
--- @param ahView string|nil the remembered view, 'haggler' or 'blizzard'; nil is the default
function WindowModel.opensAtAuctionHouse(placement, ahView)
	return placement ~= 'manual' and (ahView or WindowModel.DEFAULT_AH_VIEW) == 'haggler'
end

--- One page of a list.
--- @param list table
--- @param pageIndex number 1-based; clamped to the pages there are
--- @param pageSize number
--- @return table { items, page, pageCount, first } first is the list index of items[1]
function WindowModel.page(list, pageIndex, pageSize)
	if type(list) ~= 'table' or type(pageSize) ~= 'number' or pageSize < 1 then
		error('WindowModel.page: needs a list and a page size', 2)
	end
	local pageCount = math.max(1, math.ceil(#list / pageSize))
	local page = math.max(1, math.min(pageCount, math.floor(tonumber(pageIndex) or 1)))
	local first = (page - 1) * pageSize + 1
	local items = {}
	for index = first, math.min(#list, first + pageSize - 1) do
		items[#items + 1] = list[index]
	end
	return { items = items, page = page, pageCount = pageCount, first = first }
end

--- The item a Lookup search means: an item id, an item link, or (part of) a name of an item
--- Haggler has seen this session.
--- @param text string|nil
--- @param deps table { itemIdFromLink(text) -> id|nil, itemIdsByName(lowerText) -> id[] }
--- @return number|nil itemId
--- @return string|nil reason
function WindowModel.itemIdFromText(text, deps)
	local trimmed = type(text) == 'string' and text:match('^%s*(.-)%s*$') or ''
	if trimmed == '' then
		return nil, 'type an item name, paste an item link or shift-click an item'
	end
	local asNumber = tonumber(trimmed)
	if asNumber and asNumber >= 1 and asNumber % 1 == 0 then
		return asNumber
	end
	local fromLink = deps.itemIdFromLink and deps.itemIdFromLink(trimmed)
	if fromLink then
		return fromLink
	end
	local matches = deps.itemIdsByName and deps.itemIdsByName(trimmed:lower()) or {}
	if #matches == 0 then
		return nil, 'no item by that name among the items seen this session; try its link or id'
	end
	return matches[1]
end

--- What Lookup shows for one item: every rule's price, confidence and reasons, then the facts.
--- @param quote table PriceService:Quote
--- @return table { { text, level? }... }
function WindowModel.lookupLines(quote)
	local lines = {}
	for _, entry in ipairs(quote.prices) do
		local label = entry.name .. (entry.isDefault and ' (default)' or '')
		if entry.price then
			local confidence = entry.price.confidence or {}
			lines[#lines + 1] = {
				text = string.format(
					'%s: %s · %s',
					label,
					money(entry.price.copper),
					confidenceText(confidence.level)
				),
				level = confidence.level,
			}
			for _, reason in ipairs(confidence.reasons or {}) do
				lines[#lines + 1] = { text = '    ' .. tostring(reason.text), level = reason.level }
			end
		else
			lines[#lines + 1] =
				{ text = label .. ': no price (' .. tostring(entry.reason or 'unknown') .. ')', level = 'low' }
		end
	end
	local facts = quote.facts or {}
	lines[#lines + 1] = {
		text = 'Sold a day: '
			.. (facts.salesPerDay and string.format('%.1f', facts.salesPerDay) or 'unknown')
			.. (facts.salesSource == 'own' and ' (your scans)' or ''),
	}
	if facts.listedUnits then
		lines[#lines + 1] = {
			text = string.format('Listed: %d units from %s', facts.listedUnits, money(facts.lowestListed or 0)),
		}
	end
	if facts.vendor then
		lines[#lines + 1] = { text = 'Vendor: ' .. money(facts.vendor) }
	end
	return lines
end

--- The item's own sales count per day, newest first, from the market's daily summaries.
--- @param scanDays table|nil market.scanDays
--- @param itemId number
--- @param now number unix seconds
--- @param days number|nil how many days back (default HISTORY_DAYS)
--- @return table { { day, daysAgo, sold, troll }... } only days with a summary
function WindowModel.historyLines(scanDays, itemId, now, days)
	local history = {}
	if type(scanDays) ~= 'table' then
		return history
	end
	local today = math.floor(now / SECONDS_PER_DAY)
	for daysAgo = 0, (days or WindowModel.HISTORY_DAYS) - 1 do
		local summary = scanDays[today - daysAgo]
		if type(summary) == 'table' then
			local item = type(summary.items) == 'table' and summary.items[itemId] or nil
			history[#history + 1] = {
				day = today - daysAgo,
				daysAgo = daysAgo,
				sold = type(item) == 'table' and tonumber(item.sold) or 0,
				troll = type(item) == 'table' and tonumber(item.troll) or 0,
			}
		end
	end
	return history
end

--- What the Sell tab says about posting a row at a verdict's price.
--- @param row table SellRow
--- @param verdict table Verdict
--- @return table { { text, level? }... }
function WindowModel.sellLines(row, verdict)
	local lines = {}
	local listingText = row.listings > 1 and string.format('%d listings of %d', row.listings, row.units)
		or string.format('%d units', row.units)
	lines[#lines + 1] = { text = listingText .. ' at ' .. money(verdict.price or 0) .. ' each' }
	if verdict.net then
		lines[#lines + 1] = { text = 'Expected net a listing: ' .. money(math.max(0, verdict.net)) }
	end
	lines[#lines + 1] = {
		text = 'Sell chance: '
			.. (verdict.sellChance and percentText(verdict.sellChance) or 'unknown')
			.. ' · deposit '
			.. money(verdict.deposit or 0),
	}
	if verdict.breakEven then
		lines[#lines + 1] = { text = 'Break-even: ' .. money(verdict.breakEven) }
	end
	if verdict.vendorNet then
		lines[#lines + 1] = { text = 'Vendor pays: ' .. money(verdict.vendorNet) }
	end
	if verdict.isLoss then
		lines[#lines + 1] = { text = 'Expected to lose money at this price', level = 'low' }
	elseif verdict.isBelowVendor then
		lines[#lines + 1] = { text = 'Nets less than the vendor pays', level = 'medium' }
	end
	if verdict.action == 'vendor' then
		lines[#lines + 1] = { text = 'Suggested: sell to the vendor', level = 'medium' }
	elseif verdict.action == 'hold' then
		lines[#lines + 1] = { text = 'Suggested: keep it for now', level = 'medium' }
	end
	if not row.price and row.reason then
		lines[#lines + 1] = { text = 'No price: ' .. tostring(row.reason), level = 'low' }
	end
	-- The verdict's confidence merges the price's own reasons with the guardrail's.
	local confidence = verdict.confidence or { reasons = verdict.reasons }
	lines[#lines + 1] = { text = confidenceText(confidence.level), level = confidence.level or 'low' }
	for _, reason in ipairs(confidence.reasons or {}) do
		if reason.level ~= 'high' then
			lines[#lines + 1] = { text = '    ' .. tostring(reason.text), level = reason.level }
		end
	end
	return lines
end

--- What the Buy tab says about a scan row's rule price: the price, its confidence and every
--- reason that is not high.
--- @param row table BuyRow
--- @return table { { text, level? }... }
function WindowModel.buyLines(row)
	local lines = {}
	lines[#lines + 1] = {
		text = string.format('Last scan: %d from %s', row.units or 0, money(row.unitPrice or 0)),
	}
	if not row.rulePrice then
		lines[#lines + 1] = {
			text = 'Rule price: unknown' .. (row.ruleReason and (' (' .. tostring(row.ruleReason) .. ')') or ''),
			level = 'low',
		}
		return lines
	end
	local discountText = row.discountPercent and string.format(' · %d%% under', row.discountPercent) or ''
	lines[#lines + 1] = { text = 'Rule price: ' .. money(row.rulePrice) .. discountText }
	local confidence = row.confidence or {}
	lines[#lines + 1] = { text = confidenceText(confidence.level), level = confidence.level or 'low' }
	for _, reason in ipairs(confidence.reasons or {}) do
		if reason.level ~= 'high' then
			lines[#lines + 1] = { text = '    ' .. tostring(reason.text), level = reason.level }
		end
	end
	return lines
end

--- How far a buy price is over the rule price, when it is far over (FAR_ABOVE_RULE times or
--- more): the ratio, else nil.
--- @param unitPrice number
--- @param rulePrice number|nil
--- @return number|nil
function WindowModel.farAboveRule(unitPrice, rulePrice)
	if type(unitPrice) ~= 'number' or type(rulePrice) ~= 'number' or rulePrice <= 0 then
		return nil
	end
	local ratio = unitPrice / rulePrice
	return ratio >= WindowModel.FAR_ABOVE_RULE and ratio or nil
end

--- Units one post takes: a commodity lists every unit carried at once; any other item lists
--- what its first slot holds (one, for an unstackable item).
--- @param row table SellRow
--- @param sellable table Wow:SellableItem
--- @return number
function WindowModel.postQuantity(row, sellable)
	if sellable.isCommodity then
		return row.units
	end
	local first = row.slots[1]
	return math.max(1, math.min(row.units, first and first.count or 1))
end

--- The client's duration index for a duration setting.
--- @param hoursText string '12'|'24'|'48'
--- @return number 1|2|3
function WindowModel.durationIndex(hoursText)
	return DURATION_INDEX[hoursText] or 2
end

-- Helpers ---------------------------------------------------------------------------------

function validateTab(tab)
	if type(tab) ~= 'table' or type(tab.key) ~= 'string' or not tab.key:find(KEY_PATTERN) then
		error('WindowModel tabs: a tab needs a key of letters and digits', 3)
	end
	if type(tab.label) ~= 'string' or tab.label == '' then
		error(string.format('WindowModel tabs: %q needs a label', tab.key), 3)
	end
	if type(tab.order) ~= 'number' then
		error(string.format('WindowModel tabs: %q needs an order number', tab.key), 3)
	end
	if type(tab.build) ~= 'function' then
		error(string.format('WindowModel tabs: %q needs a build function', tab.key), 3)
	end
	if tab.events ~= nil and type(tab.events) ~= 'table' then
		error(string.format('WindowModel tabs: %q events must be a list', tab.key), 3)
	end
end

function money(copper)
	return ns.TooltipLines.money(copper)
end

function percentText(fraction)
	return string.format('%d%%', math.floor(fraction * 100 + 0.5))
end

function confidenceText(level)
	return (level or 'unknown') .. ' confidence'
end

return WindowModel
