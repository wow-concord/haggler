--[[
	Badges: what a bag button shows about its item, and the overlay that shows it. Bag hosts
	(Host/BagHosts/) find the buttons; this file decides and paints.

	  Badges.decide(value, options, item?) -> Decision     pure; value is an ItemValue or nil
	      options = { showValue, decisionBadge, typeBadge }
	      item    = { isBound?, isQuest?, isJunk? }
	      Decision = { badges = { { slot, kind, icon, color }... }, advice?, valueText?,
	                   isLowConfidence }
	  Badges.decisionLabel(kind, icons) -> string|nil   the badge glyph and its word, for a tooltip
	  Badges.valueLabel(decision, icons) -> string|nil   the value text, marked when low
	  Badges.shortMoney(copper) -> '12g' | '3s' | '45c'
	  Badges.iconSize(theme) / Badges.outlineWidth(theme) -> whole pixels from the tokens, at least 1
	  Badges.footprint(theme) -> the glyph and its outline on both sides
	  Badges.outlineOffsets(width) -> { { dx, dy }... } the outline copies
	  Badges.newPainter({ icons, theme }) -> painter
	      painter:Paint(button, decision)   creates the overlay on first use, then reuses it
	      painter:Clear(button)
	      painter:NewBadgeFrame(frame)      a frame of its own that shows one badge (Baganator)
	      painter:PaintBadgeFrame(frame, badge|nil)

	Two slots, one badge each:
	  decision  top left    what to do with the item (Advice.forItem): post (gavel), sell (store),
	                        wait (hourglass) or undecided (the low-confidence triangle, caution)
	  type      top right   quest (flag) or junk (recycle: a grey the vendor pays for); nothing
	                        for any other item. Quest wins over junk.
	Bound and quest items get no decision: they cannot go to the AH. Junk that should be sold
	shows only the junk badge, which already says so. A shown value carries the low marker inside
	its own text too, so no setting or hidden widget can show a guessed value bare.

	Both slots sit on the top edge, clear of the stack count (bottom right) and the value text
	(bottom left). Each glyph (size.icon.badge, 12) sits over sixteen copies of itself in the
	outline colour, the DS glyph outline (border.glyphOutline, 2): the 8 side and diagonal offsets
	at 1 and again at 2. It is solid, a dark edge that keeps the glyph readable on any item icon,
	with a footprint of 16. The copies at 2 alone would leave a pixel of the item art showing
	between a thin stroke and its outline; the ring at 1 fills it. While the client shows its junk coin or upgrade arrow on a button
	(both top left), the decision badge stays off it; the tooltip's Decision line still names it.
	A badge is retextured only when its icon or colour changes.

	Taint: overlay textures and font strings are created on the host's button (allowed in and out
	of combat, never protected) and kept in a weak table keyed by the button. Nothing is written
	onto the button table itself, so Blizzard's code never reads an add-on value.
]]
local _, ns = ...

local Badges = {}
ns.Badges = Badges

