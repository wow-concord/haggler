--[[
	Window: the Haggler frame, one window with two modes.

	At the auction house (AUCTION_HOUSE_SHOW until AUCTION_HOUSE_CLOSED) it can post, buy and
	cancel. How it shows there is the ahMode setting (WindowModel.placement):
	  takeover  Blizzard's window is made invisible (alpha 0; hiding it would close the auction
	            house) and Haggler's frame covers it; the "Blizzard" button gives it back. The
	            frame cannot be dragged then: Blizzard's invisible window under it would still
	            take clicks. When the interface hides and shows again (Alt+Z, a cinematic) the
	            takeover is applied again on show.
	  dock      Haggler opens beside the auction house window; always so when TradeSkillMaster
	            or Auctionator runs the auction house, so Haggler never fights them
	  manual    nothing opens by itself; /hag opens it, docked
	While Haggler's frame is closed at the auction house, a "Haggler" button sits on the auction
	house window to bring it back.

	The window the player switches to at the auction house is remembered in the ahView setting
	(account-wide, like every setting): the "Blizzard" button and a plain /hag that closes the
	frame there choose Blizzard's; any explicit window:Open there (the "Haggler" button, /hag,
	/hag open, the top bar, the options entry, Crafting) chooses Haggler's once it opened. The
	close button and Escape only close, they are no switch. The next visit opens the same one,
	after a /reload or restart too; nothing saved means Haggler's. Manual mode remembers nothing.
	When Haggler's frames fail to build, Blizzard's window shows for that visit and the saved
	choice stays. Docked, the frame goes right of the auction house, else left
	of it, else centred, and always stays on screen. A frame dragged elsewhere keeps that place
	per mode (docked, away) in the character's saved UI state.

	Blizzard's auction house UI loads on demand, so AUCTION_HOUSE_SHOW can come before its
	window is shown: the placement then waits a frame, and a hook on the window's OnShow
	(installed once the window exists) applies it as soon as it shows.

	A shift-clicked item (ChatEdit_InsertLink, post-hooked) goes to the shown tab's
	onItemLink when the window is open; Lookup and Buy fill their box when it has focus.

	The footer credits AHledger only while the view shows a price that used an AHledger
	figure: a tab calls ctx.setCredit(ctx.window:Credit()) for such a price, nil otherwise.

	Away from the auction house /hag opens it on saved data, with post and buy greyed out.

	Tabs come from the registry (WindowModel.newTabs): a tab file calls ns.window:AddTab{...}
	at load. A tab's container is built the first time it is shown; refresh runs on every show
	and whenever the window's mode changes. Frames are made on the first open, so a player who
	never opens the window pays nothing for it.

	  /hag          opens or closes the window
	  /hag open [tab]   opens it (on a tab: scan, lookup, rules, sell, buy)
]]
local _, ns = ...

local MODULE_KEY = 'window'
local EVENT_OWNER = 'window'
local FRAME_NAME = 'HagglerFrame'
local WIDTH, HEIGHT = 920, 680
local DOCK_GAP = 8
local HEADER_HEIGHT = 48
local TAB_HEIGHT = 40
local FOOTER_HEIGHT = 32
local PADDING = 16
-- The window's own events: a tab that lists one gets it from the window's handler, since an
-- owner has one handler per event and a second registration would replace the window's.
local WINDOW_EVENTS = { AUCTION_HOUSE_SHOW = true, AUCTION_HOUSE_CLOSED = true }

-- Helpers live at the bottom of the file; declared here so they stay local.
local buildFrame, buildTabStrip, showTab, refreshCurrentTab, onAuctionHouseShow, onAuctionHouseClosed
local placeFrame, restoreBlizzardFrame, updateHeader, otherAuctionAddon, dispatchTabEvent, ensureReturnButton
local updateReturnButton, runOpenCommand, openWhenBlizzardShows, ensureBlizzardShowHook, onItemLink
local dockPoint, savedPosition, savePosition, reapplyTakeover, rememberView, openAtAuctionHouse, openFrame
local attachToBlizzardFrame

