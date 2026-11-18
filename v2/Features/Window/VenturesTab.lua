--[[
	Ventures tab (V2, left out of the release package): crafting ventures from plan to the last copper in the mail (Engine/Ventures.lua,
	booked by Features/Tracking.lua). Pick a venture (open ones first, closed ones kept for good)
	and see its lines, materials, profit both ways (cash, and over what the materials were
	worth) with the known share, and the forecast at today's values. Plan more or fewer crafts
	of a line, and close by hand: leftovers are written off or moved to stock. A venture that
	has sold everything closes by itself. Ventures are never deleted.

	  VenturesTab.detailLines(venture, forecast, nameOf, valueOf?) -> { { text, level? } }
	  valueOf(itemId, qty) -> copper|nil values the estimates live (nothing estimated is stored)
]]
local _, ns = ...

local VenturesTab = {}
ns.VenturesTab = VenturesTab

local MAX_LINES = 22
local LINES_WIDTH = 860
local STATUS_LABELS = {
	planning = 'planning',
	buying = 'buying materials',
	crafting = 'crafting',
	selling = 'selling',
	closed = 'closed',
}
local VALUATION_LABELS = { opportunity = 'what the materials would sell for', paid = 'what was paid' }
local CLOSE_LABELS = { sold = 'sold out', manual = 'closed by hand' }
local LEFTOVER_LABELS = { toStock = 'leftovers moved to stock', writeOff = 'leftovers written off' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local refresh, selected, selectedLine, forecastOf, liveValueOf, marketNow, closeSelected, stepCrafts, signed, percent, itemName

ns.window:AddTab({
	key = 'ventures',
	label = 'Ventures',
	order = 70,
	build = function(container, ctx)
		local ui = ctx.ui
		container.state = { index = 1, lineIndex = 1 }
		container.picker = ui:Stepper(container, 360, function(delta)
			container.state.index = container.state.index + delta
			container.state.lineIndex = 1
			refresh(container, ctx)
		end)
		container.picker:SetPoint('TOPLEFT', container, 'TOPLEFT', 0, 0)
		container.linePicker = ui:Stepper(container, 260, function(delta)
			container.state.lineIndex = container.state.lineIndex + delta
			refresh(container, ctx)
		end)
		container.linePicker:SetPoint('LEFT', container.picker, 'RIGHT', 8, 0)
		container.crafts = ui:Stepper(container, 140, function(delta)
			stepCrafts(container, ctx, delta)
		end, { '−', '+' })
		container.crafts:SetPoint('LEFT', container.linePicker, 'RIGHT', 8, 0)
		container.lines = ui:PagedLines(container, MAX_LINES, 13, LINES_WIDTH)
		container.lines.frame:SetPoint('TOPLEFT', container.picker, 'BOTTOMLEFT', 0, -12)
		container.toStock = ui:Button(container, 'Close: leftovers to stock', 'secondary')
		container.toStock:SetPoint('TOPLEFT', container.lines.frame, 'BOTTOMLEFT', 0, -8)
		container.toStock:OnClick(function()
			closeSelected(container, ctx, 'toStock')
		end)
		container.writeOff = ui:Button(container, 'Close: write leftovers off', 'secondary')
		container.writeOff:SetPoint('LEFT', container.toStock, 'RIGHT', 8, 0)
		container.writeOff:OnClick(function()
			closeSelected(container, ctx, 'writeOff')
		end)
	end,
	refresh = function(container, ctx)
		refresh(container, ctx)
	end,
})

--- What the tab shows for one venture.
--- @param forecast table|nil Ventures.forecast (open ventures only)
--- @param nameOf function fun(itemId) -> string
function VenturesTab.detailLines(venture, forecast, nameOf, valueOf)
	local money = ns.TooltipLines.money
	local lines = {}
	local function add(text, level)
		lines[#lines + 1] = { text = text, level = level }
	end
	local status = STATUS_LABELS[venture.status] or venture.status
	if venture.status == 'closed' then
		status = string.format(
			'%s (%s, %s)',
			status,
			CLOSE_LABELS[venture.closeReason] or tostring(venture.closeReason),
			LEFTOVER_LABELS[venture.leftoverAction] or 'nothing left over'
		)
	end
	add(string.format('%s · %s · costed at %s', venture.name, status, VALUATION_LABELS[venture.valuation] or '?'))
	for _, line in ipairs(venture.lines) do
		add(
			string.format(
				'  %s: planned %d · crafted %d · posted %d · sold %d · back %d',
				nameOf(line.itemId),
				line.planned,
				line.crafted,
				line.posted,
				line.sold,
				line.returned
			)
		)
	end
	local materials = {}
	for itemId, material in pairs(venture.materials) do
		materials[#materials + 1] = { itemId = itemId, material = material }
	end
	table.sort(materials, function(a, b)
		return a.itemId < b.itemId
	end)
	for _, entry in ipairs(materials) do
		local material = entry.material
		add(
			string.format(
				'  %s: need %d · bought %d (%s) · used %d',
				nameOf(entry.itemId),
				material.need,
				material.bought,
				money(material.boughtCopper),
				material.used
			)
		)
	end
	local profit = ns.Ventures.profit(venture, valueOf)
	add(
		string.format(
			'Net %s · cash %s · over materials %s',
			signed(profit.net),
			signed(profit.cash),
			signed(profit.overMaterials)
		)
	)
	add(
		string.format(
			'Materials %s: known %s · estimated %s (%s known)',
			money(profit.materialsCost),
			money(profit.knownCopper),
			money(profit.estimatedCopper),
			percent(profit.knownShare)
		),
		profit.knownShare and profit.knownShare < 0.5 and profit.materialsCost > 0 and 'medium' or nil
	)
	if profit.isSplitLost then
		add(
			"Part of this venture's history was lost in the update. Those materials count only what was paid.",
			'medium'
		)
	end
	if profit.hasUnpricedUnits then
		add('Some estimates have no price now. They count as nothing.', 'medium')
	end
	if forecast then
		add(
			string.format(
				'Forecast: income %s · cost %s · profit %s%s',
				money(forecast.income),
				money(forecast.cost),
				signed(forecast.profit),
				forecast.margin and (' · margin ' .. percent(forecast.margin)) or ''
			),
			forecast.profit < 0 and 'low' or nil
		)
		add(
			forecast.days and string.format('Selling should take about %.1f days. %s', forecast.days, forecast.note)
				or 'Selling time unknown: no sales a day for an item.',
			forecast.days == nil and 'medium' or nil
		)
		-- Low and medium confidence always show, with every reason.
		local confidence = forecast.confidence or {}
		if confidence.level and confidence.level ~= 'high' then
			add('Forecast confidence ' .. confidence.level, confidence.level)
			for _, reason in ipairs(confidence.reasons or {}) do
				add('  ' .. (reason.text or tostring(reason.code)), reason.level or confidence.level)
			end
		end
	end
	return lines
end

-- Helpers ---------------------------------------------------------------------------------

function refresh(container, ctx)
	local market = marketNow()
	if not market or not ns.books then
		container.lines:SetLines({ { text = 'Ventures need the market and tracking on.', level = 'medium' } })
		container.picker:SetValue('')
		ctx.setCredit(nil)
		return
	end
	local venture, count = selected(container, market)
	container.toStock:SetEnabled(venture ~= nil and venture.status ~= 'closed')
	container.writeOff:SetEnabled(venture ~= nil and venture.status ~= 'closed')
	if not venture then
		container.picker:SetValue('No ventures')
		container.linePicker:SetValue('')
		container.crafts:SetValue('')
		container.lines:SetLines({
			{ text = 'No ventures yet. Pick a recipe in your profession window and press Plan venture.' },
		})
		ctx.setCredit(nil)
		return
	end
	container.picker:SetValue(string.format('%d/%d %s', container.state.index, count, venture.name))
	local line = selectedLine(container, venture)
	container.linePicker:SetValue(line and itemName(line.itemId) or 'No recipes')
	container.crafts:SetValue(line and (line.plannedCrafts .. ' crafts') or '')
	container.crafts:SetEnabled(line ~= nil and venture.status ~= 'closed')
	local forecast = venture.status ~= 'closed' and forecastOf(venture, ctx) or nil
	container.lines:SetLines(VenturesTab.detailLines(venture, forecast, itemName, liveValueOf(venture)))
	ctx.setCredit(forecast and forecast.usesPriceSource and ctx.window:Credit() or nil)
end

-- Open ventures first (newest first), then closed ones.
function selected(container, market)
	local list = ns.Ventures.list(market, { isOpen = true })
	for _, venture in ipairs(ns.Ventures.list(market, { isOpen = false })) do
		list[#list + 1] = venture
	end
	if #list == 0 then
		return nil, 0
	end
	container.state.index = (container.state.index - 1) % #list + 1
	return list[container.state.index], #list
end

function selectedLine(container, venture)
	local count = #venture.lines
	if count == 0 then
		return nil
	end
	container.state.lineIndex = (container.state.lineIndex - 1) % count + 1
	return venture.lines[container.state.lineIndex]
end

-- Today's value of units at the venture's rule: estimates are read live, never stored.
function liveValueOf(venture)
	local priceCtx = ns.prices and ns.prices:Context()
	return function(itemId, qty)
		local value = ns.values and ns.values:Stack(itemId, qty, { ruleId = venture.ruleId, ctx = priceCtx })
		return value and value.isPriced and value.copper or nil
	end
end

function forecastOf(venture, ctx)
	local prices = ns.prices
	local priceCtx = prices and prices:Context()
	local view = ns.CraftingView.new({
		schematic = function(recipeId)
			return ctx.wow:RecipeSchematic(recipeId)
		end,
		prices = prices,
		values = ns.values,
		market = marketNow,
		held = function(itemId)
			return ctx.wow:ItemCount(itemId)
		end,
		valuation = function()
			return venture.valuation
		end,
	})
	return ns.Ventures.forecast(venture, {
		valueOf = function(itemId, qty)
			local value = ns.values and ns.values:Stack(itemId, qty, { ruleId = venture.ruleId, ctx = priceCtx })
			if not (value and value.isPriced) then
				return nil
			end
			local rulePrice = value.rulePrice
			return value.copper, value.confidence, type(rulePrice) == 'table' and rulePrice.usesPriceSource == true
		end,
		costOf = function(line, crafts)
			local craft = view:Craft(line.recipeId, crafts)
			if not craft then
				return nil
			end
			return craft.isComplete and craft.cost or nil, craft.confidence, craft.usesPriceSource
		end,
		salesPerDay = function(itemId)
			return priceCtx and ns.PriceContext.facts(priceCtx, itemId).salesPerDay or nil
		end,
	})
end

function closeSelected(container, ctx, action)
	local market = marketNow()
	local venture = market and selected(container, market)
	if not venture or not ns.books then
		return
	end
	local leftovers, reason = ns.books:CloseVenture(venture.id, action)
	if not leftovers then
		ctx.setStatus(reason)
		return
	end
	ctx.setStatus(
		string.format('%s closed: %d leftover %s.', venture.name, #leftovers, #leftovers == 1 and 'item' or 'items')
	)
	refresh(container, ctx)
end

-- Plans one craft more or fewer of the selected line; the recipe comes from the client.
function stepCrafts(container, ctx, delta)
	local market = marketNow()
	local venture = market and selected(container, market)
	local line = venture and selectedLine(container, venture)
	if not line or not ns.books then
		return
	end
	local recipe = ns.CraftingView.ventureRecipe(ctx.wow:RecipeSchematic(line.recipeId))
	if not recipe then
		ctx.setStatus('Open your profession window once so the recipe is known.')
		return
	end
	local planned, reason = ns.books:PlanCrafts(venture.id, recipe, delta)
	if not planned then
		ctx.setStatus(reason)
	end
	refresh(container, ctx)
end

function marketNow()
	local marketKey = ns.prices and ns.prices:MarketKey()
	return marketKey and ns.store:Market(marketKey) or nil
end

function signed(copper)
	return (copper < 0 and '-' or '+') .. ns.TooltipLines.money(math.abs(copper))
end

function percent(fraction)
	return fraction and string.format('%d%%', math.floor(fraction * 100 + 0.5)) or '?'
end

function itemName(itemId)
	local info = ns.prices and ns.prices:ItemInfo(itemId)
	return info and info.name or ('Item ' .. tostring(itemId))
end
