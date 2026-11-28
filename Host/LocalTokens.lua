--[[
	Haggler-local tokens, kept beside the generated Host/Tokens.lua so tools/sync-design.sh
	never drops them. They colour the craft window's margin bands (Features/Crafting/View.lua
	MARGIN_BANDS) next to the DS's money.loss, color.state.caution and money.gain; the DS writer
	adopts them into the design system, after which this file goes. A token the DS already
	carries wins. Every one reads at 4.5:1 or better on color.surface.base; tests/crafting_spec.lua
	fails if they go missing.
]]
local _, ns = ...

local HAGGLER_LOCAL_TOKENS = {
	banneret = {
		['money.lossTint'] = { 0.902, 0.690, 0.651, 1.00 },
		['money.gainTint'] = { 0.698, 0.808, 0.659, 1.00 },
		['money.gainStrong'] = { 0.663, 0.882, 0.302, 1.00 },
	},
	forever = {
		['money.lossTint'] = { 1.000, 0.600, 0.600, 1.00 },
		['money.gainTint'] = { 0.600, 0.900, 0.560, 1.00 },
		['money.gainStrong'] = { 0.667, 1.000, 0.000, 1.00 },
	},
	sable = {
		['money.lossTint'] = { 1.000, 0.800, 0.780, 1.00 },
		['money.gainTint'] = { 0.780, 0.925, 0.760, 1.00 },
		['money.gainStrong'] = { 0.780, 1.000, 0.341, 1.00 },
	},
	['sakura-day'] = {
		['money.lossTint'] = { 0.600, 0.310, 0.310, 1.00 },
		['money.gainTint'] = { 0.290, 0.440, 0.330, 1.00 },
		['money.gainStrong'] = { 0.290, 0.471, 0.039, 1.00 },
	},
	['sakura-night'] = {
		['money.lossTint'] = { 0.937, 0.706, 0.733, 1.00 },
		['money.gainTint'] = { 0.729, 0.847, 0.737, 1.00 },
		['money.gainStrong'] = { 0.737, 0.902, 0.400, 1.00 },
	},
}

local themes = type(ns.Tokens) == 'table' and ns.Tokens.themes or {}
for themeKey, tokens in pairs(HAGGLER_LOCAL_TOKENS) do
	local theme = themes[themeKey]
	if type(theme) == 'table' and type(theme.tokens) == 'table' then
		for name, value in pairs(tokens) do
			if theme.tokens[name] == nil then
				theme.tokens[name] = value
			end
		end
	end
end
