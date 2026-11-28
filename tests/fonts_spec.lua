local t = ...
local FakeGame = require('tests.fake_game')

local FONT_DIR = 'Interface\\AddOns\\Haggler\\media\\fonts\\'
local ATKINSON = FONT_DIR .. 'AtkinsonHyperlegibleNext-SemiBold.ttf'
local ROBOTO = FONT_DIR .. 'RobotoCondensed-Regular.ttf'
local HEADING_FACE_TOKENS = { 'font.face.heading', 'font.face.display', 'window.titleFace', 'tabs.face' }
local BODY_FACE_TOKENS = { 'font.face.body', 'font.face.number', 'notice.face' }

-- An add-on font path as a repo path: Interface\AddOns\Haggler\media\fonts\X.ttf -> media/fonts/X.ttf.
local function repoPathOf(addonPath)
	return (addonPath:gsub('^Interface\\AddOns\\Haggler\\', ''):gsub('\\', '/'))
end

local function fileExists(path)
	local file = io.open(path, 'rb')
	if file then
		file:close()
		return true
	end
	return false
end

local function start()
	local game = FakeGame.new({ now = 1000000 })
	return game, FakeGame.startAddon(t, game)
end

t.group('font faces')

t.test('Banneret headings, display, window titles and tabs read the shipped Atkinson face', function()
	local ns = t.loadAddon()
	local theme = ns.Theme.new(ns.Tokens)
	for _, name in ipairs(HEADING_FACE_TOKENS) do
		t.eq(theme:Face(name), ATKINSON, name)
	end
end)

t.test('Banneret body, figures and notices stay Roboto Condensed', function()
	local ns = t.loadAddon()
	local theme = ns.Theme.new(ns.Tokens)
	for _, name in ipairs(BODY_FACE_TOKENS) do
		t.eq(theme:Face(name), ROBOTO, name)
	end
end)

t.test('a missing face token falls back to the body face, never to nil', function()
	local ns = t.loadAddon()
	local theme = ns.Theme.new(ns.Tokens)
	t.eq(theme:Face('font.face.no-such-face'), ROBOTO)
	t.eq(ns.Theme.new({ themes = {} }):Face('font.face.heading'), ns.Theme.FALLBACK_FACE)
end)

t.test('a non-default theme falls back to the default theme token, then the body face, then Arial Narrow', function()
	local ns = t.loadAddon()
	local tokens = {
		themes = {
			banneret = { tokens = { ['font.face.heading'] = 'default-heading', ['font.face.body'] = 'default-body' } },
			other = { tokens = { ['font.face.body'] = 'other-body' } },
			bare = { tokens = {} },
		},
	}
	local other = ns.Theme.new(tokens, 'other')
	t.eq(other:Face('font.face.heading'), 'default-heading', 'same token in the default theme first')
	t.eq(other:Face('font.face.display'), 'other-body', 'then the theme own body face')
	t.eq(ns.Theme.new(tokens, 'bare'):Face('font.face.display'), 'default-body', 'then the default body face')
	local noBody = ns.Theme.new({ themes = { banneret = { tokens = {} }, other = { tokens = {} } } }, 'other')
	t.eq(noBody:Face('font.face.heading'), ns.Theme.FALLBACK_FACE)
	t.eq(ns.Theme.FALLBACK_FACE, 'Fonts\\ARIALN.TTF')
end)

t.test('every add-on font a theme names ships in media/fonts with a licence beside it', function()
	local ns = t.loadAddon()
	local checked = 0
	for themeKey, theme in pairs(ns.Tokens.themes) do
		for name, value in pairs(theme.tokens or {}) do
			if type(value) == 'string' and value:find(FONT_DIR, 1, true) == 1 then
				t.truthy(fileExists(repoPathOf(value)), themeKey .. ' ' .. name .. ' ships ' .. value)
				checked = checked + 1
			end
		end
	end
	t.truthy(checked > 0, 'some theme names an add-on font')
	t.truthy(fileExists('media/fonts/OFL-AtkinsonHyperlegibleNext.txt'), 'Atkinson licence ships')
	t.truthy(fileExists('media/fonts/LICENSE-RobotoCondensed.txt'), 'Roboto licence ships')
end)

