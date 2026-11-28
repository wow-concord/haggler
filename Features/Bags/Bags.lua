--[[
	Bags: badges and values on bag buttons, and the bag total, in whichever bag add-on is in use
	(Host/BagHosts/: Blizzard, BagPad, Bagnon, Baganator; a missing one is a no-op).

	Hooks into a host cannot be removed, so they are installed the first time the module is on
	and check the module on every call; switching it off clears the overlays and the totals and
	drops its events. A host that loads later is attached on its ADDON_LOADED.
]]
local _, ns = ...

local MODULE_KEY = 'bags'
local EVENT_OWNER = 'bags'
local REPAINT_EVENTS = { 'BAG_UPDATE_DELAYED', 'PLAYER_REGEN_ENABLED', 'ADDON_LOADED' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local ensureView, repaint, scheduleRepaint, attachHosts, reportHostError, migrateVendorBadge

-- isOn is the module's own flag: the host still reports it enabled while onDisable runs.
local state = { attached = {}, isRepaintQueued = false, isOn = false }

local function toggle(key, label, default)
	return { key = key, type = 'toggle', label = label, default = default }
end

local bags = ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Bags',
	settings = {
		toggle('showValue', 'Value on each bag button', false),
		toggle('showTotal', 'Total value of the bags, where the bag add-on has a spot for it', true),
		toggle('decisionBadge', 'Decision badge, top left: post, sell, wait or undecided', true),
		toggle('typeBadge', 'Item type badge, top right: quest or junk', true),
	},
	onLoad = function(module)
		migrateVendorBadge(module)
	end,
	onEnable = function(module)
		state.isOn = true
		local view = ensureView(module)
		for _, event in ipairs(REPAINT_EVENTS) do
			ns.wow:OnEvent(event, function()
				if event == 'ADDON_LOADED' then
					attachHosts(view)
				end
				scheduleRepaint(view)
			end, EVENT_OWNER)
		end
		module:On(ns.Host.SETTINGS_CHANGED, function()
			scheduleRepaint(view)
		end)
		-- A saved scan changes prices, so every painted value and badge may be stale.
		module:On('SCAN_READY', function()
			scheduleRepaint(view)
		end)
		-- A saved or newly default rule changes the price every value comes from.
		for _, message in ipairs({ 'RULES_CHANGED', 'DEFAULT_RULE_CHANGED' }) do
			module:On(message, function()
				view.ctx = nil
				scheduleRepaint(view)
			end)
		end
		attachHosts(view)
		repaint(view)
	end,
	onDisable = function()
		state.isOn = false
		for _, event in ipairs(REPAINT_EVENTS) do
			ns.wow:OffEvent(event, EVENT_OWNER)
		end
		if state.view then
			repaint(state.view)
		end
	end,
})
ns.bags = bags

-- Helpers ---------------------------------------------------------------------------------

-- vendorBadge (the old top-left vendor badge) became decisionBadge: a player who had switched it
-- off keeps the top left empty, unless they already chose a decision badge setting.
function migrateVendorBadge(module)
	local wasVendorBadgeOff = module.host.Settings:TakeRetired(MODULE_KEY, 'vendorBadge') == false
	if wasVendorBadgeOff and not module:IsSettingSet('decisionBadge') then
		module:SetSetting('decisionBadge', false)
	end
end

function ensureView(module)
	if state.view then
		return state.view
	end
	local icons = ns.IconSet.new({ theme = ns.theme })
	state.view = ns.BagView.new({
		wow = ns.wow,
		icons = icons,
		painter = ns.Badges.newPainter({ icons = icons, theme = ns.theme }),
		values = function()
			return ns.values
		end,
		options = function()
			return {
				showValue = module:Setting('showValue'),
				showTotal = module:Setting('showTotal'),
				decisionBadge = module:Setting('decisionBadge'),
				typeBadge = module:Setting('typeBadge'),
			}
		end,
		isActive = function()
			return state.isOn
		end,
		money = ns.TooltipLines.money,
	})
	return state.view
end

function attachHosts(view)
	ns.BagHosts.attachAll(ns.wow, view, state.attached, reportHostError)
end

function repaint(view)
	state.isRepaintQueued = false
	view.isDirty = false
	view:StartPass()
	ns.BagHosts.refreshAll(ns.wow, view, state.attached, reportHostError)
	view:UpdateTotals()
end

-- Bag updates come in bursts (looting, sorting): one repaint per frame.
function scheduleRepaint(view)
	if state.isRepaintQueued then
		return
	end
	state.isRepaintQueued = true
	if not ns.wow:After(0, function()
		repaint(view)
	end) then
		repaint(view)
	end
end

function reportHostError(name, err)
	ns.wow:Print(string.format('bag host %s failed: %s', name, tostring(err)))
end
