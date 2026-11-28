--[[
	Scan: the module that runs the scanner (Engine/Scan.lua) and saves its snapshots. It reads
	every full listing the client delivers, asks for one itself only when no scan is newer than
	15 minutes, and sends SCAN_READY(marketKey, { at, source, count }) once a snapshot is saved.
	Before saving, it compares the new scan with the market's last one, a slice per frame, and
	adds the units sold to the daily summaries (Engine/Sales.lua). Each save also sorts held
	units whose vendor price is now known, keeps the summaries to the sales window, and drops
	the scans of markets not scanned for keepMarketDays.
	Each saved scan also goes into the scan history (Engine/ScanArchive.lua, HagglerArchiveDB),
	built in the same follow-up and kept to its own size budget; the stale-market drop does not
	touch it. Nothing in it leaves the machine. A failing history never fails the scan: its
	problem shows in /hag scan status as a scan history problem.
	Switching it off stops listening and drops a read in progress.

	Every C_AuctionHouse.ReplicateItems call, by any add-on, is recorded through a post-hook and
	saved per market (market.replicateRequestedAt), so the shared 15-minute window holds across
	a /reload even when Haggler never read the listing. Haggler's own request passes through
	the same hook; the window takes the newest time, so it is never counted twice. The hook is
	installed once and keeps recording while the module is off.

	  /hag scan          asks for a scan now (under the same 15-minute rule)
	  /hag scan status   what the scanner is doing
]]
local _, ns = ...

-- Helpers live at the bottom of the file; declared here so they stay local.
local newScanner, newFollowUp, newSalesDiff, newArchiveBuilder, newCombinedFollowUp, saveSnapshot, archiveSnapshot
local runScanCommand, statusLines, archiveLine, playerMarket, vendorPriceOf
local tidySavedScans, installRequestHook, recordRequest, lastRequestedAt, savedRequestAt

-- A saved request time this far ahead of the clock is a clock that ran ahead (or a hand edit),
-- not a request: it is ignored, then replaced, instead of blocking requests until that time.
local REQUEST_CLOCK_TOLERANCE = 60

local scanner, scanModule
-- The newest scan history problem this session; nil when the last archive step worked.
local archiveState = { lastError = nil }
-- requestedAt: the newest request seen this session, kept while the market is not known yet.
local requests = { isHooked = false, requestedAt = nil }

-- What the Haggler window's Scan tab reads and asks; works while the module is off too.
ns.scanControl = {
	StatusLines = function()
		if not scanner then
			return { 'The scan module is off (/hag set scan.enabled on).' }
		end
		return statusLines(scanner:Status())
	end,
	-- The scanner's Status() table; nil while the module is off.
	Status = function()
		return scanner and scanner:Status() or nil
	end,
	RequestNow = function()
		if not scanner then
			return false, 'the scan module is off'
		end
		return scanner:RequestNow()
	end,
}

ns.host.AddModule({
	key = 'scan',
	label = 'Auction house scan',
	settings = {
		{
			key = 'autoScan',
			type = 'toggle',
			label = 'Ask for a full scan when the auction house opens and no scan is newer than 15 minutes',
			default = true,
		},
		{
			key = 'graceSeconds',
			type = 'slider',
			label = 'Seconds to wait after the auction house opens, so another add-on can scan first',
			default = ns.Scan.DEFAULT_GRACE_SECONDS,
			min = 0,
			max = 60,
		},
		{
			key = 'frameBudgetMs',
			type = 'slider',
			label = 'Milliseconds a frame may spend reading a scan',
			default = ns.Scan.DEFAULT_FRAME_BUDGET_MS,
			min = 1,
			max = 30,
		},
		{
			key = 'keepMarketDays',
			type = 'slider',
			label = 'Days to keep the scan of an auction house you have not scanned since',
			default = ns.ScanStore.DEFAULT_KEEP_MARKET_DAYS,
			min = 1,
			max = 365,
		},
		{
			key = 'archive',
			type = 'toggle',
			label = 'Keep a history of your own scans on this computer for a future Haggler price network. Nothing is sent.',
			default = true,
		},
		{
			key = 'archiveMaxMB',
			type = 'slider',
			label = 'Megabytes the scan history may use; the oldest scans go first',
			default = ns.ScanArchive.DEFAULT_MAX_MB,
			min = 4,
			max = 128,
		},
	},
	onEnable = function(module)
		installRequestHook()
		scanModule = module
		scanner = newScanner(module)
		scanner:Enable()
		module:AddCommand('scan', {
			usage = 'scan [status]',
			help = 'Ask for an auction house scan (at most one every 15 minutes), or show its status',
			run = function(args)
				return runScanCommand(args)
			end,
		})
	end,
	onDisable = function()
		if scanner then
			scanner:Disable()
			scanner = nil
		end
	end,
})

