--[[
	Icons: Concord's line icons (Lucide, Tabler where Lucide has none) from the design system's
	atlas. media/icons/Icons.lua is the generated manifest (ns.Icons: texcoords per icon, one
	atlas PNG per stroke weight, all with the same layout); this file turns an icon name into a
	texture path and texcoords, and tints it with a token colour.

	  IconSet.new({ manifest?, theme?, basePath?, weight? })  weight defaults to the theme's
	      icon.stroke when an atlas ships for it, else DEFAULT_WEIGHT
	  icons:Lookup(name, weight?) -> { texture, texcoords = { left, right, top, bottom }, size } | nil
	  icons:Apply(texture, name, colorToken?, weight?) -> boolean
	  icons:Inline(name, size, colorToken?) -> '|T...|t' for font strings

	An unknown name or weight is an expected outcome (a renamed icon in a later sync): Lookup
	returns nil and Apply hides the texture, so a frame never shows a wrong glyph. The atlases
	are white on transparent; SetVertexColor tints them.
]]
local _, ns = ...

local IconSet = {}
ns.IconSet = IconSet

IconSet.BASE_PATH = 'Interface\\AddOns\\Haggler\\media\\icons\\atlas-'
-- The extension is explicit: a weight such as 2.5 puts a dot in the name, which the client
-- would otherwise read as the extension.
IconSet.EXTENSION = '.png'
-- A weight becomes part of a file path (and of a |T escape split on ':'), so only a plain number
-- is accepted.
IconSet.WEIGHT_PATTERN = '^%d+%.?%d*$'
IconSet.DEFAULT_WEIGHT = '2'
--- The low-confidence marker, on frames and in tooltips alike: a caution, so the triangle in
--- the caution colour (circle-alert is for danger only).
IconSet.LOW_CONFIDENCE = 'triangle-alert'
IconSet.LOW_CONFIDENCE_COLOR = 'color.state.caution'

-- Helpers live at the bottom of the file; declared here so they stay local.
local hasWeight, isSafeWeight, isTexcoords, themeStrokeWeight

local IconSetMethods = {}
IconSetMethods.__index = IconSetMethods

--- @param options table|nil { manifest = ns.Icons, theme = ns.theme, basePath, weight }
--- @return table icons
function IconSet.new(options)
	options = options or {}
	local manifest = options.manifest or ns.Icons
	return setmetatable({
		manifest = type(manifest) == 'table' and manifest or { texcoords = {}, weights = {} },
		theme = options.theme,
		basePath = options.basePath or IconSet.BASE_PATH,
		weight = options.weight or themeStrokeWeight(options.theme, manifest) or IconSet.DEFAULT_WEIGHT,
	}, IconSetMethods)
end

--- The texture and texcoords of one icon.
--- @param name string icon name, e.g. 'triangle-alert'
--- @param weight string|nil stroke weight; the set's default when nil
--- @return table|nil { texture, texcoords = { left, right, top, bottom }, size }
function IconSetMethods:Lookup(name, weight)
	local texcoords = type(self.manifest.texcoords) == 'table' and self.manifest.texcoords[name] or nil
	weight = weight or self.weight
	if not isTexcoords(texcoords) or not isSafeWeight(weight) or not hasWeight(self.manifest, weight) then
		return nil
	end
	return {
		texture = self.basePath .. weight .. IconSet.EXTENSION,
		texcoords = { texcoords[1], texcoords[2], texcoords[3], texcoords[4] },
		size = texcoords.size or self.manifest.iconSize,
	}
end

--- Sets an icon on a texture region and tints it. An unknown icon hides the texture.
--- @param texture table a Texture region
--- @param name string
--- @param colorToken string|nil token name; white when nil
--- @param weight string|nil
--- @return boolean applied
function IconSetMethods:Apply(texture, name, colorToken, weight)
	local icon = self:Lookup(name, weight)
	if not icon then
		texture:Hide()
		return false
	end
	texture:SetTexture(icon.texture)
	texture:SetTexCoord(icon.texcoords[1], icon.texcoords[2], icon.texcoords[3], icon.texcoords[4])
	local color = colorToken and self.theme and self.theme:Color(colorToken) or { r = 1, g = 1, b = 1, a = 1 }
	texture:SetVertexColor(color.r, color.g, color.b, color.a or 1)
	texture:Show()
	return true
end

--- An icon as a |T escape for font strings, tinted (the client takes 0..255 vertex colours
--- after the texcoords). Empty when the icon is unknown or the manifest has no atlas size.
--- @param name string
--- @param size number height in UI units (the width follows; icons are square)
--- @param colorToken string|nil
--- @return string
function IconSetMethods:Inline(name, size, colorToken)
	local icon = self:Lookup(name)
	local width, height = tonumber(self.manifest.atlasWidth), tonumber(self.manifest.atlasHeight)
	if not icon or not width or not height then
		return ''
	end
	local color = colorToken and self.theme and self.theme:Color(colorToken) or { r = 1, g = 1, b = 1 }
	local coords = icon.texcoords
	return string.format(
		'|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d:%d:%d:%d|t',
		icon.texture,
		size,
		size,
		width,
		height,
		math.floor(coords[1] * width + 0.5),
		math.floor(coords[2] * width + 0.5),
		math.floor(coords[3] * height + 0.5),
		math.floor(coords[4] * height + 0.5),
		math.floor(color.r * 255 + 0.5),
		math.floor(color.g * 255 + 0.5),
		math.floor(color.b * 255 + 0.5)
	)
end

-- Helpers ---------------------------------------------------------------------------------

function isSafeWeight(weight)
	return type(weight) == 'string' and weight:find(IconSet.WEIGHT_PATTERN) ~= nil
end

function hasWeight(manifest, weight)
	for _, known in ipairs(type(manifest.weights) == 'table' and manifest.weights or {}) do
		if known == weight then
			return true
		end
	end
	return false
end

function isTexcoords(value)
	if type(value) ~= 'table' then
		return false
	end
	for index = 1, 4 do
		local coord = value[index]
		if type(coord) ~= 'number' or coord < 0 or coord > 1 then
			return false
		end
	end
	return true
end

-- The theme's icon.stroke as an atlas weight ('1.5', '2'), or nil when it has none the manifest ships.
function themeStrokeWeight(theme, manifest)
	if type(theme) ~= 'table' or type(theme.Number) ~= 'function' or type(manifest) ~= 'table' then
		return nil
	end
	local stroke = theme:Number('icon.stroke')
	if stroke <= 0 then
		return nil
	end
	local weight = string.format('%g', stroke)
	return isSafeWeight(weight) and hasWeight(manifest, weight) and weight or nil
end

return IconSet