Badges.DECISIONS = {
	post = { icon = 'gavel', color = 'color.state.success', label = 'Post' },
	sell = { icon = 'store', color = 'color.state.info', label = 'Sell' },
	wait = { icon = 'hourglass', color = 'color.text.secondary', label = 'Wait' },
	undecided = { icon = ns.IconSet.LOW_CONFIDENCE, color = ns.IconSet.LOW_CONFIDENCE_COLOR, label = 'Undecided' },
}
Badges.TYPES = {
	quest = { icon = 'flag', color = 'color.text.accent', label = 'Quest' },
	junk = { icon = 'recycle', color = 'color.text.muted', label = 'Junk' },
}
-- The glyph size (12) and the outline width (2), read from the theme in whole pixels.
Badges.ICON_SIZE_TOKEN = 'size.icon.badge'
Badges.OUTLINE_WIDTH_TOKEN = 'border.glyphOutline'
-- The DS glyph outline: one copy at each of these, at every whole step from 1 to the width.
Badges.OUTLINE_DIRECTIONS = {
	{ -1, 0 },
	{ 1, 0 },
	{ 0, -1 },
	{ 0, 1 },
	{ -1, -1 },
	{ -1, 1 },
	{ 1, -1 },
	{ 1, 1 },
}
-- Off the 8px grid by design: the item icon art fills the 37px button nearly to its edge, so a
-- grid step (8) would sink the badge well into the art. 2 is border.glyphOutline: the outline
-- runs to the button's edge and no further.
Badges.INSET = 2
Badges.SLOTS = {
	decision = { point = 'TOPLEFT', x = Badges.INSET, y = -Badges.INSET },
	type = { point = 'TOPRIGHT', x = -Badges.INSET, y = -Badges.INSET },
}
Badges.SLOT_ORDER = { 'decision', 'type' }
Badges.OUTLINE_COLOR = 'color.text.shadow'
-- The client's own top-left marks on a Blizzard-style item button; the decision badge yields to them.
Badges.CLIENT_TOP_LEFT_MARKS = { 'JunkIcon', 'UpgradeIcon' }
-- Above the client's own junk coin (OVERLAY 5) and quest border (OVERLAY 2).
Badges.OUTLINE_SUBLEVEL = 6
Badges.GLYPH_SUBLEVEL = 7
-- An |T height of 0 follows the font height of the line.
Badges.TOOLTIP_ICON_SIZE = 0
Badges.VALUE_FONT = 'NumberFontNormalSmall'
Badges.VALUE_ICON_SIZE = 10
--- The marker when the icon atlas has no triangle-alert.
Badges.LOW_TEXT_MARKER = '!'
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

-- Helpers live at the bottom of the file; declared here so they stay local.
local decisionBadge, typeBadge, newBadge, newOverlay, newGroup, paintGroup, hideGroup, isClientMarkingTopLeft
local wholePixels

local PainterMethods = {}
PainterMethods.__index = PainterMethods

