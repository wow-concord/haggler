--[[
	TopBarModel: what the top bar and its LibDataBroker feed show, as plain text, with no frames.
	TopBar.lua and Feed.lua both read it, so the bar and a broker display never disagree.

	  TopBarModel.VISIBILITY            the visibility setting's choices
	  TopBarModel.isShown(visibility, places) -> boolean
	      places = { auctionHouse, merchant, mailbox } booleans: where the player is now
	  TopBarModel.goldText(money, profit?) -> text   gold, then session profit when known
	  TopBarModel.profitText(profit) -> text         signed: +12g 30s / -4s
	  TopBarModel.scanText(status, now) -> text       short scan state for the bar
	  TopBarModel.ruleText(name) -> text
	  TopBarModel.nextRule(ids, current, direction) -> id|nil   the rule switcher's cycle
	  TopBarModel.profitTooltip(profit, mode, note) -> { line }
	  TopBarModel.SHORTCUTS             the shortcut buttons, in order: { key, label, tab? }
	                                    (the V2 Flips tab adds its own before settings)

	Money is integer copper; text uses ns.TooltipLines.money, the add-on's one money format.
]]
local _, ns = ...

local TopBarModel = {}
ns.TopBarModel = TopBarModel

TopBarModel.VISIBILITY = {
	{ value = 'always', label = 'Always' },
	{ value = 'market', label = 'Only at the auction house, a vendor or a mailbox' },
	{ value = 'hidden', label = 'Hidden (the broker feed still works)' },
}

TopBarModel.SHORTCUTS = {
	{ key = 'frame', label = 'Haggler' },
	{ key = 'queue', label = 'Sell', tab = 'sell' },
	{ key = 'settings', label = 'Settings' },
}

local SCAN_TEXT = {
	closed = 'Scan: away',
	open = 'Scan: ready',
	requested = 'Scan: asked',
	reading = 'Scan: reading',
	packing = 'Scan: packing',
	comparing = 'Scan: comparing',
}

-- Helpers live at the bottom of the file; declared here so they stay local.
local money, isFiniteNumber

--- Whether the bar shows, for a visibility setting and where the player is.
--- @param visibility string 'always'|'market'|'hidden' (anything else counts as 'always')
--- @param places table|nil { auctionHouse, merchant, mailbox }
--- @return boolean
function TopBarModel.isShown(visibility, places)
	if visibility == 'hidden' then
		return false
	end
	if visibility ~= 'market' then
		return true
	end
	places = type(places) == 'table' and places or {}
	return places.auctionHouse == true or places.merchant == true or places.mailbox == true
end

--- @param copper number|nil the character's money
--- @param profit number|nil session profit in copper
--- @return string
function TopBarModel.goldText(copper, profit)
	local text = isFiniteNumber(copper) and money(copper) or '?'
	if isFiniteNumber(profit) then
		text = text .. '  ' .. TopBarModel.profitText(profit)
	end
	return text
end

--- @param profit number copper, may be negative
--- @return string
function TopBarModel.profitText(profit)
	if not isFiniteNumber(profit) then
		return '?'
	end
	if profit < 0 then
		return '-' .. money(-profit)
	end
	return '+' .. money(profit)
end

--- @param status table|nil scanControl.Status()
--- @param now number unix seconds
--- @return string
function TopBarModel.scanText(status, now)
	if type(status) ~= 'table' then
		return 'Scan: off'
	end
	local text = SCAN_TEXT[status.state] or ('Scan: ' .. tostring(status.state))
	if isFiniteNumber(status.lastFullScanAt) and isFiniteNumber(now) then
		text = text .. ' · ' .. ns.TooltipLines.age(math.max(0, now - status.lastFullScanAt))
	end
	return text
end

function TopBarModel.ruleText(name)
	return 'Rule: ' .. (type(name) == 'string' and name ~= '' and name or '?')
end

--- The rule the switcher moves to.
--- @param ids table rule ids in display order
--- @param current string|nil the default rule id
--- @param direction number 1 (next) or -1 (previous)
--- @return string|nil id; nil with no rules
function TopBarModel.nextRule(ids, current, direction)
	if type(ids) ~= 'table' or #ids == 0 then
		return nil
	end
	local at = 0
	for index, id in ipairs(ids) do
		if id == current then
			at = index
			break
		end
	end
	if at == 0 then
		return ids[1]
	end
	local step = direction == -1 and -1 or 1
	return ids[((at - 1 + step) % #ids) + 1]
end

--- Tooltip lines for the gold widget: session profit, what the session counts from, and the
--- reason when the start is a fallback.
--- @return table { string... }
function TopBarModel.profitTooltip(profit, modeLabel, note)
	local lines = { 'Session profit: ' .. TopBarModel.profitText(profit) }
	if type(modeLabel) == 'string' then
		lines[#lines + 1] = 'Session: ' .. modeLabel
	end
	if type(note) == 'string' and note ~= '' then
		lines[#lines + 1] = 'Note: ' .. note
	end
	return lines
end

-- Helpers ---------------------------------------------------------------------------------

function money(copper)
	return ns.TooltipLines.money(copper)
end

function isFiniteNumber(value)
	return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end
