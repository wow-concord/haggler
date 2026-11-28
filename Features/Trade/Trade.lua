--[[
	Trade: values in Blizzard's trade window and a loss warning (Features/Trade/Model.lua reads,
	Frames.lua draws). Gold counts at face value, items at their value (net after the cut and
	deposit risk, never below vendor), the enchant slot not at all.

	Loss: the player gives more than they get by more than the convenience fee (an amount plus a
	percentage of the player's side). Mode off shows values only, warn (default) shows the
	warning, confirm also covers the Trade button with a click-twice button of Haggler's own.
	Friends (character or Battle.net) and guild members each get a policy: full, values only, or
	off (Haggler shows nothing for them).

	A completed trade is logged to the market's ledger as tradeOut / tradeIn events, whatever the
	policy, when "Log trades" is on. The rule picked on the frame is remembered per character.
]]
local _, ns = ...

local MODULE_KEY = 'trade'
local EVENT_OWNER = 'trade'
local COPPER_PER_SILVER = 100
local POLICY_CHOICES = {
	{ value = 'full', label = 'Values and loss warning' },
	{ value = 'values', label = 'Values only' },
	{ value = 'off', label = 'Nothing' },
}

-- Helpers live at the bottom of the file; declared here so they stay local.
local ensureParts, onTradeEvent, logTrade, nextRuleId, savedRuleId, characterKey

local state = { isOn = false }

local trade = ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Trade window',
	settings = {
		{
			key = 'mode',
			type = 'choice',
			label = 'When a trade loses more than the fee',
			default = 'warn',
			choices = {
				{ value = 'warn', label = 'Warn' },
				{ value = 'confirm', label = 'Warn and ask to confirm the Trade button' },
				{ value = 'off', label = 'Show values only' },
			},
		},
		{
			key = 'feeSilver',
			type = 'slider',
			label = 'Convenience fee: silver you accept to lose on any trade',
			default = 50,
			min = 0,
			max = 20000,
		},
		{
			key = 'feePercent',
			type = 'slider',
			label = 'Convenience fee: percent of what you give that you accept to lose',
			default = 5,
			min = 0,
			max = 50,
		},
		{ key = 'friends', type = 'choice', label = 'Trades with friends', default = 'full', choices = POLICY_CHOICES },
		{
			key = 'guild',
			type = 'choice',
			label = 'Trades with guild members',
			default = 'full',
			choices = POLICY_CHOICES,
		},
		{ key = 'logTrades', type = 'toggle', label = 'Log completed trades for profit tracking', default = true },
	},
	onEnable = function(module)
		state.isOn = true
		ensureParts(module)
		for _, event in ipairs(ns.TradeModel.EVENTS) do
			ns.wow:OnEvent(event, function(_, ...)
				onTradeEvent(module, event, ...)
			end, EVENT_OWNER)
		end
		module:On(ns.Host.SETTINGS_CHANGED, function(_, moduleKey)
			if moduleKey == MODULE_KEY and state.model.isOpen and state.model:Read() then
				state.frames:Render(state.model:Describe())
			end
		end)
	end,
	onDisable = function()
		state.isOn = false
		for _, event in ipairs(ns.TradeModel.EVENTS) do
			ns.wow:OffEvent(event, EVENT_OWNER)
		end
		if state.frames then
			state.frames:Render(nil)
		end
	end,
})
ns.trade = trade

-- Helpers ---------------------------------------------------------------------------------

function ensureParts(module)
	if state.model then
		return
	end
	local icons = ns.IconSet.new({ theme = ns.theme })
	state.model = ns.TradeModel.new({
		wow = ns.wow,
		values = function()
			return ns.values
		end,
		options = function()
			return {
				mode = module:Setting('mode'),
				feeCopper = module:Setting('feeSilver') * COPPER_PER_SILVER,
				feePercent = module:Setting('feePercent'),
				friends = module:Setting('friends'),
				guild = module:Setting('guild'),
				ruleId = savedRuleId(),
				money = ns.TooltipLines.money,
			}
		end,
		onComplete = function(snapshot)
			if module:Setting('logTrades') then
				logTrade(snapshot)
			end
		end,
	})
	state.frames = ns.TradeFrames.new({
		wow = ns.wow,
		icons = icons,
		theme = ns.theme,
		ruleName = function(ruleId)
			local rule = ns.store:Rule(ruleId)
			return rule and rule.name or tostring(ruleId)
		end,
		onRuleClick = function()
			ns.store:Ui().tradeRuleId = nextRuleId(state.model.snapshot and state.model.snapshot.ruleId)
			if state.model.isOpen and state.model:Read() then
				state.frames:Render(state.model:Describe())
			end
		end,
		onAccept = function()
			ns.wow:AcceptTrade()
		end,
	})
end

function onTradeEvent(_, event, ...)
	if not state.isOn then
		return
	end
	local change = state.model:OnEvent(event, ...)
	if change == 'changed' then
		state.frames:Attach()
		state.frames:Render(state.model:Describe())
	elseif change == 'closed' then
		state.frames:Render(nil)
	end
end

function logTrade(snapshot)
	local marketKey = ns.prices and ns.prices:MarketKey()
	local charKey = characterKey(ns.wow:Player())
	if not marketKey or not charKey then
		return
	end
	local market = ns.store:Market(marketKey)
	ns.Ledger.appendAll(market, ns.Ledger.tradeEvents(snapshot, ns.wow:Now(), charKey))
end

-- The rule after the current one, in the store's order (built-ins first), wrapping around.
function nextRuleId(currentRuleId)
	local ruleIds = ns.store:RuleIds()
	for index, ruleId in ipairs(ruleIds) do
		if ruleId == currentRuleId then
			return ruleIds[index % #ruleIds + 1]
		end
	end
	return ruleIds[1]
end

-- The rule picked on the frame, while it still exists (a deleted rule falls back to the default).
function savedRuleId()
	local ruleId = ns.store:Ui().tradeRuleId
	return ruleId and ns.store:Rule(ruleId) and ruleId or nil
end

function characterKey(player)
	return ns.store and ns.store:CharacterKey(player) or nil
end
