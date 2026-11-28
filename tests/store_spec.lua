local t = ...
local ns = t.loadAddon()
local Store = ns.Store

t.group('migrations')

t.test('runs each migration in order and stamps the version', function()
	local order = {}
	local migrations = {
		[1] = function(db)
			order[#order + 1] = 1
			db.a = true
		end,
		[2] = function(db)
			order[#order + 1] = 2
			db.b = db.a
		end,
		[3] = function()
			order[#order + 1] = 3
		end,
	}
	local db = Store.migrate({}, migrations, 3)
	t.same(order, { 1, 2, 3 })
	t.eq(db.version, 3)
	t.eq(db.b, true)
end)

t.test('starts from the stored version', function()
	local order = {}
	local migrations = {
		[1] = function()
			order[#order + 1] = 1
		end,
		[2] = function()
			order[#order + 1] = 2
		end,
	}
	Store.migrate({ version = 1 }, migrations, 2)
	t.same(order, { 2 })
end)

t.test('refuses data from a newer schema and leaves it alone', function()
	local db = { version = 99, keep = 'me' }
	local result, reason = Store.migrate(db)
	t.eq(result, nil)
	t.eq(reason, 'newer schema')
	t.same(db, { version = 99, keep = 'me' })
end)

t.test('a missing migration step is a bug', function()
	t.raises(function()
		Store.migrate({}, {}, 1)
	end, 'no migration to version 1')
end)

t.test('0 -> 1 parks an unversioned layout under legacy', function()
	local db = { sellLog = { 1, 2 }, mode = 'realistic' }
	Store.migrate(db, nil, 1)
	t.eq(db.version, 1)
	t.same(db.legacy, { sellLog = { 1, 2 }, mode = 'realistic' })
	t.eq(db.sellLog, nil)
end)

t.test('1 -> 2 packs saved scan items; broken ones are dropped', function()
	local db = {
		version = 1,
		markets = {
			['forever/normal/alliance/us'] = {
				scan = {
					at = 10,
					hasBands = true,
					items = {
						[2589] = {
							min = 91,
							units = 37,
							copperSeen = true,
							maxStackSeen = 20,
							levels = { { price = 91, qty = 5 }, { price = 100, qty = 32, short = 12 } },
						},
						[2592] = { min = 1, units = 1, levels = { { price = 'x', qty = 1 } } },
						[2488] = 'junk',
					},
				},
			},
			['forever/normal/horde/us'] = { scan = 'junk' },
		},
	}
	Store.migrate(db, nil, 2)
	t.eq(db.version, 2)
	local scan = db.markets['forever/normal/alliance/us'].scan
	t.eq(scan.isPacked, true)
	t.same(scan.items, { [2589] = '37,1,20;91:5,100:32:12' })
	t.eq(db.markets['forever/normal/horde/us'].scan, 'junk', 'left for ScanStore.latest to ignore')
end)

t.group('store')

t.test('a first run builds the whole layout and seeds the built-in rules', function()
	local db, charDb = {}, {}
	local store = Store.open(db, charDb)
	t.eq(db.version, Store.SCHEMA_VERSION)
	for _, name in ipairs({ 'settings', 'rules', 'shownRules', 'recipes', 'markets', 'characters', 'sessions' }) do
		t.eq(type(db[name]), 'table', name)
	end
	t.eq(db.legacy, nil, 'nothing to park on a first run')
	t.eq(db.defaultRuleId, 'realistic')
	t.truthy(db.rules.realistic.builtIn)
	t.truthy(db.rules.minimum)
	t.truthy(db.rules.median)
	t.same(db.shownRules, { tooltip = {}, crafting = {}, ah = {}, bar = {} })
	t.same(charDb, { version = 1, ui = {} })
	t.eq(store:Settings(), db.settings)
end)

t.test('opening again keeps tuned built-ins and adds missing ones', function()
	local db = {}
	Store.open(db, {})
	db.rules.realistic.antiBait.minutes = 30
	db.rules.median = nil
	Store.open(db, {})
	t.eq(db.rules.realistic.antiBait.minutes, 30)
	t.truthy(db.rules.median)
end)

t.test('open refuses newer data, account or character', function()
	local store, reason = Store.open({ version = Store.SCHEMA_VERSION + 1 }, {})
	t.eq(store, nil)
	t.eq(reason, 'newer schema')
	local db = {}
	store, reason = Store.open(db, { version = 9 })
	t.eq(store, nil)
	t.eq(reason, 'newer schema')
	t.eq(db.version, nil, 'account data untouched when the character data is newer')
end)

t.test('markets are grouped by market key and created on first use', function()
	local store = Store.open({}, {})
	local market = store:Market('forever/normal/alliance/us')
	t.same(market, { scanDays = {}, ventures = {}, auctions = {}, ledger = {}, costPools = {}, ledgerDays = {} })
	market.ledger[1] = 'event'
	t.eq(store:Market('forever/normal/alliance/us').ledger[1], 'event')
	t.raises(function()
		store:Market('normal/alliance')
	end, 'bad market key')
end)

t.test('market keys follow AHledger, rulesets read from the realm name', function()
	t.eq(
		Store.marketKeyFor({ realm = 'Nightslayer', faction = 'Alliance', region = 'us' }),
		'forever/normal/alliance/us'
	)
	t.eq(
		Store.marketKeyFor({ realm = 'Doomhowl Hardcore', faction = 'Horde', region = 'us' }),
		'forever/hardcore/horde/us'
	)
	t.eq(Store.rulesetFromRealm('Crusader Strike PvP'), 'pvp')
	t.eq(Store.rulesetFromRealm('Living Flame RP'), 'rp')
	t.eq(Store.rulesetFromRealm('Wild Growth RP PvP'), 'rppvp')
	t.eq(Store.rulesetFromRealm('Sulfuron JcJ'), 'pvp')
	t.eq(Store.rulesetFromRealm('Les Ombres JdR'), 'rp')
	t.eq(Store.rulesetFromRealm('Grumpy'), 'normal', 'rp inside a word is not RP')
	t.eq(Store.rulesetFromRealm(nil), 'normal')
	t.truthy(Store.isMarketKey('forever/rppvp/horde/eu'))
	t.eq(Store.isMarketKey('forever/normal/alliance'), false)
end)

t.test('characters by Name-Realm', function()
	local store = Store.open({}, {})
	store:Character('Eilu-Nightslayer').gold = 5
	t.eq(store:Character('Eilu-Nightslayer').gold, 5)
	t.raises(function()
		store:Character('Eilu')
	end, 'bad character key')
end)

t.group('store rules')

local function customRule(id)
	return { id = id, name = 'Quick sale', base = { kind = 'lowest' }, steps = {}, antiBait = { enabled = false } }
end

t.test('saves a valid custom rule as a copy; refuses an invalid one', function()
	local store = Store.open({}, {})
	local rule = customRule('quick')
	t.truthy(store:SaveRule(rule))
	rule.name = 'changed after save'
	t.eq(store:Rule('quick').name, 'Quick sale')
	t.eq(store:Rule('quick').builtIn, nil)
	local ok, reason = store:SaveRule({ id = 'bad', name = 'Bad', base = { kind = 'guess' }, steps = {} })
	t.eq(ok, nil)
	t.truthy(reason:find('unknown kind'))
end)

t.test('saving a tuned built-in keeps it built-in', function()
	local store = Store.open({}, {})
	local tuned = ns.Rules.copy(store:Rule('median'))
	tuned.builtIn = nil
	tuned.steps = { { kind = 'multiply', factor = 0.9 } }
	t.truthy(store:SaveRule(tuned))
	t.eq(store:Rule('median').builtIn, true)
end)

t.test('rule ids list built-ins first, then by name', function()
	local store = Store.open({}, {})
	store:SaveRule(customRule('quick'))
	local ids = store:RuleIds()
	t.eq(#ids, 4)
	t.eq(ids[4], 'quick')
	t.eq(store:Rule(ids[1]).builtIn, true)
end)

t.test('delete removes a custom rule everywhere; built-ins only reset', function()
	local store = Store.open({}, {})
	store:SaveRule(customRule('quick'))
	store:SetDefaultRule('quick')
	store.db.shownRules.tooltip = { 'median', 'quick' }
	t.truthy(store:DeleteRule('quick'))
	t.eq(store:DefaultRuleId(), 'realistic')
	t.same(store.db.shownRules.tooltip, { 'median' })
	local ok, reason = store:DeleteRule('median')
	t.eq(ok, nil)
	t.eq(reason, 'built-in rules can be reset, not deleted')
	ok, reason = store:DeleteRule('nope')
	t.eq(ok, nil)
	t.eq(reason, 'unknown rule')
end)

t.test('reset puts a built-in back as shipped', function()
	local store = Store.open({}, {})
	store:Rule('minimum').steps = {}
	t.truthy(store:ResetRule('minimum'))
	t.same(store:Rule('minimum'), ns.Rules.builtIns().minimum)
	local _, reason = store:ResetRule('quick')
	t.eq(reason, 'not a built-in rule')
end)

t.test('the default rule must exist and always heads the shown rules', function()
	local store = Store.open({}, {})
	local _, reason = store:SetDefaultRule('nope')
	t.eq(reason, 'unknown rule')
	t.truthy(store:SetDefaultRule('median'))
	store.db.shownRules.crafting = { 'minimum', 'median', 'gone' }
	t.same(store:ShownRules('crafting'), { 'median', 'minimum' })
	t.same(store:ShownRules('bar'), { 'median' })
end)

t.test('a default rule that vanished falls back to Realistic on open', function()
	local db = {}
	Store.open(db, {})
	db.defaultRuleId = 'deleted'
	Store.open(db, {})
	t.eq(db.defaultRuleId, 'realistic')
end)

t.test('rule ids sort without throwing when a saved rule lost its name', function()
	local store = Store.open({}, {})
	store:SaveRule(customRule('quick'))
	store.db.rules.nameless = { id = 'nameless', base = { kind = 'median' }, steps = {} }
	local ids = store:RuleIds()
	t.eq(#ids, 5)
	t.eq(ids[5], 'nameless', 'a nameless rule sorts by its id')
end)

t.group('realm and character key with no realm name from the client')

local SAVED_REALM = 'CAMWOW EU5 Realm 3 PvE'

local function realmless(fields)
	local player = { name = 'Eilu', realm = '', faction = 'Horde', region = 'eu', server = 6928 }
	for key, value in pairs(fields or {}) do
		player[key] = value
	end
	return player
end

t.test("the client's realm name is the key, and is remembered for this character", function()
	local charDb = {}
	local store = assert(Store.open({}, charDb))
	t.eq(store:CharacterKey(realmless({ realm = 'Nightslayer' })), 'Eilu-Nightslayer')
	t.eq(charDb.realm, 'Nightslayer')
	t.eq(store:CharacterKey(realmless()), 'Eilu-Nightslayer', 'the remembered name, once the client gives none')
	t.same({ store:ResolveRealm(realmless()) }, { 'Nightslayer', 'remembered' })
end)

t.test('with no memory, the one realm saved keys name for this character is taken and kept', function()
	local charDb = {}
	local store = assert(Store.open({}, charDb))
	store:Session('Eilu-' .. SAVED_REALM).resetAt = 1
	store:Session('Other-Somewhere').resetAt = 1
	t.same({ store:ResolveRealm(realmless()) }, { SAVED_REALM, 'saved' })
	t.eq(store:CharacterKey(realmless()), 'Eilu-' .. SAVED_REALM)
	t.eq(charDb.realm, SAVED_REALM)
end)

t.test('the same name saved on two realms names no realm: the server number stands in', function()
	local store = assert(Store.open({}, {}))
	store:Session('Eilu-Nightslayer').resetAt = 1
	store:Character('Eilu-Doomhowl')
	t.eq((store:ResolveRealm(realmless())), nil)
	t.eq(store:CharacterKey(realmless()), 'Eilu-Server6928')
end)

t.test('a server-number key is not taken for a realm name', function()
	local charDb = {}
	local store = assert(Store.open({}, charDb))
	store:Session('Eilu-Server6928').resetAt = 1
	t.eq((store:ResolveRealm(realmless())), nil)
	t.eq(charDb.realm, nil)
end)

t.test('never "Name-": no name, or no realm and no server, is no key', function()
	local store = assert(Store.open({}, {}))
	t.eq(store:CharacterKey(realmless({ server = false })), nil)
	t.eq(store:CharacterKey(realmless({ name = '' })), nil)
	t.eq(store:CharacterKey(realmless({ name = false })), nil)
	t.eq(store:CharacterKey(nil), nil)
end)

t.test("a realm is remembered with the server's id, and a session saved with it carries it", function()
	local charDb = {}
	local store = assert(Store.open({}, charDb))
	store:CharacterKey(realmless({ realm = 'Nightslayer' }))
	t.eq(charDb.server, 6928)
	t.eq(store:Session('Eilu-Nightslayer', 6928).server, 6928)
	t.eq(store:Session('Eilu-Nightslayer').server, 6928, 'kept when a later call gives none')
end)

t.test("a namesake's session saved with another server's id names no realm for this character", function()
	local charDb = {}
	local store = assert(Store.open({}, charDb))
	store:Session('Eilu-Nightslayer', 6945).resetAt = 1
	t.eq((store:ResolveRealm(realmless())), nil)
	t.eq(store:CharacterKey(realmless()), 'Eilu-Server6928')
	t.eq(charDb.realm, nil, 'nothing is kept for good')
end)

t.test("a session saved with this server's id outranks legacy records that disagree", function()
	local charDb = {}
	local store = assert(Store.open({}, charDb))
	store:Session('Eilu-Nightslayer', 6928).resetAt = 1
	store:Character('Eilu-Doomhowl')
	t.same({ store:ResolveRealm(realmless()) }, { 'Nightslayer', 'saved' })
	t.eq(charDb.server, 6928)
end)

t.test("legacy records count only while no other server's record names a realm", function()
	local store = assert(Store.open({}, {}))
	store:Market('forever/normal/horde/eu').auctions[7] = { state = 'sold', char = 'Eilu-Nightslayer' }
	store:Session('Eilu-Nightslayer', 6945).resetAt = 1
	t.eq((store:ResolveRealm(realmless())), nil, "the legacy auction is server 6945's character's")
end)

t.test("a realm remembered for another server's id is not this character's", function()
	local store = assert(Store.open({}, { realm = 'Nightslayer', server = 6945 }))
	t.eq((store:ResolveRealm(realmless())), nil)
	local legacy = assert(Store.open({}, { realm = 'Nightslayer' }))
	t.same({ legacy:ResolveRealm(realmless()) }, { 'Nightslayer', 'remembered' }, 'one saved before the id was')
end)

t.test("before the GUID answers, no realm is taken, kept or cached: a namesake's stays theirs", function()
	local charDb = {}
	local store = assert(Store.open({}, charDb))
	store:Session('Eilu-RealmA', 100).resetAt = 1
	local beforeGuid = realmless({ server = false })
	t.eq((store:ResolveRealm(beforeGuid)), nil)
	t.eq(store:CharacterKey(beforeGuid), nil)
	t.eq(charDb.realm, nil)
	t.eq(charDb.server, nil)
	t.eq(store:CharacterKey(realmless({ server = 200 })), 'Eilu-Server200', 'nothing cached blocks the lookup')
	t.eq(store.db.sessions['Eilu-RealmA'].server, 100)
end)

t.test("a session's server id is never overwritten with another one", function()
	local store = assert(Store.open({}, {}))
	store:Session('Eilu-RealmA', 100)
	t.eq(store:Session('Eilu-RealmA', 200).server, 100)
end)

t.test('a remembered realm saved without a server id gets it once known, and waits for the GUID', function()
	local charDb = { realm = 'Nightslayer' }
	local store = assert(Store.open({}, charDb))
	t.eq((store:ResolveRealm(realmless({ server = false }))), nil, 'no GUID yet')
	t.same({ store:ResolveRealm(realmless()) }, { 'Nightslayer', 'remembered' })
	t.eq(charDb.server, 6928)
end)

t.test('no realm anywhere is looked up once a session, not on every key', function()
	local store = assert(Store.open({}, {}))
	local market = store:Market('forever/normal/horde/eu')
	ns.Ledger.append(market, { t = 1, kind = 'sale', itemId = 2589, qty = 1, copper = 1, char = 'Other-Elsewhere' })
	local events = ns.Ledger.events
	local scans = 0
	ns.Ledger.events = function(...)
		scans = scans + 1
		return events(...)
	end
	local ok, problem = pcall(function()
		for _ = 1, 3 do
			t.eq(store:CharacterKey(realmless()), 'Eilu-Server6928')
		end
	end)
	ns.Ledger.events = events
	assert(ok, problem)
	t.eq(scans, 1)
end)

t.test("with no realm name the market's ruleset is AHledger's, when its faction and region match", function()
	local store = assert(Store.open({}, {}))
	t.eq(store:MarketKeyFor(realmless(), 'forever/pvp/horde/eu'), 'forever/pvp/horde/eu')
	t.eq(store:MarketKeyFor(realmless(), 'forever/pvp/alliance/eu'), 'forever/normal/horde/eu', 'other faction')
	t.eq(store:MarketKeyFor(realmless(), 'forever/rp/horde/us'), 'forever/normal/horde/eu', 'other region')
	t.eq(store:MarketKeyFor(realmless(), 'forever/odd/horde/eu'), 'forever/normal/horde/eu', 'unknown ruleset')
	t.eq(store:MarketKeyFor(realmless(), nil), 'forever/normal/horde/eu', 'no AHledger')
end)

t.test("a realm name, the client's or remembered, outranks AHledger's market", function()
	local store = assert(Store.open({}, { realm = 'Crusader Strike PvP' }))
	t.eq(store:MarketKeyFor(realmless(), 'forever/rp/horde/eu'), 'forever/pvp/horde/eu')
	t.eq(store:MarketKeyFor(realmless({ realm = 'Living Flame RP' }), 'forever/pvp/horde/eu'), 'forever/rp/horde/eu')
end)

t.group('records saved under the broken "Name-" key')

local HORDE_EU = 'forever/normal/horde/eu'
local ALLIANCE_EU = 'forever/normal/alliance/eu'

local function seedBrokenRecords(store, marketKey, char)
	local market = store:Market(marketKey)
	market.auctions[101] = {
		itemId = 2589,
		qty = 20,
		remaining = 20,
		listed = 20,
		unitPrice = 25,
		deposit = 60,
		postedAt = 900,
		hours = 48,
		state = 'active',
		changedAt = 900,
		char = char,
		knownUnits = 0,
		knownCopper = 0,
	}
	market.auctions[102] = { itemId = 2589, qty = 20, state = 'sold', char = 'Other-Elsewhere' }
	ns.Ledger.append(market, { t = 1000, kind = 'sale', itemId = 2589, qty = 20, copper = 500, char = char })
	ns.Ledger.append(market, { t = 1001, kind = 'sale', itemId = 2589, qty = 1, copper = 5, char = 'Other-Elsewhere' })
	return market
end

local function charsOf(market)
	local chars = {}
	for _, event in ipairs(ns.Ledger.events(market)) do
		chars[#chars + 1] = event.char
	end
	return chars
end

t.test('the first key for a character takes over its "Name-" auctions and ledger events', function()
	local store = assert(Store.open({}, { realm = SAVED_REALM }))
	local market = seedBrokenRecords(store, HORDE_EU, 'Eilu-')
	local key = store:CharacterKey(realmless())
	t.eq(key, 'Eilu-' .. SAVED_REALM)
	t.eq(market.auctions[101].char, key)
	t.eq(market.auctions[102].char, 'Other-Elsewhere', "someone else's record stays")
	t.same(charsOf(market), { key, 'Other-Elsewhere' })
	t.eq(#ns.AuctionTracker.list(market, { state = 'active', char = key }), 1)
end)

t.test('"Name-" records on another faction or region are not this character\'s', function()
	local store = assert(Store.open({}, { realm = SAVED_REALM }))
	local other = seedBrokenRecords(store, ALLIANCE_EU, 'Eilu-')
	store:CharacterKey(realmless())
	t.eq(other.auctions[101].char, 'Eilu-')
	t.same(charsOf(other), { 'Eilu-', 'Other-Elsewhere' })
end)

t.test('the server-number key takes them over too, when no realm is known', function()
	local store = assert(Store.open({}, {}))
	local market = seedBrokenRecords(store, HORDE_EU, 'Eilu-')
	t.eq(store:CharacterKey(realmless()), 'Eilu-Server6928')
	t.eq(market.auctions[101].char, 'Eilu-Server6928')
end)

t.test('an auction or ledger event under the realm name recovers it', function()
	local fromAuction = assert(Store.open({}, {}))
	fromAuction:Market(HORDE_EU).auctions[7] = { state = 'sold', char = 'Eilu-' .. SAVED_REALM }
	t.same({ fromAuction:ResolveRealm(realmless()) }, { SAVED_REALM, 'saved' })
	local fromLedger = assert(Store.open({}, {}))
	ns.Ledger.append(
		fromLedger:Market(HORDE_EU),
		{ t = 1, kind = 'sale', itemId = 2589, qty = 1, copper = 1, char = 'Eilu-' .. SAVED_REALM }
	)
	t.same({ fromLedger:ResolveRealm(realmless()) }, { SAVED_REALM, 'saved' })
	local otherFaction = assert(Store.open({}, {}))
	otherFaction:Market(ALLIANCE_EU).auctions[7] = { state = 'sold', char = 'Eilu-Nightslayer' }
	t.eq((otherFaction:ResolveRealm(realmless())), nil, "another faction's namesake is not evidence")
end)
