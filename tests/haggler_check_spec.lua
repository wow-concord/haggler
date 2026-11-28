-- The dev-only check suite (dev/Haggler_Check): runs and verdicts, the judges, the observer and
-- the checker, against fake saved tables and a fake client.
local t = ...

local DIR = 'dev/Haggler_Check/'
local MARKET = 'forever/normal/alliance/us'
local CHAR = 'Eilu-Nightslayer'
local NOW = 1000000

local function loadCheckAddon()
	local ns = {}
	for _, file in ipairs({ 'Suite.lua', 'Items.lua', 'Observer.lua', 'Panel.lua', 'Check.lua' }) do
		assert(loadfile(DIR .. file))('Haggler_Check', ns)
	end
	return ns
end

local ns = loadCheckAddon()
local Suite, Items = ns.Suite, ns.Items

local function itemById(id)
	for _, item in ipairs(Items.list) do
		if item.id == id then
			return item
		end
	end
	error('no item ' .. id)
end

local function fakeApi(overrides)
	local api = {
		isHagglerLoaded = function()
			return true
		end,
		hagglerVersion = function()
			return '0.2.0-dev'
		end,
		hasErrorHook = function()
			return true
		end,
		frameShown = function()
			return false
		end,
		framePoint = function()
			return nil
		end,
		settingsCategoryShown = function()
			return nil
		end,
		bindingAction = function()
			return nil
		end,
		hasLdb = function()
			return true
		end,
		ldbText = function()
			return true, ''
		end,
		freeBagSlots = function()
			return 10
		end,
		inboxCount = function()
			return 0
		end,
		isInCombat = function()
			return false
		end,
	}
	for name, fn in pairs(overrides or {}) do
		api[name] = fn
	end
	return api
end

local function factsWith(db, overrides)
	return {
		db = db,
		charDb = {},
		charKey = CHAR,
		now = NOW,
		run = { startedAt = NOW - 100 },
		api = fakeApi(overrides),
	}
end

local function signal(name, at, ...)
	return { name = name, args = { ... }, at = at or NOW }
end

local function ledgerRow(kind, itemId, extra)
	local row = { t = NOW, kind = kind, itemId = itemId, qty = 1, copper = 100, char = CHAR }
	for key, value in pairs(extra or {}) do
		row[key] = value
	end
	return row
end

-- Feeds signals to one item's judge and returns the last verdict.
local function judgeAll(item, facts, signals, scratch)
	scratch = scratch or {}
	local verdict
	for _, each in ipairs(signals) do
		verdict = item.judge(facts, scratch, each) or verdict
	end
	return verdict, scratch
end

-- The item table ---------------------------------------------------------------------------

t.test('the item table is well formed: safe items first, every judge listens', function()
	Suite.validateItems(Items.list)
	local known = { LOAD = true, LOGOUT = true, TICK = true, LEDGER = true, LUA_ERROR = true }
	for _, item in ipairs(Items.list) do
		for _, name in ipairs(item.on or {}) do
			local hookName = name:match('^HOOK:(.+)$')
			t.truthy(known[name] or name:match('^[A-Z_]+$') or hookName, item.id .. ' listens to ' .. name)
		end
	end
	t.raises(function()
		Suite.validateItems({
			{ id = 'a', title = 'A', kind = 'look', prompt = 'x', zone = 'fight' },
			{ id = 'b', title = 'B', kind = 'look', prompt = 'x', zone = 'safe' },
		})
	end, 'after a fight item')
	t.raises(function()
		Suite.validateItems({ { id = 'a', title = 'A', kind = 'action', prompt = 'x', zone = 'safe' } })
	end, 'needs a judge')
end)

-- Suite ------------------------------------------------------------------------------------

t.test('a run is keyed by version and build and reused on reload', function()
	local db = {}
	local run = Suite.openRun(db, '0.2.0', '1.15.8.1234', NOW)
	t.eq(run.key, '0.2.0@1.15.8.1234')
	t.eq(Suite.openRun(db, '0.2.0', '1.15.8.1234', NOW + 5), run, 'same run after a reload')
	t.eq(db.current, run.key)
	local nextBuild = Suite.openRun(db, '0.2.0', '1.15.8.1300', NOW + 10)
	t.truthy(nextBuild ~= run, 'a new build is a new run')
end)