local window = {
	tabs = ns.WindowModel.newTabs(),
	isAtAuctionHouse = false,
	placement = nil,
	hasHiddenBlizzard = false,
	currentTabKey = nil,
	containers = {},
}
ns.window = window

--- Adds a tab (see WindowModel.newTabs). Tab files call this at load.
function window:AddTab(tab)
	self.tabs:Add(tab)
end

--- Whether post, buy and cancel can run now.
function window:IsAtAuctionHouse()
	return self.isAtAuctionHouse
end

--- Opens the window, on a tab when given. An explicit open at the auction house is the player
--- choosing Haggler's window there, saved once it opened.
--- @param tabKey string|nil
function window:Open(tabKey)
	local isOpened = openFrame(self, tabKey)
	if isOpened then
		rememberView(self, 'haggler')
	end
	return isOpened
end

function window:Close()
	self.intendsTakeover = false
	if self.frame then
		self.frame:Hide()
	end
	restoreBlizzardFrame(self)
	updateReturnButton(self)
end

function window:Toggle()
	if self.frame and self.frame:IsShown() then
		rememberView(self, 'blizzard')
		self:Close()
		return false
	end
	return self:Open()
end

function window:IsOpen()
	return self.frame ~= nil and self.frame:IsShown()
end

--- Redraws the tab on show (after saved data changed, say).
function window:Refresh()
	if self:IsOpen() then
		refreshCurrentTab(self)
	end
end

--- A line in the footer.
function window:SetStatus(text)
	if self.footerText then
		self.footerText:SetText(text or '')
	end
end

--- The credit for the price source, to pass to SetCredit for a price that used its figures.
function window:Credit()
	local status = ns.prices and ns.prices:SourceStatus()
	return status and status.credit or ns.PriceData.DEFAULT_CREDIT
end

--- Shows the credit in the footer, or hides it when text is nil.
function window:SetCredit(text)
	if not self.creditText then
		return
	end
	self.creditText:SetText(text or '')
	self.creditText:SetShown(text ~= nil)
end

--- What a tab's build and refresh get.
function window:TabContext()
	if not self.tabContext then
		self.tabContext = {
			wow = ns.wow,
			ui = self.ui,
			theme = ns.theme,
			window = self,
			setting = function(key)
				return self.module:Setting(key)
			end,
			setStatus = function(text)
				self:SetStatus(text)
			end,
			setCredit = function(text)
				self:SetCredit(text)
			end,
		}
	end
	return self.tabContext
end