-- Helpers ---------------------------------------------------------------------------------

function newScanner(module)
	return ns.Scan.new({
		wow = ns.wow,
		lastSavedAt = function()
			local snapshot = ns.prices and ns.prices:Snapshot()
			return snapshot and snapshot.at
		end,
		lastRequestedAt = lastRequestedAt,
		newFollowUp = function(snapshot)
			return newFollowUp(module, snapshot)
		end,
		onSnapshot = function(snapshot, followUpResult)
			saveSnapshot(module, snapshot, followUpResult)
		end,
		settings = function()
			return {
				autoScan = module:Setting('autoScan'),
				graceSeconds = module:Setting('graceSeconds'),
				frameBudgetMs = module:Setting('frameBudgetMs'),
			}
		end,
		onError = function(where, err)
			ns.wow:Print(string.format('scan failed in %s: %s', where, tostring(err)))
		end,
	})
end

function installRequestHook()
	if requests.isHooked then
		return
	end
	requests.isHooked = ns.wow:HookReplicateRequests(recordRequest)
end

-- Any ReplicateItems call counts, Haggler's or another add-on's, even one the server refuses:
-- the client cannot tell, and the shared window is what the server enforces.
function recordRequest()
	local now = ns.wow:Now()
	requests.requestedAt = math.max(requests.requestedAt or now, now)
	local market = playerMarket()
	if market then
		local saved = savedRequestAt(market, now)
		market.replicateRequestedAt = saved and math.max(saved, now) or now
	end
end

function lastRequestedAt()
	local market = playerMarket()
	local saved = market and savedRequestAt(market, ns.wow:Now()) or nil
	if saved and requests.requestedAt then
		return math.max(saved, requests.requestedAt)
	end
	return saved or requests.requestedAt
end

function savedRequestAt(market, now)
	local saved = tonumber(market.replicateRequestedAt)
	if not saved or saved > now + REQUEST_CLOCK_TOLERANCE then
		return nil
	end
	return saved
end

-- The work run on a new snapshot before it is saved: the sales diff and the archive entry.
function newFollowUp(module, snapshot)
	local salesDiff = newSalesDiff(snapshot)
	local archiveBuilder = module:Setting('archive') and newArchiveBuilder(snapshot) or nil
	if not salesDiff and not archiveBuilder then
		return nil
	end
	return newCombinedFollowUp(salesDiff, archiveBuilder)
end

-- The comparison with the market's last scan, or nil when there is nothing to compare.
function newSalesDiff(snapshot)
	local market = playerMarket()
	if not market then
		return nil
	end
	return ns.Sales.newDiff(ns.ScanStore.latest(market), snapshot, vendorPriceOf)
end

function newArchiveBuilder(snapshot)
	if not ns.archiveDb then
		return nil
	end
	return ns.ScanArchive.newEntryBuilder(snapshot)
end

-- Runs the sales diff, then the archive builder, a slice at a time. A failing archive builder
-- costs only the archive entry (kept in archiveState), and the sales diff still counts. A
-- failing sales diff fails the whole follow-up, so it costs the archive entry too; the scanner
-- reports it and the scan is still saved.
function newCombinedFollowUp(salesDiff, archiveBuilder)
	local combined = { salesDiff = salesDiff, archiveBuilder = archiveBuilder }
	function combined:Step(shouldContinue)
		if self.salesDiff and not self.isSalesDone then
			self.isSalesDone = self.salesDiff:Step(shouldContinue)
			if not self.isSalesDone then
				return false
			end
		end
		if self.archiveBuilder then
			local ok, isDoneOrError = pcall(self.archiveBuilder.Step, self.archiveBuilder, shouldContinue)
			if not ok then
				self.archiveBuilder = nil
				self.archiveError = isDoneOrError
				return true
			end
			return isDoneOrError
		end
		return true
	end
	function combined:Result()
		local archiveEntry = nil
		if self.archiveBuilder then
			local ok, entryOrError = pcall(self.archiveBuilder.Result, self.archiveBuilder)
			archiveEntry = ok and entryOrError or nil
			self.archiveError = not ok and entryOrError or self.archiveError
		end
		return {
			salesDiff = self.salesDiff and self.salesDiff:Result() or nil,
			archiveEntry = archiveEntry,
			archiveError = self.archiveError,
		}
	end
	return combined
