--[[
	Vendors: records what merchants charge (Engine/VendorStore.lua, in HagglerArchiveDB) each
	time a merchant window opens or its list changes, and answers vendor buy prices
	(Engine/VendorPrices.lua): the player's own reads first, the shipped seed (Data/VendorSeed.lua)
	under them. Reads wait one frame so a burst of MERCHANT_UPDATE costs one read. Nothing in
	the store leaves the machine. Other add-ons get the capability:

	  vendorPrices v1  buyPrice(itemId) -> BuyPrice | nil   (Engine/VendorPrices.lua)

	  /hag vendors   how many vendors and items are kept, and their size
]]
local _, ns = ...

local MODULE_KEY = 'vendors'
local EVENT_OWNER = 'vendors'
local MERCHANT_EVENTS = { 'MERCHANT_SHOW', 'MERCHANT_UPDATE' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local scheduleRead, readMerchant, statusLines

local state = { module = nil, isReadPending = false }

ns.host.AddModule({
	key = MODULE_KEY,
	label = 'Vendor prices',
	settings = {
		{
			key = 'record',
			type = 'toggle',
			label = 'Remember what merchants charge on this computer. Nothing is sent.',
			default = true,
		},
		{
			key = 'maxKB',
			type = 'slider',
			label = 'Kilobytes the merchant record may use. The vendors seen longest ago go first.',
			default = ns.VendorStore.DEFAULT_MAX_KB,
			min = 64,
			max = 4096,
		},
	},
	onEnable = function(module)
		state.module = module
		ns.vendorPrices = ns.VendorPrices.new({
			db = function()
				return ns.vendorDb
			end,
			seed = ns.VendorSeed,
			now = function()
				return ns.wow:Now()
			end,
			isVendorSold = function(itemId)
				return ns.wow:QuestieItemVendors(itemId)
			end,
		})
		for _, event in ipairs(MERCHANT_EVENTS) do
			ns.wow:OnEvent(event, scheduleRead, EVENT_OWNER)
		end
		module:Provide('vendorPrices', 1, {
			buyPrice = function(itemId)
				return ns.vendorPrices:BuyPrice(itemId)
			end,
		})
		module:AddCommand('vendors', {
			usage = 'vendors',
			help = 'Show how many vendors and items the merchant record keeps',
			run = function()
				return statusLines()
			end,
		})
	end,
	onDisable = function()
		for _, event in ipairs(MERCHANT_EVENTS) do
			ns.wow:OffEvent(event, EVENT_OWNER)
		end
		ns.vendorPrices = nil
		state.module = nil
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function scheduleRead()
	if state.isReadPending then
		return
	end
	state.isReadPending = true
	if not ns.wow:After(0, readMerchant) then
		readMerchant()
	end
end

function readMerchant()
	state.isReadPending = false
	local module = state.module
	if not module or not ns.vendorDb or not module:Setting('record') then
		return
	end
	local vendor = ns.wow:MerchantVendor()
	if not vendor then
		return
	end
	local read = ns.wow:MerchantSlots()
	local saved = ns.VendorStore.record(
		ns.vendorDb,
		{ vendor = vendor, slots = read.slots, isComplete = read.isComplete },
		ns.wow:Now()
	)
	if saved then
		ns.VendorStore.prune(ns.vendorDb, { maxBytes = module:Setting('maxKB') * ns.VendorStore.BYTES_PER_KB })
	end
end

function statusLines()
	if not ns.vendorDb then
		return { 'The merchant record is from a newer Haggler. It is kept as it is.' }
	end
	local summary = ns.VendorStore.summary(ns.vendorDb)
	local seedCount = 0
	for _ in pairs(ns.VendorSeed and ns.VendorSeed.items or {}) do
		seedCount = seedCount + 1
	end
	local maxKB = state.module and state.module:Setting('maxKB')
	return {
		string.format(
			'Merchant record: %d vendor%s, %d item%s, %.1f of %d KB',
			summary.vendors,
			summary.vendors == 1 and '' or 's',
			summary.items,
			summary.items == 1 and '' or 's',
			summary.bytes / ns.VendorStore.BYTES_PER_KB,
			maxKB or ns.VendorStore.DEFAULT_MAX_KB
		),
		string.format(
			'Seed: %d item%s from build %s',
			seedCount,
			seedCount == 1 and '' or 's',
			ns.VendorSeed and ns.VendorSeed.build or 'none'
		),
	}
end
