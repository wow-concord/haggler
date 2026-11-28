--[[
	Settings: each module declares its settings as a schema, a list of entries of four kinds:

	  { key, type = 'toggle', label, default = boolean }
	  { key, type = 'slider', label, default, min, max, step? }        step defaults to 1
	  { key, type = 'choice', label, default, choices = { { value, label }, ... } }
	  { key, type = 'binding', label, default = '' }                    a key name; '' is unbound

	Any entry may also carry a note (a line shown under it in /hag list) and isHidden, a
	fun(settings): boolean that leaves the entry out of /hag list while it has no effect; get, set
	and reset still reach it.

	Defaults live in the schema; the stored table keeps only values that differ from them, so a
	changed default reaches everyone who never touched the setting. The /hag command tree is
	generated from the same schemas, so a window drawn from them later always matches.

	A setting a module drops can be carried over once with TakeRetired, which hands back its stored
	value and removes it.

	A bad schema is a programmer error and throws. A bad value from the player is an expected
	outcome: Set and Parse return nil and a reason.
]]
local _, ns = ...

local Settings = {}
ns.Settings = Settings

local KINDS = { toggle = true, slider = true, choice = true, binding = true }
-- A slider value this close to a step counts as on it (0.1 steps are not exact in binary).
local STEP_TOLERANCE = 1e-9
local KEY_PATTERN = '^%a[%w_]*$'
local TRUE_WORDS = { on = true, ['true'] = true, yes = true, ['1'] = true }
local FALSE_WORDS = { off = false, ['false'] = false, no = false, ['0'] = false }

-- Helpers live at the bottom of the file; declared here so they stay local.
local validateSchema, validateEntry, checkValue, parseText, formatValue, splitPath, splitWords, sortedKeys
local runHelp, runList, runGet, runSet, runReset

local SettingsMethods = {}
SettingsMethods.__index = SettingsMethods

--- The commands every /hag tree has; a module command may not use these names.
Settings.BUILT_IN_COMMANDS = { help = true, list = true, get = true, set = true, reset = true }

--- Checks a schema without registering it; throws on a bad one (a programmer error).
--- @param moduleKey string
--- @param schema table list of entries
function Settings.validateSchema(moduleKey, schema)
	validateSchema(moduleKey, schema)
end

--- Creates a settings store over a saved table.
--- @param stored table|nil saved values, { [moduleKey] = { [key] = value } }; changed in place
--- @param onChange fun(moduleKey: string, key: string, value: any, oldValue: any)|nil
--- @return table settings
function Settings.new(stored, onChange)
	if stored ~= nil and type(stored) ~= 'table' then
		error('Settings.new: stored must be a table or nil', 2)
	end
	return setmetatable({
		stored = stored or {},
		schemas = {},
		onChange = onChange,
	}, SettingsMethods)
end

--- Registers a module's schema. Registering the same module again replaces its schema.
--- @param moduleKey string
--- @param schema table list of entries
function SettingsMethods:Register(moduleKey, schema)
	if type(moduleKey) ~= 'string' or not moduleKey:find(KEY_PATTERN) then
		error('Settings:Register: moduleKey must be an identifier', 2)
	end
	local entriesByKey = validateSchema(moduleKey, schema)
	self.schemas[moduleKey] = { list = schema, byKey = entriesByKey }
end

--- @return boolean true when the module has a registered schema
function SettingsMethods:HasModule(moduleKey)
	return self.schemas[moduleKey] ~= nil
end

--- Registered module keys, sorted.
function SettingsMethods:Modules()
	return sortedKeys(self.schemas)
end

--- The module's schema entries in declared order.
function SettingsMethods:Schema(moduleKey)
	local schema = self.schemas[moduleKey]
	if not schema then
		error(string.format('Settings: unknown module %q', tostring(moduleKey)), 2)
	end
	return schema.list
end

--- The current value: the stored one when it is still valid for the schema, else the default.
function SettingsMethods:Get(moduleKey, key)
	local entry = self:Entry(moduleKey, key)
	local moduleValues = self.stored[moduleKey]
	local value = moduleValues and moduleValues[key]
	if value == nil then
		return entry.default
	end
	local checked = checkValue(entry, value)
	if checked == nil then
		return entry.default
	end
	return checked
end

