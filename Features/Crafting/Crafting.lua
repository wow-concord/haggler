--[[
	Crafting: cost, value, margin and confidence on Blizzard's profession frame; no window of
	Haggler's own. Each recipe row in the list gets its profit and margin; the selected recipe
	gets a side panel with the figures, the known versus estimated share, the confidence and a
	"Plan venture" button. Each part has its own setting; low confidence and its reasons show
	whatever is switched off.

	The valuation setting picks how reagents the player holds are costed: what they would fetch
	(opportunity, the default) or what was paid for them (cost pools; units of unknown origin
	fall back to opportunity).

	Taint: Haggler adds its own font strings and panel to Blizzard's frames and listens through
	hooksecurefunc and the scroll box's frame-initialized callback; it never replaces a
	Blizzard function, never sorts or filters the recipe list and never touches a secure frame.
	Placement: Features/Crafting/Anchor.lua puts the panel right of Forever's side tab column,
	measured each time the selected recipe repaints.
	Frame cost: a row costs a cache lookup (Features/Crafting/View.lua); the cache drops on
	prices, scans, rules, the bags and the books, and the visible rows repaint once a frame.
]]
local _, ns = ...

local MODULE_KEY = 'crafting'
local EVENT_OWNER = 'crafting'
-- 8-point grid (Concord DS): whole pixels, heights in 4s, the hairline drawn inside the box.
local PANEL_WIDTH = 264
local PANEL_LINES = 9
local LINE_SIZE = 12
local PANEL_PADDING = 8
local GRID = 8
-- Nine 18-high lines (Widgets:Lines) round up to the grid.
local PANEL_BODY_HEIGHT = math.ceil(PANEL_LINES * (LINE_SIZE + 6) / GRID) * GRID
local ROW_TEXT_INSET = -6
local LEVEL_TOKENS = { low = 'color.state.danger', medium = 'color.state.warning' }
local INVALIDATING_MESSAGES =
	{ 'SCAN_READY', 'PRICE_TABLE_LOADED', 'RULES_CHANGED', 'DEFAULT_RULE_CHANGED', 'LEDGER_CHANGED' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local attach, paintRow, paintRecipeRow, paintDetail, ensurePanel, invalidate, repaint, planVenture, marketNow, setColor
local placePanel, queuePlacement, watchColumn

local state = {
	isOn = false,
	isHooked = false,
	-- Blizzard recycles row frames: weak keys let a dropped frame go.
	rowTexts = setmetatable({}, { __mode = 'k' }),
	rowRecipes = setmetatable({}, { __mode = 'k' }),
	-- Tab column frames already hooked (a script hook cannot be removed, so once each).
	watchedColumnFrames = setmetatable({}, { __mode = 'k' }),
}

ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Profession window',
	settings = {
		{ key = 'showList', type = 'toggle', label = 'Profit and margin on each recipe', default = true },
		{
			key = 'showDetail',
			type = 'toggle',
			label = 'Cost, value and profit of the selected recipe',
			default = true,
		},
		{ key = 'showShare', type = 'toggle', label = 'Known and estimated share of the cost', default = true },
		{ key = 'showPlan', type = 'toggle', label = 'Plan venture button', default = true },
		{
			key = 'valuation',
			type = 'choice',
			label = 'Reagents you hold cost',
			default = 'opportunity',
			choices = {
				{ value = 'opportunity', label = 'What they would sell for' },
				{ value = 'paid', label = 'What you paid (unknown origin: what they would sell for)' },
			},
		},
	},
	onEnable = function(module)
		state.isOn = true
		state.module = module
		state.view = ns.CraftingView.new({
			schematic = function(recipeId)
				return ns.wow:RecipeSchematic(recipeId)
			end,
			prices = ns.prices,
			values = ns.values,
			market = marketNow,
			held = function(itemId)
				return ns.wow:ItemCount(itemId)
			end,
			valuation = function()
				return module:Setting('valuation')
			end,
		})
		ns.wow:OnEvent('TRADE_SKILL_SHOW', function()
			attach()
			invalidate(true)
		end, EVENT_OWNER)
		ns.wow:OnEvent('BAG_UPDATE_DELAYED', invalidate, EVENT_OWNER)
		module:On(ns.Host.SETTINGS_CHANGED, invalidate)
		for _, message in ipairs(INVALIDATING_MESSAGES) do
			module:On(message, invalidate)
		end
		attach()
		repaint()
	end,
	onDisable = function()
		state.isOn = false
		ns.wow:OffEvent('TRADE_SKILL_SHOW', EVENT_OWNER)
		ns.wow:OffEvent('BAG_UPDATE_DELAYED', EVENT_OWNER)
		for _, text in pairs(state.rowTexts) do
			text:Hide()
		end
		if state.panel then
			state.panel:Hide()
		end
	end,
})

