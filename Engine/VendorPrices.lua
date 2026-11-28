--[[
	VendorPrices: what a vendor charges the player for an item. The player's own merchant reads
	(Engine/VendorStore.lua) beat the shipped seed (Data/VendorSeed.lua, Forever's ItemSparse
	base prices). Not the sell price: Wow:ItemInfo's vendorPrice is what a vendor pays.

	  prices:BuyPrice(itemId) -> BuyPrice | nil
	  prices:FullPrice(itemId) -> { stackPrice, stack } | nil   the seed's base price alone

	  BuyPrice = { price, stackPrice, stack, source = 'seen'|'seed', vendorCount,
	               cheapestVendor?, ageSeconds?, isLimited, isBasePrice, isVendorConfirmed? }

	price is copper for one unit (stackPrice / stack, so a fraction for items sold in stacks of
	many, like arrows). A vendor's base price (a read at or below
	VendorStore.BASE_PRICE_MAX_REACTION, kept beside later discounted reads) beats discounted
	prices from any vendor, so a read by an exalted character never becomes the price another
	character sees. Among base prices the cheapest vendor with unlimited stock wins, or the
	cheapest limited one when none is unlimited; at the same price an unlimited vendor goes
	first. When every seen price is discounted (or of unknown standing), the seed's base price
	comes back if it has the item (source 'seed'), else the discounted price with isBasePrice
	false. Consumers must check isBasePrice: false means the price may be below what a
	character without that standing pays.

	vendorCount says how many seen vendors sell it now, with a seed price too. isLimited is true
	only when no seen vendor that sells it now has unlimited stock (from the seed alone, the
	seed's flag). An offer that is gone or asks a currency or item beside copper is not a copper
	price and is left out. cheapestVendor = { npcId, name?, zone?, mapId?, faction?, reaction?,
	priceFromBase }, the vendor the price came from. reaction is the standing of that vendor's
	latest read. priceFromBase true means the price is the vendor's kept base price from an
	earlier read at or below BASE_PRICE_MAX_REACTION, not the latest read's, so a discounted
	reaction there never contradicts isBasePrice. ageSeconds is how long ago that price was read. isVendorConfirmed is true when Questie's item data lists a vendor, nil when
	it cannot say.
]]
local _, ns = ...

local VendorPrices = {}
ns.VendorPrices = VendorPrices

local Methods = {}
Methods.__index = Methods

-- Helpers live at the bottom of the file; declared here so they stay local.
local isWholePositive, isUsableOffer, cheapestOffer, isEveryLimited, seedEntry

--- @param deps table { db = fun(): table|nil, seed = table|nil, now = fun(): number,
---   isVendorSold = fun(itemId): boolean|nil }
--- @return table prices
function VendorPrices.new(deps)
	if type(deps) ~= 'table' or type(deps.db) ~= 'function' or type(deps.now) ~= 'function' then
		error('VendorPrices.new: db and now are required', 2)
	end
	return setmetatable({ deps = deps }, Methods)
end

--- The buy price of one unit of an item, or nil when no vendor is known to sell it.
--- @param itemId number
--- @return table|nil BuyPrice (see the header)
function Methods:BuyPrice(itemId)
	if not isWholePositive(itemId) then
		error('VendorPrices:BuyPrice: itemId must be a whole number', 2)
	end
	local deps = self.deps
	local usable = {}
	for _, offer in ipairs(ns.VendorStore.offers(deps.db(), itemId)) do
		if isUsableOffer(offer) then
			usable[#usable + 1] = offer
		end
	end
	local isVendorConfirmed = deps.isVendorSold and deps.isVendorSold(itemId) == true or nil
	local offer = cheapestOffer(usable)
	local stackPrice, stack = seedEntry(deps.seed, itemId)
	if offer and (offer.isBasePrice or not stackPrice) then
		return {
			price = offer.unitPrice,
			stackPrice = offer.price,
			stack = offer.stack,
			source = 'seen',
			vendorCount = #usable,
			cheapestVendor = {
				npcId = offer.npcId,
				name = offer.name,
				zone = offer.zone,
				mapId = offer.mapId,
				faction = offer.faction,
				reaction = offer.reaction,
				priceFromBase = offer.priceFromBase,
			},
			ageSeconds = math.max(0, deps.now() - offer.priceSeenAt),
			isLimited = isEveryLimited(usable),
			isBasePrice = offer.isBasePrice,
			isVendorConfirmed = isVendorConfirmed,
		}
	end
	if not stackPrice then
		return nil
	end
	local isLimited = type(deps.seed.limited) == 'table' and deps.seed.limited[itemId] == true
	if #usable > 0 then
		isLimited = isEveryLimited(usable)
	end
	return {
		price = stackPrice / stack,
		stackPrice = stackPrice,
		stack = stack,
		source = 'seed',
		vendorCount = #usable,
		isLimited = isLimited,
		isBasePrice = true,
		isVendorConfirmed = isVendorConfirmed,
	}
end

--- The seed's base price for an item, whatever the player has seen, or nil without a seed entry.
--- @param itemId number
--- @return table|nil { stackPrice, stack }
function Methods:FullPrice(itemId)
	if not isWholePositive(itemId) then
		error('VendorPrices:FullPrice: itemId must be a whole number', 2)
	end
	local stackPrice, stack = seedEntry(self.deps.seed, itemId)
	if not stackPrice then
		return nil
	end
	return { stackPrice = stackPrice, stack = stack }
end

-- Helpers ---------------------------------------------------------------------------------

function isWholePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

function isUsableOffer(offer)
	return offer.goneAt == nil and not offer.hasExtendedCost and offer.price > 0
end

-- Offers come cheapest first. Base-price reads go before discounted ones; within the chosen
-- group the first unlimited one wins, else the cheapest limited one.
function cheapestOffer(offers)
	local baseOffers, discountedOffers = {}, {}
	for _, offer in ipairs(offers) do
		local group = offer.isBasePrice and baseOffers or discountedOffers
		group[#group + 1] = offer
	end
	local preferred = #baseOffers > 0 and baseOffers or discountedOffers
	for _, offer in ipairs(preferred) do
		if not offer.isLimited then
			return offer
		end
	end
	return preferred[1]
end

function isEveryLimited(offers)
	for _, offer in ipairs(offers) do
		if not offer.isLimited then
			return false
		end
	end
	return true
end

-- A seed row: copper, or { copper, units }. Anything else reads as none.
function seedEntry(seed, itemId)
	local items = type(seed) == 'table' and type(seed.items) == 'table' and seed.items or nil
	local entry = items and items[itemId]
	if isWholePositive(entry) then
		return entry, 1
	end
	if type(entry) == 'table' and isWholePositive(entry[1]) and isWholePositive(entry[2]) then
		return entry[1], entry[2]
	end
	return nil
end

return VendorPrices
