--[[
	BagView: what bag hosts paint with. It reads a bag slot, values its stack (ns.Value through
	the getter it is given), decides the badges and paints them, and keeps the bag total spots
	current. UI-light: it only touches the buttons and font strings hosts hand it.

	  BagView.new({ wow, values, painter, icons, options, isActive, money })
	    values()   -> Value|nil      the value service (nil while it is off)
	    options()  -> { showValue, decisionBadge, typeBadge, showTotal }
	    isActive() -> boolean        the Bags module is on
	    money(copper) -> string
	  view:PaintSlot(button, bag, slot)
	  view:DecideItem(itemId, count, item?) -> Decision   item = { isBound?, isQuest?, isJunk? }
	  view:ItemFlags(itemId, quality, isBound) -> item   for a host that reads no bag slot
	  view:ClearSlot(button)
	  view:NewBadgeFrame(frame) / view:PaintBadgeFrame(frame, badge|nil)   one badge in a frame
	  view:ValueLabel(decision) -> string|nil   the value text with its low marker
	  view:TrackTotal(fontString, onResize?)
	  view:BagTotal() -> Total|nil
	  view:UpdateTotals()
	  view:StartPass()   a fresh price context for the next paints (prices or bags changed)

	Combat: no item is valued while in combat lockdown (bag updates from looting are frequent
	there) and the view is marked dirty; the Bags module repaints when combat ends. A slot that
	empties or holds a different stack mid-fight is cleared at once (textures are allowed in
	combat), so no button keeps the badge of an item it no longer holds.
]]
local _, ns = ...

local BagView = {}
ns.BagView = BagView

-- Enum.ItemQuality.Poor: a grey item.
BagView.POOR_QUALITY = 0

BagView.TOTAL_LABEL = 'Bags'
BagView.LOW_ICON_SIZE = 12

-- Helpers live at the bottom of the file; declared here so they stay local.
local totalText, slotFlags, stackKey

local ViewMethods = {}
ViewMethods.__index = ViewMethods

--- @param options table see the file header
--- @return table view
function BagView.new(options)
	if type(options) ~= 'table' or not options.wow or not options.painter or not options.icons then
		error('BagView.new: needs wow, painter and icons', 2)
	end
	for _, fn in ipairs({ 'values', 'options', 'isActive', 'money' }) do
		if type(options[fn]) ~= 'function' then
			error('BagView.new: needs ' .. fn, 2)
		end
	end
	return setmetatable({
		deps = options,
		totals = {},
		isDirty = false,
		paintedStacks = setmetatable({}, { __mode = 'k' }),
	}, ViewMethods)
end

function ViewMethods:IsActive()
	return self.deps.isActive() == true and self.deps.values() ~= nil
end

--- Drops the cached price context so the next paint reads fresh prices.
function ViewMethods:StartPass()
	self.ctx = nil
end

--- The value of a stack under the default rule, or nil (no value service, a bad id).
function ViewMethods:ItemValue(itemId, count, isBound)
	local values = self.deps.values()
	if not values or type(itemId) ~= 'number' then
		return nil
	end
	self.ctx = self.ctx or values:Context()
	local stack = tonumber(count) or 1
	return values:Stack(itemId, stack >= 1 and math.floor(stack) or 1, { ctx = self.ctx, isBound = isBound })
end

--- The badges and value text for a stack.
--- @param item table|nil { isBound?, isQuest?, isJunk? }
function ViewMethods:DecideItem(itemId, count, item)
	item = type(item) == 'table' and item or {}
	return ns.Badges.decide(self:ItemValue(itemId, count, item.isBound == true), self.deps.options(), item)
end

--- Bound, quest and junk flags from what a host knows of an item: its quality and binding. Junk
--- is a grey the vendor pays for.
--- @return table item { isBound, isQuest, isJunk }
function ViewMethods:ItemFlags(itemId, quality, isBound)
	local wow = self.deps.wow
	local info = quality == BagView.POOR_QUALITY and wow:CachedItemInfo(itemId) or nil
	return {
		isBound = isBound == true,
		isQuest = wow:IsQuestItemClass(itemId),
		isJunk = info ~= nil and (info.vendorPrice or 0) > 0,
	}
