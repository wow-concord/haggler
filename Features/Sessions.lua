--[[
	Sessions: what "this session" means for session profit, shared by the Ledger tab and the top
	bar. The player picks a mode (Ledger.SESSION_MODES); the start points the clock cannot give
	(the login, the last Reset, the last time the auction house closed) are kept per character in
	the saved `sessions` key, so they survive a /reload. The login is the last
	PLAYER_ENTERING_WORLD with isInitialLogin; a /reload keeps it.

	  ns.sessions:Start(now?) -> start, note|nil, mode   where the session starts (Ledger.sessionStart)
	  ns.sessions:Mode() · :SetMode(mode) · :ModeLabel(mode?)
	  ns.sessions:Reset()     starts a new session now and switches to the 'manual' mode

	Reset and a mode change send SESSION_RESET (start) on the bus, so every view of session
	profit redraws from the new start.
]]
local _, ns = ...

local MODULE_KEY = 'sessions'
local EVENT_OWNER = 'sessions'
local SESSION_RESET = 'SESSION_RESET'

-- Helpers live at the bottom of the file; declared here so they stay local.
local sessionPoints, charKey, isMode, isFiniteTime, moveLegacyPoints

local Sessions = {}

ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Sessions',
	category = 'core',
	canDisable = false,
	settings = {
		{
			key = 'mode',
			type = 'choice',
			label = 'Session profit counts',
			default = 'login',
			choices = ns.Ledger.SESSION_MODES,
		},
	},
	onEnable = function(module)
		Sessions.module = module
		moveLegacyPoints()
		local loginPoints = sessionPoints()
		if loginPoints and not isFiniteTime(loginPoints.loginAt) then
			loginPoints.loginAt = ns.wow:Now()
		end
		ns.wow:OnEvent('PLAYER_ENTERING_WORLD', function(_, isInitialLogin)
			local current = sessionPoints()
			if current and isInitialLogin then
				current.loginAt = ns.wow:Now()
			end
		end, EVENT_OWNER)
		ns.wow:OnEvent('AUCTION_HOUSE_CLOSED', function()
			local points = sessionPoints()
			if points then
				points.ahLeftAt = ns.wow:Now()
			end
		end, EVENT_OWNER)
		ns.sessions = Sessions
	end,
	onDisable = function()
		ns.wow:OffEvent('AUCTION_HOUSE_CLOSED', EVENT_OWNER)
		ns.wow:OffEvent('PLAYER_ENTERING_WORLD', EVENT_OWNER)
		ns.sessions = nil
	end,
})

--- Where the session starts in the chosen mode.
--- @param now number|nil unix seconds (now by default)
--- @return number start
--- @return string|nil note why the start is a fallback
--- @return string mode
function Sessions:Start(now)
	now = now or ns.wow:Now()
	local mode = self:Mode()
	local points = sessionPoints() or {}
	local start, note = ns.Ledger.sessionStart(mode, {
		now = now,
		loginAt = isFiniteTime(points.loginAt) and points.loginAt or nil,
		resets = ns.wow:ResetTimes(now),
		ahLeftAt = points.ahLeftAt,
		resetAt = points.resetAt,
	})
	return start, note, mode
end

function Sessions:Mode()
	local mode = self.module and self.module:Setting('mode')
	return isMode(mode) and mode or 'login'
end

--- Switches the mode; the session restarts from that mode's start.
function Sessions:SetMode(mode)
	if not isMode(mode) then
		error('Sessions:SetMode: unknown mode ' .. tostring(mode), 2)
	end
	if mode == self:Mode() then
		return
	end
	self.module:SetSetting('mode', mode)
	self.module:Send(SESSION_RESET, (self:Start()))
end

function Sessions:ModeLabel(mode)
	mode = mode or self:Mode()
	for _, choice in ipairs(ns.Ledger.SESSION_MODES) do
		if choice.value == mode then
			return choice.label
		end
	end
	return mode
end

--- Starts a new session now.
function Sessions:Reset()
	local now = ns.wow:Now()
	local points = sessionPoints()
	if points then
		points.resetAt = now
	end
	if self:Mode() ~= 'manual' then
		self.module:SetSetting('mode', 'manual')
	end
	self.module:Send(SESSION_RESET, now)
end

-- Helpers ---------------------------------------------------------------------------------

function sessionPoints()
	local player = ns.wow:Player()
	local key = charKey(player)
	return key and ns.store:Session(key, player.server) or nil
end

function charKey(player)
	return ns.store and ns.store:CharacterKey(player) or nil
end

function isMode(mode)
	for _, choice in ipairs(ns.Ledger.SESSION_MODES) do
		if choice.value == mode then
			return true
		end
	end
	return false
end

function isFiniteTime(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

-- Step 5 kept the start points and the Ledger tab's mode in the character's UI state. The mode
-- is account-wide now: a character's old mode is taken only while the account has none, so an
-- alt's first login does not overwrite the player's choice.
function moveLegacyPoints()
	local uiState = ns.store:Ui()
	local points = sessionPoints()
	if not points then
		return
	end
	points.resetAt = points.resetAt or uiState.ledgerResetAt
	points.ahLeftAt = points.ahLeftAt or uiState.ledgerAhLeftAt
	if isMode(uiState.ledgerSession) and not Sessions.module:IsSettingSet('mode') then
		Sessions.module:SetSetting('mode', uiState.ledgerSession)
	end
	uiState.ledgerResetAt, uiState.ledgerAhLeftAt, uiState.ledgerSession = nil, nil, nil
end