t.test('a fail sticks, a look never replaces a judged result, evidence is capped', function()
	local db = {}
	local run = Suite.openRun(db, 'v', 'b', NOW)
	local item = { id = 'x', once = false }
	t.eq(Suite.record(db, run, item, { state = 'pass', evidence = { 'ok' } }, NOW), true)
	t.eq(Suite.record(db, run, item, { state = 'look', evidence = { 'hm' } }, NOW), false, 'look after pass')
	t.eq(Suite.record(db, run, item, { state = 'fail', evidence = { 'bad' } }, NOW), true)
	t.eq(Suite.record(db, run, item, { state = 'pass', evidence = { 'ok again' } }, NOW), false, 'pass after fail')
	t.eq(run.results.x.state, 'fail')
	local long = {}
	for index = 1, 20 do
		long[index] = string.rep('z', 500)
	end
	Suite.record(db, run, { id = 'y' }, { state = 'look', evidence = long }, NOW)
	t.eq(#run.results.y.evidence, Suite.MAX_EVIDENCE_LINES)
	t.eq(#run.results.y.evidence[1], Suite.MAX_EVIDENCE_BYTES)
	t.raises(function()
		Suite.record(db, run, item, { state = 'maybe' }, NOW)
	end, 'must be pass, fail')
end)

t.test('the player judges a look and may change it; a judged item stays judged', function()
	local db = {}
	local run = Suite.openRun(db, 'v', 'b', NOW)
	local lookItem = { id = 'l', kind = 'look' }
	t.eq(Suite.record(db, run, lookItem, { state = 'fail', evidence = { 'misclick' } }, NOW, true), true)
	t.eq(Suite.record(db, run, lookItem, { state = 'pass', evidence = { 'fixed' } }, NOW, true), true, 'changed back')
	t.eq(run.results.l.state, 'pass')
	local onceItem = { id = 'o', kind = 'auto', once = true }
	Suite.record(db, run, onceItem, { state = 'look', evidence = { 'cannot tell' } }, NOW)
	local laterRun = Suite.openRun(db, 'v', 'b2', NOW + 1)
	t.eq(Suite.canPlayerJudge(db, laterRun, onceItem), true, 'a once look stays confirmable in the next run')
	t.eq(Suite.record(db, laterRun, onceItem, { state = 'pass', evidence = {} }, NOW, true), true)
	t.eq(db.once.o.state, 'pass')
	t.eq(Suite.canPlayerJudge(db, laterRun, onceItem), true, 'the player may change it again')
	local actionItem = { id = 'a', kind = 'action' }
	Suite.record(db, laterRun, actionItem, { state = 'fail', evidence = { 'judged' } }, NOW)
	t.eq(Suite.canPlayerJudge(db, laterRun, actionItem), false)
	t.eq(Suite.record(db, laterRun, actionItem, { state = 'pass', evidence = {} }, NOW, true), false)
end)

t.test('once answers carry over runs until a reset, which keeps the old run aside', function()
	local db = {}
	local run = Suite.openRun(db, 'v', 'b', NOW)
	local onceItem = { id = 'o', once = true }
	Suite.record(db, run, onceItem, { state = 'pass', evidence = {} }, NOW)
	local laterRun = Suite.openRun(db, 'v', 'b2', NOW + 1)
	t.eq(Suite.resultOf(db, laterRun, onceItem).state, 'pass', 'once answer shown in the next build')
	local fresh = Suite.resetRun(db, 'v', 'b2', NOW + 2)
	t.eq(Suite.resultOf(db, fresh, onceItem), nil, 'reset clears once answers')
	t.truthy(db.runs['v@b2 #1'], 'old run kept aside')
	t.eq(db.runs['v@b2'], fresh)
end)

t.test('progress counts states and the next item is the first unjudged one', function()
	local db = {}
	local run = Suite.openRun(db, 'v', 'b', NOW)
	local items = { { id = 'a' }, { id = 'b' }, { id = 'c' }, { id = 'd' } }
	Suite.record(db, run, items[1], { state = 'pass' }, NOW)
	Suite.record(db, run, items[2], { state = 'look' }, NOW)
	Suite.record(db, run, items[3], { state = 'na' }, NOW)
	t.same(Suite.progress(db, run, items), { judged = 2, total = 4, pass = 1, fail = 0, look = 1, na = 1, pending = 1 })
	t.eq(Suite.nextItem(db, run, items), items[2])
end)

t.test('old runs are pruned, the current one never', function()
	local db = {}
	for index = 1, Suite.MAX_KEPT_RUNS + 5 do
		Suite.openRun(db, 'v', 'b' .. index, NOW + index)
	end
	local count = 0
	for _ in pairs(db.runs) do
		count = count + 1
	end
	t.eq(count, Suite.MAX_KEPT_RUNS)
	t.truthy(db.runs['v@b' .. (Suite.MAX_KEPT_RUNS + 5)], 'current kept')
end)

-- Judges -----------------------------------------------------------------------------------

t.test('load.clean: passes at load, fails on a Haggler error or blocked action only', function()
	local item = itemById('load.clean')
	local facts = factsWith({ version = 2 })
	t.eq(item.judge(facts, {}, signal('LOAD', NOW, false, true)).state, 'pass')
	t.eq(item.judge(facts, {}, signal('LUA_ERROR', NOW, 'Interface/AddOns/Other/x.lua:1: boom')), nil)
	t.eq(item.judge(facts, {}, signal('LUA_ERROR', NOW, 'Interface/AddOns/Haggler_Check/x.lua:1')), nil, 'own errors')
	t.eq(item.judge(facts, {}, signal('LUA_ERROR', NOW, 'Interface/AddOns/Haggler/UI/Bar.lua:1: boom')).state, 'fail')
	t.eq(item.judge(facts, {}, signal('ADDON_ACTION_BLOCKED', NOW, 'Haggler', 'UseAction()')).state, 'fail')
	t.eq(item.judge(facts, {}, signal('ADDON_ACTION_BLOCKED', NOW, 'Other', 'UseAction()')), nil)
	t.eq(item.judge(factsWith({}), {}, signal('LOAD')).state, 'fail', 'no store')
end)

t.test('bar.rule: passes after two changes of the default rule', function()
	local item = itemById('bar.rule')
	local db = { defaultRuleId = 'r1' }
	local facts = factsWith(db)
	local scratch = {}
	t.eq(item.judge(facts, scratch, signal('TICK')), nil)
	db.defaultRuleId = 'r2'
	t.eq(item.judge(facts, scratch, signal('TICK')), nil)
	db.defaultRuleId = 'r1'
	t.same(item.judge(facts, scratch, signal('TICK')), { state = 'pass', evidence = { 'r1 -> r2', 'r2 -> r1' } })
end)

t.test('bar.shortcuts: the settings shortcut passes through the Settings window or the legacy panel', function()
	local item = itemById('bar.shortcuts')
	local function windowOn(tab)
		return { window = { lastTab = tab } }
	end
	local function tickWith(tab, overrides)
		local db = { settings = windowOn(tab) }
		local facts = factsWith(db, overrides)
		facts.db = db
		return facts
	end
	local isWindowShown = function(name)
		return name == 'HagglerFrame'
	end
	local function run(settingsOverrides)
		local scratch = {}
		t.eq(item.judge(tickWith('sell', { frameShown = isWindowShown }), scratch, signal('TICK')), nil)
		return item.judge(tickWith('sell', settingsOverrides), scratch, signal('TICK'))
	end

	local viaSettings = run({
		settingsCategoryShown = function()
			return 'Haggler'
		end,
	})
	t.eq(
		viaSettings and viaSettings.state,
		'pass',
		'Settings API: no HagglerOptionsPanel, the Settings window on Haggler'
	)
	t.eq(
		run({
			settingsCategoryShown = function()
				return 'Controls'
			end,
		}),
		nil,
		'the Settings window on another category'
	)
	local viaLegacy = run({
		frameShown = function(name)
			return name == 'HagglerOptionsPanel'
		end,
	})
	t.eq(viaLegacy and viaLegacy.state, 'pass', 'legacy fallback: the named panel')
end)

t.test('bar.position: the bar is placed after a reload where it was dragged', function()
	local item = itemById('bar.position')
	local charDb = { ui = { topBar = { point = 'TOP', relativePoint = 'TOP', x = 0, y = 0 } } }
	local placed = { 'TOP', 'TOP', 120, -40 }
	local facts = factsWith({}, {
		framePoint = function()
			return placed[1], placed[2], placed[3], placed[4]
		end,
	})
	facts.charDb = charDb
	local scratch = {}
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, true, false)), nil, 'first load sets the baseline')
	charDb.ui.topBar = { point = 'TOP', relativePoint = 'TOP', x = 120, y = -40 }
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'pass')
	charDb.ui.topBar = { point = 'TOP', relativePoint = 'TOP', x = 300, y = -40 }
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'fail', 'placed elsewhere')

	local afterReset = {}
	item.judge(facts, afterReset, signal('TICK'))
	item.judge(facts, afterReset, signal('LOGOUT'))
	t.eq(item.judge(facts, afterReset, signal('LOAD', NOW, false, true)), nil, 'a reset mid-session: no drag, no pass')
	local noBaseline = {}
	item.judge(facts, noBaseline, signal('LOGOUT'))
	t.eq(item.judge(facts, noBaseline, signal('LOAD', NOW, false, true)), nil, 'no baseline, no verdict')
