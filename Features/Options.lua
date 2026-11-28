--[[
	Options: Haggler's entry under Settings → AddOns. It lists every on/off switch of every
	module (each module's Enabled first) as a checkbox bound to the host's settings, so the
	panel, /hag and the Haggler window always agree, and a button that opens the Haggler window.
	It also carries the price source's credit (AHledgerAPI.CREDIT, through PriceData), which
	AHledger's terms ask for where its prices appear; the item tooltip does not. The credit is
	read again when a price table loads (the moment AHledger's line can change), before /hag
	options opens the entry, and each time the panel shows, so the row already holds the current
	line when Settings draws the category, even when it reopens on it.
	It sits on a section header row; a client without that initializer gets it as the plain
	label of the open button's row, and one without either gets the old panel, where it is a
	muted line under the title.

	Clients with the Settings API get a vertical-layout category; the registration runs in
	pcall, and when it fails, or the client has no Settings API, an old Interface Options panel
	takes its place, with the same switches as buttons.

	  ns.Options.toggleEntries(settings, labelOf) -> { { moduleKey, key, label, variable }, ... }
	  ns.Options.credit()                          -> the credit line, PriceData.DEFAULT_CREDIT without one
	  /hag options                                   opens the entry
]]
local _, ns = ...

local Options = {}
ns.Options = Options

Options.CATEGORY_NAME = 'Haggler'
local PANEL_NAME = 'HagglerOptionsPanel'
local PADDING = 16
local ROW_HEIGHT = 36

-- Helpers live at the bottom of the file; declared here so they stay local.
local registerCategory, registerWithSettingsApi, registerLegacyPanel, addOpenButton, moduleLabel, openWindow
local refreshLegacyPanel, addCredit, refreshCredit, setInitializerName, hookSettingsPanelShow, switchLabel

--- The on/off switches of every module, in module order and each module's schema order.
--- @param settings table the host's settings store (Modules, Schema)
--- @param labelOf fun(moduleKey: string): string the module's label
--- @return table list of { moduleKey, key, label, variable }
function Options.toggleEntries(settings, labelOf)
	if type(settings) ~= 'table' or type(labelOf) ~= 'function' then
		error('Options.toggleEntries: settings and labelOf are required', 2)
	end
	local entries = {}
	for _, moduleKey in ipairs(settings:Modules()) do
		local moduleName = labelOf(moduleKey)
		for _, entry in ipairs(settings:Schema(moduleKey)) do
			if entry.type == 'toggle' then
				entries[#entries + 1] = {
					moduleKey = moduleKey,
					key = entry.key,
					label = entry.key == 'enabled' and moduleName or switchLabel(entry.label, moduleName),
					variable = string.format('HAGGLER_%s_%s', moduleKey:upper(), entry.key:upper()),
				}
			end
		end
	end
	return entries
end

--- The price source's credit line (PriceData reads AHledgerAPI.CREDIT), or the default one.
--- @return string
function Options.credit()
	local status = ns.prices and ns.prices:SourceStatus()
	return status and status.credit or ns.PriceData.DEFAULT_CREDIT
end

local options = ns.host.AddModule({
	key = 'options',
	label = 'Settings entry',
	category = 'core',
	canDisable = false,
	onEnable = function(module)
		registerCategory()
		module:On('PRICE_TABLE_LOADED', refreshCredit)
		module:AddCommand('options', {
			usage = 'options',
			help = 'Open Haggler under Settings → AddOns',
			run = function()
				refreshCredit()
				if not ns.wow:OpenOptionsCategory(Options.category) then
					return { 'The Settings window did not open. Find Haggler under Settings → AddOns.' }
				end
				return {}
			end,
		})
	end,
})
Options.module = options

-- Helpers ---------------------------------------------------------------------------------

-- Registers once per session; the client keeps a category for good.
function registerCategory()
	if Options.category then
		return
	end
	local wow = ns.wow
	local entries = Options.toggleEntries(ns.host.Settings, moduleLabel)
	local api = wow:SettingsApi()
	if api then
		local ok, result = pcall(registerWithSettingsApi, api, entries)
		if ok then
			Options.category, Options.kind = result, 'settings'
			hookSettingsPanelShow()
			return
		end
		-- Chat says only what changed for the player; the error itself is kept off it.
		Options.registrationError = tostring(result)
		wow:Print('The Settings entry failed, so Haggler uses the old options panel')
	end
	Options.category, Options.kind = registerLegacyPanel(entries), 'legacy'
end

function registerWithSettingsApi(api, entries)
	local settings = ns.host.Settings
	local category, layout = api.RegisterVerticalLayoutCategory(Options.CATEGORY_NAME)
	local booleanType = type(api.VarType) == 'table' and api.VarType.Boolean or 'boolean'
	local createCheckbox = api.CreateCheckbox or api.CreateCheckBox
	for _, entry in ipairs(entries) do
		local setting = api.RegisterProxySetting(
			category,
			entry.variable,
			booleanType,
			entry.label,
			settings:Defaults(entry.moduleKey)[entry.key],
			function()
				return settings:Get(entry.moduleKey, entry.key) == true
			end,
			function(value)
				settings:Set(entry.moduleKey, entry.key, value == true)
			end
		)
		createCheckbox(category, setting, nil)
	end
	local button = addOpenButton(layout)
	Options.creditInitializer = addCredit(layout) or button
	if not Options.creditInitializer then
		-- Raised so registerCategory falls back to the old panel, which can show the credit.
		error('no initializer can show the credit')
	end
	refreshCredit()
	api.RegisterAddOnCategory(category)
	return category
end

-- The credit as a section header row of the category, or nil on a client without one.
function addCredit(layout)
	local createHeader = ns.wow:Global('CreateSettingsListSectionHeaderInitializer')
	if type(createHeader) ~= 'function' or type(layout) ~= 'table' or type(layout.AddInitializer) ~= 'function' then
		return nil
	end
	local initializer = createHeader(Options.credit())
	layout:AddInitializer(initializer)
	return initializer
end

-- The button is a nicety: a client without the initializer still gets the switches. Returns
-- the initializer, whose row label carries the credit when no section header can.
function addOpenButton(layout)
	local createButton = ns.wow:Global('CreateSettingsButtonInitializer')
	if type(createButton) ~= 'function' or type(layout) ~= 'table' or type(layout.AddInitializer) ~= 'function' then
		return nil
	end
	local initializer = createButton('', 'Open Haggler', openWindow, 'Open the Haggler window', true)
	layout:AddInitializer(initializer)
	return initializer
end

-- Puts the current credit on its row (Settings API) or its text (old panel).
function refreshCredit()
	local credit = Options.credit()
	if Options.creditInitializer then
		setInitializerName(Options.creditInitializer, credit)
	end
	if Options.legacyCredit then
		Options.legacyCredit:SetText(credit)
	end
end

-- An initializer's row reads its data's name when it is drawn, so a new name shows next time.
function setInitializerName(initializer, name)
	local data = type(initializer) == 'table' and type(initializer.GetData) == 'function' and initializer:GetData()
		or nil
	if type(data) == 'table' then
		data.name = name
	end
end

-- A late catch for a credit that changed with no price table loading; the hook runs after the
-- panel's own OnShow, so the refreshes above are what the first draw reads.
function hookSettingsPanelShow()
	ns.wow:HookFrameScript(ns.wow:Global('SettingsPanel'), 'OnShow', refreshCredit)
end

function registerLegacyPanel(entries)
	local wow = ns.wow
	local ui = ns.Widgets.new(wow, ns.theme)
	local panel = wow:CreateFrame('Frame', nil, nil, PANEL_NAME)
	panel.name = Options.CATEGORY_NAME
	local title = ui:Text(panel, 17, 'color.text.title', ns.Widgets.HEADING_FACE)
	title:SetPoint('TOPLEFT', panel, 'TOPLEFT', PADDING, -PADDING)
	title:SetText(Options.CATEGORY_NAME)
	local credit = ui:Text(panel, 12, 'color.text.muted')
	credit:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -8)
	panel.credit = credit
	Options.legacyCredit = credit
	local openButton = ui:Button(panel, 'Open Haggler', 'primary')
	openButton:SetPoint('TOPLEFT', credit, 'BOTTOMLEFT', 0, -12)
	openButton:OnClick(openWindow)
	panel.openButton = openButton
	panel.toggles = {}
	for index, entry in ipairs(entries) do
		local button = ui:Button(panel, entry.label, 'secondary')
		button:SetPoint('TOPLEFT', openButton, 'BOTTOMLEFT', 0, -12 - (index - 1) * ROW_HEIGHT)
		button:OnClick(function()
			local settings = ns.host.Settings
			settings:Set(entry.moduleKey, entry.key, settings:Get(entry.moduleKey, entry.key) ~= true)
			refreshLegacyPanel(panel)
		end)
		panel.toggles[index] = { button = button, entry = entry }
	end
	panel:SetScript('OnShow', function()
		refreshLegacyPanel(panel)
	end)
	refreshLegacyPanel(panel)
	wow:AddLegacyOptionsPanel(panel)
	return panel
end

function refreshLegacyPanel(panel)
	refreshCredit()
	local settings = ns.host.Settings
	for _, toggle in ipairs(panel.toggles) do
		local isOn = settings:Get(toggle.entry.moduleKey, toggle.entry.key) == true
		toggle.button:SetLabel(string.format('%s, %s', toggle.entry.label, isOn and 'on' or 'off'))
	end
end

-- A switch names its module in brackets after it, unless the label already names it as a whole
-- word. Labels carry no brackets of their own, so the two never stack. The word frontier applies
-- only on a side whose edge is a letter or digit: a name ending in punctuation, like
-- "Sorter (by Author)", has no word edge there to find.
function switchLabel(label, moduleName)
	local name = moduleName:lower()
	local pattern = (name:find('^%w') and '%f[%w]' or '')
		.. name:gsub('%p', '%%%0')
		.. (name:find('%w$') and '%f[%W]' or '')
	if label:lower():find(pattern) then
		return label
	end
	return label .. ' (' .. moduleName .. ')'
end

function moduleLabel(moduleKey)
	local module = ns.host.Module(moduleKey)
	return module and module.definition.label or moduleKey
end

function openWindow()
	if ns.window and ns.host.IsEnabled('window') then
		ns.window:Open()
		return
	end
	ns.wow:Print('the Haggler window is turned off; /hag set window.enabled on turns it on.')
end
