--[[
	Compat: a one-time notice of the AHledger features that do what Haggler also does
	(tooltips, bag marks, posting help and the rest), so the player can turn the doubles off in
	AHledger's own options. Haggler reads AHledger's settings (AHledgerDB.settings, where a
	missing key means the default, on) and never writes them.

	The notice shows once, at login, while any overlapping feature is on. Closing it in any
	way (its button, Escape; not the interface hiding for Alt+Z or a cinematic) dismisses it for
	good; /hag compat shows it again on demand.

	  ns.Compat.overlappingFeatures(settings) -> { { key, label }, ... } the overlapping features
	                                             that are on, in AHLEDGER_FEATURES order
]]
local _, ns = ...

local Compat = {}
ns.Compat = Compat
local state = { isDisabling = false }

local EVENT_OWNER = 'compat'
local FRAME_NAME = 'HagglerCompatNotice'
local WIDTH = 460
local PADDING = 16
local LINE_HEIGHT = 18

-- AHledger's option keys that overlap Haggler, labelled as AHledger's options list them.
Compat.AHLEDGER_FEATURES = {
	{ key = 'tooltip', label = 'Prices in item tooltips' },
	{ key = 'crafting', label = 'Crafting margins' },
	{ key = 'craftDots', label = 'Profession window: profit dots' },
	{ key = 'bar', label = 'Ledger bar' },
	{ key = 'bagDots', label = 'Bags: dots on slots' },
	{ key = 'postingHelper', label = 'Auction house: posting helper' },
	{ key = 'postingPlan', label = 'Auction house: posting plan' },
	{ key = 'vendorFlips', label = 'Vendors: mark items worth flipping' },
	{ key = 'ledger', label = 'Ledger: posts, sales and purchases' },
}

-- Helpers live at the bottom of the file; declared here so they stay local.
local showNotice, showNoticeIfDue, buildNotice

--- The overlapping AHledger features that are on. A key AHledger has not saved is at its
--- default, which is on; only an explicit false is off.
--- @param settings table|nil AHledgerDB.settings, read only
--- @return table list of { key, label }
function Compat.overlappingFeatures(settings)
	local readable = type(settings) == 'table' and settings or {}
	local features = {}
	for _, feature in ipairs(Compat.AHLEDGER_FEATURES) do
		if readable[feature.key] ~= false then
			features[#features + 1] = { key = feature.key, label = feature.label }
		end
	end
	return features
end

local compat = ns.host.AddModule({
	key = 'compat',
	label = 'AHledger overlap notice',
	settings = {
		{
			key = 'noticeDismissed',
			type = 'toggle',
			label = 'AHledger overlap notice already seen (off shows it at the next login)',
			default = false,
		},
	},
	onEnable = function(module)
		local wow = ns.wow
		module:AddCommand('compat', {
			usage = 'compat',
			help = 'Show which AHledger features overlap Haggler',
			run = function()
				if not showNotice(module) then
					return { 'No AHledger feature overlaps Haggler right now.' }
				end
				return {}
			end,
		})
		local isLoggedIn = wow:Global('IsLoggedIn')
		if type(isLoggedIn) == 'function' and isLoggedIn() then
			showNoticeIfDue(module)
			return
		end
		wow:OnEvent('PLAYER_LOGIN', function()
			wow:OffEvent('PLAYER_LOGIN', EVENT_OWNER)
			showNoticeIfDue(module)
		end, EVENT_OWNER)
	end,
	onDisable = function()
		ns.wow:OffEvent('PLAYER_LOGIN', EVENT_OWNER)
		if Compat.notice then
			-- Turning the module off is not the player closing the notice.
			state.isDisabling = true
			Compat.notice:Hide()
			state.isDisabling = false
		end
	end,
})
Compat.module = compat

-- Helpers ---------------------------------------------------------------------------------

function showNoticeIfDue(module)
	if module:Setting('noticeDismissed') then
		return false
	end
	return showNotice(module)
end

-- Shows the notice when anything overlaps; returns whether it did.
function showNotice(module)
	local features = Compat.overlappingFeatures(ns.wow:AHledgerSettings())
	if #features == 0 then
		return false
	end
	local notice = buildNotice(module)
	local lines = {}
	for _, feature in ipairs(features) do
		lines[#lines + 1] = '· ' .. feature.label
	end
	notice.list:SetText(table.concat(lines, '\n'))
	notice:SetHeight(150 + #features * LINE_HEIGHT)
	notice:Show()
	return true
end

function buildNotice(module)
	if Compat.notice then
		return Compat.notice
	end
	local wow = ns.wow
	local ui = ns.Widgets.new(wow, ns.theme)
	local notice = wow:CreateFrame('Frame', nil, nil, FRAME_NAME)
	notice:SetSize(WIDTH, 300)
	notice:SetPoint('CENTER', wow:Global('UIParent'), 'CENTER', 0, 120)
	notice:SetFrameStrata('DIALOG')
	notice:EnableMouse(true)
	ui:Fill(notice, 'color.surface.raised')
	ui:Border(notice, 'color.border.subtle')

	local title = ui:Text(notice, 17, 'color.text.title', ns.Widgets.HEADING_FACE)
	title:SetPoint('TOPLEFT', notice, 'TOPLEFT', PADDING, -PADDING)
	title:SetText('Haggler and AHledger')
	local intro = ui:Text(notice, 13, 'color.text.secondary')
	intro:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -8)
	intro:SetWidth(WIDTH - 2 * PADDING)
	intro:SetText('These AHledger features are on and Haggler does the same. Turn off the ones you do not want twice.')
	notice.list = ui:Text(notice, 13, 'color.text.primary')
	notice.list:SetPoint('TOPLEFT', intro, 'BOTTOMLEFT', 0, -8)
	notice.list:SetWidth(WIDTH - 2 * PADDING)

	local openButton = ui:Button(notice, 'Open AHledger options', 'primary')
	openButton:SetPoint('BOTTOMLEFT', notice, 'BOTTOMLEFT', PADDING, PADDING)
	openButton:OnClick(function()
		if not wow:OpenAHledgerOptions() then
			wow:Print('AHledger did not open its options; type /ahl options.')
		end
	end)
	notice.openButton = openButton
	local closeButton = ui:Button(notice, 'Close', 'secondary')
	closeButton:SetPoint('LEFT', openButton, 'RIGHT', 8, 0)
	closeButton:OnClick(function()
		notice:Hide()
	end)
	notice.closeButton = closeButton
	notice:Hide()
	notice:SetScript('OnHide', function()
		-- Alt+Z and cinematics hide UIParent, and the notice with it: that is not a close.
		local uiParent = wow:Global('UIParent')
		local isInterfaceHidden = type(uiParent) == 'table' and not uiParent:IsShown()
		if not state.isDisabling and not isInterfaceHidden then
			module:SetSetting('noticeDismissed', true)
		end
	end)
	-- Escape closes it like any panel; the list is read by name.
	local specialFrames = wow:Global('UISpecialFrames')
	if type(specialFrames) == 'table' then
		table.insert(specialFrames, FRAME_NAME)
	end
	Compat.notice = notice
	return notice
end