--- Hooks the profession frame once it exists (Blizzard_Professions loads on demand).
function attach()
	local env = ns.wow.env
	local frame = env.ProfessionsFrame
	local page = type(frame) == 'table' and frame.CraftingPage
	if state.isHooked or type(page) ~= 'table' then
		return
	end
	state.isHooked = true
	state.frame = frame
	-- The tab column lays out with the frame and changes with the profession: place again then.
	ns.wow:HookFrameScript(frame, 'OnShow', queuePlacement)
	ns.wow:HookFrameScript(frame, 'OnSizeChanged', queuePlacement)
	ns.wow:HookMethod(page.SchematicForm, 'Init', function(_, recipeInfo)
		state.recipeId = type(recipeInfo) == 'table' and recipeInfo.recipeID or nil
		paintDetail()
	end)
	local scrollBox = type(page.RecipeList) == 'table' and page.RecipeList.ScrollBox
	local scrollUtil = env.ScrollUtil
	if scrollBox and type(scrollUtil) == 'table' and type(scrollUtil.AddInitializedFrameCallback) == 'function' then
		scrollUtil.AddInitializedFrameCallback(scrollBox, function(_, row, node)
			local ok, err = pcall(paintRow, row, node)
			if not ok then
				ns.wow:ReportHookError('recipe row', err)
			end
		end, MODULE_KEY, true)
	end
end

function paintRow(row, node)
	if type(row) ~= 'table' then
		return
	end
	local data = type(node) == 'table' and node.GetData and node:GetData()
	local recipeInfo = type(data) == 'table' and data.recipeInfo
	paintRecipeRow(row, type(recipeInfo) == 'table' and recipeInfo.recipeID or nil)
end

function paintRecipeRow(row, recipeId)
	state.rowRecipes[row] = recipeId
	local text = state.rowTexts[row]
	if not (state.isOn and recipeId and state.module:Setting('showList')) then
		if text then
			text:Hide()
		end
		return
	end
	if not text then
		text = row:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
		text:SetPoint('RIGHT', row, 'RIGHT', ROW_TEXT_INSET, 0)
		state.rowTexts[row] = text
	end
	local label, level = ns.CraftingView.rowText(state.view:Craft(recipeId))
	text:SetText(label)
	setColor(text, LEVEL_TOKENS[level] or 'color.text.secondary')
	text:Show()
end