end)

t.test('session.reload: the session survives a reload, a moved start fails', function()
	local item = itemById('session.reload')
	local db = { sessions = { [CHAR] = { loginAt = NOW - 900, resetAt = 5, ahLeftAt = 7 } } }
	local facts = factsWith(db)
	local scratch = {}
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'pass')
	item.judge(facts, scratch, signal('LOGOUT'))
	db.sessions[CHAR].loginAt = NOW
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, false, true)).state, 'fail')
	item.judge(facts, scratch, signal('LOGOUT'))
	t.eq(item.judge(facts, scratch, signal('LOAD', NOW, true, false)), nil, 'a login is not a reload')
	local empty = factsWith({})
	item.judge(empty, scratch, signal('LOGOUT'))
	t.eq(item.judge(empty, scratch, signal('LOAD', NOW, false, true)), nil, 'no session saved: nothing to compare')
end)

t.test('session.relog: the login start moves on a relog of the same character', function()
	local item = itemById('session.relog')
	local db = { sessions = { [CHAR] = { loginAt = NOW - 900 } } }
	local scratch = {}
	item.judge(factsWith(db), scratch, signal('LOGOUT'))
	db.sessions[CHAR].loginAt = NOW + 60
	local later = factsWith(db)
	later.now = NOW + 60
	t.eq(item.judge(later, scratch, signal('LOAD', NOW + 60, true, false)).state, 'pass')
	item.judge(later, scratch, signal('LOGOUT'))
	local alt = factsWith(db)
	alt.charKey = 'Alt-Nightslayer'
	t.eq(item.judge(alt, scratch, signal('LOAD', NOW + 120, true, false)), nil, 'another character')
end)

t.test('persist.data: fails when the last ledger row changes across a reload', function()
	local item = itemById('persist.data')
	local market = { ledger = { { NOW, 'sale', 1, 1, 100 } }, costPools = {} }
	local db = { markets = { [MARKET] = market } }
	local scratch = {}
	item.judge(factsWith(db), scratch, signal('LOGOUT'))
	t.eq(item.judge(factsWith(db), scratch, signal('LOAD')).state, 'pass')
	item.judge(factsWith(db), scratch, signal('LOGOUT'))
	market.ledger = {}
	t.eq(item.judge(factsWith(db), scratch, signal('LOAD')).state, 'fail')
	local emptyDb = { markets = { [MARKET] = { ledger = {} } } }
	item.judge(factsWith(emptyDb), scratch, signal('LOGOUT'))
	t.eq(item.judge(factsWith(emptyDb), scratch, signal('LOAD')), nil, 'an empty store proves nothing')
end)

t.test('craft.book: one craft row per cast, judged after the casts settle', function()
	local item = itemById('craft.book')
	local facts = factsWith({})
	local verdict = judgeAll(item, facts, {
		signal('HOOK:CraftRecipe', NOW, 2001, 2),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW, { ledgerRow('craft', 5) }),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW + 1, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW + 1, { ledgerRow('craft', 5) }),
		signal('TICK', NOW + 2),
	})
	t.eq(verdict, nil, 'not settled')
	verdict = judgeAll(item, facts, {
		signal('HOOK:CraftRecipe', NOW, 2001, 1),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW, { ledgerRow('craft', 5), ledgerRow('craft', 5) }),
		signal('TICK', NOW + 4),
	})
	t.eq(verdict.state, 'fail', 'booked twice')
	verdict = judgeAll(item, facts, {
		signal('HOOK:CraftRecipe', NOW, 2001, 1),
		signal('UNIT_SPELLCAST_SUCCEEDED', NOW, 'player', 'cast-guid', 2001),
		signal('LEDGER', NOW, { ledgerRow('craft', 5) }),
		signal('TICK', NOW + 4),
	})
	t.eq(verdict.state, 'pass')
end)

t.test('vendor.book: a vendor buy and sell pass, more vendor buys than buy calls fail', function()
	local item = itemById('vendor.book')
	local facts = factsWith({})
	t.eq(
		judgeAll(item, facts, {
			signal('MERCHANT_SHOW'),
			signal('HOOK:BuyMerchantItem', NOW, 3, 1),
			signal('LEDGER', NOW, { ledgerRow('vendorBuy', 5), ledgerRow('vendorSell', 6) }),
			signal('MERCHANT_CLOSED'),
		}).state,
		'pass'
	)
	t.eq(
		judgeAll(item, facts, {
			signal('MERCHANT_SHOW'),
			signal('HOOK:BuyMerchantItem', NOW, 3, 1),
			signal('LEDGER', NOW, { ledgerRow('vendorBuy', 5), ledgerRow('vendorBuy', 5) }),
		}).state,
		'fail',
		'one buy booked twice'
	)
end)

