--[[
	Advice: what to do with an auction already listed when the market moves, from the spec's
	Watch step ("relist at X"), and which listings the "cancel untracked" action takes out.
	Pure: the caller reads the scan and the tracked auctions.

	  Advice.forAuction(auction, facts, options?) -> Advice
	  Advice.cheapestOther(levels, own) -> copper|nil   the cheapest price not only ours
	  Advice.untracked(owned, tracked) -> { owned entry }   active auctions that belong to no venture

	auction = { itemId, unitPrice, listed, deposit? }   a tracked auction (AuctionTracker)
	facts   = { cheapestOther?, rulePrice?, step, vendor?, breakEven?, scanAgeSeconds?,
	            confidence? }   confidence is the rule price's, when a floor or target used it
	options = { thresholdPercent? (default THRESHOLD_PERCENT), minGain? copper (default 0) }

	Advice = { action = 'relist'|'hold', direction? = 'down'|'up', price?, gain?, code, text,
	           confidence }

	Relisting means cancelling (the whole deposit is lost) and posting again, so it is advised
	only when it pays:
	  down  someone lists under us: relist one full step under the cheapest other listing, when
	        that is at least thresholdPercent under our price, not under the floor (break-even,
	        the vendor price, one step) and still nets more than the vendor would after the
	        lost deposit.
	  up    we are the cheapest and the market (or, with no other listing, the rule price) moved
	        up by at least thresholdPercent: relist one step under it when the extra sale beats
	        the lost deposit by more than minGain.
	Otherwise hold, with the reason. Every price is on the item's step: an undercut goes down a
	full step, never into copper on a silver item.
]]
local _, ns = ...

local Advice = {}
ns.Advice = Advice

Advice.THRESHOLD_PERCENT = 5

-- Helpers live at the bottom of the file; declared here so they stay local.
local hold, relist, confidenceOf, isFinitePositive, isFiniteNonNegative, percentApart, claimPendingPost

--- Advice for one listed auction.
--- @param auction table see the file header
--- @param facts table see the file header
--- @param options table|nil see the file header
--- @return table Advice
function Advice.forAuction(auction, facts, options)
	if type(facts) ~= 'table' then
		error('Advice.forAuction: needs facts', 2)
	end
	options = type(options) == 'table' and options or {}
	local confidence = confidenceOf(facts.scanAgeSeconds)
	if type(auction) ~= 'table' or not isFinitePositive(auction.unitPrice) or not isFinitePositive(auction.listed) then
		return hold('unreadable', 'the auction cannot be read', {
			level = 'low',
			reasons = { { code = 'badInput', level = 'low', text = 'the auction cannot be read' } },
		})
	end
	local Guardrail = ns.Guardrail
	local grid = { step = facts.step == ns.ItemMarket.SILVER_STEP and facts.step or ns.ItemMarket.COPPER_STEP }
	local threshold = isFiniteNonNegative(options.thresholdPercent) and options.thresholdPercent
		or Advice.THRESHOLD_PERCENT
	local minGain = isFiniteNonNegative(options.minGain) and options.minGain or 0
	local ours, listed = auction.unitPrice, auction.listed
	local deposit = isFiniteNonNegative(auction.deposit) and auction.deposit or 0
	local vendor = isFiniteNonNegative(facts.vendor) and facts.vendor or 0
	local floor = math.max(grid.step, vendor, isFiniteNonNegative(facts.breakEven) and facts.breakEven or 0)
	local cheapest = isFinitePositive(facts.cheapestOther) and facts.cheapestOther or nil
	if cheapest and cheapest < ours then
		local target = ns.ItemMarket.undercut(grid, cheapest, 1)
		if percentApart(ours, target) < threshold then
			return hold('closeEnough', string.format('within %d%% of the cheapest listing', threshold), confidence)
		end
		if target < floor then
			return hold('underFloor', 'the cheapest listing is under your floor; wait, or take it out', confidence)
		end
		local net = Guardrail.saleNet(target, listed) - deposit
		if net <= vendor * listed then
			return hold('costsMore', 'relisting loses the deposit; it would net no more than a vendor', confidence)
		end
		local advice = relist('down', target, net - Guardrail.saleNet(ours, listed), confidence)
		advice.net, advice.overVendor = net, net - vendor * listed
		return advice
	end
	if cheapest == ours then
		return hold('tied', 'another listing is at your price; you share the front of the queue', confidence)
	end
	local isRuleTarget = not cheapest and isFinitePositive(facts.rulePrice)
	if isRuleTarget then
		-- The rule price is the market here, so its confidence (and its source) count.
		confidence = confidenceOf(facts.scanAgeSeconds, facts.confidence)
	end
	local market = cheapest or (isRuleTarget and facts.rulePrice or nil)
	if not market then
		return hold('noMarket', 'no other listing in the last scan and no rule price', confidence)
	end
	local target = cheapest and ns.ItemMarket.undercut(grid, cheapest, 1) or ns.ItemMarket.snapPrice(grid, market)
	local advice
	if target <= ours or percentApart(target, ours) < threshold then
		advice = hold('cheapest', 'yours is the cheapest listing', confidence)
	else
		local gain = Guardrail.saleNet(target, listed) - Guardrail.saleNet(ours, listed) - deposit
		if gain <= minGain then
			advice = hold('costsMore', 'the market rose, but not by more than the deposit a relist loses', confidence)
		else
			advice = relist('up', target, gain, confidence)
			advice.net = Guardrail.saleNet(target, listed) - deposit
		end
	end
	advice.usesRulePrice = isRuleTarget or nil
	return advice
