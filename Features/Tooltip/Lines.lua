--[[
	TooltipLines: builds Haggler's tooltip lines from a price quote (PriceService:Quote). Pure:
	no game calls, so every line is tested in luajit.

	  build(input) -> Line[]
	  input = { quote, stackCount, isDetail, options, theme, advice?, icons? }
	  advice  = Advice.forItem's BagAdvice for a bag slot
	  options = { detailTrace, detailSales, detailListings, detailVendor, detailSellTime,
	              sellTimeNote }

	The lines come in sections with a separator line ({ kind = 'separator' }, which the host
	draws as a rule) between each two. A section without rows is left out, separator and all.

	Buy: a header (the shopping cart) with the age of the data the lowest listing came from,
	then what one unit costs to buy: "Auction house (each)", the lowest listing, never a total.
	A listing from the player's own scan shows the search icon and the age of the scan that
	holds the item; one from AHledger (no scan minimum for the item) shows the plug icon and
	the age of AHledger's row. A "Vendor (each)" row is meant to go above the AH row once its
	source is settled (buySection).

	Sell: a header (the module icon) with the age of the default price's base, after its source's
	icon: the search icon for Haggler's scans, the plug icon for AHledger. When a step read
	AHledger's row (the default rule caps at the median), the plug icon and that row's own age
	follow; a vendor, craft cost or own-sales base then names itself first ("Craft cost"), with
	no age, and with no such step it shows nothing, as does no price. A scan icon never carries
	AHledger's age: an unknown scan time leaves the search icon alone. On a client without the
	icon atlas each age is named in words ("Scan 5 min AHledger 2 d"), so two ages never stand
	bare side by side. No header says "no data". For a bag slot a Signal line with the decision (Advice.forItem's) as its glyph and
	word; then the default rule's price as "Price (each)" and "Price × N" for the hovered stack,
	or one "Price" line for a single item. Details come last: a Wait says why in short label and
	value rows (small, indented, muted): how far under the usual price the lowest listing is,
	that the market holds steady, and what posting at the usual price nets over the vendor. A
	low-confidence price carries the caution triangle on its first price line; while the detail
	block is off a wrapped line closes the section with "Low confidence" and its top reason.

	Detail, a section of its own after Sell: the other shown rules (Minimum and the like) for
	the stack, how the default rule got its price, every confidence reason, sales a day,
	listings, vendor price and an estimated sell time with its note.

	A label line stays short and anything that can grow long goes on a wrapped line of its own,
	so Haggler's own lines keep the tooltip narrow (an item name or another add-on may still
	widen it). Money reads with the game's coin icons, by texture path, as GetCoinTextureString
	writes it. The price source's credit is not in the tooltip: the options panel and the
	window footer carry it.

	Sell time = (units listed at or under the price + this stack) / units sold a day. It is an
	estimate from sales per day, not in-game time, and low confidence under one sale a day.
]]
local _, ns = ...

local TooltipLines = {}
ns.TooltipLines = TooltipLines

