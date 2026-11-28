local t = ...
local FakeGame = require('tests.fake_game')

local ns = t.loadAddon()
local Ledger = ns.Ledger

local DAY = 86400
-- 2026-03-29 00:00 UTC, a Sunday: Europe moves its clocks forward an hour at 01:00 UTC.
local MARCH_29 = 1774742400
local DST_SWITCH = MARCH_29 + 3600

-- Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil); linear in day, so
-- day 0 or -1 is the end of the month before, as os.time normalizes it.
local function daysFromCivil(year, month, day)
	year = month <= 2 and year - 1 or year
	local era = math.floor(year / 400)
	local yearOfEra = year - era * 400
	local monthIndex = month > 2 and month - 3 or month + 9
	local dayOfYear = math.floor((153 * monthIndex + 2) / 5) + day - 1
	local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
	return era * 146097 + dayOfEra - 719468
end

-- A local clock whose UTC offset is offsetAt(t), like the client's date and time.
local function zoneClock(offsetAt)
	local clock = {}
	function clock.date(format, at)
		t.eq(format, '*t', 'date format')
		return os.date('!*t', at + offsetAt(at))
	end
	function clock.time(fields)
		local localSeconds = daysFromCivil(fields.year, fields.month, fields.day) * DAY
			+ (fields.hour or 12) * 3600
			+ (fields.min or 0) * 60
			+ (fields.sec or 0)
		-- Try the offset of the moment itself; at a switch the earlier offset wins, as mktime.
		local guess = localSeconds - offsetAt(localSeconds - 3600)
		return localSeconds - offsetAt(guess)
	end
	return clock
end

local function fixed(offset)
	return zoneClock(function()
		return offset
	end)
end

local europe = zoneClock(function(at)
	return at < DST_SWITCH and 3600 or 7200
end)

t.test('local midnight in a fixed zone', function()
	-- 15:00 UTC is 17:00 at UTC+2; local midnight is 22:00 UTC the day before.
	local now = MARCH_29 + 15 * 3600
	t.eq(Ledger.localMidnight(now, fixed(7200)), MARCH_29 - 2 * 3600)
	t.eq(Ledger.localMidnight(now, fixed(-5 * 3600)), MARCH_29 + 5 * 3600)
end)

t.test('local midnight on the day the clocks go forward is the real midnight', function()
	-- 12:00 UTC is 14:00 local (UTC+2 since 01:00 UTC); midnight was at UTC+1, 23:00 UTC.
	-- Subtracting 14 hours of clock time would give 22:00 UTC, an hour early.
	local now = MARCH_29 + 12 * 3600
	t.eq(Ledger.localMidnight(now, europe), MARCH_29 - 3600)
end)

t.test('six local days back across the switch', function()
	local now = MARCH_29 + 12 * 3600
	-- 23 March, midnight at UTC+1.
	t.eq(Ledger.localMidnight(now, europe, 6), MARCH_29 - 6 * DAY - 3600)
end)

t.test('a clock without time falls back to clock arithmetic', function()
	local clock = { date = europe.date }
	t.eq(Ledger.localMidnight(MARCH_29 + 12 * 3600, clock), MARCH_29 + 12 * 3600 - 14 * 3600)
end)

t.test('a time that ignores its argument (the fake game) is not trusted', function()
	local now = MARCH_29 + 15 * 3600
	local clock = {
		date = fixed(7200).date,
		time = function()
			return now
		end,
	}
	t.eq(Ledger.localMidnight(now, clock), MARCH_29 - 2 * 3600)
end)

t.test('no date function: unknown', function()
	t.eq(Ledger.localMidnight(MARCH_29, {}), nil)
	t.eq(
		Ledger.localMidnight(MARCH_29, {
			date = function()
				error('no')
			end,
		}),
		nil
	)
end)

t.test('session starts for each mode, with a note on every fallback', function()
	local now = MARCH_29 + 15 * 3600
	local facts = {
		now = now,
		loginAt = now - 600,
		resets = { daily = now - 3600, weekly = now - 3 * DAY, localDay = now - 7200, localWeek = now - 6 * DAY },
		ahLeftAt = now - 300,
		resetAt = now - 100,
	}
	t.same({ Ledger.sessionStart('login', facts) }, { now - 600 })
	t.same({ Ledger.sessionStart('daily', facts) }, { now - 3600 })
	t.same({ Ledger.sessionStart('today', facts) }, { now - 7200 })
	t.same({ Ledger.sessionStart('week', facts) }, { now - 3 * DAY })
	t.same({ Ledger.sessionStart('ahVisit', facts) }, { now - 300 })
	t.same({ Ledger.sessionStart('manual', facts) }, { now - 100 })
	local bare = { now = now, loginAt = now - 600 }
	local start, note = Ledger.sessionStart('daily', bare)
	t.eq(start, MARCH_29)
	t.truthy(note, 'daily note')
	start, note = Ledger.sessionStart('week', bare)
	t.eq(start, MARCH_29 - 6 * DAY)
	t.truthy(note, 'week note')
	start = Ledger.sessionStart('week', { now = now, resets = { localWeek = now - 5 * DAY } })
	t.eq(start, now - 5 * DAY, 'week falls back to six local days back')
	start, note = Ledger.sessionStart('ahVisit', bare)
	t.eq(start, now - 600)
	t.truthy(note, 'ahVisit note')
	t.raises(function()
		Ledger.sessionStart('login', {})
	end, 'needs facts.now')
end)

