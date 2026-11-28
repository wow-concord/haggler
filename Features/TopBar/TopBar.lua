--[[
	TopBar: a slim bar across the top of the screen with gold and session profit, the rule
	switcher, the scan status and shortcuts (window, sell queue, flips, settings). The same
	widgets go out as a LibDataBroker-1.1 feed (Feed.lua).

	Settings: visibility (always / only at the auction house, a vendor or a mailbox / hidden),
	locked (no dragging), one toggle per widget, the broker feed, and focusKey: one binding
	(keyboard or gamepad) that gives the bar the pad through Host/Input. While focused the d-pad
	and arrows move between widgets, A / Enter presses one, B / Escape leaves.

	The bar holds no protected action: the shortcuts open Haggler's window, which keeps post and
	buy on its own buttons. A dragged bar keeps its place in the character's saved UI state
	(ui.topBar). Frames are made the first time the bar shows, parented to UIParent (UI scale,
	Alt-Z).

	Session profit is this character's, like the gold beside it: the ledger's net since the
	session start, counting the character's own events only (Ledger.netSince, no decode), cached
	until the start, the ledger or the character changes. Nothing is read while neither the bar
	nor the feed shows. A ticker (TICK_SECONDS, only while either shows) keeps the scan age and
	the session start (midnight, the daily reset) current.

	  ns.topBar:Refresh()   redraws (the bar and the feed)
	  ns.topBar:Texts() -> { gold, rule, scan }
	  ns.topBar:Focus()     what the focus binding runs
]]
local _, ns = ...

local MODULE_KEY = 'topbar'
local EVENT_OWNER = 'topbar'
local FRAME_NAME = 'HagglerTopBar'
local BAR_HEIGHT = 36
local TICK_SECONDS = 60
local GAP = 4
local PADDING = 4
local PLACE_EVENTS = {
	AUCTION_HOUSE_SHOW = { 'auctionHouse', true },
	AUCTION_HOUSE_CLOSED = { 'auctionHouse', false },
	MERCHANT_SHOW = { 'merchant', true },
	MERCHANT_CLOSED = { 'merchant', false },
	MAIL_SHOW = { 'mailbox', true },
	MAIL_CLOSED = { 'mailbox', false },
}
local BUS_MESSAGES = { 'SCAN_READY', 'DEFAULT_RULE_CHANGED', 'RULES_CHANGED', 'LEDGER_CHANGED', 'SESSION_RESET' }
local WIDGET_SETTINGS = { gold = 'showGold', rule = 'showRule', scan = 'showScan' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildFrame, layout, applyVisibility, sessionProfit, cycleRule, runShortcut, openWindow
local savePosition, placeFrame, moveFocus, paintFocus, shownButtons, allButtons, keepFocusOnShownWidget, applyFocusBinding, inputService
local hookTooltip, updateFeed, isFeedOn, startTicker, playerKey

local topBar = { places = {}, focusIndex = 1 }

ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Top bar',
	settings = {
		{
			key = 'visibility',
			type = 'choice',
			label = 'Show the top bar',
			default = 'always',
			choices = ns.TopBarModel.VISIBILITY,
		},
		{ key = 'locked', type = 'toggle', label = 'Lock the bar in place', default = false },
		{ key = 'showGold', type = 'toggle', label = 'Gold and session profit', default = true },
		{ key = 'showRule', type = 'toggle', label = 'Rule switcher', default = true },
		{ key = 'showScan', type = 'toggle', label = 'Scan status', default = true },
		{ key = 'showShortcuts', type = 'toggle', label = 'Shortcuts', default = true },
		{ key = 'feed', type = 'toggle', label = 'Broker feed (LibDataBroker)', default = true },
		{ key = 'focusKey', type = 'binding', label = 'Focus the top bar', default = '' },
	},
	onEnable = function(module)
		topBar.module = module
		for event, place in pairs(PLACE_EVENTS) do
			ns.wow:OnEvent(event, function()
				topBar.places[place[1]] = place[2]
				topBar:Refresh()
			end, EVENT_OWNER)
		end
		ns.wow:OnEvent('PLAYER_MONEY', function()
			topBar:Refresh()
		end, EVENT_OWNER)
		for _, message in ipairs(BUS_MESSAGES) do
			module:On(message, function()
				topBar:Refresh()
			end)
		end
		module:On(ns.Host.SETTINGS_CHANGED, function(_, moduleKey, key)
			if moduleKey == MODULE_KEY and key == 'focusKey' then
				applyFocusBinding()
			end
			if moduleKey == MODULE_KEY or moduleKey == 'sessions' then
				topBar:Refresh()
			end
		end)
		topBar.feed = topBar.feed
			or ns.TopBarFeed.new(ns.wow:Library('LibDataBroker-1.1'), {
				onLauncher = function(button)
					runShortcut(button == 'RightButton' and 'settings' or 'frame')
				end,
				onRule = function(direction)
					cycleRule(direction)
				end,
				onScan = function()
					runShortcut('scan')
				end,
				tooltipLines = function(key)
					return topBar:TooltipLines(key)
				end,
			})
		applyFocusBinding()
		ns.topBar = topBar
		topBar:Refresh()
	end,
	onDisable = function()
		for event in pairs(PLACE_EVENTS) do
			ns.wow:OffEvent(event, EVENT_OWNER)
		end
		ns.wow:OffEvent('PLAYER_MONEY', EVENT_OWNER)
		local input = inputService()
		input:Unbind(MODULE_KEY)
		paintFocus(topBar, nil)
		input:ReleaseFocus(MODULE_KEY)
		if topBar.feed then
			topBar.feed:SetActive(false)
		end
		if topBar.frame then
			topBar.frame:Hide()
		end
		ns.topBar = nil
	end,
})

