--[[
	CraftingAnchor: where the crafting side panel (Features/Crafting/Crafting.lua) sits next to
	Blizzard's profession frame.

	WoW: Forever draws a column of side tabs on the profession frame's right edge (the
	profession and spell icons, with the gamepad hint under them). Their names are not part of
	any API Haggler can rely on, so the column is measured: every shown frame or region of the
	profession frame, up to two levels down, that starts at or just inside its right edge,
	sticks out past it, is no wider than a tab and lies within the frame's height. A wider
	frame there is another add-on's panel, not a tab, and is left alone.

	  CraftingAnchor.place(panel, frame, uiParent, width) -> 'right'|'left'|'clamped'
	      right of the tab column (or the frame edge when there is none) when the panel fits on
	      screen there, else left of the frame, else right and clamped to the screen
	  CraftingAnchor.columnRight(frame, exclude) -> screen x|nil   the column's right edge
	  CraftingAnchor.columnFrames(frame, exclude) -> { frame }      the column's frames, shown
	      or hidden, for a caller to re-place the panel when one shows or hides

	Cost: one walk of the frame's children, run when the selected recipe repaints or the frame
	or a column frame shows, hides or resizes; never per frame.
]]
local _, ns = ...

local CraftingAnchor = {}
ns.CraftingAnchor = CraftingAnchor

-- space.2: the gap between the panel and what it sits beside.
CraftingAnchor.GAP = 8
-- A tab may start this far inside the frame edge (screen pixels) and still count.
local COLUMN_INSET = 32
-- Wider than this is not a tab (screen pixels).
local COLUMN_MAX_WIDTH = 96
-- The frame, its children and their children.
local COLUMN_DEPTH = 2

-- Helpers live at the bottom of the file; declared here so they stay local.
local scaleOf, screenEdges, isColumnPart, widestColumnRight, collectColumnFrames, regionsAndChildren

--- Anchors the panel beside the profession frame and clamps it to the screen.
--- @param panel table the side panel, a child of frame
--- @param frame table Blizzard's profession frame
--- @param uiParent table|nil the screen's frame, for its width
--- @param width number the panel's width in frame units
--- @return string side 'right', 'left' or 'clamped'
function CraftingAnchor.place(panel, frame, uiParent, width)
	if type(panel) ~= 'table' or type(frame) ~= 'table' or type(width) ~= 'number' then
		error('CraftingAnchor.place: needs panel, frame and width', 2)
	end
	local scale = scaleOf(frame)
	local edges = screenEdges(frame)
	local columnRight = CraftingAnchor.columnRight(frame, panel)
	local rightOffset = CraftingAnchor.GAP
	if edges and columnRight and columnRight > edges.right then
		rightOffset = math.floor((columnRight - edges.right) / scale + 0.5) + CraftingAnchor.GAP
	end
	local screen = uiParent and screenEdges(uiParent)
	local side = 'clamped'
	if not (edges and screen) then
		side = 'right'
	elseif edges.right + (rightOffset + width) * scale <= screen.right then
		side = 'right'
	elseif edges.left - (CraftingAnchor.GAP + width) * scale >= screen.left then
		side = 'left'
	end
	panel:ClearAllPoints()
	if side == 'left' then
		panel:SetPoint('TOPRIGHT', frame, 'TOPLEFT', -CraftingAnchor.GAP, 0)
	else
		panel:SetPoint('TOPLEFT', frame, 'TOPRIGHT', rightOffset, 0)
	end
	panel:SetClampedToScreen(true)
	return side
end

--- The right edge of the side tab column, in screen pixels.
--- @param frame table Blizzard's profession frame
--- @param exclude table|nil a frame left out with everything in it (the panel)
--- @return number|nil right nil when the frame is not laid out or has no column
function CraftingAnchor.columnRight(frame, exclude)
	local edges = screenEdges(frame)
	if not edges then
		return nil
	end
	return widestColumnRight(frame, edges, exclude, COLUMN_DEPTH)
end

--- The frames of the side tab column, shown or hidden (a hidden one may show later).
--- @param frame table Blizzard's profession frame
--- @param exclude table|nil a frame left out with everything in it (the panel)
--- @return table frames empty when the frame is not laid out or has no column
function CraftingAnchor.columnFrames(frame, exclude)
	local frames = {}
	local edges = screenEdges(frame)
	if edges then
		collectColumnFrames(frame, edges, exclude, COLUMN_DEPTH, frames)
	end
	return frames
end

-- Helpers ---------------------------------------------------------------------------------

function scaleOf(region)
	local scale = region.GetEffectiveScale and region:GetEffectiveScale()
	return type(scale) == 'number' and scale > 0 and scale or 1
end

-- The region's edges in screen pixels; nil while the client cannot say (not laid out yet).
function screenEdges(region)
	local left = region.GetLeft and region:GetLeft()
	local right = region.GetRight and region:GetRight()
	if type(left) ~= 'number' or type(right) ~= 'number' then
		return nil
	end
	local top = region.GetTop and region:GetTop()
	local bottom = region.GetBottom and region:GetBottom()
	local scale = scaleOf(region)
	return {
		left = left * scale,
		right = right * scale,
		top = type(top) == 'number' and top * scale or nil,
		bottom = type(bottom) == 'number' and bottom * scale or nil,
	}
end

-- The geometry test alone; whether the region shows is the caller's question.
function isColumnPart(region, frameEdges)
	local edges = screenEdges(region)
	if not edges or edges.right <= frameEdges.right then
		return false, edges
	end
	if edges.left < frameEdges.right - COLUMN_INSET or edges.right - edges.left > COLUMN_MAX_WIDTH then
		return false, edges
	end
	local isAbove = edges.bottom and frameEdges.top and edges.bottom >= frameEdges.top
	local isBelow = edges.top and frameEdges.bottom and edges.top <= frameEdges.bottom
	return not (isAbove or isBelow), edges
end

function widestColumnRight(parent, frameEdges, exclude, depth)
	local widest
	for _, region in ipairs(regionsAndChildren(parent)) do
		if region ~= exclude and not (region.IsShown and not region:IsShown()) then
			local isPart, edges = isColumnPart(region, frameEdges)
			if isPart and edges and (not widest or edges.right > widest) then
				widest = edges.right
			end
			local deeper = depth > 1
				and region.GetChildren
				and widestColumnRight(region, frameEdges, exclude, depth - 1)
			if deeper and (not widest or deeper > widest) then
				widest = deeper
			end
		end
	end
	return widest
end

function collectColumnFrames(parent, frameEdges, exclude, depth, frames)
	if not parent.GetChildren then
		return
	end
	for _, child in ipairs({ parent:GetChildren() }) do
		if child ~= exclude then
			if isColumnPart(child, frameEdges) then
				frames[#frames + 1] = child
			end
			if depth > 1 then
				collectColumnFrames(child, frameEdges, exclude, depth - 1, frames)
			end
		end
	end
end

function regionsAndChildren(parent)
	local list = {}
	if parent.GetRegions then
		for _, region in ipairs({ parent:GetRegions() }) do
			list[#list + 1] = region
		end
	end
	if parent.GetChildren then
		for _, child in ipairs({ parent:GetChildren() }) do
			list[#list + 1] = child
		end
	end
	return list
end
