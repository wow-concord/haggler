--[[
	Theme: colours from the design system's tokens (Host/Tokens.lua). A theme may extend
	another; a token missing from the whole chain falls back to the default theme, then to grey,
	so a renamed token shows as grey instead of breaking a frame.

	  Theme.new(tokens?, themeKey?)  tokens default ns.Tokens, themeKey default banneret
	  theme:Color(name) -> { r, g, b, a }
	  theme:Hex(name)   -> 'ffrrggbb' for |c escapes
	  theme:Wrap(name, text) -> text in that colour
	  theme:Number(name) -> number, e.g. 'focus.ringWidth'; 0 when no theme in the chain has it
]]
local _, ns = ...

local Theme = {}
ns.Theme = Theme

Theme.DEFAULT_THEME = 'banneret'
Theme.FALLBACK_COLOR = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
local MAX_EXTENDS_DEPTH = 8

-- Helpers live at the bottom of the file; declared here so they stay local.
local findToken, toColor, toHexByte

local ThemeMethods = {}
ThemeMethods.__index = ThemeMethods

--- @param tokens table|nil the generated token table
--- @param themeKey string|nil
--- @return table theme
function Theme.new(tokens, themeKey)
	tokens = tokens or ns.Tokens
	local themes = type(tokens) == 'table' and type(tokens.themes) == 'table' and tokens.themes or {}
	local key = themes[themeKey] and themeKey or Theme.DEFAULT_THEME
	return setmetatable({ themes = themes, key = key, colorCache = {} }, ThemeMethods)
end

--- @param name string token name, e.g. 'color.text.accent'
--- @return table { r, g, b, a }
function ThemeMethods:Color(name)
	local cached = self.colorCache[name]
	if cached then
		return cached
	end
	local value = findToken(self.themes, self.key, name) or findToken(self.themes, Theme.DEFAULT_THEME, name)
	local color = toColor(value) or Theme.FALLBACK_COLOR
	self.colorCache[name] = color
	return color
end

--- @return string 'ffrrggbb'
function ThemeMethods:Hex(name)
	local color = self:Color(name)
	return 'ff' .. toHexByte(color.r) .. toHexByte(color.g) .. toHexByte(color.b)
end

--- Text wrapped in a colour escape.
function ThemeMethods:Wrap(name, text)
	return '|c' .. self:Hex(name) .. tostring(text) .. '|r'
end

--- A size or count token; 0 when missing, so a renamed token draws nothing instead of failing.
--- @param name string token name, e.g. 'focus.ringWidth'
--- @return number
function ThemeMethods:Number(name)
	local value = findToken(self.themes, self.key, name)
	if type(value) ~= 'number' then
		value = findToken(self.themes, Theme.DEFAULT_THEME, name)
	end
	return type(value) == 'number' and value or 0
end

-- Helpers ---------------------------------------------------------------------------------

function findToken(themes, key, name)
	for _ = 1, MAX_EXTENDS_DEPTH do
		local theme = themes[key]
		if type(theme) ~= 'table' then
			return nil
		end
		local value = type(theme.tokens) == 'table' and theme.tokens[name] or nil
		if value ~= nil then
			return value
		end
		key = theme.extends
	end
	return nil
end

function toColor(value)
	if type(value) ~= 'table' then
		return nil
	end
	for index = 1, 3 do
		if type(value[index]) ~= 'number' then
			return nil
		end
	end
	return { r = value[1], g = value[2], b = value[3], a = type(value[4]) == 'number' and value[4] or 1 }
end

function toHexByte(channel)
	local byte = math.floor(math.max(0, math.min(1, channel)) * 255 + 0.5)
	return string.format('%02x', byte)
end

return Theme