function paintDetail()
	local module = state.module
	if not state.isOn or not state.frame then
		return
	end
	local craft = state.recipeId and state.view:Craft(state.recipeId)
	local lines = ns.CraftingView.detailLines(craft, {
		figures = module:Setting('showDetail'),
		share = module:Setting('showShare'),
		credit = ns.window and ns.window:Credit() or ns.PriceData.DEFAULT_CREDIT,
	})
	local canPlan = craft ~= nil and module:Setting('showPlan') and ns.books ~= nil
	local panel = (#lines > 0 or canPlan) and ensurePanel() or state.panel
	if not panel then
		return
	end
	panel.lines:SetLines(lines)
	panel.plan:SetShown(canPlan)
	placePanel()
	panel:SetShown(#lines > 0 or canPlan)
end

function ensurePanel()
	if state.panel then
		return state.panel
	end
	local ui = ns.Widgets.new(ns.wow, ns.theme)
	local panel = ns.wow:CreateFrame('Frame', state.frame)
	local buttonHeight = ns.Widgets.BUTTON_HEIGHT
	panel:SetSize(PANEL_WIDTH, PANEL_PADDING * 3 + PANEL_BODY_HEIGHT + buttonHeight)
	-- The DS window surface and its hairline (--window-bg, --window-border), not a tooltip.
	ui:Fill(panel, 'color.surface.base')
	ui:Border(panel, 'color.border.subtle')
	local body = ns.wow:CreateFrame('Frame', panel)
	body:SetPoint('TOPLEFT', panel, 'TOPLEFT', PANEL_PADDING, -PANEL_PADDING)
	body:SetPoint('RIGHT', panel, 'RIGHT', -PANEL_PADDING, 0)
	body:SetHeight(PANEL_BODY_HEIGHT)
	panel.lines = ui:Lines(body, PANEL_LINES, LINE_SIZE)
	panel.plan = ui:Button(panel, 'Plan venture', 'secondary')
	panel.plan:SetPoint('BOTTOMLEFT', panel, 'BOTTOMLEFT', PANEL_PADDING, PANEL_PADDING)
	panel.plan:OnClick(planVenture)
	state.panel = panel
	return panel
end

--- Plans one craft of the selected recipe in its open venture, or a new one (the Ventures tab plans more).
function planVenture()
	local recipe = ns.CraftingView.ventureRecipe(ns.wow:RecipeSchematic(state.recipeId))
	if not recipe or not ns.books then
		return
	end
	local info = ns.prices and ns.prices:ItemInfo(recipe.itemId)
	local venture = ns.books:PlanCrafts(nil, recipe, 1, {
		name = info and info.name or nil,
		valuation = state.module:Setting('valuation'),
	})
	if venture and ns.window then
		ns.window:Open('ventures')
	end
end

-- Helpers ---------------------------------------------------------------------------------

-- isOpening: the profession frame is opening, so the repaint is queued even while it is hidden.
function invalidate(isOpening)
	if not state.view then
		return
	end
	state.view:Invalidate()
	-- Closed: the next TRADE_SKILL_SHOW paints from scratch, so no repaint is queued.
	local isShown = state.frame and state.frame:IsShown()
	if state.isRepaintQueued or not (isShown or isOpening == true) then
		return
	end
	state.isRepaintQueued = true
	ns.wow:After(0, function()
		state.isRepaintQueued = false
		repaint()
	end)
end

function repaint()
	if not state.isOn or not state.frame or not state.frame:IsShown() then
		return
	end
	for row in pairs(state.rowTexts) do
		paintRecipeRow(row, state.rowRecipes[row])
	end
	paintDetail()
end

function placePanel()
	if not state.panel or not state.frame then
		return
	end
	ns.CraftingAnchor.place(state.panel, state.frame, ns.wow.env.UIParent, PANEL_WIDTH)
	watchColumn()
end

-- Next frame: a frame that just showed or resized has not laid out its children yet.
function queuePlacement()
	if state.isPlacementQueued or not state.isOn then
		return
	end
	state.isPlacementQueued = true
	ns.wow:After(0, function()
		state.isPlacementQueued = false
		placePanel()
	end)
end

function watchColumn()
	for _, columnFrame in ipairs(ns.CraftingAnchor.columnFrames(state.frame, state.panel)) do
		if not state.watchedColumnFrames[columnFrame] then
			state.watchedColumnFrames[columnFrame] = true
			ns.wow:HookFrameScript(columnFrame, 'OnShow', queuePlacement)
			ns.wow:HookFrameScript(columnFrame, 'OnHide', queuePlacement)
			ns.wow:HookFrameScript(columnFrame, 'OnSizeChanged', queuePlacement)
		end
	end
end

function marketNow()
	local marketKey = ns.prices and ns.prices:MarketKey()
	return marketKey and ns.store:Market(marketKey) or nil
end

function setColor(text, token)
	local color = ns.theme:Color(token)
	text:SetTextColor(color.r, color.g, color.b, color.a)
end