t.test('bags.destroy: a destroy row must match the deleted item', function()
	local item = itemById('bags.destroy')
	local facts = factsWith({})
	local function deleted(itemId, at)
		local each = signal('HOOK:DeleteCursorItem', at)
		each.args.itemId = itemId
		return each
	end
	t.eq(
		judgeAll(
			item,
			facts,
			{ deleted(5, NOW), signal('LEDGER', NOW, { ledgerRow('destroy', 5) }), signal('TICK', NOW + 4) }
		).state,
		'pass'
	)
	t.eq(
		judgeAll(item, facts, { signal('LEDGER', NOW, { ledgerRow('destroy', 5) }), signal('TICK', NOW + 4) }).state,
		'fail',
		'destroy without a delete'
	)
	t.eq(judgeAll(item, facts, { deleted(5, NOW), signal('TICK', NOW + 4) }).state, 'fail', 'delete not booked')
end)

t.test('mail.take: sale, return and won rows pass; more sales than sale takes fail', function()
	local item = itemById('mail.take')
	local facts = factsWith({})
	local function take(invoiceType)
		local each = signal('HOOK:TakeInboxMoney', NOW, 1)
		each.args.invoiceType = invoiceType
		return each
	end
	t.eq(
		judgeAll(item, facts, {
			signal('MAIL_SHOW'),
			take('seller'),
			signal(
				'LEDGER',
				NOW,
				{ ledgerRow('sale', 5), ledgerRow('cut', 5), ledgerRow('expire', 6), ledgerRow('buy', 7) }
			),
		}).state,
		'pass'
	)
	t.eq(judgeAll(item, facts, { signal('MAIL_SHOW'), signal('LEDGER', NOW, { ledgerRow('sale', 5) }) }).state, 'fail')
	t.eq(
		judgeAll(item, facts, {
			signal('MAIL_SHOW'),
			take('seller'),
			signal('LEDGER', NOW, { ledgerRow('sale', 5) }),
			signal('MAIL_CLOSED'),
			signal('MAIL_SHOW', NOW + 60),
			signal('LEDGER', NOW + 60, { ledgerRow('cancel', 6), ledgerRow('buy', 7) }),
		}),
		nil,
		'a second visit is no fail; a cancel is no expiry'
	)
	t.eq(
		judgeAll(item, facts, {
			signal('MAIL_SHOW'),
			take('seller'),
			signal('MAIL_CLOSED', NOW),
			signal('LEDGER', NOW + 1, { ledgerRow('sale', 5) }),
			signal('MAIL_SHOW', NOW + 60),
			signal('LEDGER', NOW + 60, { ledgerRow('expire', 6), ledgerRow('buy', 7) }),
		}).state,
		'pass',
		'over two visits, with a row read just after a close'
	)
end)

t.test('mail.fullbags: a won take that failed on full bags is not booked, the retake is', function()
	local item = itemById('mail.fullbags')
	local facts = factsWith({})
	local function take(freeSlots, at)
		local each = signal('HOOK:TakeInboxItem', at or NOW, 1, 1)
		each.args.invoiceType, each.args.freeSlots = 'buyer', freeSlots
		return each
	end
	t.eq(
		judgeAll(
			item,
			facts,
			{ take(0), signal('MAIL_CLOSED'), take(3), signal('LEDGER', NOW, { ledgerRow('buy', 5) }) }
		).state,
		'pass'
	)
	t.eq(
		judgeAll(item, facts, { take(0), signal('LEDGER', NOW, { ledgerRow('buy', 5) }), signal('MAIL_CLOSED') }).state,
		'fail'
	)
end)