t.test('the daily reset start is the last reset, not the next', function()
	local game = FakeGame.new({ now = MARCH_29 + 15 * 3600 })
	game.env.GetQuestResetTime = function()
		return 3 * 3600
	end
	game.env.C_DateAndTime = {
		GetSecondsUntilWeeklyReset = function()
			return 2 * DAY
		end,
	}
	local wow = ns.Wow.create(game.env, {})
	local times = wow:ResetTimes(game.now)
	t.eq(times.daily, game.now + 3 * 3600 - DAY)
	t.eq(times.weekly, game.now + 2 * DAY - 7 * DAY)
end)

-- The Sessions module ---------------------------------------------------------------------

local function start(beforeStart)
	local game = FakeGame.new({ now = MARCH_29 + 15 * 3600 })
	local addon = FakeGame.startAddon(t, game, beforeStart)
	local sent = {}
	addon.host.Bus:Listen('spec', 'SESSION_RESET', function(_, at)
		sent[#sent + 1] = at
	end)
	return game, addon, sent
end

t.test('Reset starts a session now, switches to manual and says so', function()
	local game, addon, sent = start()
	t.eq(addon.sessions:Mode(), 'login')
	game.now = game.now + 500
	addon.sessions:Reset()
	t.eq(addon.sessions:Mode(), 'manual')
	t.same(sent, { game.now })
	t.eq((addon.sessions:Start()), game.now)
	t.same(addon.errors, {})
end)

t.test('a mode change says where the session now starts', function()
	local _, addon, sent = start()
	addon.sessions:SetMode('ahVisit')
	t.eq(#sent, 1)
	t.eq(sent[1], (addon.sessions:Start()))
	t.raises(function()
		addon.sessions:SetMode('nope')
	end, 'unknown mode')
end)

t.test('closing the auction house is a session start point that survives a reload', function()
	local game, addon = start()
	addon.sessions:SetMode('ahVisit')
	game:Fire('AUCTION_HOUSE_SHOW')
	game.now = game.now + 60
	game:Fire('AUCTION_HOUSE_CLOSED')
	local closedAt = game.now
	t.eq((addon.sessions:Start()), closedAt)
	local reloaded = FakeGame.startAddon(t, game)
	t.eq((reloaded.sessions:Start()), closedAt)
end)

t.test('the step 5 start points move into the sessions store', function()
	local _, addon = start(function(started)
		local uiState = started.store:Ui()
		uiState.ledgerResetAt, uiState.ledgerAhLeftAt, uiState.ledgerSession = 123, 456, 'manual'
	end)
	t.eq(addon.sessions:Mode(), 'manual')
	t.eq((addon.sessions:Start()), 123)
	local player = addon.wow:Player()
	t.eq(addon.store:Session(player.name .. '-' .. player.realm).ahLeftAt, 456, 'ahLeftAt moved')
	local uiState = addon.store:Ui()
	t.eq(uiState.ledgerResetAt, nil)
	t.eq(uiState.ledgerAhLeftAt, nil)
	t.eq(uiState.ledgerSession, nil)
end)

t.test("an alt's old mode does not overwrite the account's mode", function()
	local _, addon = start(function(started)
		started.store:Settings().sessions = { mode = 'ahVisit' }
		local uiState = started.store:Ui()
		uiState.ledgerResetAt, uiState.ledgerSession = 123, 'manual'
	end)
	t.eq(addon.sessions:Mode(), 'ahVisit')
	local player = addon.wow:Player()
	t.eq(addon.store:Session(player.name .. '-' .. player.realm).resetAt, 123, 'start points still move')
	t.eq(addon.store:Ui().ledgerSession, nil)
end)

t.test('since login survives a /reload and restarts at the next login', function()
	local game, addon = start()
	game:Fire('PLAYER_ENTERING_WORLD', true, false)
	local loginAt = game.now
	t.eq((addon.sessions:Start()), loginAt)
	game.now = game.now + 900
	local reloaded = FakeGame.startAddon(t, game)
	game:Fire('PLAYER_ENTERING_WORLD', false, true)
	t.eq((reloaded.sessions:Start()), loginAt, 'a /reload is not a login')
	game.now = game.now + 900
	game:Fire('PLAYER_ENTERING_WORLD', true, false)
	t.eq((reloaded.sessions:Start()), game.now)
	t.same(reloaded.errors, {})
end)

t.group('client build 71037: GetRealmName answers ""')

local SAVED_REALM = 'CAMWOW EU5 Realm 3 PvE'

local function startRealmless(beforeStart, game)
	game = game or FakeGame.new({ now = MARCH_29 + 15 * 3600 })
	game.env.GetRealmName = function()
		return ''
	end
	game.env.UnitGUID = function(unit)
		return unit == 'player' and 'Player-6928-00A1AEB0' or nil
	end
	return game, FakeGame.startAddon(t, game, beforeStart)
end

t.test('starting with no realm name leaves no module failing', function()
	local _, addon = startRealmless()
	t.same(addon.errors, {})
	t.truthy(addon.sessions:Start(), 'the session has a start')
end)

t.test("a character's points saved under its realm name keep resolving once the name is gone", function()
	local game, addon = startRealmless(function(started)
		started.store:Settings().sessions = { mode = 'manual' }
		started.store.db.sessions['Eilu-' .. SAVED_REALM] = { resetAt = 123 }
	end)
	t.same(addon.errors, {})
	t.eq((addon.sessions:Start()), 123)
	t.eq(game.savedCharDb.realm, SAVED_REALM, 'remembered for this character')
	t.eq(game.savedCharDb.server, 6928, "with the server's id")
	t.eq(game.savedDb.sessions['Eilu-' .. SAVED_REALM].server, 6928, "the session carries the server's id")
	t.eq(game.savedDb.sessions['Eilu-'], nil, 'no "Name-" key')
end)