--- What the widgets read now.
--- @return table { gold, rule, scan } strings
function topBar:Texts()
	local Model = ns.TopBarModel
	local profit = sessionProfit()
	local ruleId = ns.store and ns.store:DefaultRuleId()
	local rule = ruleId and ns.store:Rule(ruleId)
	return {
		gold = Model.goldText(ns.wow:Money(), profit),
		rule = Model.ruleText(rule and rule.name),
		scan = Model.scanText(ns.scanControl.Status(), ns.wow:Now()),
	}
end

--- Tooltip lines for a widget.
function topBar:TooltipLines(key)
	if key == 'gold' then
		local profit, modeLabel, note = sessionProfit()
		return ns.TopBarModel.profitTooltip(profit, modeLabel, note)
	elseif key == 'rule' then
		return { 'Default rule', 'Click: next rule' }
	elseif key == 'scan' then
		return ns.scanControl.StatusLines()
	end
	return {}
end

function topBar:Refresh()
	if not self.module or not self.module:IsEnabled() then
		return
	end
	local isBarShown = ns.TopBarModel.isShown(self.module:Setting('visibility'), self.places)
	if self.feed then
		self.feed:SetActive(isFeedOn(self))
	end
	if not isBarShown then
		applyVisibility(self, false)
	end
	if not isBarShown and not isFeedOn(self) then
		return
	end
	local texts = self:Texts()
	updateFeed(self, texts)
	startTicker(self)
	if not isBarShown then
		return
	end
	buildFrame(self)
	self.buttons.gold:SetLabel(texts.gold)
	self.buttons.rule:SetLabel(texts.rule)
	self.buttons.scan:SetLabel(texts.scan)
	layout(self)
	applyVisibility(self, true)
end

--- Gives the bar the pad and arrow keys (the focusKey binding).
function topBar:Focus()
	if not self.frame or not self.frame:IsShown() then
		return false
	end
	local input = inputService()
	if input:HasFocus(MODULE_KEY) then
		input:ReleaseFocus(MODULE_KEY)
		paintFocus(self, nil)
		return false
	end
	local isFocused = input:RequestFocus(MODULE_KEY, {
		next = function()
			moveFocus(self, 1)
		end,
		previous = function()
			moveFocus(self, -1)
		end,
		activate = function()
			local button = shownButtons(self)[self.focusIndex]
			if button then
				button:Click()
			end
		end,
		leave = function()
			paintFocus(self, nil)
		end,
	})
	if isFocused then
		self.focusIndex = 1
		paintFocus(self, self.focusIndex)
	end
	return isFocused
end

-- Helpers ---------------------------------------------------------------------------------

