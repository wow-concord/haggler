-- A tiny test harness for luajit: no globals, no dependencies.
-- isV1Only: the release file set, without v2/ (luajit tests/run.lua --v1; run.lua sets it).
local harness = { passed = 0, failed = 0, failures = {}, isV1Only = false, skipped = 0 }

local ADDON_FILES = {
	'Host/Tokens.lua',
	'Host/Bus.lua',
	'Host/Settings.lua',
	'Host/Host.lua',
	'Engine/Wow.lua',
	'Engine/WowTracking.lua',
	'Engine/ItemMarket.lua',
	'Engine/PriceData.lua',
	'Engine/Rules.lua',
	'Engine/Store.lua',
	'Engine/ScanStore.lua',
	'Engine/Sales.lua',
	'Engine/Scan.lua',
	'Engine/PriceContext.lua',
	'Engine/PriceService.lua',
	'Engine/Guardrail.lua',
	'Engine/RuleEditor.lua',
	'Engine/Sell.lua',
	'Engine/Buy.lua',
	'Engine/Value.lua',
	'Engine/Trade.lua',
	'Engine/Ledger.lua',
	'Engine/CostPool.lua',
	'Engine/AuctionTracker.lua',
	'Engine/MailMatcher.lua',
	'Engine/VentureRecords.lua',
	'v2/Engine/Ventures.lua',
	'Engine/CraftCost.lua',
	'Engine/Books.lua',
	'Engine/OwnOnly.lua',
	'v2/Engine/Flips.lua',
	'Engine/Advice.lua',
	'Host/Theme.lua',
	'Host/Tooltip.lua',
	'media/icons/Icons.lua',
	'Host/Icons.lua',
	'Host/Badges.lua',
	'Host/Widgets.lua',
	'Host/Input.lua',
	'Host/BagHosts/BagHosts.lua',
	'Host/BagHosts/Blizzard.lua',
	'Host/BagHosts/BagPad.lua',
	'Host/BagHosts/Bagnon.lua',
	'Host/BagHosts/Baganator.lua',
	'Features/Tooltip/Lines.lua',
	'Features/Bags/View.lua',
	'Features/Trade/Model.lua',
	'Features/Trade/Frames.lua',
	'Features/Window/Model.lua',
	'Features/TopBar/Model.lua',
	'Features/TopBar/Feed.lua',
}

local currentGroup = ''

local function describeValue(value)
	if type(value) == 'string' then
		return string.format('%q', value)
	end
	return tostring(value)
end

local function deepEqual(a, b, path)
	if type(a) ~= type(b) then
		return false, string.format('%s: %s ~= %s', path, describeValue(a), describeValue(b))
	end
	if type(a) ~= 'table' then
		if a == b then
			return true
		end
		return false, string.format('%s: %s ~= %s', path, describeValue(a), describeValue(b))
	end
	for key, value in pairs(a) do
		local ok, why = deepEqual(value, b[key], path .. '.' .. tostring(key))
		if not ok then
			return false, why
		end
	end
	for key, value in pairs(b) do
		if a[key] == nil then
			return false, string.format('%s.%s: missing, expected %s', path, tostring(key), describeValue(value))
		end
	end
	return true
end

function harness.group(name)
	currentGroup = name
end

function harness.test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		harness.passed = harness.passed + 1
	else
		harness.failed = harness.failed + 1
		harness.failures[#harness.failures + 1] = string.format('%s > %s: %s', currentGroup, name, tostring(err))
	end
end

function harness.eq(actual, expected, what)
	if actual ~= expected then
		error(
			string.format('%s: expected %s, got %s', what or 'value', describeValue(expected), describeValue(actual)),
			2
		)
	end
end

function harness.same(actual, expected, what)
	local ok, why = deepEqual(actual, expected, what or 'value')
	if not ok then
		error(why, 2)
	end
end

function harness.truthy(value, what)
	if not value then
		error(string.format('%s: expected a truthy value, got %s', what or 'value', describeValue(value)), 2)
	end
end

function harness.raises(fn, pattern)
	local ok, err = pcall(fn)
	if ok then
		error('expected an error', 2)
	end
	if pattern and not tostring(err):find(pattern) then
		error(string.format('error %q does not match %q', tostring(err), pattern), 2)
	end
end

--- The paths a run loads: all of them, or in a V1-only run those outside v2/ (the release set).
--- @param paths string[]
--- @return string[]
function harness.addonPaths(paths)
	local kept = {}
	for _, path in ipairs(paths) do
		if not (harness.isV1Only and path:find('^v2/')) then
			kept[#kept + 1] = path
		end
	end
	return kept
end

--- A test of V2 code (Flips, Ventures): skipped in a V1-only run, where v2/ is not loaded.
function harness.v2test(name, fn)
	if harness.isV1Only then
		harness.skipped = harness.skipped + 1
		return
	end
	harness.test(name, fn)
end

--- Loads the add-on's files into a fresh namespace, as the game would.
function harness.loadAddon()
	local ns = {}
	for _, path in ipairs(harness.addonPaths(ADDON_FILES)) do
		local chunk = assert(loadfile(path))
		chunk('Haggler', ns)
	end
	return ns
end

return harness
