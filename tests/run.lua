-- Runs every tests/*_spec.lua under luajit. Run from the repo root: luajit tests/run.lua
package.path = './?.lua;' .. package.path
local harness = require('tests.harness')

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
	harness.group(path:match('([^/]+)_spec%.lua$'))
	local chunk = assert(loadfile(path))
	chunk(harness)
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
print(string.format('%d passed, %d failed', harness.passed, harness.failed))
os.exit(harness.failed == 0 and 0 or 1)