-- The Sell header shows the module icon (the TOC's IconTexture, never a banner) in place of a
-- word, inline at height 0: the client sizes it to the line's own text height and keeps it on
-- the line as it does the decision glyph.
TooltipLines.TITLE_ICON_TEXTURE = 'Interface\\AddOns\\Haggler\\media\\icon.png'
TooltipLines.SEPARATOR = 'separator'
TooltipLines.BUY_ICON = 'shopping-cart'
-- What the Buy header says on a client without the icon atlas.
TooltipLines.BUY_FALLBACK = 'Buy'
TooltipLines.SCAN_AGE_ICON = 'search'
TooltipLines.TABLE_AGE_ICON = 'plug'
TooltipLines.AUCTION_HOUSE_LABEL = 'Auction house'
TooltipLines.PRICE_LABEL = 'Price'
TooltipLines.SIGNAL_LABEL = 'Signal'
TooltipLines.LOW_CONFIDENCE = 'Low confidence'
TooltipLines.SLOW_SELL_REASON = 'under 1 sale a day'
-- Why an item waits, one label and value row each; the Signal line already says Wait. A wait
-- only ever happens in a steady market (Advice), so Market always reads Steady.
TooltipLines.WAIT_LOWEST_LABEL = 'Lowest listing'
TooltipLines.WAIT_LOWEST_VALUE = '%d%% under usual'
TooltipLines.WAIT_MARKET_LABEL = 'Market'
TooltipLines.WAIT_MARKET_VALUE = 'Steady'
TooltipLines.WAIT_GAIN_LABEL = 'Over vendor'
-- The reason rows hang off the Sell rows by one grid step.
local REASON_INDENT_TOKEN = 'space.3'
-- A unit price says each; a stack reads ' × 12', the DS quantity format.
TooltipLines.EACH_SUFFIX = ' (each)'
TooltipLines.QUANTITY_MARK = ' × '
-- A count in its own column carries the sign too: '× 60'.
TooltipLines.COUNT_MARK = '× '
TooltipLines.SELL_TIME_NOTE = 'estimate from sales per day, not in-game time'
TooltipLines.OWN_SALES_VALUE = 'Own scans'
-- The price sources a header can name by icon, keyed by Price.source and facts.lowestListedSource.
local SOURCE_AGE_ICONS = { scan = TooltipLines.SCAN_AGE_ICON, ahledger = TooltipLines.TABLE_AGE_ICON }
-- What an age's icon says on a client without the icon atlas, as the Buy header falls back.
local SOURCE_AGE_WORDS = { scan = 'Scan', ahledger = 'AHledger' }
-- The base named before an AHledger row age, for bases with no age icon of their own.
local BASE_SOURCE_LABELS = { vendor = 'Vendor', craft = 'Craft cost', realized = 'Your sales' }
-- The detail line of a shown rule that fails validation.
TooltipLines.UNUSABLE_RULE_NAMED = "%s can't be used"
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
local appendSection, buySection, sellSection, detailSection, buyHeaderLine, sellHeaderLine, auctionHouseRow
local sellPriceRows, priceRow, ageText, traceLines, reasonLines, salesLines, listingsLines, vendorLine
local sellTimeLines, hasAnyData, defaultEntry, color, unitsAtOrUnder, formatSellTime, levelIcon, topLowReason
local lowReasonLine, capitalized, iconSetFor, signalLine, waitReasonRows, reasonRow, stackSuffix, detailRow
local sellAgesText
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
	local view = {
		stackCount = math.max(1, input.stackCount or 1),
		theme = input.theme,
		icons = input.icons or iconSetFor(input.theme),
		isDetail = input.isDetail,
	}
	local advice = type(input.advice) == 'table' and input.advice or nil
	local lines = {}
	appendSection(lines, buySection(quote, view))
	appendSection(lines, sellSection(quote, advice, view))
	if input.isDetail then
		appendSection(lines, detailSection(quote, input.options or {}, view))
	end
	return lines
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

-- Adds a section under the lines so far, a separator between; an empty section adds nothing.
function appendSection(lines, section)
	if #section == 0 then
		return
	end
	if #lines > 0 then
		lines[#lines + 1] = { kind = TooltipLines.SEPARATOR }
	end
	for _, line in ipairs(section) do
		lines[#lines + 1] = line
	end
end

-- The header and what a unit costs to buy; nothing when no row has a figure. Each row builder
-- returns a line or nil. A "Vendor (each)" row goes first once the user settles where a vendor's
-- buy price comes from. Never feed it facts.vendor or itemInfo.vendorPrice: that is what a vendor
-- pays the player (the sell price), not what buying from one costs.
function buySection(quote, view)
	local rows = {}
	for _, buildRow in ipairs({ auctionHouseRow }) do
		local row = buildRow(quote, view)
		if row then
			rows[#rows + 1] = row
		end
	end
	if #rows == 0 then
		return {}
	end
	table.insert(rows, 1, buyHeaderLine(quote.facts, view))
	return rows
end

function sellSection(quote, advice, view)
	local main = defaultEntry(quote.prices)
	local lines = { sellHeaderLine(main and main.price, view) }
	local signal = signalLine(advice and advice.decision, view)
	if signal then
		lines[#lines + 1] = signal
	end
	for _, row in ipairs(sellPriceRows(main and main.price, view)) do
		lines[#lines + 1] = row
	end
	for _, row in ipairs(advice and waitReasonRows(advice, view) or {}) do
		lines[#lines + 1] = row
	end
	if not view.isDetail and main and main.price and main.price.confidence.level == 'low' then
		lines[#lines + 1] = lowReasonLine(topLowReason(main.price.confidence.reasons), view)
	end
	return lines
end

function detailSection(quote, options, view)
	local main = defaultEntry(quote.prices)
	local detail = {}
	for _, entry in ipairs(quote.prices) do
		if entry ~= main then
			local label = entry.name .. stackSuffix(view.stackCount)
			detail[#detail + 1] = priceRow(label, entry.price, view.stackCount, true, view)
		end
	end
	if options.detailTrace ~= false and main and main.price then
		traceLines(detail, main, view)
	end
	reasonLines(detail, quote.prices, view)
	if options.detailSales ~= false then
		salesLines(detail, quote.facts, view)
	end
	if options.detailListings ~= false then
		listingsLines(detail, quote.facts, view)
	end
	if options.detailVendor ~= false and quote.facts.vendor and quote.facts.vendor > 0 then
		detail[#detail + 1] = vendorLine(quote.facts, view)
	end
	if options.detailSellTime ~= false and main and main.price then
		sellTimeLines(detail, main.price, quote.facts, view.stackCount, options.sellTimeNote ~= false, view)
	end
	return detail
end

-- The age of the data the lowest listing came from: the item's scan, or AHledger's row.
function buyHeaderLine(facts, view)
	local cart = view.icons:Inline(TooltipLines.BUY_ICON, LINE_HEIGHT_ICON, 'color.text.accent')
	local isFromScan = facts.lowestListedSource == 'scan'
	local right = isFromScan and ageText('scan', facts.scanAge, view) or ageText('ahledger', facts.rowAge, view)
	return {
		left = cart ~= '' and cart or TooltipLines.BUY_FALLBACK,
		right = right,
		color = color(view, 'color.text.accent'),
		rightColor = color(view, 'color.text.muted'),
	}
end

-- The base's icon and own age, then AHledger's row age when a step read it; no right side for
-- a source without a market age.
function sellHeaderLine(price, view)
	return {
		left = '|T' .. TooltipLines.TITLE_ICON_TEXTURE .. ':' .. LINE_HEIGHT_ICON .. '|t',
		right = price and sellAgesText(price, view) or nil,
		color = color(view, 'color.text.accent'),
		rightColor = color(view, 'color.text.muted'),
	}
end

function sellAgesText(price, view)
	local row = price.source ~= 'ahledger'
			and price.rowAgeSeconds ~= nil
			and ageText('ahledger', price.rowAgeSeconds, view)
		or nil
	local base = ageText(price.source, price.baseAgeSeconds, view) or (row and BASE_SOURCE_LABELS[price.source])
	if base and row then
		return base .. ' ' .. row
	end
	return base or row
end

-- The age after its source's icon; nil for a source no icon names. Without a known age the icon
-- stands alone. On a client without the atlas the source's word takes the icon's place.
function ageText(source, seconds, view)
	local iconName = SOURCE_AGE_ICONS[source]
	if not iconName then
		return nil
	end
	local text = type(seconds) == 'number' and TooltipLines.age(seconds) or nil
	local icon = view.icons:Inline(iconName, LINE_HEIGHT_ICON, 'color.text.muted')
	if icon == '' then
		icon = SOURCE_AGE_WORDS[source]
	end
	return text and (icon .. ' ' .. text) or icon
end

-- The lowest listing a unit, never the stack: buying is per unit.
function auctionHouseRow(quote, view)
	local lowest = type(quote.facts) == 'table' and quote.facts.lowestListed or nil
	if type(lowest) ~= 'number' then
		return nil
	end
	return {
		left = TooltipLines.AUCTION_HOUSE_LABEL .. TooltipLines.EACH_SUFFIX,
		right = TooltipLines.money(lowest),
		color = color(view, 'color.text.secondary'),
		rightColor = color(view, 'color.text.primary'),
	}
end

-- The default rule's price a unit and for the stack; one Price line for a single item or no price.
function sellPriceRows(price, view)
	local label, count = TooltipLines.PRICE_LABEL, view.stackCount
	if not price or count == 1 then
		return { priceRow(label, price, 1, true, view) }
	end
	return {
		priceRow(label .. TooltipLines.EACH_SUFFIX, price, 1, true, view),
		priceRow(label .. stackSuffix(count), price, count, false, view),
	}
end

-- A price for a quantity; isMarked puts the caution triangle on a low-confidence price.
function priceRow(label, price, quantity, isMarked, view)
	local line = { left = label, color = color(view, 'color.text.secondary') }
	if not price then
		line.right = 'no price'
		line.rightColor = color(view, 'color.text.muted')
		return line
	end
	line.right = TooltipLines.money(price.copper * quantity)
	line.rightColor = color(view, 'color.text.primary')
	if isMarked and price.confidence.level == 'low' then
		line.right = line.right .. ' ' .. levelIcon('low', view)
	end
	return line
end

-- The bag decision in the badge's own glyph and word; nil (no line) without one.
function signalLine(decision, view)
	local label = type(decision) == 'string' and view.icons and ns.Badges.decisionLabel(decision, view.icons) or nil
	if not label then
		return nil
	end
	return {
		left = TooltipLines.SIGNAL_LABEL,
		right = label,
		color = color(view, 'color.text.secondary'),
		rightColor = color(view, 'color.text.primary'),
	}
end

-- Why an item waits, as label and value rows after the prices; none for any other decision, or
-- a wait without its facts. The gain is the stack's, as the Price × N line above it.
function waitReasonRows(advice, view)
	local percent, gain = advice.underTypicalPercent, advice.gainOverVendor
	if advice.decision ~= 'wait' or type(percent) ~= 'number' or type(gain) ~= 'number' then
		return {}
	end
	return {
		reasonRow(TooltipLines.WAIT_LOWEST_LABEL, string.format(TooltipLines.WAIT_LOWEST_VALUE, percent), view),
		reasonRow(TooltipLines.WAIT_MARKET_LABEL, TooltipLines.WAIT_MARKET_VALUE, view),
		reasonRow(TooltipLines.WAIT_GAIN_LABEL .. stackSuffix(view.stackCount), '+' .. TooltipLines.money(gain), view),
	}
end

-- A supporting row: small text, indented a grid step, label and value both muted, so it reads
-- as detail of the Signal and the prices and not as another row.
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

-- A stack's label mark: ' × 20', nothing for a single item.
function stackSuffix(stackCount)
	return stackCount > 1 and (TooltipLines.QUANTITY_MARK .. stackCount) or ''
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
	detail[#detail + 1] = { left = entry.name .. TooltipLines.EACH_SUFFIX, color = color(view, 'color.text.muted') }
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
		local prefix = entry.isDefault and '' or (entry.name .. ', ')
		if not entry.price and entry.reason == ns.Rules.UNUSABLE_RULE then
			detail[#detail + 1] = {
				left = entry.isDefault and entry.reason or string.format(TooltipLines.UNUSABLE_RULE_NAMED, entry.name),
				color = color(view, 'color.text.muted'),
				wrap = true,
			}
		elseif not entry.price then
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

-- Sales a day, and a row of its own when the count is the player's own.
function salesLines(detail, facts, view)
	local right = 'unknown'
	if facts.salesPerDay then
		right = (string.format('%.1f', facts.salesPerDay):gsub('%.0$', ''))
	end
	detail[#detail + 1] = detailRow('Sold a day', right, view)
	if facts.salesPerDay and facts.salesSource == 'own' then
		detail[#detail + 1] = detailRow('Sales from', TooltipLines.OWN_SALES_VALUE, view)
	end
end

-- Units listed in the DS quantity format, and how many price levels they sit at.
function listingsLines(detail, facts, view)
	if not facts.listedUnits then
		detail[#detail + 1] = detailRow('Listed', 'no scan', view)
		return
	end
	detail[#detail + 1] = detailRow('Listed', TooltipLines.COUNT_MARK .. facts.listedUnits, view)
	detail[#detail + 1] = detailRow('Price levels', tostring(facts.levelCount or 0), view)
end

function detailRow(label, value, view)
	return {
		left = label,
		right = value,
		color = color(view, 'color.text.muted'),
		rightColor = color(view, 'color.text.secondary'),
	}
end

-- What a vendor pays for the stack, labelled with the count as the other stack rows are.
function vendorLine(facts, view)
	return {
		left = 'Vendor' .. stackSuffix(view.stackCount),
		right = TooltipLines.money(facts.vendor * view.stackCount),
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