window.module = ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Haggler window',
	settings = {
		{
			key = 'ahMode',
			type = 'choice',
			label = 'At the auction house',
			default = 'takeover',
			choices = ns.WindowModel.AH_MODES,
		},
		{
			key = 'ahView',
			type = 'choice',
			label = 'Auction house opens in',
			note = 'the last one you switched to',
			default = ns.WindowModel.DEFAULT_AH_VIEW,
			choices = ns.WindowModel.AH_VIEWS,
			isHidden = function(settings)
				return settings:Get(MODULE_KEY, 'ahMode') == 'manual'
			end,
		},
		{
			key = 'guardrail',
			type = 'choice',
			label = 'Posting at a loss',
			default = ns.Guardrail.DEFAULT_BEHAVIOUR,
			choices = {
				{ value = 'confirm', label = 'Warn and ask to confirm' },
				{ value = 'warn', label = 'Warn' },
				{ value = 'off', label = 'Say nothing' },
			},
		},
		{
			key = 'duration',
			type = 'choice',
			label = 'Listing duration',
			default = '24',
			choices = ns.WindowModel.DURATIONS,
		},
		{
			key = 'vendorThresholdSilver',
			type = 'slider',
			label = 'Suggest the vendor unless the auction house nets this many silver more',
			default = ns.Guardrail.DEFAULT_THRESHOLD.copper / 100,
			min = 0,
			max = 10000,
		},
		{
			key = 'vendorThresholdPercent',
			type = 'slider',
			label = 'and this many percent more',
			default = ns.Guardrail.DEFAULT_THRESHOLD.percent,
			min = 0,
			max = 100,
		},
		{
			key = 'lastTab',
			type = 'choice',
			label = 'Tab shown when the window opens',
			default = 'sell',
			choices = {
				{ value = 'scan', label = 'Scan' },
				{ value = 'lookup', label = 'Lookup' },
				{ value = 'rules', label = 'Rules' },
				{ value = 'sell', label = 'Sell' },
				{ value = 'buy', label = 'Buy' },
				{ value = 'ledger', label = 'Ledger' },
				-- V2: only with the venture planner loaded. A saved 'ventures' stays saved without it
				-- (Settings reads it as the default and never drops it).
				ns.Ventures.hasPlanner and { value = 'ventures', label = 'Ventures' } or nil,
			},
		},
	},
	onEnable = function(module)
		local wow = ns.wow
		wow:OnEvent('AUCTION_HOUSE_SHOW', function()
			onAuctionHouseShow(window)
		end, EVENT_OWNER)
		wow:OnEvent('AUCTION_HOUSE_CLOSED', function()
			onAuctionHouseClosed(window)
		end, EVENT_OWNER)
		local seen = {}
		for _, tab in ipairs(window.tabs:List()) do
			for _, event in ipairs(tab.events or {}) do
				if not seen[event] and not WINDOW_EVENTS[event] then
					seen[event] = true
					wow:OnEvent(event, function(_, ...)
						dispatchTabEvent(window, event, ...)
					end, EVENT_OWNER)
				end
			end
		end
		-- A new scan or a rule change changes every price shown; the host drops these on disable.
		-- The books (Features/Tracking.lua) change the Ledger and Ventures tabs.
		for _, message in ipairs({
			'SCAN_READY',
			'DEFAULT_RULE_CHANGED',
			'RULES_CHANGED',
			'PRICE_TABLE_LOADED',
			'LEDGER_CHANGED',
			'VENTURE_UPDATED',
			'SESSION_RESET',
		}) do
			module:On(message, function()
				window:Refresh()
			end)
		end
		-- A hook cannot be removed: installed once, it checks the module on every call.
		if not window.hasItemLinkHook then
			window.hasItemLinkHook = wow:HookGlobalFunction('ChatEdit_InsertLink', function(link)
				onItemLink(window, link)
			end)
		end
		module:AddCommand('open', {
			usage = 'open [scan|lookup|rules|sell|buy|ledger]',
			help = 'Open the Haggler window (plain /hag opens and closes it)',
			run = function(args)
				return runOpenCommand(window, args)
			end,
		})
	end,
	onDisable = function()
		local wow = ns.wow
		wow:OffEvent('AUCTION_HOUSE_SHOW', EVENT_OWNER)
		wow:OffEvent('AUCTION_HOUSE_CLOSED', EVENT_OWNER)
		for _, tab in ipairs(window.tabs:List()) do
			for _, event in ipairs(tab.events or {}) do
				if not WINDOW_EVENTS[event] then
					wow:OffEvent(event, EVENT_OWNER)
				end
			end
		end
		window:Close()
		window.isAtAuctionHouse = false
		window.isPlacementPending = false
	end,
})

-- Helpers ---------------------------------------------------------------------------------

-- Builds, places and shows the frame; no view is saved (window:Open saves for explicit opens).
function openFrame(self, tabKey)
	if not self.module or not self.module:IsEnabled() then
		return false
	end
	buildFrame(self)
	placeFrame(self, self.isAtAuctionHouse and (self.placement == 'takeover' and 'takeover' or 'dock') or 'away')
	self.frame:Show()
	updateReturnButton(self)
	showTab(self, tabKey or self.currentTabKey or self.module:Setting('lastTab'))
	return true
end

