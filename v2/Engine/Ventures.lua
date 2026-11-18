--[[
	Ventures (V2, left out of the release package): a plan to craft and sell, followed from the
	plan to the last copper in the mailbox (markets[marketKey].ventures[id] = Venture). A venture
	is never deleted; closing keeps it.

	  Venture = { id, name, ruleId, valuation, status, createdAt, closedAt?, closeReason?,
	              leftoverAction?, lines, materials, totals }
	  VentureLine = { recipeId, itemId, perCraft, plannedCrafts, planned, crafted, posted, sold,
	                  returned }
	  materials[itemId] = { need, bought, boughtCopper, used, knownUnits?, knownCopper }
	  totals = { gross, cut, depositPaid, depositRefunded, trollUnits }

	Own-only (ASK-M-005): a venture stores only what the player paid. knownUnits / knownCopper
	are the cost-pool share (cash) the crafts used; the rest of the materials and the leftovers
	moved to stock are valued on read with valueOf (a rule quote, at the venture's ruleId), never
	stored. knownUnits is nil only on a venture from before version 3 whose split was lost.

	Status follows progress and can move back (planning more crafts reopens crafting):
	  planning  nothing bought or crafted yet
	  buying    materials bought, nothing crafted
	  crafting  some crafted, the plan not met
	  selling   the plan crafted, units still to sell
	  closed    every crafted unit sold and nothing live (closeReason 'sold'), or closed by hand
	            ('manual') with the leftovers written off or moved to stock

	Materials are kept per venture, not per line: two recipes sharing a reagent share its pool.
	Profit comes two ways (Haggler.md): cash (what came in minus what was spent on the venture,
	buys included) and over materials (net sales minus what the crafted materials cost, owned
	units at the venture's valuation).

	  Ventures.create(market, spec, now)            -> Venture   spec = { name?, ruleId?, valuation? }
	  Ventures.get / Ventures.list / Ventures.cashCost / Ventures.VALUATIONS   Engine/VentureRecords.lua
	  Ventures.addCrafts(venture, recipe, crafts)   recipe = { recipeId, itemId, perCraft, reagents }
	  Ventures.openFor(market, role, key)           -> Venture | nil  role: buy · craft · post
	  Ventures.noteBuy / noteCraft / notePost / noteSale / noteReturn
	  Ventures.leftovers(venture)                   -> { { itemId, qty, kind } }
	  Ventures.isSoldOut(venture)                   -> boolean
	  Ventures.close(venture, now, action, reason)  -> leftovers | nil, reason
	  Ventures.refresh(venture)                     -> boolean status changed
	  Ventures.profit(venture, valueOf?)            -> VentureProfit
	  Ventures.forecast(venture, sources)           -> Forecast
]]
local _, ns = ...

-- Engine/VentureRecords.lua (V1) made ns.Ventures with the saved-data readers; this file adds
-- the planner, which only the V2 Ventures tab and the profession frame's Plan venture use.
local Ventures = ns.Ventures
Ventures.hasPlanner = true

Ventures.LEFTOVER_ACTIONS = { writeOff = true, toStock = true }
Ventures.DEFAULT_MARKET_SHARE = 20

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWhole, venturesOf, lineFor, lineForItem, materialFor, deriveStatus, live, unposted
local sumMaterials, openVentures, estimateOf, leftoverEstimate

--- Starts a venture in planning.
--- @param market table Store:Market(key)
--- @param spec table|nil { name?, ruleId?, valuation? }
--- @param now number unix seconds
--- @return table Venture
function Ventures.create(market, spec, now)
	local ventures = venturesOf(market)
	if not ventures or type(now) ~= 'number' then
		error('Ventures.create: needs a market with ventures and a time', 2)
	end
	spec = spec or {}
	if spec.valuation ~= nil and not Ventures.VALUATIONS[spec.valuation] then
		error('Ventures.create: unknown valuation ' .. tostring(spec.valuation), 2)
	end
	local id = 1
	for existingId in pairs(ventures) do
		if isWhole(existingId) and existingId >= id then
			id = existingId + 1
		end
	end
	local venture = {
		id = id,
		name = type(spec.name) == 'string' and spec.name ~= '' and spec.name or ('Venture ' .. id),
		ruleId = spec.ruleId,
		valuation = spec.valuation or 'opportunity',
		status = 'planning',
		createdAt = now,
		lines = {},
		materials = {},
		totals = { gross = 0, cut = 0, depositPaid = 0, depositRefunded = 0, trollUnits = 0 },
	}
	ventures[id] = venture
	return venture
end

--- Plans crafts of a recipe (negative to plan fewer, never below what was crafted).
--- @param venture table
--- @param recipe table { recipeId, itemId, perCraft, reagents = { { itemId, qty } } }
--- @param crafts number whole, may be negative
--- @return table|nil VentureLine
--- @return string|nil reason
function Ventures.addCrafts(venture, recipe, crafts)
	if type(venture) ~= 'table' or type(recipe) ~= 'table' or type(crafts) ~= 'number' or crafts % 1 ~= 0 then
		error('Ventures.addCrafts: needs a venture, a recipe and a whole number of crafts', 2)
	end
	if not (isWhole(recipe.recipeId) and isWhole(recipe.itemId) and isWhole(recipe.perCraft)) then
		error('Ventures.addCrafts: a recipe needs recipeId, itemId and perCraft', 2)
	end
	if venture.status == 'closed' then
		return nil, 'venture is closed'
	end
	local line = lineFor(venture, recipe.recipeId)
	if not line then
		line = {
			recipeId = recipe.recipeId,
			itemId = recipe.itemId,
			perCraft = math.max(1, recipe.perCraft),
			plannedCrafts = 0,
			planned = 0,
			crafted = 0,
			posted = 0,
			sold = 0,
			returned = 0,
		}
		venture.lines[#venture.lines + 1] = line
	end
	local craftedCrafts = math.ceil(line.crafted / line.perCraft)
	local plannedCrafts = math.max(craftedCrafts, line.plannedCrafts + crafts)
	local change = plannedCrafts - line.plannedCrafts
	line.plannedCrafts = plannedCrafts
	line.planned = plannedCrafts * line.perCraft
	for _, reagent in ipairs(type(recipe.reagents) == 'table' and recipe.reagents or {}) do
		if isWhole(reagent.itemId) and isWhole(reagent.qty) then
			local material = materialFor(venture, reagent.itemId)
			material.need = math.max(0, material.need + reagent.qty * change)
		end
	end
	Ventures.refresh(venture)
	return line
end

--- The oldest open venture that wants an item or recipe:
---   buy   a material it needs more of than it bought (itemId)
---   craft a recipe crafted fewer times than planned (recipeId)
---   post  a crafted item with units not yet posted (itemId)
--- @return table|nil Venture
function Ventures.openFor(market, role, key)
	for _, venture in ipairs(openVentures(market)) do
		if role == 'buy' then
			local material = venture.materials[key]
			if material and material.need > material.bought then
				return venture
			end
		elseif role == 'craft' then
			local line = lineFor(venture, key)
			if line and line.crafted < line.planned then
				return venture
			end
		elseif role == 'post' then
			local line = lineForItem(venture, key)
			if line and unposted(line) > 0 then
				return venture
			end
		else
			error('Ventures.openFor: unknown role ' .. tostring(role), 2)
		end
	end
	return nil
end

--- Materials bought for the venture (an auction won, a vendor buy).
function Ventures.noteBuy(venture, itemId, qty, copper)
	local material = materialFor(venture, itemId)
	material.bought = material.bought + qty
	material.boughtCopper = material.boughtCopper + copper
	Ventures.refresh(venture)
end

--- A craft: made output units, and the cash share of each reagent (its cost-pool share).
--- @param costs table { [itemId] = { qty, knownUnits, knownCopper } }
function Ventures.noteCraft(venture, recipeId, made, costs)
	local line = lineFor(venture, recipeId)
	if line then
		line.crafted = line.crafted + made
	end
	for itemId, cost in pairs(type(costs) == 'table' and costs or {}) do
		local material = materialFor(venture, itemId)
		material.used = material.used + (cost.qty or 0)
		-- A legacy material with its split lost keeps it lost.
		material.knownUnits = material.knownUnits and material.knownUnits + (cost.knownUnits or 0)
		material.knownCopper = material.knownCopper + (cost.knownCopper or 0)
	end
	Ventures.refresh(venture)
end

--- Units of a crafted item posted, and the deposit paid.
function Ventures.notePost(venture, itemId, qty, deposit)
	local line = lineForItem(venture, itemId)
	if line then
		line.posted = line.posted + qty
	end
	venture.totals.depositPaid = venture.totals.depositPaid + (deposit or 0)
	Ventures.refresh(venture)
end

--- A sale settled by mail: gross is the buyer's bid, cut the house's 5%, refund the deposit back.
--- A troll sale counts as sold but is kept apart from the sell rate.
function Ventures.noteSale(venture, itemId, qty, sale)
	local line = lineForItem(venture, itemId)
	if line then
		line.sold = line.sold + qty
	end
	local totals = venture.totals
	totals.gross = totals.gross + (sale.gross or 0)
	totals.cut = totals.cut + (sale.cut or 0)
	totals.depositRefunded = totals.depositRefunded + (sale.refund or 0)
	if sale.isTroll then
		totals.trollUnits = totals.trollUnits + qty
	end
	Ventures.refresh(venture)
end

--- Units back from an expired or cancelled auction; they can be posted again.
function Ventures.noteReturn(venture, itemId, qty)
	local line = lineForItem(venture, itemId)
	if line then
		line.returned = line.returned + qty
	end
	Ventures.refresh(venture)
end

--- What would be left over if the venture closed now: crafted units neither sold nor live on
--- the auction house, and bought materials never used.
--- @return table { { itemId, qty, kind = 'crafted' | 'material' } }
function Ventures.leftovers(venture)
	local leftovers = {}
	for _, line in ipairs(venture.lines) do
		local qty = unposted(line)
		if qty > 0 then
			leftovers[#leftovers + 1] = { itemId = line.itemId, qty = qty, kind = 'crafted' }
		end
	end
	for itemId, material in pairs(venture.materials) do
		local qty = material.bought - material.used
		if qty > 0 then
			leftovers[#leftovers + 1] = { itemId = itemId, qty = qty, kind = 'material' }
		end
	end
	table.sort(leftovers, function(a, b)
		return a.itemId < b.itemId
	end)
	return leftovers
end

--- Every planned unit crafted and sold, nothing on the auction house or in the mail.
function Ventures.isSoldOut(venture)
	if #venture.lines == 0 then
		return false
	end
	for _, line in ipairs(venture.lines) do
		if line.planned == 0 or line.crafted < line.planned or line.sold < line.crafted then
			return false
		end
	end
	return true
end

--- Closes a venture. By hand (reason 'manual') the leftovers are written off or moved to stock;
--- a sold-out venture closes with reason 'sold'. Units still live stay tracked: a later sale is
--- still credited to the venture.
--- @param action string|nil writeOff | toStock (needed by hand when leftovers remain)
--- @return table|nil leftovers the caller books (ledger, cost pools)
--- @return string|nil reason
function Ventures.close(venture, now, action, reason)
	if venture.status == 'closed' then
		return nil, 'already closed'
	end
	if action ~= nil and not Ventures.LEFTOVER_ACTIONS[action] then
		error('Ventures.close: unknown leftover action ' .. tostring(action), 2)
	end
	local leftovers = Ventures.leftovers(venture)
	if #leftovers > 0 and not action then
		return nil, 'choose what happens to the leftovers'
	end
	venture.status = 'closed'
	venture.closedAt = now
	venture.closeReason = reason or 'manual'
	venture.leftoverAction = #leftovers > 0 and action or nil
	return leftovers
end

--- Recomputes the status from progress (never reopens a closed venture).
--- @return boolean changed
function Ventures.refresh(venture)
	if venture.status == 'closed' then
		return false
	end
	local status = deriveStatus(venture)
	local isChanged = status ~= venture.status
	venture.status = status
	return isChanged
end

--- The venture's profit both ways. Estimates are read now, through valueOf; without it (or for
--- an item it cannot price) they count as nothing and isEstimateComplete says so.
--- @param valueOf fun(itemId, qty): number|nil the value of units now (the venture's rule)
--- @return table { net, cash, overMaterials, spent, materialsCost, knownCopper, estimatedCopper,
---   knownShare, leftoverEstimate, isEstimateComplete, isSplitLost, hasUnpricedUnits } knownShare
---   is 0..1 of the materials cost that was paid, not estimated; isSplitLost: a legacy material's
---   known/estimated split was lost in the version-3 update; hasUnpricedUnits: some units have
---   no price now
function Ventures.profit(venture, valueOf)
	local totals = venture.totals
	local materials = sumMaterials(venture, valueOf)
	-- Leftovers moved to stock count at their value now; written-off ones count as nothing.
	local leftover, isLeftoverComplete = leftoverEstimate(venture, valueOf)
	local net = totals.gross - totals.cut + totals.depositRefunded - totals.depositPaid + leftover
	local materialsCost = materials.knownCopper + materials.estimatedCopper
	return {
		net = net,
		-- Cash is gold logged out and in: leftovers moved to stock are value, not gold.
		cash = net - materials.boughtCopper - leftover,
		overMaterials = net - materialsCost,
		spent = materials.boughtCopper + totals.depositPaid,
		materialsCost = materialsCost,
		knownCopper = materials.knownCopper,
		estimatedCopper = materials.estimatedCopper,
		knownShare = materialsCost > 0 and materials.knownCopper / materialsCost or nil,
		leftoverEstimate = leftover,
		isEstimateComplete = materials.isComplete and isLeftoverComplete,
		isSplitLost = materials.isSplitLost,
		hasUnpricedUnits = materials.hasUnpricedUnits or not isLeftoverComplete,
	}
end

--- What the venture should bring in if every planned unit sells at today's value, and how long
--- selling should take: units to sell / (sales per day × market share). The time is an
--- estimate and says so.
--- @param sources table { valueOf = fun(itemId, qty) -> copper|nil, confidence?, usesPriceSource?,
---   costOf = fun(line, crafts) -> copper|nil, confidence?, usesPriceSource?,
---   salesPerDay = fun(itemId) -> number|nil, sharePercent? }
--- @return table Forecast { income, cost, profit, margin?, days?, isComplete, confidence,
---   usesPriceSource, note }
function Ventures.forecast(venture, sources)
	local share = (sources.sharePercent or Ventures.DEFAULT_MARKET_SHARE) / 100
	local profit = Ventures.profit(venture, sources.valueOf)
	local income, cost, days, isComplete = profit.net, profit.materialsCost, 0, true
	local confidences, usesPriceSource = {}, false
	for _, line in ipairs(venture.lines) do
		local toSell = line.planned - line.sold
		if toSell > 0 then
			local value, valueConfidence, valueUsesSource = sources.valueOf(line.itemId, toSell)
			income = income + (value or 0)
			isComplete = isComplete and value ~= nil
			confidences[#confidences + 1] = valueConfidence
			usesPriceSource = usesPriceSource or valueUsesSource == true
			local perDay = sources.salesPerDay(line.itemId)
			if perDay and perDay > 0 and days then
				days = math.max(days, toSell / (perDay * share))
			else
				days = nil
			end
		end
		local toCraft = line.plannedCrafts - math.ceil(line.crafted / line.perCraft)
		if toCraft > 0 then
			local lineCost, costConfidence, costUsesSource = sources.costOf(line, toCraft)
			cost = cost + (lineCost or 0)
			isComplete = isComplete and lineCost ~= nil
			confidences[#confidences + 1] = costConfidence
			usesPriceSource = usesPriceSource or costUsesSource == true
		end
	end
	if not isComplete then
		confidences[#confidences + 1] = {
			level = 'low',
			reasons = { { code = 'noPrice', level = 'low', text = 'some items have no price: counted as nothing' } },
		}
	end
	local forecastProfit = income - cost
	return {
		income = income,
		cost = cost,
		profit = forecastProfit,
		margin = income > 0 and forecastProfit / income or nil,
		days = days,
		isComplete = isComplete,
		confidence = ns.Value.mergeConfidence(confidences, 4),
		usesPriceSource = usesPriceSource,
		note = 'Estimated from sales per day and a ' .. math.floor(share * 100) .. '% market share',
	}
end

-- Helpers ---------------------------------------------------------------------------------

function isWhole(value)
	return type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0
end

function venturesOf(market)
	return type(market) == 'table' and type(market.ventures) == 'table' and market.ventures or nil
end

function lineFor(venture, recipeId)
	for _, line in ipairs(venture.lines) do
		if line.recipeId == recipeId then
			return line
		end
	end
	return nil
end

-- The first line making an item that still has room for it.
function lineForItem(venture, itemId)
	local fallback
	for _, line in ipairs(venture.lines) do
		if line.itemId == itemId then
			if unposted(line) > 0 or live(line) > 0 then
				return line
			end
			fallback = fallback or line
		end
	end
	return fallback
end

function materialFor(venture, itemId)
	local material = venture.materials[itemId]
	if not material then
		material = { need = 0, bought = 0, boughtCopper = 0, used = 0, knownUnits = 0, knownCopper = 0 }
		venture.materials[itemId] = material
	end
	return material
end

function deriveStatus(venture)
	local isAllCrafted, hasCrafted, hasBought = #venture.lines > 0, false, false
	for _, line in ipairs(venture.lines) do
		isAllCrafted = isAllCrafted and line.planned > 0 and line.crafted >= line.planned
		hasCrafted = hasCrafted or line.crafted > 0
	end
	for _, material in pairs(venture.materials) do
		hasBought = hasBought or material.bought > 0
	end
	if isAllCrafted then
		return 'selling'
	end
	if hasCrafted then
		return 'crafting'
	end
	return hasBought and 'buying' or 'planning'
end

-- Units on the auction house or on their way back by mail.
function live(line)
	return math.max(0, line.posted - line.sold - line.returned)
end

-- Crafted units in the bags: neither live nor sold.
function unposted(line)
	return math.max(0, line.crafted - line.sold - live(line))
end

-- Paid valuation: the known copper plus today's value of the units of unknown origin.
-- Opportunity valuation: today's value of every unit used, known or not.
function sumMaterials(venture, valueOf)
	local sum = {
		boughtCopper = 0,
		knownCopper = 0,
		estimatedCopper = 0,
		isComplete = true,
		isSplitLost = false,
		hasUnpricedUnits = false,
	}
	local isPaid = venture.valuation == 'paid'
	for itemId, material in pairs(venture.materials) do
		sum.boughtCopper = sum.boughtCopper + material.boughtCopper
		local known = isPaid and material.knownCopper or 0
		local unknownUnits = material.used
		if isPaid then
			-- A legacy split that was lost: the known copper stands, the rest cannot be valued.
			unknownUnits = material.knownUnits and material.used - material.knownUnits or nil
		end
		sum.knownCopper = sum.knownCopper + known
		local estimate, isComplete = estimateOf(valueOf, itemId, unknownUnits)
		sum.estimatedCopper = sum.estimatedCopper + estimate
		sum.isComplete = sum.isComplete and isComplete
		sum.isSplitLost = sum.isSplitLost or unknownUnits == nil
		sum.hasUnpricedUnits = sum.hasUnpricedUnits or (unknownUnits ~= nil and not isComplete)
	end
	return sum
end

-- Today's value of units: 0 with nothing to value; incomplete when it cannot be read.
function estimateOf(valueOf, itemId, units)
	if units == nil then
		return 0, false
	end
	if units <= 0 then
		return 0, true
	end
	if type(valueOf) ~= 'function' then
		return 0, false
	end
	local ok, copper = pcall(valueOf, itemId, units)
	if ok and isWhole(copper) then
		return copper, true
	end
	return 0, false
end

function leftoverEstimate(venture, valueOf)
	if venture.status ~= 'closed' or venture.leftoverAction ~= 'toStock' then
		return 0, true
	end
	local total, isComplete = 0, true
	for _, leftover in ipairs(Ventures.leftovers(venture)) do
		local estimate, isKnown = estimateOf(valueOf, leftover.itemId, leftover.qty)
		total, isComplete = total + estimate, isComplete and isKnown
	end
	return total, isComplete
end

function openVentures(market)
	local open = Ventures.list(market, { isOpen = true })
	table.sort(open, function(a, b)
		return a.id < b.id
	end)
	return open
end

return Ventures