--- Whether a value is stored (a value equal to the default is not stored, so reads as unset).
function SettingsMethods:IsSet(moduleKey, key)
	self:Entry(moduleKey, key)
	local moduleValues = self.stored[moduleKey]
	return moduleValues ~= nil and moduleValues[key] ~= nil
end

--- Sets a value after checking it against the schema.
--- @return boolean|nil true when stored
--- @return string|nil reason when the value is refused
function SettingsMethods:Set(moduleKey, key, value)
	local entry = self:Entry(moduleKey, key)
	local checked, reason = checkValue(entry, value)
	if checked == nil then
		return nil, reason
	end
	local oldValue = self:Get(moduleKey, key)
	local moduleValues = self.stored[moduleKey] or {}
	if checked == entry.default then
		moduleValues[key] = nil
	else
		moduleValues[key] = checked
	end
	self.stored[moduleKey] = next(moduleValues) and moduleValues or nil
	if oldValue ~= checked and self.onChange then
		self.onChange(moduleKey, key, checked, oldValue)
	end
	return true
end

--- Parses a typed value from command text, then sets it.
--- @return boolean|nil true when stored
--- @return string|nil reason when the text is refused
function SettingsMethods:SetFromText(moduleKey, key, text)
	local value, reason = parseText(self:Entry(moduleKey, key), text)
	if value == nil then
		return nil, reason
	end
	return self:Set(moduleKey, key, value)
end