function buildFrame(self)
	if self.frame then
		return
	end
	local wow, ui = ns.wow, ns.Widgets.new(ns.wow, ns.theme)
	self.ui = ui
	local frame = wow:CreateFrame('Frame', nil, nil, FRAME_NAME)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata('HIGH')
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag('LeftButton')
	frame:SetScript('OnDragStart', function()
		if self.placedAs ~= 'takeover' then
			frame:StartMoving()
		end
	end)
	frame:SetScript('OnDragStop', function()
		frame:StopMovingOrSizing()
		savePosition(self)
	end)
	frame:SetScript('OnHide', function()
		restoreBlizzardFrame(self)
		updateReturnButton(self)
	end)
	frame:SetScript('OnShow', function()
		reapplyTakeover(self)
	end)
	ui:Fill(frame, 'color.surface.base')
	ui:Border(frame, 'color.border.subtle')
	frame:Hide()
	self.frame = frame
	-- Escape closes it like any panel; the list is read by name.
	local specialFrames = wow:Global('UISpecialFrames')
	if type(specialFrames) == 'table' then
		table.insert(specialFrames, FRAME_NAME)
	end

	local title = ui:Text(frame, 17, 'color.text.title', ns.Widgets.TITLE_FACE)
	title:SetPoint('TOPLEFT', frame, 'TOPLEFT', PADDING, -14)
	title:SetText('Haggler')
	self.titleText = title
	self.modeText = ui:Text(frame, 13, 'color.text.muted')
	self.modeText:SetPoint('LEFT', title, 'RIGHT', PADDING, 0)

	local close = ui:Button(frame, 'x', 'ghost')
	close:SetWidth(32)
	close:SetPoint('TOPRIGHT', frame, 'TOPRIGHT', -8, -8)
	close:OnClick(function()
		self:Close()
	end)
	self.closeButton = close

	local blizzard = ui:Button(frame, "Blizzard's window", 'secondary')
	blizzard:SetPoint('RIGHT', close, 'LEFT', -8, 0)
	blizzard:OnClick(function()
		rememberView(self, 'blizzard')
		self:Close()
	end)
	self.blizzardButton = blizzard

	buildTabStrip(self, ui)

	local content = wow:CreateFrame('Frame', frame)
	content:SetPoint('TOPLEFT', frame, 'TOPLEFT', PADDING, -(HEADER_HEIGHT + TAB_HEIGHT + PADDING))
	content:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', -PADDING, FOOTER_HEIGHT + 8)
	self.content = content

	local footer = wow:CreateFrame('Frame', frame)
	footer:SetPoint('BOTTOMLEFT', frame, 'BOTTOMLEFT', 1, 1)
	footer:SetPoint('BOTTOMRIGHT', frame, 'BOTTOMRIGHT', -1, 1)
	footer:SetHeight(FOOTER_HEIGHT)
	ui:Fill(footer, 'color.surface.sunken')
	self.footerText = ui:Text(footer, 13, 'color.text.secondary')
	self.footerText:SetPoint('LEFT', footer, 'LEFT', PADDING, 0)
	local credit = ui:Text(footer, 12, 'color.text.muted')
	credit:SetPoint('RIGHT', footer, 'RIGHT', -PADDING, 0)
	credit:Hide()
	self.creditText = credit
end

function buildTabStrip(self, ui)
	local strip = ns.wow:CreateFrame('Frame', self.frame)
	strip:SetPoint('TOPLEFT', self.frame, 'TOPLEFT', 1, -HEADER_HEIGHT)
	strip:SetPoint('TOPRIGHT', self.frame, 'TOPRIGHT', -1, -HEADER_HEIGHT)
	strip:SetHeight(TAB_HEIGHT)
	local divider = strip:CreateTexture(nil, 'BORDER')
	local color = ns.theme:Color('color.border.subtle')
	divider:SetColorTexture(color.r, color.g, color.b, color.a)
	divider:SetPoint('BOTTOMLEFT', strip, 'BOTTOMLEFT')
	divider:SetPoint('BOTTOMRIGHT', strip, 'BOTTOMRIGHT')
	divider:SetHeight(1)
	self.tabButtons = {}
	local previous
	for _, tab in ipairs(self.tabs:List()) do
		local button = ui:Button(strip, tab.label, 'tab')
		button:SetHeight(TAB_HEIGHT)
		if previous then
			button:SetPoint('LEFT', previous, 'RIGHT', 0, 0)
		else
			button:SetPoint('LEFT', strip, 'LEFT', 8, 0)
		end
		button:OnClick(function()
			showTab(self, tab.key)
		end)
		self.tabButtons[tab.key] = button
		previous = button
	end
