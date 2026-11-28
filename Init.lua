--[[
	Init.lua: the add-on's shared services, loaded after the Host and Engine files and before
	the features, which register their modules with ns.host as they load. Haggler.lua (last)
	opens the saved data and starts the host.
]]
local _, ns = ...

ns.wow = ns.Wow.create(nil, {
	onError = function(where, err)
		ns.wow:Print(string.format('%s failed: %s', where, err))
	end,
})
ns.host = ns.Host.create({
	onError = function(owner, where, err)
		ns.wow:Print(string.format('%s failed in %s: %s', owner, where, err))
	end,
})
ns.theme = ns.Theme.new(ns.Tokens)
ns.tooltips = ns.Tooltip.new({
	theme = ns.theme,
	wow = ns.wow,
	onError = function(owner, err)
		ns.wow:Print(string.format('tooltip lines of %s failed: %s', owner, err))
	end,
})
