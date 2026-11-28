local t = ...
local ns = t.loadAddon()
local Settings = ns.Settings

local SCHEMA = {
	{ key = 'detail', type = 'toggle', label = 'Detail lines', default = true },
	{ key = 'scale', type = 'slider', label = 'Scale', default = 1, min = 0.5, max = 2, step = 0.1 },
	{
		key = 'mode',
		type = 'choice',
		label = 'Mode',
		default = 'compact',
		choices = { { value = 'compact', label = 'Compact' }, { value = 'full', label = 'Full' } },
	},
	{ key = 'focus', type = 'binding', label = 'Focus key', default = '' },
}

local function newSettings()
	local stored = {}
	local changes = {}
	local settings = Settings.new(stored, function(moduleKey, key, value, oldValue)
		changes[#changes + 1] = { moduleKey, key, value, oldValue }
	end)
	settings:Register('tooltip', SCHEMA)
	return settings, stored, changes
end

t.test('defaults come from the schema', function()
	local settings = newSettings()
	t.eq(settings:Get('tooltip', 'detail'), true)
	t.eq(settings:Get('tooltip', 'scale'), 1)
	t.eq(settings:Get('tooltip', 'mode'), 'compact')
	t.eq(settings:Get('tooltip', 'focus'), '')
	t.same(settings:Defaults('tooltip'), { detail = true, scale = 1, mode = 'compact', focus = '' })
end)

t.test('stores only values that differ from the default', function()
	local settings, stored, changes = newSettings()
	t.truthy(settings:Set('tooltip', 'detail', false))
	t.same(stored, { tooltip = { detail = false } })
	t.truthy(settings:Set('tooltip', 'detail', true))
	t.same(stored, {})
	t.eq(#changes, 2)
	t.same(changes[1], { 'tooltip', 'detail', false, true })
end)

t.test('TakeRetired hands back a dropped setting once and removes it', function()
	local settings, stored = newSettings()
	stored.tooltip = { oldKey = false, detail = false }
	t.eq(settings:TakeRetired('tooltip', 'oldKey'), false)
	t.same(stored, { tooltip = { detail = false } })
	t.eq(settings:TakeRetired('tooltip', 'oldKey'), nil, 'gone after the first take')
	stored.tooltip = { oldKey = true }
	t.eq(settings:TakeRetired('tooltip', 'oldKey'), true)
	t.same(stored, {}, 'an emptied module table is dropped')
	t.eq(settings:TakeRetired('nothing', 'oldKey'), nil)
	t.raises(function()
		settings:TakeRetired('tooltip', 'detail')
	end, 'still a setting')
end)

t.test('no change event when the value is the same', function()
	local settings, _, changes = newSettings()
	settings:Set('tooltip', 'mode', 'compact')
	t.eq(#changes, 0)
end)

t.test('refuses values of the wrong kind with a reason', function()
	local settings = newSettings()
	local ok, reason = settings:Set('tooltip', 'detail', 'yes')
	t.eq(ok, nil)
	t.eq(reason, 'expects on or off')
	ok, reason = settings:Set('tooltip', 'mode', 'huge')
	t.eq(ok, nil)
	t.eq(reason, 'expects one of compact, full')
	ok = settings:Set('tooltip', 'scale', 3)
	t.eq(ok, nil)
	ok = settings:Set('tooltip', 'scale', 0 / 0)
	t.eq(ok, nil)
	ok = settings:Set('tooltip', 'focus', 'ctrl h')
	t.eq(ok, nil)
end)

t.test('sliders snap to their step', function()
	local settings = newSettings()
	t.truthy(settings:Set('tooltip', 'scale', 1.26))
	t.truthy(math.abs(settings:Get('tooltip', 'scale') - 1.3) < 1e-9)
end)

t.test('a stored value that no longer fits the schema reads as the default', function()
	local settings = Settings.new({ tooltip = { mode = 'removed', detail = 'garbage' } })
	settings:Register('tooltip', SCHEMA)
	t.eq(settings:Get('tooltip', 'mode'), 'compact')
	t.eq(settings:Get('tooltip', 'detail'), true)
end)

t.test('reset restores one value or the whole module', function()
	local settings, stored = newSettings()
	settings:Set('tooltip', 'detail', false)
	settings:Set('tooltip', 'mode', 'full')
	settings:Reset('tooltip', 'mode')
	t.eq(settings:Get('tooltip', 'mode'), 'compact')
	t.eq(settings:Get('tooltip', 'detail'), false)
	settings:Reset('tooltip')
	t.same(stored, {})
end)

t.test('unknown modules and keys are caller bugs', function()
	local settings = newSettings()
	t.raises(function()
		settings:Get('tooltip', 'nope')
	end, 'unknown setting')
	t.raises(function()
		settings:Set('bags', 'detail', true)
	end, 'unknown setting')
end)

t.test('bad schemas throw at registration', function()
	local settings = Settings.new()
	t.raises(function()
		settings:Register('a', { { key = 'x', type = 'dial', label = 'X', default = 1 } })
	end, 'unknown type')
	t.raises(function()
		settings:Register('a', { { key = 'x', type = 'slider', label = 'X', default = 5, min = 0, max = 1 } })
	end, 'default is not a valid value')
	t.raises(function()
		settings:Register('a', { { key = 'x', type = 'choice', label = 'X', default = 'a', choices = {} } })
	end, 'needs choices')
	t.raises(function()
		settings:Register('a', {
			{ key = 'x', type = 'toggle', label = 'X', default = true },
			{ key = 'x', type = 'toggle', label = 'X', default = true },
		})
	end, 'declared twice')
	t.raises(function()
		settings:Register('bad key', {})
	end, 'identifier')
end)

t.group('settings commands')

t.test('help lists the generated commands', function()
	local settings = newSettings()
	local lines = settings:RunCommand('')
	t.eq(lines[1], 'Haggler commands:')
	t.truthy(table.concat(lines, '\n'):find('/hag set <module>.<setting> <value>', 1, true))
end)

t.test('list, get and set work from text', function()
	local settings = newSettings()
	t.same(settings:RunCommand('set tooltip.detail off'), { 'tooltip.detail = off' })
	t.same(settings:RunCommand('get tooltip.detail'), { 'tooltip.detail = off' })
	t.same(settings:RunCommand('set tooltip.mode FULL'), { 'tooltip.mode = full' })
	t.same(settings:RunCommand('set tooltip.scale 1.5'), { 'tooltip.scale = 1.5' })
	t.same(settings:RunCommand('set tooltip.focus ctrl-h'), { 'tooltip.focus = CTRL-H' })
	t.same(settings:RunCommand('set tooltip.focus none'), { 'tooltip.focus = none' })
	local listed = settings:RunCommand('list tooltip')
	t.eq(#listed, 4)
	t.eq(listed[1], 'tooltip.detail = off  (Detail lines)')
end)

t.test('commands explain bad input instead of throwing', function()
	local settings = newSettings()
	t.same(settings:RunCommand('set tooltip.scale big'), { 'tooltip.scale: expects a number' })
	t.same(settings:RunCommand('set tooltip.detail maybe'), { 'tooltip.detail: expects on or off' })
	t.same(settings:RunCommand('get tooltip'), { 'Expected <module>.<setting>, for example tooltip.enabled.' })
	t.same(settings:RunCommand('get bags.size'), { 'Unknown module "bags".' })
	t.same(settings:RunCommand('get tooltip.size'), { 'Unknown setting "tooltip.size".' })
	t.same(settings:RunCommand('frobnicate'), { 'Unknown command "frobnicate". Try /hag help.' })
end)

t.test('reset from text', function()
	local settings = newSettings()
	settings:RunCommand('set tooltip.mode full')
	t.same(settings:RunCommand('reset tooltip'), { 'tooltip: defaults restored.' })
	t.eq(settings:Get('tooltip', 'mode'), 'compact')
end)

t.test('extra commands join the tree but cannot shadow built-ins', function()
	local settings = newSettings()
	local extra = {
		scan = {
			usage = 'scan',
			help = 'Scans.',
			run = function(args)
				return { 'scanning ' .. (args[1] or '') }
			end,
		},
	}
	t.same(settings:RunCommand('scan now', extra), { 'scanning now' })
	t.raises(function()
		settings:RunCommand('set', { set = { run = function() end } })
	end, 'built in')
end)

t.test('fractional slider defaults and values survive the step snap', function()
	local settings = Settings.new({})
	settings:Register('pricing', {
		{ key = 'share', type = 'slider', label = 'Share', default = 0.3, min = 0, max = 1, step = 0.1 },
	})
	t.eq(settings:Get('pricing', 'share'), 0.3)
	t.truthy(settings:Set('pricing', 'share', 0.7))
	t.eq(settings:Get('pricing', 'share'), 0.7)
end)