end

function showTab(self, tabKey)
	local tab = self.tabs:Get(tabKey or '') or self.tabs:List()[1]
	if not tab then
		return
	end
	for key, container in pairs(self.containers) do
		if key ~= tab.key then
			container:Hide()
		end
	end
	for key, button in pairs(self.tabButtons) do
		button:SetSelected(key == tab.key)
	end
	local container = self.containers[tab.key]
	if not container then
		container = ns.wow:CreateFrame('Frame', self.content)
		container:SetAllPoints(self.content)
		self.containers[tab.key] = container
		tab.build(container, self:TabContext())
	end
	container:Show()
	self.currentTabKey = tab.key
	self:SetCredit(nil)
	if self.module:Setting('lastTab') ~= tab.key then
		pcall(self.module.SetSetting, self.module, 'lastTab', tab.key)
	end
	refreshCurrentTab(self)
end

function refreshCurrentTab(self)
	local tab = self.currentTabKey and self.tabs:Get(self.currentTabKey)
	local container = tab and self.containers[tab.key]
	updateHeader(self)
	if tab and container and tab.refresh then
		tab.refresh(container, self:TabContext())
	end
end

function dispatchTabEvent(self, event, ...)
	for _, tab in ipairs(self.tabs:List()) do
		local container = self.containers[tab.key]
		local listens = false
		for _, tabEvent in ipairs(tab.events or {}) do
			listens = listens or tabEvent == event
		end
		if listens and container and tab.onEvent then
			tab.onEvent(container, self:TabContext(), event, ...)
		end
	end
end

function updateHeader(self)
	if not self.modeText then
		return
	end
	if self.isAtAuctionHouse then
		self.modeText:SetText('At the auction house')
	else
		self.modeText:SetText('Away: saved data; posting and buying need the auction house')
	end
	if self.hasHiddenBlizzard then
		self.blizzardButton:Show()
	else
		self.blizzardButton:Hide()
	end
end

function onAuctionHouseShow(self)
	self.isAtAuctionHouse = true
	self.placement = ns.WindowModel.placement(self.module:Setting('ahMode'), otherAuctionAddon())
	ensureReturnButton(self)
	ensureBlizzardShowHook(self)
	dispatchTabEvent(self, 'AUCTION_HOUSE_SHOW')
	if not ns.WindowModel.opensAtAuctionHouse(self.placement, self.module:Setting('ahView')) then
		updateReturnButton(self)
		self:Refresh()
		if not self.returnButton then
			-- Blizzard's window loads on demand: put the button on it once it exists.
			ns.wow:After(0, function()
				attachToBlizzardFrame(self)
			end)
		end
		return
	end
	local blizzardFrame = ns.wow:Global('AuctionHouseFrame')
	if type(blizzardFrame) == 'table' and blizzardFrame:IsShown() then
		ensureBlizzardShowHook(self)
		openAtAuctionHouse(self)
		return
	end
	-- Blizzard's window is not shown yet (its UI loads on demand): place once it is.
	self.isPlacementPending = true
	ensureBlizzardShowHook(self)
	if not ns.wow:After(0, function()
		openWhenBlizzardShows(self)
	end) then
		openWhenBlizzardShows(self)
	end
end

-- Opens a placement that waited for Blizzard's window, once (the hook or the next frame).
function openWhenBlizzardShows(self)
	if not self.isPlacementPending or not self.isAtAuctionHouse then
		return
	end
	self.isPlacementPending = false
	ensureBlizzardShowHook(self)
	ensureReturnButton(self)
	openAtAuctionHouse(self)
end

-- The Haggler button and the OnShow hook for a visit that left Blizzard's window up, once
-- Blizzard's window exists (its UI loads on demand).
function attachToBlizzardFrame(self)
	if not self.isAtAuctionHouse or not self.module:IsEnabled() then
		return
	end
	ensureBlizzardShowHook(self)
	ensureReturnButton(self)
	updateReturnButton(self)
end