--- Resets one setting, or every setting of the module when key is nil, to its default.
function SettingsMethods:Reset(moduleKey, key)
	local keys = key and { key } or {}
	if not key then
		for _, entry in ipairs(self:Schema(moduleKey)) do
			keys[#keys + 1] = entry.key
		end
	end
	for _, resetKey in ipairs(keys) do
		local entry = self:Entry(moduleKey, resetKey)
		self:Set(moduleKey, resetKey, entry.default)
	end
end

--- The default values of a module, { [key] = default }.
function SettingsMethods:Defaults(moduleKey)
	local defaults = {}
	for _, entry in ipairs(self:Schema(moduleKey)) do
		defaults[entry.key] = entry.default
	end
	return defaults
end

--- The schema entry for a setting; throws for an unknown module or key (a caller bug).
function SettingsMethods:Entry(moduleKey, key)
	local schema = self.schemas[moduleKey]
	local entry = schema and schema.byKey[key]
	if not entry then
		error(string.format('Settings: unknown setting %s.%s', tostring(moduleKey), tostring(key)), 2)
	end
	return entry
end

--- Removes a stored value whose key is no longer in the module's schema and returns it, so a
--- module can carry an old setting over to its new one. Throws for a key the schema still has.
--- @return any|nil the stored value, nil when none was stored
function SettingsMethods:TakeRetired(moduleKey, key)
	local schema = self.schemas[moduleKey]
	if schema and schema.byKey[key] then
		error(string.format('Settings:TakeRetired: %s.%s is still a setting', tostring(moduleKey), tostring(key)), 2)
	end
	local moduleValues = self.stored[moduleKey]
	if type(moduleValues) ~= 'table' then
		return nil
	end
	local value = moduleValues[key]
	moduleValues[key] = nil
	self.stored[moduleKey] = next(moduleValues) and moduleValues or nil
	return value
end

--- Text for a value, as the command tree prints it.
function SettingsMethods:Format(moduleKey, key)
	return formatValue(self:Entry(moduleKey, key), self:Get(moduleKey, key))
end

--- The command tree generated from the schemas, plus extra commands from the host.
--- Each node is { usage, help, run = fun(settings, args): lines }.
--- @param extraCommands table|nil { [name] = { usage, help, run = fun(args): lines } }
function SettingsMethods:CommandTree(extraCommands)
	local tree = {
		help = { usage = 'help', help = 'Lists the commands.', run = runHelp },
		list = { usage = 'list [module]', help = 'Lists settings and their values.', run = runList },
		get = { usage = 'get <module>.<setting>', help = 'Shows one value.', run = runGet },
		set = { usage = 'set <module>.<setting> <value>', help = 'Changes one value.', run = runSet },
		reset = { usage = 'reset <module>[.<setting>]', help = 'Restores defaults.', run = runReset },
	}
	for name, command in pairs(extraCommands or {}) do
		if tree[name] then
			error(string.format('Settings: command %q is built in', name), 2)
		end
		tree[name] = {
			usage = command.usage or name,
			help = command.help or '',
			run = function(_, args)
				return command.run(args)
			end,
		}
	end
	return tree
end

--- Runs one command line (the text after /hag) and returns the lines to print.
--- @param line string|nil
--- @param extraCommands table|nil see CommandTree
--- @return string[] lines
function SettingsMethods:RunCommand(line, extraCommands)
	local words = splitWords(line or '')
	local tree = self:CommandTree(extraCommands)
	local name = (table.remove(words, 1) or 'help'):lower()
	local command = tree[name]
	if not command then
		return { string.format('Unknown command "%s". Try /hag help.', name) }
	end
	return command.run(self, words, tree)
end

-- Command handlers ------------------------------------------------------------------------

function runHelp(_, _, tree)
	local lines = { 'Haggler commands:' }
	for _, name in ipairs(sortedKeys(tree)) do
		local command = tree[name]
		lines[#lines + 1] = string.format('  /hag %s: %s', command.usage, command.help)
	end
	return lines
end

function runList(settings, args)
	local wanted = args[1]
	if wanted and not settings:HasModule(wanted) then
		return { string.format('Unknown module "%s".', wanted) }
	end
	local lines = {}
	local moduleKeys = wanted and { wanted } or settings:Modules()
	for _, moduleKey in ipairs(moduleKeys) do
		for _, entry in ipairs(settings:Schema(moduleKey)) do
			if not (entry.isHidden and entry.isHidden(settings)) then
				lines[#lines + 1] = string.format(
					'%s.%s = %s  (%s)',
					moduleKey,
					entry.key,
					settings:Format(moduleKey, entry.key),
					entry.label
				)
				if entry.note then
					lines[#lines + 1] = '    ' .. entry.note
				end
			end
		end
	end
	if #lines == 0 then
		lines[1] = 'No settings.'
	end
	return lines
end

function runGet(settings, args)
	local moduleKey, key, reason = splitPath(settings, args[1])
	if not moduleKey then
		return { reason }
	end
	return { string.format('%s.%s = %s', moduleKey, key, settings:Format(moduleKey, key)) }
end

function runSet(settings, args)
	local moduleKey, key, reason = splitPath(settings, args[1])
	if not moduleKey then
		return { reason }
	end
	local text = table.concat(args, ' ', 2)
	local ok, refused = settings:SetFromText(moduleKey, key, text)
	if not ok then
		return { string.format('%s.%s: %s', moduleKey, key, refused) }
	end
	return { string.format('%s.%s = %s', moduleKey, key, settings:Format(moduleKey, key)) }
end

function runReset(settings, args)
	local path = args[1]
	if not path then
		return { 'Usage: /hag reset <module>[.<setting>]' }
	end
	if settings:HasModule(path) then
		settings:Reset(path)
		return { string.format('%s: defaults restored.', path) }
	end
	local moduleKey, key, reason = splitPath(settings, path)
	if not moduleKey then
		return { reason }
	end
	settings:Reset(moduleKey, key)
	return { string.format('%s.%s = %s', moduleKey, key, settings:Format(moduleKey, key)) }
end

-- Helpers ---------------------------------------------------------------------------------

function validateSchema(moduleKey, schema)
	if type(schema) ~= 'table' then
		error(string.format('Settings: schema of %s must be a list', moduleKey), 3)
	end
	local entriesByKey = {}
	for index, entry in ipairs(schema) do
		local problem = validateEntry(entry)
		if problem then
			error(string.format('Settings: %s entry %d: %s', moduleKey, index, problem), 3)
		end
		if entriesByKey[entry.key] then
			error(string.format('Settings: %s.%s is declared twice', moduleKey, entry.key), 3)
		end
		entriesByKey[entry.key] = entry
	end
	return entriesByKey
end

-- Returns a problem description, or nil when the entry is well formed.
function validateEntry(entry)
	if type(entry) ~= 'table' then
		return 'not a table'
	end
	if type(entry.key) ~= 'string' or not entry.key:find(KEY_PATTERN) then
		return 'key must be an identifier'
	end
	if not KINDS[entry.type] then
		return string.format('unknown type %q', tostring(entry.type))
	end
	if type(entry.label) ~= 'string' or entry.label == '' then
		return 'label is required'
	end
	if entry.note ~= nil and (type(entry.note) ~= 'string' or entry.note == '') then
		return 'note must be a non-empty string'
	end
	if entry.isHidden ~= nil and type(entry.isHidden) ~= 'function' then
		return 'isHidden must be a function'
	end
	if entry.type == 'slider' then
		local isRange = type(entry.min) == 'number' and type(entry.max) == 'number' and entry.min <= entry.max
		if not isRange then
			return 'slider needs min <= max'
		end
		if entry.step ~= nil and (type(entry.step) ~= 'number' or entry.step <= 0) then
			return 'slider step must be positive'
		end
	end
	if entry.type == 'choice' then
		if type(entry.choices) ~= 'table' or #entry.choices == 0 then
			return 'choice needs choices'
		end
		for _, choice in ipairs(entry.choices) do
			if type(choice) ~= 'table' or type(choice.value) ~= 'string' or type(choice.label) ~= 'string' then
				return 'each choice needs a string value and label'
			end
		end
	end
	local checkedDefault = checkValue(entry, entry.default)
	if checkedDefault == nil or checkedDefault ~= entry.default then
		return 'default is not a valid value'
	end
	return nil
end

-- Returns the value as it will be stored (sliders snap to their step), or nil and a reason.
function checkValue(entry, value)
	local kind = entry.type
	if kind == 'toggle' then
		if type(value) ~= 'boolean' then
			return nil, 'expects on or off'
		end
		return value
	end
	if kind == 'slider' then
		if type(value) ~= 'number' or value ~= value then
			return nil, 'expects a number'
		end
		local step = entry.step or 1
		local snapped = entry.min + math.floor((value - entry.min) / step + 0.5) * step
		if math.abs(snapped - value) <= STEP_TOLERANCE * step then
			snapped = value
		end
		if snapped < entry.min or snapped > entry.max then
			return nil, string.format('expects %s to %s', tostring(entry.min), tostring(entry.max))
		end
		return snapped
	end
	if kind == 'choice' then
		for _, choice in ipairs(entry.choices) do
			if choice.value == value then
				return value
			end
		end
		local values = {}
		for _, choice in ipairs(entry.choices) do
			values[#values + 1] = choice.value
		end
		return nil, 'expects one of ' .. table.concat(values, ', ')
	end
	-- binding: a key name such as CTRL-SHIFT-H or PADLSHOULDER, or '' for unbound.
	if type(value) ~= 'string' or not value:find('^[%u%d%-]*$') then
		return nil, 'expects a key name such as CTRL-H, or none'
	end
	return value
end

function parseText(entry, text)
	local word = (text or ''):match('^%s*(.-)%s*$')
	if word == '' and entry.type ~= 'binding' then
		return nil, 'needs a value'
	end
	local kind = entry.type
	if kind == 'toggle' then
		local lowered = word:lower()
		if TRUE_WORDS[lowered] then
			return true
		end
		if FALSE_WORDS[lowered] ~= nil then
			return false
		end
		return nil, 'expects on or off'
	end
	if kind == 'slider' then
		local number = tonumber(word)
		if not number then
			return nil, 'expects a number'
		end
		return number
	end
	if kind == 'choice' then
		for _, choice in ipairs(entry.choices) do
			if choice.value:lower() == word:lower() then
				return choice.value
			end
		end
		return word
	end
	if word:lower() == 'none' then
		return ''
	end
	return word:upper()
end

function formatValue(entry, value)
	if entry.type == 'toggle' then
		return value and 'on' or 'off'
	end
	if entry.type == 'binding' and value == '' then
		return 'none'
	end
	return tostring(value)
end

-- 'module.key' -> moduleKey, key; or nil and a reason the player can read.
function splitPath(settings, path)
	local moduleKey, key = (path or ''):match('^([%w_]+)%.([%w_]+)$')
	if not moduleKey then
		return nil, nil, 'Expected <module>.<setting>, for example tooltip.enabled.'
	end
	if not settings:HasModule(moduleKey) then
		return nil, nil, string.format('Unknown module "%s".', moduleKey)
	end
	local schema = settings.schemas[moduleKey]
	if not schema.byKey[key] then
		return nil, nil, string.format('Unknown setting "%s.%s".', moduleKey, key)
	end
	return moduleKey, key
end

function splitWords(line)
	local words = {}
	for word in line:gmatch('%S+') do
		words[#words + 1] = word
	end
	return words
end

function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

return Settings
