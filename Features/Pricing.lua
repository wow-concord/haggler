--[[
	Pricing: the always-on module that owns prices. It owns the confidence settings, reads market
	prices from AHledger (PriceData's AHledgerAPI source), and provides prices to the rest of the
	add-on and to other add-ons:

	  price v1          get(itemId) -> { copper, ageSeconds, source } under the default rule
	  haggler.price v1  get(itemId, ruleId?) -> Price · rules() · defaultRule()

	ns.prices is the PriceService the add-on's own modules use. Sends PRICE_TABLE_LOADED
	(marketKeys) once AHledger's table for the player's market is known: at enable, or at
	PLAYER_LOGIN when the market is not known before. Without AHledger, says once in chat that
	Haggler needs it; prices then come from the own scans, with low confidence. When AHledger
	is set to another market than the one the player is on, Haggler keeps its own (its scans
	are of this auction house), asks AHledger for that one and says so once in chat.
]]
local _, ns = ...

-- Helpers live at the bottom of the file; declared here so they stay local.
local newMarketKeyResolver, provideCapabilities, announcePriceSource, sendTableLoaded, noteMarketMismatch

-- The confidence settings, then the own sales count's.
local PRICING_SETTINGS = ns.Rules.confidenceSettings()
for _, setting in ipairs(ns.Sales.settings()) do
	PRICING_SETTINGS[#PRICING_SETTINGS + 1] = setting
end

local pricing = ns.host.AddModule({
	key = 'pricing',
	label = 'Pricing',
	category = 'core',
	canDisable = false,
	settings = PRICING_SETTINGS,
	onEnable = function(module)
		local wow = ns.wow
		local priceSource = ns.PriceData.newAHledgerSource(function()
			return wow:AHledgerAPI()
		end)
		ns.prices = ns.PriceService.new({
			now = function()
				return wow:Now()
			end,
			store = ns.store,
			priceSource = priceSource,
			marketKey = newMarketKeyResolver(wow),
			itemInfo = function(itemId)
				return wow:ItemInfo(itemId)
			end,
			cachedItemInfo = function(itemId)
				return wow:CachedItemInfo(itemId)
			end,
			requestItemData = function(itemId)
				wow:RequestItemData(itemId)
			end,
			nextFrame = function(fn)
				return wow:After(0, fn)
			end,
			confidence = function()
				return {
					staleMediumHours = module:Setting('staleMediumHours'),
					staleLowHours = module:Setting('staleLowHours'),
				}
			end,
			sales = function()
				return {
					minScans = module:Setting('ownSalesMinScans'),
					minHours = module:Setting('ownSalesMinHours'),
					trollSharePercent = module:Setting('trollSharePercent'),
					windowDays = module:Setting('salesWindowDays'),
				}
			end,
		})
		provideCapabilities(module, ns.prices)
		announcePriceSource(module, wow, ns.prices)
	end,
	onDisable = function()
		ns.wow:OffEvent('PLAYER_LOGIN', 'pricing')
		ns.prices = nil
	end,
})
ns.pricing = pricing

-- Helpers ---------------------------------------------------------------------------------

-- The market key is known once the client knows the player's faction; it is kept after that.
function newMarketKeyResolver(wow)
	local marketKey
	return function()
		if marketKey then
			return marketKey
		end
		local player = wow:Player()
		if player.faction ~= 'Alliance' and player.faction ~= 'Horde' then
			return nil
		end
		-- With no realm name, AHledger tells the ruleset from the GUID's server number, and answers
		-- the Normal market until the client knows it: a market taken then would stick.
		if ns.store and not ns.store:ResolveRealm(player) and not player.server then
			return nil
		end
		marketKey = ns.store and ns.store:MarketKeyFor(player, wow:AHledgerMarket()) or ns.Store.marketKeyFor(player)
		return marketKey
	end
end

function provideCapabilities(module, prices)
	module:Provide('price', 1, {
		get = function(itemId)
			return prices:Simple(itemId)
		end,
	})
	module:Provide('haggler.price', 1, {
		get = function(itemId, ruleId)
			return prices:Get(itemId, ruleId)
		end,
		rules = function()
			return prices:Rules()
		end,
		defaultRule = function()
			return prices:DefaultRule()
		end,
	})
end

function announcePriceSource(module, wow, prices)
	local status = prices:SourceStatus()
	if status.code == 'noPriceSource' then
		wow:Print(
			string.format(
				'needs AHledger for market prices (%s). Until then prices come from your own scans, with low confidence.',
				status.reason or 'unknown reason'
			)
		)
		return
	end
	if sendTableLoaded(module, prices) then
		noteMarketMismatch(wow, prices)
		return
	end
	wow:OnEvent('PLAYER_LOGIN', function()
		wow:OffEvent('PLAYER_LOGIN', 'pricing')
		sendTableLoaded(module, prices)
		noteMarketMismatch(wow, prices)
	end, 'pricing')
end

-- Called once, when the player's market is known: AHledger set to another market is said.
function noteMarketMismatch(wow, prices)
	local marketKey = prices:MarketKey()
	local sourceMarket = prices:SourceStatus().market
	if not marketKey or not sourceMarket or sourceMarket == marketKey then
		return
	end
	wow:Print(
		string.format('AHledger uses %s. Haggler prices %s, the auction house you are on.', sourceMarket, marketKey)
	)
end

-- Sends PRICE_TABLE_LOADED when the player's market has a table; returns whether it did.
function sendTableLoaded(module, prices)
	local priceTable = prices:PriceTable()
	if not priceTable then
		return false
	end
	module:Send('PRICE_TABLE_LOADED', { priceTable.market })
	return true
end