-- Opens Haggler's frame by itself at the auction house, saving no view. When its frames fail to
-- build, Blizzard's window shows for this visit instead and the saved ahView stays as it is; the
-- error is raised again after the fallback so the caller's handler reports it.
function openAtAuctionHouse(self)
	local ok, err = pcall(openFrame, self)
	if not ok then
		self:Close()
		error(err, 0)
	end
end

-- Saves the window the player switched to at the auction house; elsewhere, and in manual mode,
-- it is not a switch.
function rememberView(self, view)
	if not self.isAtAuctionHouse or self.placement == 'manual' then
		return
	end
	if self.module:Setting('ahView') ~= view then
		pcall(self.module.SetSetting, self.module, 'ahView', view)
	end
end

function ensureBlizzardShowHook(self)
	if self.hasBlizzardShowHook then
		return
	end
	local blizzardFrame = ns.wow:Global('AuctionHouseFrame')
	if type(blizzardFrame) ~= 'table' then
		return
	end
	self.hasBlizzardShowHook = ns.wow:HookFrameScript(blizzardFrame, 'OnShow', function()
		if not self.module:IsEnabled() or not self.isAtAuctionHouse then
			return
		end
		ensureReturnButton(self)
		if self.isPlacementPending then
			openWhenBlizzardShows(self)
		elseif self:IsOpen() and self.placedAs == 'away' and self.placement ~= 'manual' then
			-- Opened by the next-frame fallback before Blizzard's window showed: place it now.
			openFrame(self)
		else
			updateReturnButton(self)
		end
	end)
end

function onAuctionHouseClosed(self)
	self.isAtAuctionHouse = false
	self.isPlacementPending = false
	local wasOpen = self:IsOpen()
	restoreBlizzardFrame(self)
	if self.frame then
		self.frame:Hide()
	end
	if self.returnButton then
		self.returnButton:Hide()
	end
	dispatchTabEvent(self, 'AUCTION_HOUSE_CLOSED')
	if wasOpen then
		self:SetStatus('The auction house closed.')
	end
end

-- 'takeover' covers Blizzard's window; 'dock' sits beside the auction house; 'away' centres.
-- A place the player dragged the frame to wins for dock and away.
function placeFrame(self, how)
	local frame = self.frame
	local blizzardFrame = ns.wow:Global('AuctionHouseFrame')
	local isBlizzardShown = type(blizzardFrame) == 'table' and blizzardFrame:IsShown()
	local uiParent = ns.wow:Global('UIParent')
	frame:ClearAllPoints()
	local isTakeover = how == 'takeover' and isBlizzardShown
	self.placedAs = isTakeover and 'takeover' or (how == 'dock' and isBlizzardShown and 'dock' or 'away')
	self.intendsTakeover = isTakeover
	local saved = savedPosition(self.placedAs)
	if isTakeover then
		blizzardFrame:SetAlpha(0)
		self.hasHiddenBlizzard = true
		frame:SetPoint('TOPLEFT', blizzardFrame, 'TOPLEFT')
	elseif saved then
		restoreBlizzardFrame(self)
		frame:SetPoint(saved.point, uiParent, saved.relativePoint, saved.x, saved.y)
	elseif self.placedAs == 'dock' then
		restoreBlizzardFrame(self)
		local point, relativePoint, x = dockPoint(blizzardFrame, uiParent)
		if point then
			frame:SetPoint(point, blizzardFrame, relativePoint, x, 0)
		else
			frame:SetPoint('CENTER', uiParent, 'CENTER')
		end
	else
		restoreBlizzardFrame(self)
		frame:SetPoint('CENTER', uiParent, 'CENTER')
	end
	updateHeader(self)
end

-- Right of the auction house when the frame fits there, else left of it; nil when neither.
-- An edge the client cannot say is taken as room enough (the frame is clamped to the screen).
function dockPoint(blizzardFrame, uiParent)
	local screenWidth = uiParent and uiParent.GetWidth and uiParent:GetWidth()
	local right = blizzardFrame.GetRight and blizzardFrame:GetRight()
	local left = blizzardFrame.GetLeft and blizzardFrame:GetLeft()
	if not (screenWidth and right) or right + DOCK_GAP + WIDTH <= screenWidth then
		return 'TOPLEFT', 'TOPRIGHT', DOCK_GAP
	end
	if left and left - DOCK_GAP - WIDTH >= 0 then
		return 'TOPRIGHT', 'TOPLEFT', -DOCK_GAP
	end
	return nil
