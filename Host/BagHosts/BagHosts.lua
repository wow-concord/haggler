--[[
	BagHosts: adapters for the bag add-ons Haggler draws on. Each adapter finds item buttons in
	its host and hands them to a BagView (Features/Bags/View.lua), which decides and paints.

	  BagHosts.register(adapter)
	  BagHosts.attachAll(wow, view, attached, onError?) -> names of the hosts attached now
	  BagHosts.refreshAll(wow, view, attached, onError?)
	      attached = { [name] = true }, kept by the caller across calls

	Adapter = { name, targets, detect(wow) -> boolean, attach(wow, view) -> boolean,
	            refresh(wow, view) }

	Hosts are detected at runtime; a missing host is a no-op. attach runs once per adapter per
	session: the client cannot remove a hook, so an adapter hooks once and asks view:IsActive()
	on every call. A host that loads later (load on demand) is attached on the next attachAll.
	An adapter that throws is skipped and reported, never fatal.

	The view an adapter uses:
	  view:IsActive()                         the Bags module is on
	  view:PaintSlot(button, bag, slot)       Blizzard-style buttons: badges and value overlay
	  view:ClearSlot(button)                  removes them (a slot that is not the player's)
	  view:DecideItem(itemId, count, item?)   a Badges decision, for hosts with their own regions
	  view:ItemFlags(itemId, quality, isBound) bound, quest and junk flags without a bag slot
	  view:NewBadgeFrame(frame)               fills a frame with one badge's glyph and outline
	  view:PaintBadgeFrame(frame, badge?)     shows a badge in it (nil hides it)
	  view:TrackTotal(fontString, onResize?)  a spot that shows the bag total
]]
local _, ns = ...

local BagHosts = {}
ns.BagHosts = BagHosts

BagHosts.adapters = {}

--- Adds an adapter (each file under Host/BagHosts/ registers its own).
function BagHosts.register(adapter)
	if type(adapter) ~= 'table' or type(adapter.name) ~= 'string' then
		error('BagHosts.register: an adapter needs a name', 2)
	end
	for _, fn in ipairs({ 'detect', 'attach', 'refresh' }) do
		if type(adapter[fn]) ~= 'function' then
			error('BagHosts.register: adapter ' .. adapter.name .. ' needs ' .. fn, 2)
		end
	end
	BagHosts.adapters[#BagHosts.adapters + 1] = adapter
	return adapter
end

--- Attaches every host that is present and not attached yet.
--- @param onError function|nil fun(name, err)
--- @return table names attached by this call
function BagHosts.attachAll(wow, view, attached, onError)
	local names = {}
	for _, adapter in ipairs(BagHosts.adapters) do
		if not attached[adapter.name] then
			local ok, result = pcall(function()
				return adapter.detect(wow) and adapter.attach(wow, view)
			end)
			if not ok and onError then
				onError(adapter.name, result)
			end
			if ok and result then
				attached[adapter.name] = true
				names[#names + 1] = adapter.name
			end
		end
	end
	return names
end

--- Repaints every attached host.
function BagHosts.refreshAll(wow, view, attached, onError)
	for _, adapter in ipairs(BagHosts.adapters) do
		if attached[adapter.name] then
			local ok, err = pcall(adapter.refresh, wow, view)
			if not ok and onError then
				onError(adapter.name, err)
			end
		end
	end
end

--- Calls fn(button) for each item button an EnumerateValidItems iterator yields. Blizzard's
--- iterator yields (index, button) on Mainline; a bare button is tolerated too.
function BagHosts.eachValidItem(frame, fn)
	if type(frame) ~= 'table' or type(frame.EnumerateValidItems) ~= 'function' then
		return 0
	end
	local count = 0
	for first, second in frame:EnumerateValidItems() do
		local button = type(second) == 'table' and second or first
		if type(button) == 'table' then
			count = count + 1
			fn(button)
		end
	end
	return count
end

--- True for a real frame or region: the client keeps its C object at [0]. A class table
--- (Bagnon's PlayerMoney before the frame places it) has none, and calling a region method on
--- it throws.
function BagHosts.isRegion(value)
	return type(value) == 'table' and type(rawget(value, 0)) == 'userdata'
end

--- A font string for the bag total, just above a host's money frame. Nothing is created until
--- the frame has a real money frame of its own (rawget: an inherited class field does not count),
--- so a caller that retries on every layout never leaks font strings.
--- @return boolean attached
function BagHosts.totalAboveMoney(frame, view)
	local money = type(frame) == 'table' and rawget(frame, 'MoneyFrame') or nil
	if not BagHosts.isRegion(money) or type(frame.CreateFontString) ~= 'function' then
		return false
	end
	local text = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
	text:SetPoint('BOTTOMRIGHT', money, 'TOPRIGHT', 0, 2)
	view:TrackTotal(text)
	return true
end

return BagHosts