end

--- The cheapest price in the scan that is not only our own units.
--- @param levels table|nil { { price, qty }... } cheapest first
--- @param own table|nil { { unitPrice, listed }... } our listings of the item
--- @return number|nil copper
function Advice.cheapestOther(levels, own)
	local ownAt = {}
	for _, listing in ipairs(type(own) == 'table' and own or {}) do
		if isFinitePositive(listing.unitPrice) and isFinitePositive(listing.listed) then
			ownAt[listing.unitPrice] = (ownAt[listing.unitPrice] or 0) + listing.listed
		end
	end
	for _, level in ipairs(type(levels) == 'table' and levels or {}) do
		local isLevel = type(level) == 'table' and isFinitePositive(level.price) and isFinitePositive(level.qty)
		if isLevel and level.qty > (ownAt[level.price] or 0) then
			return level.price
		end
	end
	return nil
end

--- The owned auctions "cancel untracked" takes out: still on the auction house and not posted
--- from a venture. Sold ones (waiting for the mail) and unreadable ones are left alone. An owned
--- auction Haggler holds no record of yet is left alone when a pending venture post of the same
--- item and quantity can explain it (the server listed it before AUCTION_HOUSE_AUCTION_CREATED).
--- @param owned table|nil Wow:OwnedAuctions()
--- @param tracked table|nil { [auctionId] = Tracked } in every state: the clock may expire a
---   record whose auction is still listed
--- @param options table|nil { pendingVenturePosts = { { itemId, qty } }, skip = { [auctionId] = true } }
--- @return table { owned entry... }
function Advice.untracked(owned, tracked, options)
	tracked = type(tracked) == 'table' and tracked or {}
	options = type(options) == 'table' and options or {}
	local skip = type(options.skip) == 'table' and options.skip or {}
	local unclaimed = {}
	for _, post in ipairs(type(options.pendingVenturePosts) == 'table' and options.pendingVenturePosts or {}) do
		if type(post) == 'table' then
			unclaimed[#unclaimed + 1] = post
		end
	end
	local list = {}
	for _, entry in ipairs(type(owned) == 'table' and owned or {}) do
		local isActive = type(entry) == 'table' and isFinitePositive(entry.auctionId) and not entry.isSold
		local record = isActive and tracked[entry.auctionId] or nil
		local isVenture = type(record) == 'table' and record.ventureId ~= nil
		if isActive and not isVenture and not skip[entry.auctionId] then
			if record ~= nil or not claimPendingPost(unclaimed, entry) then
				list[#list + 1] = entry
			end
		end
	end
	return list
end

-- Helpers ---------------------------------------------------------------------------------

function hold(code, text, confidence)
	return { action = 'hold', code = code, text = text, confidence = confidence }
end

function relist(direction, price, gain, confidence)
	return {
		action = 'relist',
		direction = direction,
		price = price,
		gain = gain,
		code = direction == 'down' and 'undercut' or 'marketRose',
		text = direction == 'down' and 'listed under you: relist a step under the cheapest'
			or 'the market rose: relist higher',
		confidence = confidence,
	}
end

-- The scan's age, and the rule price's confidence when the rule price set the target.
function confidenceOf(scanAgeSeconds, ruleConfidence)
	local parts = { ns.ScanStore.scanConfidence(scanAgeSeconds) }
	if type(ruleConfidence) == 'table' then
		parts[#parts + 1] = ruleConfidence
	end
	return ns.Value.mergeConfidence(parts)
end

function isFinitePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge
end

function isFiniteNonNegative(value)
	return type(value) == 'number' and value >= 0 and value < math.huge
end

-- How far apart two prices are, in whole percent of the higher one.
function percentApart(high, low)
	return math.floor((high - low) * 100 / high)
end

-- Takes the first pending venture post that matches an owned entry; true when one did.
function claimPendingPost(unclaimed, entry)
	for index, post in ipairs(unclaimed) do
		if post.itemId == entry.itemId and post.qty == entry.qty then
			table.remove(unclaimed, index)
			return true
		end
	end
	return false
end
