--[[
	Widgets: the few controls the Haggler frame is built from, drawn in Concord's Banneret look
	(flat surfaces, hairline borders, Banneret tokens through ns.theme). Every control is a
	button or a row of buttons, so the client's gamepad cursor can reach and press all of them;
	a slider is a stepper (− value +) and a choice a picker (‹ value ›). Text input is offered
	only beside another way to do the same thing.

	  Widgets.new(wow, theme) -> ui
	  ui:Fill(frame, token)            a texture covering the frame
	  ui:Border(frame, token, width?)  a border inside the frame, 1px unless width is given
	  ui:Text(parent, size, token, face?)  a font string in the theme's face token (default
	      font.face.body; headings pass font.face.heading or window.titleFace)
	  ui:Button(parent, label, style)  style 'primary'|'secondary'|'tab'|'ghost'
	      button:SetLabel(text) · button:SetEnabled(isEnabled) · button:OnClick(fn)
	      button:SetSelected(isSelected) (tabs: the accent underline)
	      button:SetFocused(isFocused) the focus mark: the button's outer ring, drawn outside
	          the edge over a gap band, and the chevron, whose right edge sits on the button's
	          left edge as the client's own gamepad cursor does; it overhangs, reserving no gutter
	  ui:Stepper(parent, width, onStep) a ‹ value › or − value + row; onStep(-1|1)
	      stepper:SetValue(text) · stepper:SetEnabled(isEnabled)
	  ui:Input(parent, width, onSubmit) a single-line edit box; onSubmit(text)
	  ui:Lines(parent, count, size)     count lines of text; lines:SetLines({ { text, level? }... })
	  ui:PagedLines(parent, count, size, width)  lines that page instead of cutting off: a
	      ‹ Lines 1-22 of 30 › stepper shows below them while the list does not fit;
	      paged:SetLines(list, keepsPage) keeps the page for a redraw of the same thing

	Controls never hold state of their own beyond what they show: the tab that owns them keeps
	the state and redraws.
]]
local _, ns = ...

local Widgets = {}
ns.Widgets = Widgets

Widgets.BODY_FACE = 'font.face.body'
Widgets.HEADING_FACE = 'font.face.heading'
Widgets.TITLE_FACE = 'window.titleFace'
Widgets.BUTTON_HEIGHT = 32
Widgets.STEPPER_HEIGHT = 32
Widgets.DISABLED_ALPHA = 0.6
Widgets.FOCUS_CHEVRON_ICON = 'chevron-right'
-- The chevron is drawn at 60% of its token size, rounded to 4, as the design system's CSS does.
Widgets.FOCUS_CHEVRON_SCALE = 0.6

local LEVEL_COLORS = { low = 'color.state.danger', medium = 'color.state.warning', high = 'color.text.muted' }
local BUTTON_STYLES = {
	primary = { bg = 'color.accent.base', hover = 'color.accent.hover', fg = 'color.text.onAccent' },
	secondary = { bg = 'color.surface.raised', hover = 'color.surface.overlay', fg = 'color.text.primary' },
	tab = { bg = 'color.surface.base', hover = 'color.surface.raised', fg = 'color.text.secondary', face = 'tabs.face' },
	ghost = { bg = 'color.surface.sunken', hover = 'color.surface.overlay', fg = 'color.text.secondary' },
}

-- Helpers live at the bottom of the file; declared here so they stay local.
local setColor, paintButton, paintFocusMark, makeFocusRing, makeFocusChevron, roundToFour

local WidgetsMethods = {}
WidgetsMethods.__index = WidgetsMethods

--- @param wow table Engine/Wow
--- @param theme table Host/Theme
function Widgets.new(wow, theme)
	if not wow or not theme then
		error('Widgets.new: needs wow and theme', 2)
	end
	return setmetatable({ wow = wow, theme = theme }, WidgetsMethods)
end

function WidgetsMethods:Fill(frame, token)
	local texture = frame:CreateTexture(nil, 'BACKGROUND')
	texture:SetAllPoints(frame)
	setColor(texture, self.theme:Color(token))
	return texture
