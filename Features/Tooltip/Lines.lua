--[[
	TooltipLines: builds Haggler's tooltip lines from a price quote (PriceService:Quote). Pure:
	no game calls, so every line is tested in luajit.

	  build(input) -> Line[]
	  input = { quote, stackCount, isUnitView, isDetail, options, theme, advice?, icons? }
	  advice  = Advice.forItem's BagAdvice for a bag slot
	  options = { detailTrace, detailSales, detailListings, detailVendor, detailSellTime,
	              sellTimeNote }

	Compact view: a header (the module icon) with the data age, then one line per shown rule (default first) with
	the stack price, or the unit price in the unit view; then, for a bag slot, a Decision line
	with the decision (Advice.forItem's) as its glyph and word. A Wait says why in short label and
	value rows right below it, as supporting detail (small, indented, muted), in the compact and the detail view
	alike: how far under the usual price the lowest listing is, that the market holds steady, and
	what posting at the usual price nets over the vendor. A low-confidence price carries the
	caution triangle on its line; while the detail block is off a wrapped line below it says
	"Low confidence" with its top reason. This cannot be switched off. A label line stays short
	and anything that can grow long goes on a wrapped line of its own, so Haggler's own lines
	keep the tooltip narrow (an item name or another add-on may still widen it). Money reads with the game's coin icons, by texture path, as GetCoinTextureString
	writes it. The detail block adds how the default rule got its price, every
	confidence reason, sales a day, listings, vendor price and an estimated sell time with its
	note. The last line is the price source's credit (quote.credit, "Prices from AHledger"),
	whenever the source has prices: AHledger's terms ask for it where its prices appear.

	Sell time = (units listed at or under the price + this stack) / units sold a day. It is an
	estimate from sales per day, not in-game time, and low confidence under one sale a day.
]]
local _, ns = ...

local TooltipLines = {}
ns.TooltipLines = TooltipLines

-- The header shows the module icon (the TOC's IconTexture, never a banner) in place of the word,
-- inline at height 0: the client sizes it to the line's own text height and keeps it on the
-- line as it does the decision glyph.
TooltipLines.TITLE_ICON_TEXTURE = 'Interface\\AddOns\\Haggler\\media\\icon.png'
TooltipLines.LOW_CONFIDENCE = 'Low confidence'
TooltipLines.SLOW_SELL_REASON = 'under 1 sale a day'
TooltipLines.DECISION_LABEL = 'Decision'
-- Why an item waits, one label and value row each; the Decision line already says Wait. A wait
-- only ever happens in a steady market (Advice), so Market always reads Steady.
TooltipLines.WAIT_LOWEST_LABEL = 'Lowest listing'
TooltipLines.WAIT_LOWEST_VALUE = '%d%% under usual'
TooltipLines.WAIT_MARKET_LABEL = 'Market'
TooltipLines.WAIT_MARKET_VALUE = 'Steady'
TooltipLines.WAIT_GAIN_LABEL = 'Over vendor'
-- The reason rows hang off the Decision line by one grid step.
local REASON_INDENT_TOKEN = 'space.3'
-- Marks a unit price or gain in the unit view.
TooltipLines.EACH_SUFFIX = ' (each)'
TooltipLines.SELL_TIME_NOTE = 'estimate from sales per day, not in-game time'
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY = 86400
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000
-- The client's own coin textures, referenced by path as GetCoinTextureString does: no art ships.
local COIN_ICONS = {
	gold = '|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t',
	silver = '|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t',
	copper = '|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t',
}
-- Low confidence is a caution (triangle-alert); circle-alert is for danger only. A high-level
-- reason informs and does not lower confidence (e.g. where sales a day comes from).
local LEVEL_COLORS =
	{ low = ns.IconSet.LOW_CONFIDENCE_COLOR, medium = 'color.state.warning', high = 'color.text.muted' }
local LEVEL_ICONS = { low = ns.IconSet.LOW_CONFIDENCE, medium = ns.IconSet.LOW_CONFIDENCE, high = 'info' }
local LEVEL_WORDS = { low = 'low confidence', medium = 'medium confidence' }
-- Text marks for a client or build without the icon atlas.
local LEVEL_MARKERS = { low = '(!)', medium = '(?)', high = '(i)' }
-- An inline icon of height 0 takes the line's own text height.
local LINE_HEIGHT_ICON = 0

-- Helpers live at the bottom of the file; declared here so they stay local.
local headerLine, priceLine, traceLines, reasonLines, salesLine, listingsLine, vendorLine
local sellTimeLines, hasAnyData, defaultEntry, color, unitsAtOrUnder, formatSellTime, levelIcon, topLowReason
local withCredit, lowReasonLine, capitalized, iconSetFor, decisionLine, waitReasonRows, reasonRow, stackSuffix
-- One icon set per theme, built on first use instead of on every hover.
local iconSetsByTheme = setmetatable({}, { __mode = 'k' })

--- Builds the lines for one item; an item Haggler knows nothing about gets none.
--- @param input table see the file header
--- @return table Line[]
function TooltipLines.build(input)
	local quote = input.quote
	if not hasAnyData(quote) then
		return {}
	end
	local stack = math.max(1, input.stackCount or 1)
	local view = {
		stack = input.isUnitView and 1 or stack,
		stackCount = stack,
		theme = input.theme,
		icons = input.icons or iconSetFor(input.theme),
		isUnitView = input.isUnitView,
		isDetail = input.isDetail,
	}
	local lines = { headerLine(quote.ages, view) }
	for _, entry in ipairs(quote.prices) do
		lines[#lines + 1] = priceLine(entry, view)
		if not input.isDetail and entry.price and entry.price.confidence.level == 'low' then
			lines[#lines + 1] = lowReasonLine(topLowReason(entry.price.confidence.reasons), view)
		end
	end
	local advice = type(input.advice) == 'table' and input.advice or nil
	local decision = decisionLine(advice and advice.decision, view)
	if decision then
		lines[#lines + 1] = decision
		for _, row in ipairs(waitReasonRows(advice, view)) do
			lines[#lines + 1] = row
		end
	end
	if not input.isDetail then
		return withCredit(lines, quote.credit, view)
	end
	local options = input.options or {}
	local main = defaultEntry(quote.prices)
	local detail = {}
	if options.detailTrace ~= false and main and main.price then
		traceLines(detail, main, view)
	end
	reasonLines(detail, quote.prices, view)
	if options.detailSales ~= false then
		detail[#detail + 1] = salesLine(quote.facts, view)
	end
	if options.detailListings ~= false then
		detail[#detail + 1] = listingsLine(quote.facts, view)
	end
	if options.detailVendor ~= false and quote.facts.vendor and quote.facts.vendor > 0 then
		detail[#detail + 1] = vendorLine(quote.facts, view)
	end
	if options.detailSellTime ~= false and main and main.price then
		sellTimeLines(detail, main.price, quote.facts, stack, options.sellTimeNote ~= false, view)
	end
	for _, line in ipairs(detail) do
		lines[#lines + 1] = line
	end
	return withCredit(lines, quote.credit, view)
end

--- Copper with the game's coin icons, each amount before its coin ('1 20 5' with gold, silver
--- and copper coins); parts that are zero are left out, as the game does (0 copper for nothing).
function TooltipLines.money(copper)
	copper = math.floor(copper or 0)
	local gold = math.floor(copper / COPPER_PER_GOLD)
	local silver = math.floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
	local rest = copper % COPPER_PER_SILVER
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = gold .. COIN_ICONS.gold
	end
	if silver > 0 then
		parts[#parts + 1] = silver .. COIN_ICONS.silver
	end
	if rest > 0 or #parts == 0 then
		parts[#parts + 1] = rest .. COIN_ICONS.copper
	end
	return table.concat(parts, ' ')
end

--- An age in seconds as 'just now', '12 min', '3 h' or '4 d'.
function TooltipLines.age(seconds)
	if seconds < 60 then
		return 'just now'
	end
	if seconds < SECONDS_PER_HOUR then
		return math.floor(seconds / 60) .. ' min'
	end
	if seconds < SECONDS_PER_DAY then
		return math.floor(seconds / SECONDS_PER_HOUR) .. ' h'
	end
	return math.floor(seconds / SECONDS_PER_DAY) .. ' d'
end

--- How long ago, as 'just now', '12 min ago', '3 h ago' or '4 d ago'.
function TooltipLines.ago(seconds)
	local age = TooltipLines.age(seconds)
	return age == 'just now' and age or (age .. ' ago')
end

--- Days until a stack sells at a unit price, or nil without sales data.
--- @return number|nil days
--- @return boolean isLowConfidence
function TooltipLines.sellTimeDays(facts, unitPrice, stack)
	local salesPerDay = facts.salesPerDay
	if not salesPerDay or salesPerDay <= 0 then
		return nil, true
	end
	local days = (unitsAtOrUnder(facts.levels, unitPrice) + stack) / salesPerDay
	return days, salesPerDay < ns.Rules.CONFIDENCE.lowSalesPerDay
end

-- Helpers ---------------------------------------------------------------------------------

-- The bag decision in the badge's own glyph and word; nil (no line) without one.
function decisionLine(decision, view)
	local label = type(decision) == 'string' and view.icons and ns.Badges.decisionLabel(decision, view.icons) or nil
	if not label then
		return nil
	end
	return {
		left = TooltipLines.DECISION_LABEL,
		right = label,
		color = color(view, 'color.text.secondary'),
		rightColor = color(view, 'color.text.primary'),
	}
end

-- Why an item waits, as label and value rows under its Decision line; none for any other
-- decision, or a wait without its facts.
function waitReasonRows(advice, view)
	local percent, gain = advice.underTypicalPercent, advice.gainOverVendor
	if advice.decision ~= 'wait' or type(percent) ~= 'number' or type(gain) ~= 'number' then
		return {}
	end
	local each = advice.gainOverVendorEach
	-- The unit view shows the gain a unit, unless a unit gains under a copper: then it shows the
	-- stack's gain, and the label says so.
	local suffix = stackSuffix(view.stackCount)
	if view.isUnitView and type(each) == 'number' and each >= 1 then
		gain, suffix = each, TooltipLines.EACH_SUFFIX
	end
	return {
		reasonRow(TooltipLines.WAIT_LOWEST_LABEL, string.format(TooltipLines.WAIT_LOWEST_VALUE, percent), view),
		reasonRow(TooltipLines.WAIT_MARKET_LABEL, TooltipLines.WAIT_MARKET_VALUE, view),
		reasonRow(TooltipLines.WAIT_GAIN_LABEL .. suffix, '+' .. TooltipLines.money(gain), view),
	}
end

-- A supporting row under the Decision line: small text, indented a grid step, label and value
-- both muted, so it reads as detail of the Decision and not as another row.
function reasonRow(label, value, view)
	local muted = color(view, 'color.text.muted')
	return {
		left = label,
		right = value,
		color = muted,
		rightColor = muted,
		textSize = 'small',
		indent = view.theme:Number(REASON_INDENT_TOKEN),
	}
end

-- The stack view's label mark, as the price lines carry it: ' ×20', nothing for a single item.
function stackSuffix(stackCount)
	return stackCount > 1 and (' ×' .. stackCount) or ''
end

function withCredit(lines, credit, view)
	if type(credit) == 'string' and credit ~= '' then
		lines[#lines + 1] = { left = credit, color = color(view, 'color.text.muted') }
	end
	return lines
end

function headerLine(ages, view)
	local scanText = ages.scanAge and ('scan ' .. TooltipLines.age(ages.scanAge)) or 'no scan'
	local tableText = ages.tableAge and ('table ' .. TooltipLines.age(ages.tableAge)) or 'no table'
	return {
		left = '|T' .. TooltipLines.TITLE_ICON_TEXTURE .. ':' .. LINE_HEIGHT_ICON .. '|t',
		right = scanText .. ' · ' .. tableText,
		color = color(view, 'color.text.accent'),
		rightColor = color(view, 'color.text.muted'),
	}
end

function priceLine(entry, view)
	local label = entry.name
	if view.isUnitView then
		label = label .. TooltipLines.EACH_SUFFIX
	else
		label = label .. stackSuffix(view.stack)
	end
	local line = { left = label, color = color(view, 'color.text.secondary') }
	local price = entry.price
	if not price then
		line.right = 'no price'
		line.rightColor = color(view, 'color.text.muted')
		return line
	end
	line.right = TooltipLines.money(price.copper * view.stack)
	line.rightColor = color(view, 'color.text.primary')
	if price.confidence.level == 'low' then
		line.right = line.right .. ' ' .. levelIcon('low', view)
	end
	return line
end

-- The word for the icon and the top reason, wrapped under the price line it explains.
function lowReasonLine(reason, view)
	local text = reason and (TooltipLines.LOW_CONFIDENCE .. ', ' .. reason.text) or TooltipLines.LOW_CONFIDENCE
	return { left = text, color = color(view, LEVEL_COLORS.low), wrap = true }
end

-- The level's icon at the line's height, or its text mark when the atlas has no such icon.
function levelIcon(level, view)
	local icon = view.icons:Inline(LEVEL_ICONS[level], LINE_HEIGHT_ICON, LEVEL_COLORS[level])
	if icon == '' then
		return view.theme:Wrap(LEVEL_COLORS[level], LEVEL_MARKERS[level])
	end
	return icon
end

function topLowReason(reasons)
	for _, reason in ipairs(type(reasons) == 'table' and reasons or {}) do
		if type(reason) == 'table' and reason.level == 'low' and type(reason.text) == 'string' then
			return reason
		end
	end
	return nil
end

-- How the default rule got its price, per unit. Confidence entries are left to reasonLines.
function traceLines(detail, entry, view)
	detail[#detail + 1] = { left = entry.name .. ', each:', color = color(view, 'color.text.muted') }
	for _, step in ipairs(entry.price.trace) do
		if step.kind ~= 'confidence' then
			local line = { left = '  ' .. step.label, color = color(view, 'color.text.muted') }
			if step.copper then
				line.right = TooltipLines.money(step.copper)
				line.rightColor = color(view, 'color.text.muted')
			end
			detail[#detail + 1] = line
		end
	end
end

function reasonLines(detail, entries, view)
	for _, entry in ipairs(entries) do
		local prefix = entry.isDefault and '' or (entry.name .. ': ')
		if not entry.price then
			detail[#detail + 1] = {
				left = prefix .. 'no price, ' .. tostring(entry.reason or 'no data'),
				color = color(view, 'color.text.muted'),
				wrap = true,
			}
		else
			for _, reason in ipairs(entry.price.confidence.reasons) do
				local word = LEVEL_WORDS[reason.level]
				local text = word and (word .. ', ' .. reason.text) or reason.text
				detail[#detail + 1] = {
					left = levelIcon(reason.level, view)
						.. ' '
						.. (entry.isDefault and capitalized(text) or (prefix .. text)),
					color = color(view, LEVEL_COLORS[reason.level] or 'color.text.muted'),
					wrap = true,
				}
			end
		end
	end
end

function salesLine(facts, view)
	local right = 'unknown'
	if facts.salesPerDay then
		right = string.format('%.1f', facts.salesPerDay):gsub('%.0$', '')
		if facts.salesSource == 'own' then
			right = right .. ' · own scans'
		end
	end
	return {
		left = 'Sold a day',
		right = right,
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
end

function listingsLine(facts, view)
	local right = 'no scan'
	if facts.listedUnits then
		right = string.format('%d units · %d prices', facts.listedUnits, facts.levelCount or 0)
	end
	return {
		left = 'Listed',
		right = right,
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
end

function vendorLine(facts, view)
	return {
		left = 'Vendor',
		right = TooltipLines.money(facts.vendor * view.stack),
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
end

function sellTimeLines(detail, price, facts, stack, hasNote, view)
	local days, isLow = TooltipLines.sellTimeDays(facts, price.copper, stack)
	local right = days and formatSellTime(days) or 'unknown, no sales data'
	if days and isLow then
		right = right .. ' ' .. levelIcon('low', view)
	end
	detail[#detail + 1] = {
		left = 'Sell time',
		right = right,
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
	if days and isLow then
		detail[#detail + 1] = lowReasonLine({ text = TooltipLines.SLOW_SELL_REASON }, view)
	end
	if hasNote and days then
		detail[#detail + 1] =
			{ left = '  ' .. TooltipLines.SELL_TIME_NOTE, color = color(view, 'color.text.muted'), wrap = true }
	end
end

function formatSellTime(days)
	if days < 1 then
		return string.format('~%d h', math.max(1, math.floor(days * 24 + 0.5)))
	end
	if days < 10 then
		return string.format('~%.1f days', days)
	end
	return string.format('~%d days', math.floor(days + 0.5))
end

function unitsAtOrUnder(levels, unitPrice)
	local units = 0
	for _, level in ipairs(levels or {}) do
		if type(level) == 'table' and type(level.price) == 'number' and type(level.qty) == 'number' then
			if level.price <= unitPrice then
				units = units + level.qty
			end
		end
	end
	return units
end

function hasAnyData(quote)
	if type(quote) ~= 'table' or type(quote.prices) ~= 'table' then
		return false
	end
	for _, entry in ipairs(quote.prices) do
		if entry.price then
			return true
		end
	end
	local facts = quote.facts or {}
	return facts.salesPerDay ~= nil or facts.listedUnits ~= nil or facts.lowestListed ~= nil
end

function defaultEntry(entries)
	for _, entry in ipairs(entries) do
		if entry.isDefault then
			return entry
		end
	end
	return entries[1]
end

function color(view, name)
	return view.theme:Color(name)
end

function iconSetFor(theme)
	local icons = iconSetsByTheme[theme]
	if not icons then
		icons = ns.IconSet.new({ theme = theme })
		iconSetsByTheme[theme] = icons
	end
	return icons
end

function capitalized(text)
	return (text:gsub('^%l', string.upper))
end

return TooltipLines