function buildFrame(self)
	if self.frame then
		return
	end
	local wow, ui = ns.wow, ns.Widgets.new(ns.wow, ns.theme)
	self.ui = ui
	local frame = wow:CreateFrame('Frame', wow.env.UIParent, nil, FRAME_NAME)
	frame:SetHeight(BAR_HEIGHT)
	frame:SetFrameStrata('MEDIUM')
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag('LeftButton')
	frame:SetScript('OnDragStart', function()
		if not self.module:Setting('locked') then
			frame:StartMoving()
		end
	end)
	frame:SetScript('OnDragStop', function()
		frame:StopMovingOrSizing()
		savePosition(self)
	end)
	ui:Fill(frame, 'color.surface.base')
	ui:Border(frame, 'color.border.subtle')
	self.frame = frame
	self.buttons = {
		gold = ui:Button(frame, '', 'ghost'),
		rule = ui:Button(frame, '', 'ghost'),
		scan = ui:Button(frame, '', 'ghost'),
	}
	self.buttons.gold:OnClick(function()
		runShortcut('frame')
	end)
	self.buttons.rule:OnClick(function()
		cycleRule(1)
	end)
	self.buttons.scan:OnClick(function()
		runShortcut('scan')
	end)
	for key, button in pairs(self.buttons) do
		hookTooltip(button, key)
	end
	self.shortcuts = {}
	for _, shortcut in ipairs(ns.TopBarModel.SHORTCUTS) do
		local button = ui:Button(frame, shortcut.label, 'secondary')
		button:OnClick(function()
			runShortcut(shortcut.key)
		end)
		self.shortcuts[#self.shortcuts + 1] = button
	end
	placeFrame(self)
end

-- Lays the shown widgets out left to right and sizes the bar to them.
function layout(self)
	local module = self.module
	local order = {}
	for _, key in ipairs({ 'gold', 'rule', 'scan' }) do
		local button = self.buttons[key]
		local isShown = module:Setting(WIDGET_SETTINGS[key]) ~= false
		button:SetShown(isShown)
		if isShown then
			order[#order + 1] = button
		end
	end
	local showShortcuts = module:Setting('showShortcuts') ~= false
	for _, button in ipairs(self.shortcuts) do
		button:SetShown(showShortcuts)
		if showShortcuts then
			order[#order + 1] = button
		end
	end
	local x = PADDING
	for _, button in ipairs(order) do
		button:ClearAllPoints()
		button:SetPoint('LEFT', self.frame, 'LEFT', x, 0)
		x = x + (button:GetWidth() or 0) + GAP
	end
	self.frame:SetWidth(math.max(x - GAP + PADDING, BAR_HEIGHT))
	self.order = order
	keepFocusOnShownWidget(self)
end

-- A widget switched off takes its mark with it: the focus stays on a shown widget (the same
-- place, or the last one), and with none shown the bar lets go of the pad.
function keepFocusOnShownWidget(self)
	local input = inputService()
	if not input:HasFocus(MODULE_KEY) then
		paintFocus(self, nil)
		return
	end
	local count = #self.order
	if count == 0 then
		paintFocus(self, nil)
		input:ReleaseFocus(MODULE_KEY)
		return
	end
	self.focusIndex = math.min(math.max(self.focusIndex, 1), count)
	paintFocus(self, self.focusIndex)
end

function applyVisibility(self, isShown)
	if not self.frame then
		return
	end
	if isShown then
		self.frame:Show()
		return
	end
	self.frame:Hide()
	paintFocus(self, nil)
	inputService():ReleaseFocus(MODULE_KEY)
end

-- Session profit (ledger net since the session's start), the mode's label and the fallback note.
function sessionProfit()
	local sessions = ns.sessions
	local marketKey = ns.prices and ns.prices:MarketKey()
	local market = marketKey and ns.store and ns.store:Market(marketKey)
	if not sessions or not market then
		return nil
	end
	local start, note = sessions:Start(ns.wow:Now())
	local char = playerKey()
	local count = type(market.ledger) == 'table' and #market.ledger or 0
	local cache = topBar.profitCache
	local isCached = cache
		and cache.start == start
		and cache.count == count
		and cache.char == char
		and cache.market == market
	if not isCached then
		cache = { start = start, count = count, char = char, market = market }
		cache.net = char and ns.Ledger.netSince(market, start, char) or nil
		topBar.profitCache = cache
	end
	-- Days older than the ledger keeps are summaries without a character (Ledger.netSince).
	local foldedBefore = ns.wow:Now() - ns.Ledger.KEEP_DAYS * ns.Ledger.SECONDS_PER_DAY
	if start < foldedBefore then
		local folded = string.format('days over %d back count every character', ns.Ledger.KEEP_DAYS)
		note = note and (note .. '; ' .. folded) or folded
	end
	return cache.net, sessions:ModeLabel(), note
end

function cycleRule(direction)
	local store = ns.store
	if not store or not topBar.module then
		return
	end
	local current = store:DefaultRuleId()
	local ids = store:ShownRules('bar')
	if #ids < 2 then
		ids = store:RuleIds()
	end
	local nextId = ns.TopBarModel.nextRule(ids, current, direction)
	if nextId and nextId ~= current and store:SetDefaultRule(nextId) then
		topBar.module:Send('DEFAULT_RULE_CHANGED', nextId)
	end
end

function runShortcut(key)
	if key == 'settings' then
		if ns.Options and ns.Options.category then
			ns.wow:OpenOptionsCategory(ns.Options.category)
		end
		return
	end
	for _, shortcut in ipairs(ns.TopBarModel.SHORTCUTS) do
		if shortcut.key == key and shortcut.tab then
			return openWindow(shortcut.tab)
		end
	end
	if key == 'scan' then
		return openWindow('scan')
	end
	local window = ns.window
	if window then
		window:Toggle()
	end
end

function openWindow(tabKey)
	local window = ns.window
	if window then
		window:Open(tabKey)
	end
end

-- The bar's place: where the player dropped it, else the top middle of the screen.
function placeFrame(self)
	local frame = self.frame
	local saved = ns.store and ns.store:Ui().topBar
	frame:ClearAllPoints()
	local isSaved = type(saved) == 'table' and type(saved.point) == 'string'
	if isSaved and type(saved.x) == 'number' and type(saved.y) == 'number' then
		frame:SetPoint(saved.point, ns.wow.env.UIParent, saved.relativePoint or saved.point, saved.x, saved.y)
		return
	end
	frame:SetPoint('TOP', ns.wow.env.UIParent, 'TOP', 0, -4)
end

function savePosition(self)
	local point, _, relativePoint, x, y = self.frame:GetPoint(1)
	if not ns.store or type(point) ~= 'string' or type(x) ~= 'number' or type(y) ~= 'number' then
		return
	end
	ns.store:Ui().topBar = { point = point, relativePoint = relativePoint or point, x = x, y = y }
end

function moveFocus(self, step)
	local count = #shownButtons(self)
	if count == 0 then
		return
	end
	self.focusIndex = ((self.focusIndex - 1 + step) % count) + 1
	paintFocus(self, self.focusIndex)
end

-- Marks the shown widget at index and clears every other one, shown or not, so a widget
-- switched off keeps no mark to show when it comes back.
function paintFocus(self, index)
	local focusedButton = index and shownButtons(self)[index] or nil
	for _, button in ipairs(allButtons(self)) do
		button:SetFocused(button == focusedButton)
	end
end

function allButtons(self)
	if not self.buttons then
		return {}
	end
	local buttons = { self.buttons.gold, self.buttons.rule, self.buttons.scan }
	for _, button in ipairs(self.shortcuts or {}) do
		buttons[#buttons + 1] = button
	end
	return buttons
end

function shownButtons(self)
	return self.order or {}
end

function applyFocusBinding()
	local module = topBar.module
	if not module then
		return
	end
	inputService():Bind(MODULE_KEY, module:Setting('focusKey'), function()
		topBar:Focus()
	end)
end

-- Input is shared by every feature that binds keys; the first that needs it makes it.
function inputService()
	ns.input = ns.input or ns.Input.new(ns.wow)
	return ns.input
end

function hookTooltip(button, key)
	button:HookScript('OnEnter', function()
		local tooltip = ns.wow:Global('GameTooltip')
		if type(tooltip) ~= 'table' then
			return
		end
		tooltip:SetOwner(button, 'ANCHOR_BOTTOM')
		for _, line in ipairs(topBar:TooltipLines(key)) do
			tooltip:AddLine(line)
		end
		tooltip:Show()
	end)
	button:HookScript('OnLeave', function()
		local tooltip = ns.wow:Global('GameTooltip')
		if type(tooltip) == 'table' then
			tooltip:Hide()
		end
	end)
end

function updateFeed(self, texts)
	if self.feed and isFeedOn(self) then
		self.feed:Update(texts)
	end
end

function isFeedOn(self)
	return self.feed ~= nil and self.module:Setting('feed') ~= false
end

-- One timer at a time; it stops itself once neither the bar nor the feed shows.
function startTicker(self)
	if self.isTicking then
		return
	end
	self.isTicking = true
	local function tick()
		self.isTicking = false
		local module = self.module
		if not module or not module:IsEnabled() or ns.topBar ~= self then
			return
		end
		self:Refresh()
	end
	if not ns.wow:After(TICK_SECONDS, tick) then
		self.isTicking = false
	end
end

-- 'Name-Realm', as the ledger's events carry it; nil when the client cannot say.
function playerKey()
	return ns.store and ns.store:CharacterKey(ns.wow:Player()) or nil
end