end

--- Paints one Blizzard-style item button from its bag slot. Clears it when the module is off,
--- the slot is empty or its item is not loaded yet.
function ViewMethods:PaintSlot(button, bag, slot)
	if type(button) ~= 'table' then
		return
	end
	local painter = self.deps.painter
	if not self:IsActive() then
		self:ClearSlot(button)
		return
	end
	local wow = self.deps.wow
	local item = type(bag) == 'number' and type(slot) == 'number' and wow:ContainerItem(bag, slot) or nil
	if not item or not item.itemId then
		self:ClearSlot(button)
		return
	end
	local stack = stackKey(item)
	if wow:IsInCombat() then
		self.isDirty = true
		if self.paintedStacks[button] ~= stack then
			self:ClearSlot(button)
		end
		return
	end
	painter:Paint(button, self:DecideItem(item.itemId, item.count, slotFlags(wow, item, bag, slot)))
	self.paintedStacks[button] = stack
end

--- Removes the badges and value from a button (a host showing a slot that is not the player's).
function ViewMethods:ClearSlot(button)
	if type(button) == 'table' then
		self.deps.painter:Clear(button)
		self.paintedStacks[button] = nil
	end
end

function ViewMethods:NewBadgeFrame(frame)
	return self.deps.painter:NewBadgeFrame(frame)
end

function ViewMethods:PaintBadgeFrame(frame, badge)
	return self.deps.painter:PaintBadgeFrame(frame, badge)
end

function ViewMethods:ValueLabel(decision)
	return ns.Badges.valueLabel(decision, self.deps.icons)
end

--- Registers a spot for the bag total; it is filled at once and on every UpdateTotals.
--- @param fontString table
--- @param onResize function|nil fun(width) for hosts that lay the spot out by its width
function ViewMethods:TrackTotal(fontString, onResize)
	self.totals[#self.totals + 1] = { text = fontString, onResize = onResize }
	self:UpdateTotals()
end

--- The value of everything in the carried bags, or nil when there is no value service.
function ViewMethods:BagTotal()
	local values = self.deps.values()
	if not values then
		return nil
	end
	self.ctx = self.ctx or values:Context()
	return values:Total(self.deps.wow:CarriedItems(), { ctx = self.ctx })
end

--- Refills every total spot (hidden when the module or the setting is off).
function ViewMethods:UpdateTotals()
	if #self.totals == 0 then
		return
	end
	local isShown = self:IsActive() and self.deps.options().showTotal == true
	if isShown and self.deps.wow:IsInCombat() then
		self.isDirty = true
		return
	end
	local text = isShown and totalText(self, self:BagTotal()) or nil
	for _, spot in ipairs(self.totals) do
		if text then
			spot.text:SetText(text)
			spot.text:Show()
		else
			spot.text:Hide()
		end
		if spot.onResize then
			spot.onResize(text and spot.text:GetStringWidth() or 0)
		end
	end
end

-- Helpers ---------------------------------------------------------------------------------

-- A bag slot's flags: the slot's own quest info, and junk as the client marks it (a grey that
-- has a vendor value).
function slotFlags(wow, item, bag, slot)
	return {
		isBound = item.isBound,
		isQuest = wow:IsQuestSlot(bag, slot, item.itemId),
		isJunk = item.quality == BagView.POOR_QUALITY and not item.hasNoValue,
	}
end

-- What a painted badge was decided from: the item and its count.
function stackKey(item)
	return item.itemId .. 'x' .. tostring(item.count)
end

function totalText(view, total)
	if not total then
		return nil
	end
	local text = BagView.TOTAL_LABEL .. ': ' .. view.deps.money(total.copper)
	if total.confidence.level == 'low' then
		local icons = view.deps.icons
		text = text
			.. ' '
			.. icons:Inline(ns.IconSet.LOW_CONFIDENCE, BagView.LOW_ICON_SIZE, ns.IconSet.LOW_CONFIDENCE_COLOR)
	end
	return text
end

return BagView