t.test('mail.newmail: only a mail absent at the take counts as new mail', function()
	local item = itemById('mail.newmail')
	local SALE = 'Auction House: Auction successful: Copper Bar'
	local LETTER = 'Alt: Hi'
	local headers = { SALE }
	local facts = factsWith({}, {
		inboxHeaders = function()
			return headers
		end,
	})
	local take = signal('HOOK:TakeInboxMoney', NOW, 1)
	take.args.invoiceType, take.args.inboxHeaders = 'seller', { SALE }
	local function takeWithSales(saleRows)
		local signals = { take, signal('MAIL_INBOX_UPDATE') }
		if saleRows > 0 then
			local rows = {}
			for index = 1, saleRows do
				rows[index] = ledgerRow('sale', 5)
			end
			signals[#signals + 1] = signal('LEDGER', NOW, rows)
		end
		signals[#signals + 1] = signal('TICK', NOW + 4)
		return judgeAll(item, facts, signals)
	end

	t.eq(takeWithSales(1), nil, 'an ordinary take, the emptied sale mail kept: stays pending')
	headers = {}
	t.eq(takeWithSales(1), nil, 'the sale mail left and nothing came: stays pending')
	headers = { LETTER }
	t.eq(takeWithSales(1).state, 'pass', 'the sale mail left as a letter landed')
	headers = { SALE, LETTER }
	local result = takeWithSales(1)
	t.eq(result.state, 'pass')
	t.truthy(result.evidence[1]:find(LETTER, 1, true), 'evidence names the new mail')
	headers = { SALE, SALE }
	t.eq(takeWithSales(1).state, 'pass', 'a second mail with the same header is new')
	headers = { SALE, LETTER }
	t.eq(takeWithSales(2).state, 'fail', 'one take booked twice')
	t.eq(takeWithSales(0).state, 'fail', 'new mail and the sale not booked')
end)

t.test('ah.post and ah.undercut: the tracked auction carries the price actually posted', function()
	local db =
		{ markets = { [MARKET] = { auctions = { [77] = { itemId = 5, unitPrice = 90, qty = 2, state = 'active' } } } } }
	local facts = factsWith(db)
	local post = itemById('ah.post')
	t.eq(
		judgeAll(post, facts, {
			signal('AUCTION_HOUSE_AUCTION_CREATED', NOW, 77),
			signal('LEDGER', NOW, { ledgerRow('deposit', 5, { auctionId = 77 }) }),
		}).state,
		'pass'
	)
	local undercut = itemById('ah.undercut')
	local warned = {
		signal('AUCTION_HOUSE_POST_WARNING'),
		signal('HOOK:PostItem', NOW, {}, 1, 2, 0, 180),
		signal('AUCTION_HOUSE_AUCTION_CREATED', NOW, 77),
	}
	t.eq(judgeAll(undercut, facts, warned).state, 'pass', '180 for 2 is 90 each')
	db.markets[MARKET].auctions[77].unitPrice = 60
	t.eq(judgeAll(undercut, facts, warned).state, 'fail', 'the declined price was booked')
end)

t.test('ah.cancel and ah.untracked: cancel marks the record; a second cancel waits for the server', function()
	local db = {
		markets = {
			[MARKET] = {
				auctions = {
					[1] = { state = 'cancelled', deposit = 10 },
					[2] = { state = 'active' },
				},
			},
		},
	}
	local facts = factsWith(db)
	local cancel = itemById('ah.cancel')
	t.eq(judgeAll(cancel, facts, { signal('HOOK:CancelAuction', NOW, 1), signal('TICK', NOW + 4) }).state, 'pass')
	t.eq(judgeAll(cancel, facts, { signal('HOOK:CancelAuction', NOW, 2), signal('TICK', NOW + 4) }).state, 'fail')
	local untracked = itemById('ah.untracked')
	t.eq(
		judgeAll(untracked, facts, { signal('HOOK:CancelAuction', NOW, 2), signal('HOOK:CancelAuction', NOW, 4) }).state,
		'fail',
		'no server answer between'
	)
	t.eq(
		judgeAll(untracked, facts, {
			signal('HOOK:CancelAuction', NOW, 2),
			signal('OWNED_AUCTIONS_UPDATED'),
			signal('HOOK:CancelAuction', NOW + 1, 4),
			signal('AUCTION_CANCELED'),
			signal('TICK', NOW + 5),
		}).state,
		'pass'
	)
	t.eq(
		judgeAll(untracked, facts, {
			signal('HOOK:CancelAuction', NOW, 2),
			signal('HOOK:CancelAuction', NOW + 5, 4),
			signal('AUCTION_HOUSE_CLOSED', NOW + 6),
			signal('AUCTION_HOUSE_SHOW', NOW + 30),
			signal('HOOK:CancelAuction', NOW + 31, 5),
			signal('TICK', NOW + 40),
		}).state,
		'pass',
		"Haggler's 5 s wait and an AH close or show end the wait"
	)
end)

t.test('session.ahvisit: closing the AH sets the AH-visit start', function()
	local item = itemById('session.ahvisit')
	t.eq(
		item.judge(factsWith({ sessions = { [CHAR] = { ahLeftAt = NOW } } }), {}, signal('AUCTION_HOUSE_CLOSED', NOW)).state,
		'pass'
	)
	t.eq(
		item.judge(
			factsWith({ sessions = { [CHAR] = { ahLeftAt = NOW - 999 } } }),
			{},
			signal('AUCTION_HOUSE_CLOSED', NOW)
		).state,
		'fail'
	)
end)

t.test('focus.combat: no key stays overridden to Haggler after combat', function()
	local item = itemById('focus.combat')
	local facts = factsWith({})
	local function sampled(name, at, keys)
		local each = signal(name, at)
		each.args.heldFocusKeys = keys
		return each
	end
	t.eq(
		judgeAll(item, facts, {
			sampled('TICK', NOW, { 'UP' }),
			sampled('PLAYER_REGEN_DISABLED', NOW + 1, {}),
			sampled('PLAYER_REGEN_ENABLED', NOW + 9, { 'UP' }),
		}).state,
		'fail',
		'still held'
	)
	t.eq(
		judgeAll(item, facts, {
			sampled('TICK', NOW, { 'UP' }),
			sampled('PLAYER_REGEN_DISABLED', NOW + 1, {}),
			sampled('PLAYER_REGEN_ENABLED', NOW + 9, {}),
		}).state,
		'pass',
		'the tick before the pull stands for it'
	)
	t.eq(
		judgeAll(item, facts, {
			sampled('TICK', NOW, { 'UP' }),
			sampled('PLAYER_REGEN_DISABLED', NOW + 10, {}),
			sampled('PLAYER_REGEN_ENABLED', NOW + 19, {}),
		}),
		nil,
		'an old sample is not the pull'
	)
end)

t.test('focus.bind and feed.objects: the bound key and the feed texts', function()
	local db = { settings = { topbar = { focusKey = 'CTRL-SHIFT-H' } } }
	local bound = itemById('focus.bind')
	local facts = factsWith(db, {
		bindingAction = function()
			return 'CLICK HagglerInputButton1:LeftButton'
		end,
	})
	t.eq(bound.judge(facts, {}, signal('TICK')).state, 'pass')
	local feed = itemById('feed.objects')
	local texts = { ['Haggler: Gold'] = '12g', ['Haggler: Rule'] = 'Fast', ['Haggler: Scan'] = '2m' }
	local feedFacts = factsWith(db, {
		ldbText = function(name)
			return true, texts[name] or ''
		end,
	})
	t.eq(feed.judge(feedFacts, {}, signal('TICK')).state, 'pass')
	db.settings.topbar.feed = false
	local scratch = {}
	t.eq(
		judgeAll(feed, feedFacts, { signal('TICK'), signal('TICK'), signal('TICK') }, scratch).state,
		'fail',
		'still filled with the feed off'
	)
end)

-- Observer and checker ---------------------------------------------------------------------

local function fakeClient()
	local client = { clock = 0, frames = {}, hooks = {}, HagglerDB = { markets = {} } }
	function client.GetTime()
		return client.clock
	end
	function client.GetServerTime()
		return NOW + math.floor(client.clock)
	end
	client.time = client.GetServerTime
	function client.CreateFrame()
		local frame = { events = {}, scripts = {} }
		function frame.RegisterEvent(self, name)
			self.events[name] = true
		end
		function frame.SetScript(self, name, fn)
			self.scripts[name] = fn
		end
		client.frames[#client.frames + 1] = frame
		return frame
	end
	function client.hooksecurefunc(owner, name, hook)
		local original = owner[name]
		owner[name] = function(...)
			local results = { original(...) }
			hook(...)
			return unpack(results)
		end
	end
	function client.GetInboxInvoiceInfo(index)
		return index == 1 and 'seller' or 'buyer'
	end
	function client.GetInboxNumItems()
		return 3
	end
	client.TakeInboxMoney = function() end
	client.C_AuctionHouse = { CancelAuction = function() end }
	function client.advance(seconds)
		client.clock = client.clock + seconds
		client.frames[1].scripts.OnUpdate(client.frames[1], seconds)
	end
	function client.fire(event, ...)
		client.frames[1].scripts.OnEvent(client.frames[1], event, ...)
	end
	return client
end

t.test('the observer delivers events and hooks late and in order, ledger rows before the tick', function()
	local client = fakeClient()
	local heard = {}
	local observer = ns.Observer.create(client, function(each)
		heard[#heard + 1] = each
	end)
	client.HagglerDB.markets[MARKET] = { ledger = { { NOW, 'sale', 5, 1, 100 } } }
	observer:Start({ 'HOOK:TakeInboxMoney', 'HOOK:CancelAuction', 'MAIL_SHOW', 'LEDGER', 'TICK' })
	t.truthy(client.frames[1].events.MAIL_SHOW, 'item event registered')
	client.fire('PLAYER_ENTERING_WORLD', false, true)
	client.fire('MAIL_SHOW')
	client.TakeInboxMoney(1)
	client.C_AuctionHouse.CancelAuction(42)
	t.eq(#heard, 0, 'nothing before the delay')
	client.advance(0.6)
	t.same(
		{ heard[1].name, heard[2].name, heard[3].name },
		{ 'PLAYER_ENTERING_WORLD', 'MAIL_SHOW', 'HOOK:TakeInboxMoney' }
	)
	t.eq(heard[3].args.invoiceType, 'seller', 'invoice read at the take')
	t.eq(heard[4].args[1], 42)
	client.advance(0.6)
	t.eq(heard[5].name, 'LOAD')
	t.same(heard[5].args, { false, true })
	client.advance(0.6)
	t.eq(heard[6].name, 'TICK', 'the first read sets the cursors: rows from before are not new')

	client.HagglerDB.markets[MARKET].ledger[2] = { NOW, 'cut', 5, 1, 5 }
	heard = {}
	client.advance(1)
	t.eq(#heard, 0, 'ledger rows wait in the queue like everything else')
	client.advance(0.5)
	t.eq(heard[1].name, 'LEDGER')
	t.eq(heard[1].args[1][1].kind, 'cut')
	t.eq(heard[2].name, 'TICK')
	client.HagglerDB.markets[MARKET].ledger = { { NOW, 'fold', 0, 0, 0 } }
	heard = {}
	client.advance(1)
	client.advance(0.5)
	t.eq(heard[1].name, 'TICK', 'a compacted ledger restarts at its end')

	heard = {}
	client.fire('PLAYER_LOGOUT')
	t.eq(heard[1].name, 'LOGOUT', 'logout is delivered at once')
end)

t.test('the observer reads the Settings window nil-safely', function()
	local client = fakeClient()
	local api = ns.Observer.create(client, function() end):Api()
	t.eq(api.settingsCategoryShown(), nil, 'no SettingsPanel')
	local isShown = false
	client.SettingsPanel = {
		IsShown = function()
			return isShown
		end,
		GetCurrentCategory = function()
			return {
				GetName = function()
					return 'Haggler'
				end,
			}
		end,
	}
	t.eq(api.settingsCategoryShown(), nil, 'closed')
	isShown = true
	t.eq(api.settingsCategoryShown(), 'Haggler')
	client.SettingsPanel.GetCurrentCategory = function()
		return nil
	end
	t.eq(api.settingsCategoryShown(), nil, 'no current category')
	client.SettingsPanel.GetCurrentCategory = function()
		error('boom')
	end
	t.eq(api.settingsCategoryShown(), nil, 'a raising client read')
end)

-- Drives one item through a real observer over the fake client; returns every verdict it gave.
local function observeItem(client, itemId, signalNames)
	local item = itemById(itemId)
	local scratch, verdicts = {}, {}
	local observer
	observer = ns.Observer.create(client, function(each)
		local facts = factsWith(client.HagglerDB)
		facts.api = observer:Api()
		local verdict = item.judge(facts, scratch, each)
		if verdict then
			verdicts[#verdicts + 1] = verdict.state
		end
	end)
	observer:Start(signalNames or item.on)
	client.fire('PLAYER_ENTERING_WORLD', true, false)
	for _ = 1, 25 do
		client.advance(0.1)
	end
	return verdicts
end

local function hasVerdict(verdicts, state)
	for _, each in ipairs(verdicts) do
		if each == state then
			return true
		end
	end
	return false
end

t.test('vendor.book through the observer: a row booked in the same call never beats its hook', function()
	-- The review's repro: Haggler books vendorBuy inside its own BuyMerchantItem hook, and the
	-- next ledger read falls between that call and the delivery of our hook.
	local client = fakeClient()
	local ledger = {}
	client.HagglerDB.markets[MARKET] = { ledger = ledger }
	client.BuyMerchantItem = function() end
	client.hooksecurefunc(client, 'BuyMerchantItem', function()
		ledger[#ledger + 1] = { NOW, 'vendorBuy', 5, 1, 10 }
	end)
	local verdicts = observeItem(client, 'vendor.book')
	client.fire('MERCHANT_SHOW')
	for _ = 1, 6 do
		client.advance(0.1)
	end
	for _ = 1, 10 do
		client.BuyMerchantItem(3, 1)
		client.advance(0.1)
	end
	ledger[#ledger + 1] = { NOW, 'vendorSell', 6, 1, 5 }
	for _ = 1, 20 do
		client.advance(0.1)
	end
	client.fire('MERCHANT_CLOSED')
	for _ = 1, 10 do
		client.advance(0.1)
	end
	t.eq(hasVerdict(verdicts, 'fail'), false, 'no false fail')
	t.eq(hasVerdict(verdicts, 'pass'), true)
end)

t.test('focus.combat through the observer: Haggler drops the focus inside the combat event', function()
	local client = fakeClient()
	local held = { UP = true, DOWN = true }
	function client.GetBindingAction(key)
		return held[key] and 'CLICK HagglerInputButton1:LeftButton' or nil
	end
	local verdicts = observeItem(client, 'focus.combat')
	for _ = 1, 15 do
		client.advance(0.1)
	end
	held = {}
	client.fire('PLAYER_REGEN_DISABLED')
	for _ = 1, 30 do
		client.advance(0.1)
	end
	client.fire('PLAYER_REGEN_ENABLED')
	for _ = 1, 10 do
		client.advance(0.1)
	end
	t.same(verdicts, { 'pass' })

	held = { UP = true }
	for _ = 1, 15 do
		client.advance(0.1)
	end
	client.fire('PLAYER_REGEN_DISABLED')
	client.advance(0.6)
	client.fire('PLAYER_REGEN_ENABLED')
	client.advance(0.6)
	t.same(verdicts, { 'pass', 'fail' }, 'a key still held after combat')
end)

t.test('the checker records verdicts, skips answered once items and survives a judge error', function()
	local client = fakeClient()
	local db = {}
	local checker = ns.Check.create(client, db, { version = '0.2.0', build = '1.15.8.1', charKey = CHAR })
	checker.api = fakeApi()
	client.HagglerDB = { version = 2, defaultRuleId = 'r1' }
	checker:Deliver(signal('LOAD', NOW, true, false))
	t.eq(Suite.resultOf(db, checker.run, itemById('load.clean')).state, 'pass')
	t.eq(Suite.resultOf(db, checker.run, itemById('client.error-hook')).state, 'pass')
	t.truthy(db.once['client.error-hook'], 'once answer stored')

	checker.api = fakeApi({
		hasLdb = function()
			error('boom')
		end,
	})
	checker:Deliver(signal('TICK'))
	local feed = Suite.resultOf(db, checker.run, itemById('feed.objects'))
	t.eq(feed.state, 'look')
	t.truthy(feed.evidence[1]:find('judge error', 1, true), 'judge error shown')

	local heard = {}
	checker:OnRecord(function(item)
		heard[#heard + 1] = item and item.id or 'reset'
	end)
	checker:Model().setVerdict(itemById('window.tabs'), 'pass')
	t.same(heard, { 'window.tabs' })
	checker:Model().setVerdict(itemById('window.tabs'), 'fail')
	checker:Model().setVerdict(itemById('window.tabs'), 'pass')
	t.eq(Suite.resultOf(db, checker.run, itemById('window.tabs')).state, 'pass', 'a misclicked fail changes back')
	t.eq(checker:Model().canSetVerdict(itemById('load.clean')), false, "a judged item is not the player's")

	db.once['client.override-query'] = { state = 'look', evidence = { 'unreadable' } }
	checker.api = fakeApi({
		bindingAction = function()
			return 'CLICK HagglerInputButton1:LeftButton'
		end,
	})
	client.HagglerDB.settings = { topbar = { focusKey = 'CTRL-SHIFT-H' } }
	checker:Deliver(signal('TICK'))
	t.eq(db.once['client.override-query'].state, 'pass', 'a once look keeps listening')
	checker:Reset()
	t.eq(Suite.resultOf(db, checker.run, itemById('window.tabs')), nil, 'fresh run')
	t.eq(db.once['client.error-hook'], nil, 'once answers cleared')
end)

t.test('Concord v1: the items register with adapted judges; a refusal falls back to Log', function()
	local client = fakeClient()
	local registered, logged = nil, {}
	local accepts = true
	client.ConcordCheck = {
		VERSION = 1,
		RegisterProbes = function(probes)
			registered = probes
			if accepts then
				return true
			end
			return false, 'run in progress'
		end,
		Log = function(...)
			logged[#logged + 1] = { ... }
		end,
	}
	local db = {}
	local checker = ns.Check.create(client, db, { version = '0.2.0', build = '1.15.8.1', charKey = CHAR })
	checker.api = fakeApi()
	client.HagglerDB = { version = 2 }

	t.same({ ns.Check.registerWithConcord(client, checker) }, { true })
	t.eq(registered.version, 1)
	t.eq(registered.owner, 'Haggler')
	t.eq(registered.addon, 'Haggler')
	t.eq(registered.label, 'Haggler')
	t.eq(registered.runKey, nil, 'the host makes the run key')
	t.eq(#registered.items, #Items.list)
	local byId = {}
	for _, item in ipairs(registered.items) do
		byId[item.id] = item
	end
	t.same(byId['load.clean'].events, { 'ADDON_ACTION_BLOCKED', 'ADDON_ACTION_FORBIDDEN' }, 'client events only')
	t.same({ byId['load.clean'].judge({ lines = {}, trigger = { kind = 'open' } }) }, { nil, {} }, 'nothing yet')
	checker:Deliver(signal('LOAD', NOW, true, false))
	local verdict, evidence = byId['load.clean'].judge({ lines = {}, trigger = { kind = 'event' } })
	t.eq(verdict, 'pass')
	t.truthy(evidence[1]:find('HagglerDB schema 2', 1, true))
	checker:Model().setVerdict(itemById('feed.display'), 'na')
	verdict, evidence = byId['feed.display'].judge({ lines = {}, trigger = { kind = 'answer' } })
	t.eq(verdict, 'pass', 'n/a has no host verdict: a pass that says so')
	t.eq(evidence[1], 'n/a')

	accepts = false
	t.same({ ns.Check.registerWithConcord(client, checker) }, { false, 'run in progress' })
	ns.Check.forwardToConcord(client, itemById('load.clean'), Suite.resultOf(db, checker.run, itemById('load.clean')))
	t.eq(logged[1][1], 'Haggler')
	t.eq(logged[1][2], 'PASS', 'Log takes PASS, FAIL or INFO')
	t.truthy(logged[1][3]:find('^load%.clean pass: '), 'text names the item and its state')
	ns.Check.forwardToConcord(
		client,
		itemById('feed.display'),
		Suite.resultOf(db, checker.run, itemById('feed.display'))
	)
	t.eq(logged[2][2], 'INFO', 'n/a has no Log verdict')
	ns.Check.forwardToConcord(
		client,
		itemById('load.clean'),
		Suite.resultOf(db, checker.run, itemById('load.clean')),
		true
	)
	t.eq(logged[3][2], 'INFO', 'registered: evidence only, the host judges')

	client.ConcordCheck.VERSION = 2
	registered, logged = nil, {}
	t.same({ ns.Check.registerWithConcord(client, checker) }, { false, 'no host' })
	ns.Check.forwardToConcord(client, itemById('load.clean'), Suite.resultOf(db, checker.run, itemById('load.clean')))
	t.eq(registered, nil, 'another contract version is never called')
	t.eq(#logged, 0)
	client.ConcordCheck.VERSION = 1
	client.ConcordCheck.RegisterProbes = function()
		error('host bug')
	end
	t.eq(ns.Check.registerWithConcord(client, checker), false, 'a host that raises is a refusal')
end)

t.test('Concord answers reach Haggler_CheckDB: by onAnswer, or from ConcordCheckDB on older hosts', function()
	local client = fakeClient()
	local registered
	client.ConcordCheck = {
		VERSION = 1,
		FEATURES = { onAnswer = true },
		RegisterProbes = function(probes)
			registered = probes
			return true
		end,
		Log = function() end,
	}
	local db = {}
	local checker = ns.Check.create(client, db, { version = '0.2.0', build = '1.15.8.1', charKey = CHAR })
	checker.api = fakeApi()
	local function resultOf(id)
		return Suite.resultOf(db, checker.run, itemById(id))
	end
	local function storeWith(records, current)
		current = current or 'run2'
		return { suites = { Haggler = { current = current, runs = { [current] = { items = records } } } } }
	end
	local function playerAnswer(id, state, at)
		return { id = id, state = state, answeredBy = 'player', at = at }
	end
	local function hostJudges()
		registered.items[1].judge({ lines = {}, trigger = { kind = 'line' } })
	end
	t.same({ ns.Check.registerWithConcord(client, checker) }, { true })
	t.eq(type(registered.onAnswer), 'function')

	client.ConcordCheckDB = storeWith({})
	registered.onAnswer({ owner = 'Haggler', id = 'window.tabs', answer = 'pass', runKey = 'run2' })
	t.eq(resultOf('window.tabs').state, 'pass', 'the answer reaches the DB')
	t.eq(resultOf('window.tabs').isByPlayer, true, 'as a player verdict')
	registered.onAnswer({ owner = 'Haggler', id = 'window.tabs', answer = 'fail', runKey = 'run2' })
	t.eq(resultOf('window.tabs').state, 'fail', 'a changed answer')
	registered.onAnswer({ owner = 'Haggler', id = 'window.tabs', answer = 'pass', runKey = 'run1' })
	t.eq(resultOf('window.tabs').state, 'fail', 'an answer for another Concord run is dropped')
	registered.onAnswer({ owner = 'Other', id = 'bar.look', answer = 'pass', runKey = 'run2' })
	t.eq(resultOf('bar.look'), nil, 'another owner')
	registered.onAnswer({ owner = 'Haggler', id = 'no.such-item', answer = 'pass', runKey = 'run2' })
	registered.onAnswer({ owner = 'Haggler', id = 'load.clean', answer = 'pass', runKey = 'run2' })
	t.eq(resultOf('load.clean'), nil, 'not open to a player verdict: Haggler judges it')
	client.ConcordCheckDB = storeWith({ playerAnswer('bar.look', 'pass', 't1') })
	hostJudges()
	t.eq(resultOf('bar.look'), nil, 'a host with onAnswer is not read behind its back')

	client.ConcordCheck.FEATURES = { onAnswer = false }
	hostJudges()
	t.eq(resultOf('bar.look').state, 'pass', 'an older host: read from ConcordCheckDB at judge time')
	t.eq(resultOf('bar.look').isByPlayer, true)
	checker:Model().setVerdict(itemById('bar.look'), 'na')
	hostJudges()
	t.eq(resultOf('bar.look').state, 'na', 'a later /hc verdict is not overwritten by the taken answer')
	client.ConcordCheckDB.suites.Haggler.runs.run2.items[1] = playerAnswer('bar.look', 'fail', 't2')
	hostJudges()
	t.eq(resultOf('bar.look').state, 'fail', 'a newer answer in Concord wins again')

	client.ConcordCheckDB = storeWith({
		{ id = 'feed.display', state = 'pass', fromOnce = true },
		{ id = 'focus.pad', state = 'pass', answeredBy = 'player', fromOnce = true },
	})
	hostJudges()
	t.eq(resultOf('feed.display'), nil, 'a once answer carried from an earlier run records nothing')
	t.eq(resultOf('focus.pad'), nil)

	client.ConcordCheckDB = storeWith({ playerAnswer('window.tabs', 'pass', 't3') })
	checker:Reset()
	hostJudges()
	t.eq(resultOf('window.tabs'), nil, 'an answer given before /hc reset is not taken into the new run')
	client.ConcordCheckDB.suites.Haggler.runs.run2.items[2] = playerAnswer('bar.look', 'pass', 't4')
	hostJudges()
	t.eq(resultOf('bar.look').state, 'pass', 'an answer after the reset is')

	client.ConcordCheckDB = storeWith({ { id = 'window.tabs', state = 'pending' } }, 'run3')
	hostJudges()
	t.eq(resultOf('window.tabs'), nil, 'a Concord reset (pending records) records nothing')
	client.ConcordCheckDB = { suites = { Haggler = { runs = {} } } }
	hostJudges()
	client.ConcordCheckDB = nil
	hostJudges()
	registered.onAnswer({ owner = 'Haggler', id = 'window.tabs', answer = 'pass', runKey = 'run3' })
	t.eq(resultOf('window.tabs'), nil, 'a missing store is no answer')
end)

t.group('identity on client 71037')

local function identityEnv(fields)
	local env = {
		GetBuildInfo = function()
			return '1.60.1', '71037'
		end,
		UnitName = function()
			return 'Aurelius', 'Zothari'
		end,
		GetRealmName = function()
			return ''
		end,
		UnitGUID = function(unit)
			return unit == 'player' and 'Player-6945-0052E899' or nil
		end,
	}
	for key, value in pairs(fields or {}) do
		env[key] = value
	end
	return env
end

t.test("the character key is Haggler's: client realm, else remembered realm, else server number", function()
	t.eq(ns.Check.readIdentity(identityEnv()).charKey, 'Aurelius-Server6945', 'the surname is not a realm')
	t.eq(
		ns.Check.readIdentity(identityEnv({ HagglerCharDB = { realm = 'CAMWOW EU5 Realm 3 PvE' } })).charKey,
		'Aurelius-CAMWOW EU5 Realm 3 PvE'
	)
	t.eq(
		ns.Check.readIdentity(identityEnv({
			GetRealmName = function()
				return 'Nightslayer'
			end,
		})).charKey,
		'Aurelius-Nightslayer'
	)
	t.eq(ns.Check.readIdentity(identityEnv({ UnitGUID = function() end })).charKey, nil, 'never "Name-"')
end)