end

function savedPosition(mode)
	local positions = ns.store and ns.store:Ui().windowPositions
	local saved = type(positions) == 'table' and positions[mode]
	if type(saved) ~= 'table' or type(saved.point) ~= 'string' or type(saved.relativePoint) ~= 'string' then
		return nil
	end
	if type(saved.x) ~= 'number' or type(saved.y) ~= 'number' then
		return nil
	end
	return saved
end

-- Keeps where the player dropped the frame, for the mode it is in (never takeover).
function savePosition(self)
	if self.placedAs == 'takeover' or not ns.store then
		return
	end
	local point, _, relativePoint, x, y = self.frame:GetPoint(1)
	if type(point) ~= 'string' or type(x) ~= 'number' or type(y) ~= 'number' then
		return
	end
	local ui = ns.store:Ui()
	ui.windowPositions = type(ui.windowPositions) == 'table' and ui.windowPositions or {}
	ui.windowPositions[self.placedAs] = { point = point, relativePoint = relativePoint or point, x = x, y = y }
end

-- On show (after the interface hid and showed again): a takeover that was dropped by the hide
-- is applied again.
function reapplyTakeover(self)
	if not (self.intendsTakeover and self.isAtAuctionHouse) or self.hasHiddenBlizzard then
		return
	end
	local blizzardFrame = ns.wow:Global('AuctionHouseFrame')
	if type(blizzardFrame) ~= 'table' or not blizzardFrame:IsShown() then
		return
	end
	blizzardFrame:SetAlpha(0)
	self.hasHiddenBlizzard = true
	updateHeader(self)
	updateReturnButton(self)
end

function restoreBlizzardFrame(self)
	if not self.hasHiddenBlizzard then
		return
	end
	self.hasHiddenBlizzard = false
	local blizzardFrame = ns.wow:Global('AuctionHouseFrame')
	if type(blizzardFrame) == 'table' then
		blizzardFrame:SetAlpha(1)
	end
	updateHeader(self)
end

-- The "Haggler" button on the auction house window, shown while Haggler's frame is closed.
function ensureReturnButton(self)
	if self.returnButton then
		return
	end
	local blizzardFrame = ns.wow:Global('AuctionHouseFrame')
	if type(blizzardFrame) ~= 'table' then
		return
	end
	self.ui = self.ui or ns.Widgets.new(ns.wow, ns.theme)
	local button = self.ui:Button(ns.wow:Global('UIParent'), 'Haggler', 'primary')
	button:SetFrameStrata('HIGH')
	button:SetPoint('TOPRIGHT', blizzardFrame, 'TOPRIGHT', -40, -2)
	button:OnClick(function()
		self:Open()
	end)
	button:Hide()
	self.returnButton = button
end

function updateReturnButton(self)
	if not self.returnButton then
		return
	end
	if self.isAtAuctionHouse and not self:IsOpen() then
		self.returnButton:Show()
	else
		self.returnButton:Hide()
	end
end

function otherAuctionAddon()
	for _, name in ipairs(ns.WindowModel.OTHER_AH_ADDONS) do
		if ns.wow:IsAddOnLoaded(name) then
			return name
		end
	end
	return nil
end

-- A shift-clicked item: the shown tab takes it when it wants it (its box has focus).
function onItemLink(self, link)
	if not self.module:IsEnabled() or not self:IsOpen() then
		return
	end
	local tab = self.currentTabKey and self.tabs:Get(self.currentTabKey)
	local container = tab and self.containers[tab.key]
	if container and tab.onItemLink then
		tab.onItemLink(container, self:TabContext(), link)
	end
end

function runOpenCommand(self, args)
	local tabKey = args and args[1]
	if tabKey and not self.tabs:Get(tabKey) then
		return { 'No tab called ' .. tabKey .. '.' }
	end
	self:Open(tabKey)
	return {}
end