end

function saveSnapshot(module, snapshot, followUpResult)
	local salesDiff = followUpResult and followUpResult.salesDiff
	local market, marketKey = playerMarket()
	if not market then
		error('the market is not known yet (no faction)')
	end
	if not ns.ScanStore.save(market, snapshot) then
		error('the scan had no usable listings; the saved scan is kept')
	end
	-- Sales only from a scan the store kept: a refused scan's vanished units are not sales.
	if salesDiff then
		if type(market.scanDays) ~= 'table' then
			market.scanDays = {}
		end
		ns.Sales.record(market.scanDays, salesDiff)
	end
	tidySavedScans(module, market, snapshot.at)
	local archiveError = followUpResult and followUpResult.archiveError
	if archiveError ~= nil then
		archiveState.lastError = 'building the entry failed: ' .. tostring(archiveError)
	else
		local ok, err =
			pcall(archiveSnapshot, module, marketKey, followUpResult and followUpResult.archiveEntry, snapshot.at)
		archiveState.lastError = not ok and ('saving failed: ' .. tostring(err)) or nil
	end
	module:Send('SCAN_READY', marketKey, { at = snapshot.at, source = snapshot.source, count = snapshot.count })
end

-- Sorts held units, keeps the summaries to the window and drops stale markets' scans.
function tidySavedScans(module, market, now)
	ns.Sales.classifyPending(market.scanDays, vendorPriceOf)
	local salesSettings = ns.prices and ns.prices:SalesSettings()
	ns.Sales.prune(market.scanDays, now, salesSettings and salesSettings.windowDays)
	ns.ScanStore.pruneStaleMarkets(ns.store:Markets(), now, module:Setting('keepMarketDays'))
end

-- Adds the scan to the history and keeps the history to its budget.
function archiveSnapshot(module, marketKey, archiveEntry, now)
	if not ns.archiveDb or not archiveEntry or not module:Setting('archive') then
		return
	end
	ns.ScanArchive.record(ns.archiveDb, marketKey, archiveEntry)
	ns.ScanArchive.prune(ns.archiveDb, now, { maxBytes = module:Setting('archiveMaxMB') * ns.ScanArchive.BYTES_PER_MB })
end

function vendorPriceOf(itemId)
	return ns.prices and ns.prices:VendorPrice(itemId)
end

function playerMarket()
	local marketKey = ns.prices and ns.prices:MarketKey()
	if not marketKey then
		return nil
	end
	return ns.store:Market(marketKey), marketKey
end

function runScanCommand(args)
	if type(args) == 'table' and args[1] == 'status' then
		return statusLines(scanner:Status())
	end
	local isRequested, reason = scanner:RequestNow()
	if isRequested then
		return { 'Scan requested; the auction house sends the whole listing in a moment.' }
	end
	return { 'No scan requested: ' .. tostring(reason) .. '.' }
end

function statusLines(status)
	local lines = { 'Scan: ' .. status.state }
	local lastFullScan = status.lastFullScanAt and ns.TooltipLines.ago(ns.wow:Now() - status.lastFullScanAt)
	lines[#lines + 1] = 'Last full scan: ' .. (lastFullScan or 'no full scan saved yet')
	if status.nextAllowedIn and status.nextAllowedIn > 0 then
		lines[#lines + 1] = 'Next request allowed in ' .. ns.TooltipLines.age(status.nextAllowedIn)
	end
	if status.rowsTotal then
		lines[#lines + 1] = string.format('Read %d of %d listings', status.rowsRead or 0, status.rowsTotal)
	end
	if status.lastError then
		lines[#lines + 1] = 'Last problem: ' .. status.lastError
	end
	lines[#lines + 1] = archiveLine()
	if archiveState.lastError then
		lines[#lines + 1] = 'Scan history problem: ' .. archiveState.lastError
	end
	return lines
end

function archiveLine()
	if not ns.archiveDb then
		return 'Scan history: not kept (saved by a newer Haggler)'
	end
	local summary = ns.ScanArchive.summary(ns.archiveDb)
	local maxMB = scanModule and scanModule:Setting('archiveMaxMB')
	return string.format(
		'Scan history: %d scan%s, %.1f of %d MB',
		summary.scans,
		summary.scans == 1 and '' or 's',
		summary.bytes / ns.ScanArchive.BYTES_PER_MB,
		maxMB or ns.ScanArchive.DEFAULT_MAX_MB
	)
end