end

function WidgetsMethods:Border(frame, token, width)
	local color = self.theme:Color(token)
	local thickness = width or 1
	local edges = {}
	for _, side in ipairs({ 'TOP', 'BOTTOM', 'LEFT', 'RIGHT' }) do
		local edge = frame:CreateTexture(nil, 'BORDER')
		setColor(edge, color)
		if side == 'TOP' or side == 'BOTTOM' then
			edge:SetPoint(side .. 'LEFT', frame, side .. 'LEFT')
			edge:SetPoint(side .. 'RIGHT', frame, side .. 'RIGHT')
			edge:SetHeight(thickness)
		else
			edge:SetPoint('TOP' .. side, frame, 'TOP' .. side)
			edge:SetPoint('BOTTOM' .. side, frame, 'BOTTOM' .. side)
			edge:SetWidth(thickness)
		end
		edges[#edges + 1] = edge
	end
	return edges
end

function WidgetsMethods:Text(parent, size, token, face)
	local text = parent:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight')
	if text.SetFont then
		text:SetFont(self.theme:Face(face or Widgets.BODY_FACE), size or 14, '')
	end
	if text.SetJustifyH then
		text:SetJustifyH('LEFT')
	end
	local color = self.theme:Color(token or 'color.text.primary')
	text:SetTextColor(color.r, color.g, color.b, color.a)
	return text
end

function WidgetsMethods:Button(parent, label, style)
	local palette = BUTTON_STYLES[style or 'secondary'] or error('Widgets: unknown button style ' .. tostring(style))
	local button = self.wow:CreateFrame('Button', parent)
	button:SetHeight(Widgets.BUTTON_HEIGHT)
	button.palette = palette
	button.background = self:Fill(button, palette.bg)
	button.label = self:Text(button, 14, palette.fg, palette.face)
	button.label:SetPoint('CENTER', button, 'CENTER')
	button.isEnabled = true
	-- A width the caller sets is the button's least width; a label may widen it, never shrink it
	-- under that, and a shorter label later narrows it again.
	local setFrameWidth, setFrameSize = button.SetWidth, button.SetSize
	function button.SetWidth(_, width)
		button.minWidth = width
		setFrameWidth(button, width)
	end
	function button.SetSize(_, width, height)
		button.minWidth = width
		setFrameSize(button, width, height)
	end
	local theme = self.theme
	if style == 'tab' then
		button.underline = button:CreateTexture(nil, 'ARTWORK')
		setColor(button.underline, theme:Color('color.accent.base'))
		button.underline:SetPoint('BOTTOMLEFT', button, 'BOTTOMLEFT', 8, 0)
		button.underline:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', -8, 0)
		button.underline:SetHeight(4)
		button.underline:Hide()
	elseif style == 'secondary' then
		self:Border(button, 'color.border.control')
	end
	button:SetScript('OnEnter', function()
		paintButton(button, theme, true)
	end)
	button:SetScript('OnLeave', function()
		paintButton(button, theme, false)
	end)
	function button.SetLabel(_, text)
		button.label:SetText(text)
		setFrameWidth(button, math.max(button.minWidth or 0, (button.label:GetStringWidth() or 0) + 32))
	end
	function button.SetEnabled(_, isEnabled)
		button.isEnabled = isEnabled == true
		if button.isEnabled then
			button:Enable()
		else
			button:Disable()
		end
		button:SetAlpha(button.isEnabled and 1 or Widgets.DISABLED_ALPHA)
	end
	function button.OnClick(_, handler)
		-- Called straight from the click: protected auction house calls stay on the hardware event.
		button:SetScript('OnClick', function()
			handler()
		end)
	end
	function button.SetSelected(_, isSelected)
		button.isSelected = isSelected == true
		if button.underline then
			if button.isSelected then
				button.underline:Show()
			else
				button.underline:Hide()
			end
		end
		local color = theme:Color(button.isSelected and 'color.text.primary' or palette.fg)
		button.label:SetTextColor(color.r, color.g, color.b, color.a)
	end
	local ui = self
	function button.SetFocused(_, isFocused)
		button.isFocused = isFocused == true
		paintFocusMark(ui, button)
	end
	button:SetLabel(label or '')
	return button
end

function WidgetsMethods:Stepper(parent, width, onStep, glyphs)
	local frame = self.wow:CreateFrame('Frame', parent)
	frame:SetSize(width or 200, Widgets.STEPPER_HEIGHT)
	self:Fill(frame, 'color.surface.sunken')
	self:Border(frame, 'color.border.control')
	local back = self:Button(frame, glyphs and glyphs[1] or '<', 'ghost')
	back:SetWidth(32)
	back:SetPoint('LEFT', frame, 'LEFT')
	local forward = self:Button(frame, glyphs and glyphs[2] or '>', 'ghost')
	forward:SetWidth(32)
	forward:SetPoint('RIGHT', frame, 'RIGHT')
	frame.value = self:Text(frame, 14, 'color.text.primary')
	frame.value:SetPoint('CENTER', frame, 'CENTER')
	frame.back, frame.forward = back, forward
	back:OnClick(function()
		onStep(-1)
	end)
	forward:OnClick(function()
		onStep(1)
	end)
	function frame.SetValue(_, text)
		frame.value:SetText(text)
	end
	function frame.SetEnabled(_, isEnabled)
		back:SetEnabled(isEnabled)
		forward:SetEnabled(isEnabled)
	end
	return frame
end

function WidgetsMethods:Input(parent, width, onSubmit)
	local box = self.wow:CreateFrame('EditBox', parent, 'InputBoxTemplate')
	box:SetSize(width or 200, Widgets.STEPPER_HEIGHT)
	box:SetAutoFocus(false)
	box:SetScript('OnEnterPressed', function()
		box:ClearFocus()
		onSubmit(box:GetText())
	end)
	box:SetScript('OnEscapePressed', function()
		box:ClearFocus()
	end)
	return box
end

function WidgetsMethods:Lines(parent, count, size)
	local lines = { strings = {} }
	local lineHeight = (size or 14) + 6
	for index = 1, count do
		local text = self:Text(parent, size or 14, 'color.text.primary')
		text:SetPoint('TOPLEFT', parent, 'TOPLEFT', 0, -(index - 1) * lineHeight)
		text:SetPoint('RIGHT', parent, 'RIGHT')
		lines.strings[index] = text
	end
	local theme = self.theme
	function lines.SetLines(_, list)
		for index, text in ipairs(lines.strings) do
			local line = list and list[index]
			text:SetText(line and line.text or '')
			local color = theme:Color(line and LEVEL_COLORS[line.level] or 'color.text.primary')
			text:SetTextColor(color.r, color.g, color.b, color.a)
		end
	end
	return lines
end

function WidgetsMethods:PagedLines(parent, count, size, width)
	local lineHeight = (size or 14) + 6
	local frame = self.wow:CreateFrame('Frame', parent)
	frame:SetSize(width or 400, count * lineHeight + Widgets.STEPPER_HEIGHT + 8)
	local body = self.wow:CreateFrame('Frame', frame)
	body:SetPoint('TOPLEFT', frame, 'TOPLEFT')
	body:SetSize(width or 400, count * lineHeight)
	local lines = self:Lines(body, count, size)
	local paged = { strings = lines.strings, list = {}, first = 1, count = count }
	paged.pager = self:Stepper(frame, math.min(width or 400, 260), function(delta)
		paged:Scroll(delta)
	end)
	paged.pager:SetPoint('TOPLEFT', body, 'BOTTOMLEFT', 0, -8)
	paged.pager:Hide()
	--- New lines; keepsPage keeps the page shown while the new list still reaches it (the same
	--- item redrawn), else the first page shows.
	function paged.SetLines(_, list, keepsPage)
		paged.list = list or {}
		local lastFirst = math.max(1, #paged.list - count + 1)
		paged.first = keepsPage and math.min(paged.first, lastFirst) or 1
		paged:Draw()
	end
	--- Moves one page; past either end it stops there.
	function paged.Scroll(_, delta)
		local lastFirst = math.max(1, #paged.list - count + 1)
		paged.first = math.max(1, math.min(lastFirst, paged.first + delta * count))
		paged:Draw()
	end
	function paged.Draw()
		local shown = {}
		for index = paged.first, math.min(#paged.list, paged.first + count - 1) do
			shown[#shown + 1] = paged.list[index]
		end
		lines:SetLines(shown)
		local fits = #paged.list <= count
		paged.pager:SetShown(not fits)
		if not fits then
			paged.pager:SetValue(string.format('Lines %d-%d of %d', paged.first, paged.first + #shown - 1, #paged.list))
		end
	end
	paged.frame = frame
	return paged
end

-- Helpers ---------------------------------------------------------------------------------

function setColor(texture, color)
	texture:SetColorTexture(color.r, color.g, color.b, color.a)
end

function paintButton(button, theme, isHovered)
	local token = (isHovered and button.isEnabled) and button.palette.hover or button.palette.bg
	setColor(button.background, theme:Color(token))
end

-- The focus mark: the ring outside the button, past a gap band (focus.ringOffset +
-- focus.ringGap) in color.focus.gap that keeps it at 3:1 against any fill it would touch, and
-- the one chevron icon, its right edge on the button's left edge where the client's gamepad
-- cursor sits. Both overhang: the button keeps its size and place. They live on a frame beside
-- the button, not inside it, so a disabled button's alpha does not dim them. Made on first
-- focus, then only shown and hidden.
function paintFocusMark(ui, button)
	local ring = button.focusRing
	if not ring and not button.isFocused then
		return
	end
	if not ring then
		ring = makeFocusRing(ui, button)
		button.focusRing = ring
		button.focusChevron = makeFocusChevron(ui, button, ring)
	end
	ring:SetShown(button.isFocused)
	button.focusChevron:SetShown(button.isFocused)
end

function makeFocusRing(ui, button)
	local theme = ui.theme
	local ringWidth = theme:Number('focus.ringWidth')
	local gapWidth = theme:Number('focus.ringOffset') + theme:Number('focus.ringGap')
	local reach = ringWidth + gapWidth
	local ring = ui.wow:CreateFrame('Frame', button:GetParent())
	ring:SetFrameLevel(button:GetFrameLevel() + 1)
	ring:SetPoint('TOPLEFT', button, 'TOPLEFT', -reach, reach)
	ring:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', reach, -reach)
	ring.edges = ui:Border(ring, 'color.focus.ring', ringWidth)
	if gapWidth > 0 then
		local gap = ui.wow:CreateFrame('Frame', ring)
		gap:SetPoint('TOPLEFT', ring, 'TOPLEFT', ringWidth, -ringWidth)
		gap:SetPoint('BOTTOMRIGHT', ring, 'BOTTOMRIGHT', -ringWidth, ringWidth)
		ring.gapEdges = ui:Border(gap, 'color.focus.gap', gapWidth)
	end
	return ring
end

function makeFocusChevron(ui, button, ring)
	local theme = ui.theme
	local chevron = ring:CreateTexture(nil, 'OVERLAY')
	chevron:SetSize(
		roundToFour(theme:Number('focus.chevronWidth') * Widgets.FOCUS_CHEVRON_SCALE),
		roundToFour(theme:Number('focus.chevronHeight') * Widgets.FOCUS_CHEVRON_SCALE)
	)
	chevron:SetPoint('RIGHT', button, 'LEFT', 0, 0)
	ns.IconSet.new({ theme = theme }):Apply(chevron, Widgets.FOCUS_CHEVRON_ICON, 'color.focus.chevron')
	return chevron
end

function roundToFour(value)
	return math.floor(value / 4 + 0.5) * 4
end

return Widgets