--- What a button shows for an item.
--- @param value table|nil ItemValue; nil for an empty slot or an item not loaded yet
--- @param options table { showValue, decisionBadge, typeBadge }
--- @param item table|nil { isBound?, isQuest?, isJunk? }
--- @return table Decision
function Badges.decide(value, options, item)
	if type(options) ~= 'table' then
		error('Badges.decide: needs options', 2)
	end
	item = type(item) == 'table' and item or {}
	local decision = { badges = {}, isLowConfidence = false }
	if type(value) == 'table' then
		decision.isLowConfidence = type(value.confidence) == 'table' and value.confidence.level == 'low'
		decision.advice = ns.Advice.forItem(value, item)
		if options.showValue and type(value.copper) == 'number' and value.copper > 0 then
			decision.valueText = Badges.shortMoney(value.copper)
		end
	end
	local typeKind = options.typeBadge and typeBadge(item) or nil
	local adviceKind = decision.advice and decision.advice.decision
	local isSaidByType = typeKind == 'junk' and adviceKind == 'sell'
	if options.decisionBadge and adviceKind and not isSaidByType then
		decision.badges[#decision.badges + 1] = decisionBadge(adviceKind)
	end
	if typeKind then
		decision.badges[#decision.badges + 1] = newBadge('type', typeKind, Badges.TYPES[typeKind])
	end
	return decision
end

--- The decision's badge glyph at the line height, then its word, for a tooltip line.
--- @param kind string 'post'|'sell'|'wait'|'undecided'
--- @param icons table IconSet
--- @return string|nil nil for an unknown kind; the word alone when the atlas lacks the icon
function Badges.decisionLabel(kind, icons)
	local style = Badges.DECISIONS[kind]
	if not style then
		return nil
	end
	local glyph = icons:Inline(style.icon, Badges.TOOLTIP_ICON_SIZE, style.color)
	return glyph ~= '' and (glyph .. ' ' .. style.label) or style.label
end

--- The value text a button shows, with the low-confidence marker in front when the value is a
--- guess (an inline icon, or LOW_TEXT_MARKER when the atlas lacks it).
--- @param decision table Decision
--- @param icons table IconSet
--- @return string|nil nil when the decision has no value text
function Badges.valueLabel(decision, icons)
	local text = decision.valueText
	if not text or not decision.isLowConfidence then
		return text
	end
	local marker = icons:Inline(ns.IconSet.LOW_CONFIDENCE, Badges.VALUE_ICON_SIZE, ns.IconSet.LOW_CONFIDENCE_COLOR)
	return (marker ~= '' and marker or Badges.LOW_TEXT_MARKER) .. ' ' .. text
end

--- Copper in the largest whole coin, for a small button label.
function Badges.shortMoney(copper)
	copper = math.floor(tonumber(copper) or 0)
	if copper >= COPPER_PER_GOLD then
		return math.floor(copper / COPPER_PER_GOLD) .. 'g'
	end
	if copper >= COPPER_PER_SILVER then
		return math.floor(copper / COPPER_PER_SILVER) .. 's'
	end
	return copper .. 'c'
end

--- The glyph size from size.icon.badge, in whole pixels; never under one.
--- @param theme table|nil Theme
--- @return number
function Badges.iconSize(theme)
	return wholePixels(theme, Badges.ICON_SIZE_TOKEN)
end

--- The outline width from border.glyphOutline, in whole pixels; never under one.
--- @param theme table|nil Theme
--- @return number
function Badges.outlineWidth(theme)
	return wholePixels(theme, Badges.OUTLINE_WIDTH_TOKEN)
end

--- The glyph and its outline on both sides, in pixels.
--- @param theme table|nil Theme
--- @return number
function Badges.footprint(theme)
	return Badges.iconSize(theme) + 2 * Badges.outlineWidth(theme)
end

--- The outline copies for a width: every OUTLINE_DIRECTIONS step at each whole pixel from 1 to
--- the width, so no ring is left out (16 copies at 2, as the DS records it).
--- @param width number whole pixels
--- @return table { { dx, dy }... }
function Badges.outlineOffsets(width)
	local offsets = {}
	for step = 1, width do
		for _, direction in ipairs(Badges.OUTLINE_DIRECTIONS) do
			offsets[#offsets + 1] = { direction[1] * step, direction[2] * step }
		end
	end
	return offsets
end

--- @param options table { icons = IconSet, theme = Theme }; the theme defaults to the add-on's
--- @return table painter
function Badges.newPainter(options)
	if type(options) ~= 'table' or not options.icons then
		error('Badges.newPainter: needs icons', 2)
	end
	local theme = options.theme or ns.theme or ns.Theme.new(ns.Tokens)
	local width = Badges.outlineWidth(theme)
	return setmetatable({
		icons = options.icons,
		-- Read once: the textures are sized and placed when they are created.
		measures = {
			iconSize = Badges.iconSize(theme),
			footprint = Badges.footprint(theme),
			offsets = Badges.outlineOffsets(width),
		},
		overlays = setmetatable({}, { __mode = 'k' }),
		badgeFrames = setmetatable({}, { __mode = 'k' }),
	}, PainterMethods)
end

--- Shows a decision on a button. A button that never had a badge or value gets no overlay.
function PainterMethods:Paint(button, decision)
	local overlay = self.overlays[button]
	local hasContent = #decision.badges > 0 or decision.valueText ~= nil
	if not overlay then
		if not hasContent then
			return
		end
		overlay = newOverlay(button, self.measures)
		self.overlays[button] = overlay
	end
	local bySlot = {}
	for _, badge in ipairs(decision.badges) do
		bySlot[badge.slot] = badge
	end
	if isClientMarkingTopLeft(button) then
		bySlot.decision = nil
	end
	for _, slot in ipairs(Badges.SLOT_ORDER) do
		paintGroup(overlay.groups[slot], bySlot[slot], self.icons)
	end
	if decision.valueText then
		overlay.value:SetText(Badges.valueLabel(decision, self.icons))
		overlay.value:Show()
	else
		overlay.value:Hide()
	end
end

function PainterMethods:Clear(button)
	local overlay = self.overlays[button]
	if not overlay then
		return
	end
	for _, group in pairs(overlay.groups) do
		hideGroup(group)
	end
	overlay.value:Hide()
end

--- True when the button has an overlay (for tests and diagnostics).
function PainterMethods:HasOverlay(button)
	return self.overlays[button] ~= nil
end

--- Fills a frame of Haggler's own with one badge's glyph and outline, centred in it; the frame
--- is sized to hold the outline (a footprint square). For hosts that place and hide a region
--- themselves.
--- @param frame table
--- @return table frame
function PainterMethods:NewBadgeFrame(frame)
	local side = self.measures.footprint
	frame:SetSize(side, side)
	self.badgeFrames[frame] = newGroup(frame, 'CENTER', 0, 0, self.measures)
	return frame
end

--- Shows a badge in a frame from NewBadgeFrame; nil hides it.
--- @return boolean shown
function PainterMethods:PaintBadgeFrame(frame, badge)
	local group = self.badgeFrames[frame]
	if not group then
		return false
	end
	return paintGroup(group, badge, self.icons)
end

-- Helpers ---------------------------------------------------------------------------------

function decisionBadge(kind)
	return newBadge('decision', kind, Badges.DECISIONS[kind])
end

function typeBadge(item)
	if item.isQuest == true then
		return 'quest'
	end
	if item.isJunk == true then
		return 'junk'
	end
	return nil
end

function newBadge(slot, kind, style)
	return { slot = slot, kind = kind, icon = style.icon, color = style.color }
end

function newOverlay(button, measures)
	local overlay = { groups = {} }
	for name, slot in pairs(Badges.SLOTS) do
		overlay.groups[name] = newGroup(button, slot.point, slot.x, slot.y, measures)
	end
	local value = button:CreateFontString(nil, 'OVERLAY', Badges.VALUE_FONT)
	value:SetPoint('BOTTOMLEFT', button, 'BOTTOMLEFT', 2, 2)
	value:Hide()
	overlay.value = value
	return overlay
end

-- One badge: its outline copies first (drawn under, all on one sublevel: the outline colour is
-- opaque, so overlapping copies stay one even shade), then the glyph.
function newGroup(parent, point, x, y, measures)
	local size = measures.iconSize
	local function newTexture(sublevel, dx, dy)
		local texture = parent:CreateTexture(nil, 'OVERLAY', nil, sublevel)
		texture:SetSize(size, size)
		texture:SetPoint(point, parent, point, x + dx, y + dy)
		texture:Hide()
		return texture
	end
	local group = { outlines = {} }
	for _, offset in ipairs(measures.offsets) do
		group.outlines[#group.outlines + 1] = newTexture(Badges.OUTLINE_SUBLEVEL, offset[1], offset[2])
	end
	group.glyph = newTexture(Badges.GLYPH_SUBLEVEL, 0, 0)
	return group
end

-- The textures keep what they were last given, so the same icon and colour only need showing.
function paintGroup(group, badge, icons)
	if not badge then
		hideGroup(group)
		return false
	end
	local paintedKey = badge.icon .. '|' .. badge.color
	if group.paintedKey == paintedKey then
		group.glyph:Show()
		for _, outline in ipairs(group.outlines) do
			outline:Show()
		end
		return true
	end
	group.paintedKey = nil
	if not icons:Apply(group.glyph, badge.icon, badge.color) then
		hideGroup(group)
		return false
	end
	for _, outline in ipairs(group.outlines) do
		icons:Apply(outline, badge.icon, Badges.OUTLINE_COLOR)
	end
	group.paintedKey = paintedKey
	return true
end

function hideGroup(group)
	group.glyph:Hide()
	for _, outline in ipairs(group.outlines) do
		outline:Hide()
	end
end

function wholePixels(theme, token)
	local number = theme and type(theme.Number) == 'function' and tonumber(theme:Number(token)) or 0
	return math.max(1, math.floor(number + 0.5))
end

-- Reads the button's own regions only (never writes): reading a Blizzard field taints nothing.
function isClientMarkingTopLeft(button)
	for _, key in ipairs(Badges.CLIENT_TOP_LEFT_MARKS) do
		local mark = rawget(button, key)
		if type(mark) == 'table' and type(mark.IsShown) == 'function' and mark:IsShown() then
			return true
		end
	end
	return false
end

return Badges
