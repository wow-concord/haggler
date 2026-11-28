-- Lua 5.1, as in the game. Globals are allow-listed: a new client API must be added here on
-- purpose, and only Engine/Wow.lua and Haggler.lua may read them.
std = 'lua51'
max_line_length = false
codes = true
self = false

exclude_files = {
	'.claude/',
	'.luarocks/',
	'Libs/',
}

-- Globals the add-on writes: its SavedVariables and its slash command.
globals = {
	'HagglerDB',
	'HagglerCharDB',
	'HagglerArchiveDB',
	'SlashCmdList',
	'SLASH_HAGGLER1',
}

files['Engine/Wow.lua'] = {
	read_globals = {
		'C_Item',
		'CreateFrame',
		'DEFAULT_CHAT_FRAME',
		'GetCurrentRegion',
		'GetItemInfo',
		'GetRealmName',
		'GetServerTime',
		'UnitFactionGroup',
		'UnitName',
		'time',
	},
}

files['tests/'] = {
	std = 'luajit',
}
