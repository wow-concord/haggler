--[[
	VentureRecords: reads the ventures saved at markets[marketKey].ventures (V1). Ventures are
	V2 and their planner (v2/Engine/Ventures.lua) is left out of the release package, but their
	saved data is player data: V1 keeps it, reads it for the version-3 migration (OwnOnly) and
	never drops it. The planner extends this same table (ns.Ventures) and sets hasPlanner.

	  Ventures.hasPlanner                       true once the V2 planner is loaded
	  Ventures.VALUATIONS                       how owned materials are costed (also the
	                                            profession frame's valuation setting)
	  Ventures.get(market, id)                  -> Venture | nil   (nil for junk)
	  Ventures.list(market, filter?)            -> Venture[] newest first   filter = { isOpen? }
	  Ventures.cashCost(venture, leftover)      -> copper   what the player paid for a leftover

	The Venture shape is documented in v2/Engine/Ventures.lua.
]]
local _, ns = ...

local Ventures = {}
ns.Ventures = Ventures

Ventures.hasPlanner = false
Ventures.VALUATIONS = { opportunity = true, paid = true }

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWhole, venturesOf, readVenture, craftedUnits, knownCopperOf

--- One venture, or nil when there is none (or it is junk).
function Ventures.get(market, id)
	local ventures = venturesOf(market)
	return ventures and readVenture(ventures[id]) or nil
end

--- Ventures, newest first.
--- @param filter table|nil { isOpen? }
function Ventures.list(market, filter)
	local list = {}
	for _, raw in pairs(venturesOf(market) or {}) do
		local venture = readVenture(raw)
		local isWanted = venture
			and (not filter or filter.isOpen == nil or (venture.status ~= 'closed') == filter.isOpen)
		if isWanted then
			list[#list + 1] = venture
		end
	end
	table.sort(list, function(a, b)
		return a.id > b.id
	end)
	return list
end

--- What the player paid for a leftover: a material's share of what was paid for it, a crafted
--- unit's share of the cash the crafts used (every line's output alike).
--- @param leftover table { itemId, qty, kind = 'crafted' | 'material' }
--- @return number copper, 0 when nothing paid is known
function Ventures.cashCost(venture, leftover)
	if leftover.kind == 'material' then
		local material = venture.materials[leftover.itemId]
		if
			not material
			or not isWhole(material.bought)
			or material.bought <= 0
			or not isWhole(material.boughtCopper)
		then
			return 0
		end
		return math.floor(material.boughtCopper * math.min(leftover.qty, material.bought) / material.bought)
	end
	local crafted = craftedUnits(venture)
	if crafted <= 0 then
		return 0
	end
	return math.floor(knownCopperOf(venture) * math.min(leftover.qty, crafted) / crafted)
end

-- Helpers ---------------------------------------------------------------------------------

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function venturesOf(market)
	return type(market) == 'table' and type(market.ventures) == 'table' and market.ventures or nil
end

function readVenture(venture)
	local isValid = type(venture) == 'table'
		and isWhole(venture.id)
		and type(venture.lines) == 'table'
		and type(venture.materials) == 'table'
		and type(venture.totals) == 'table'
	return isValid and venture or nil
end

function craftedUnits(venture)
	local crafted = 0
	for _, line in ipairs(venture.lines) do
		-- A junk line counts as nothing crafted: the migration reads it on every load.
		crafted = crafted + (type(line) == 'table' and isWhole(line.crafted) and line.crafted or 0)
	end
	return crafted
end

function knownCopperOf(venture)
	local known = 0
	for _, material in pairs(venture.materials) do
		known = known + (isWhole(material.knownCopper) and material.knownCopper or 0)
	end
	return known
end

return Ventures
