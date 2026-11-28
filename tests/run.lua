-- Runs every tests/*_spec.lua under luajit. Run from the repo root: luajit tests/run.lua
-- That runs the dev file set (with v2/), then again as the release set (--v1): without v2/,
-- the V2 specs and v2tests skipped. luajit tests/run.lua --v1 runs only the second pass.
package.path = './?.lua;' .. package.path
local harness = require('tests.harness')

-- Specs of V2 code only (v2/); a V1-only run skips them whole.
local V2_SPECS = { ['tests/flips_spec.lua'] = true, ['tests/ventures_spec.lua'] = true }
local isV1Only = arg[1] == '--v1'
harness.isV1Only = isV1Only

local function listSpecs()
	local specs = {}
	local listing = assert(io.popen('ls tests/*_spec.lua 2>/dev/null'))
	for path in listing:lines() do
		specs[#specs + 1] = path
	end
	listing:close()
	table.sort(specs)
	return specs
end

local globalsBefore = {}
for name in pairs(_G) do
	globalsBefore[name] = true
end

-- Strict mode: a global write during the specs is an error, except the globals the add-on owns
-- (the same list as .luacheckrc).
local OWNED_GLOBALS = { HagglerDB = true, HagglerCharDB = true, HagglerArchiveDB = true, SLASH_HAGGLER1 = true }
setmetatable(_G, {
	__newindex = function(globals, name, value)
		if not OWNED_GLOBALS[name] then
			error('global write: ' .. tostring(name), 2)
		end
		rawset(globals, name, value)
	end,
})

local specs = listSpecs()
if #specs == 0 then
	print('No specs found; run from the repo root.')
	os.exit(1)
end
for _, path in ipairs(specs) do
	if isV1Only and V2_SPECS[path] then
		harness.skipped = harness.skipped + 1
		goto continue
	end
	harness.group(path:match('([^/]+)_spec%.lua$'))
	local chunk = assert(loadfile(path))
	chunk(harness)
	::continue::
end

-- The add-on must not leak globals (the bootstrap's SavedVariables are not loaded here).
harness.group('globals')
harness.test('no file leaks a global', function()
	local leaked = {}
	for name in pairs(_G) do
		if not globalsBefore[name] then
			leaked[#leaked + 1] = tostring(name)
		end
	end
	table.sort(leaked)
	harness.eq(table.concat(leaked, ', '), '', 'leaked globals')
end)

for _, failure in ipairs(harness.failures) do
	print('FAIL ' .. failure)
end
local scope = isV1Only and 'V1 release set' or 'dev set'
print(string.format('%s: %d passed, %d failed, %d skipped', scope, harness.passed, harness.failed, harness.skipped))
local isPassed = harness.failed == 0
if not isV1Only then
	-- The release pass runs in a fresh luajit: no module the dev pass loaded leaks into it.
	local luajit = arg[-1] or 'luajit'
	local status = os.execute(luajit .. ' tests/run.lua --v1')
	isPassed = isPassed and (status == 0 or status == true)
end
os.exit(isPassed and 0 or 1)