t.test('plain text draws in the body face; a face token picks another', function()
	local _, addon = start()
	local ui = addon.Widgets.new(addon.wow, addon.theme)
	local parent = addon.wow:CreateFrame('Frame', addon.wow:Global('UIParent'))
	t.eq(ui:Text(parent, 14, 'color.text.primary').font[1], ROBOTO)
	t.eq(ui:Text(parent, 17, 'color.text.title', 'font.face.heading').font[1], ATKINSON)
	t.eq(ui:Text(parent, 17, 'color.text.title', 'font.face.heading').font[2], 17)
end)

t.test('a tab label reads the tabs face; other buttons read the body face', function()
	local _, addon = start()
	local ui = addon.Widgets.new(addon.wow, addon.theme)
	local parent = addon.wow:CreateFrame('Frame', addon.wow:Global('UIParent'))
	t.eq(ui:Button(parent, 'Sell', 'tab').label.font[1], ATKINSON)
	t.eq(ui:Button(parent, 'Post', 'primary').label.font[1], ROBOTO)
	t.eq(ui:Button(parent, 'Cancel', 'secondary').label.font[1], ROBOTO)
end)

t.group('icon stroke')

t.test('icons draw from the atlas of the theme icon.stroke weight', function()
	local ns = t.loadAddon()
	local theme = ns.Theme.new(ns.Tokens)
	t.eq(theme:Number('icon.stroke'), 1.5)
	local icon = ns.IconSet.new({ theme = theme }):Lookup('coins')
	t.eq(icon.texture, ns.IconSet.BASE_PATH .. '1.5.png')
end)

t.test('without a theme, or with a stroke no atlas has, icons keep the default weight', function()
	local ns = t.loadAddon()
	t.eq(ns.IconSet.new():Lookup('coins').texture, ns.IconSet.BASE_PATH .. ns.IconSet.DEFAULT_WEIGHT .. '.png')
	local oddTheme = ns.Theme.new({ themes = { banneret = { tokens = { ['icon.stroke'] = 7 } } } })
	t.eq(
		ns.IconSet.new({ theme = oddTheme }):Lookup('coins').texture,
		ns.IconSet.BASE_PATH .. ns.IconSet.DEFAULT_WEIGHT .. '.png'
	)
end)

t.group('haggler-local tokens')

t.test('the margin band tokens live outside the generated file', function()
	local generated = assert(io.open('Host/Tokens.lua')):read('*a')
	t.eq(generated:find('HAGGLER_LOCAL_TOKENS', 1, true), nil)
	local ns = t.loadAddon()
	local theme = ns.Theme.new(ns.Tokens)
	for _, name in ipairs({ 'money.gainStrong', 'money.gainTint', 'money.lossTint' }) do
		t.truthy(theme:Color(name) ~= ns.Theme.FALLBACK_COLOR, name)
	end
end)

t.test('a local token never replaces a value the DS already sets', function()
	local dsValue = { 0.1, 0.2, 0.3, 1 }
	local ns = {
		Tokens = { themes = { banneret = { tokens = { ['money.gainStrong'] = dsValue } }, forever = { tokens = {} } } },
	}
	assert(loadfile('Host/LocalTokens.lua'))('Haggler', ns)
	local banneret = ns.Tokens.themes.banneret.tokens
	t.truthy(banneret['money.gainStrong'] == dsValue, 'the DS value is kept as is')
	t.same(banneret['money.gainStrong'], { 0.1, 0.2, 0.3, 1 })
	t.truthy(banneret['money.gainTint'] ~= nil, 'a token the DS lacks is still added')
	t.truthy(ns.Tokens.themes.forever.tokens['money.gainStrong'] ~= nil)
end)
