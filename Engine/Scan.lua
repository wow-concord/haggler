--[[
	Scan: reads full auction house scans, Haggler's own or any other add-on's.

	The 15-minute rule: the server allows about one C_AuctionHouse.ReplicateItems per 15 minutes
	(AHledger's AUTO_SCAN_MIN_INTERVAL). The answer, REPLICATE_ITEM_LIST_UPDATE, reaches every
	add-on, so Haggler listens and reads whatever full listing arrives (AHledger, Auctionator,
	TSM) without asking. It asks itself only when:
	  - the auction house is open and was opened at least graceSeconds ago, so an add-on that
	    scans on open goes first;
	  - no full listing arrived, and no add-on asked (Haggler or another), in the last
	    MIN_INTERVAL seconds. The window is shared by every add-on on the client, so any
	    ReplicateItems call counts, even one whose listing Haggler never read (another add-on
	    scanned, then a /reload). The last saved snapshot and the last recorded request are both
	    saved, so a /reload or a relog does not reset the window;
	  - the server has not refused a request in the last MIN_INTERVAL seconds;
	  - auto scan is on.

	Reading: the listing (often 50,000 to 150,000 rows) is read in slices, one per frame, each
	within frameBudgetMs on the frame clock (or ROWS_PER_SLICE rows on a client without one), then
	packed into items the same way (ITEMS_PER_SLICE items a slice without a clock, and as many
	follow-up steps), so the client never hitches. A repeated REPLICATE_ITEM_LIST_UPDATE while a
	read runs is ignored: the client and other add-ons fire it
	again for the same listing, and restarting on each one never let a read finish. Each slice of
	rows checks NumReplicateItems instead: if it fell to 0 the listing was cleared and the read is
	dropped; if it changed, the read starts over on the new listing (from the first row, since a
	replaced listing does not keep its indexes, so reading only the tail would mix two listings).
	Once every row is read the snapshot is complete, so packing and comparing ignore the event.
	A listing replaced by one of exactly the same size is not noticed and would mix two
	listings; under the 15-minute throttle two answers inside one read are not expected.
	An empty listing is dropped at once: it never replaces the saved snapshot. When the auction house closes mid-read, the rest of the rows are read at once while
	the client still holds them (a short hitch, rather than losing the scan); if they are gone,
	the read is dropped. A partial listing is never saved.

	Scan never throws: event handlers and timer callbacks run under pcall, and a failure drops the
	read and is kept in Status().lastError and passed to onError.
]]
local _, ns = ...

local Scan = {}
ns.Scan = Scan

Scan.MIN_INTERVAL = 15 * 60
Scan.DEFAULT_GRACE_SECONDS = 8
Scan.DEFAULT_FRAME_BUDGET_MS = 6
Scan.ROWS_PER_SLICE = 2000
Scan.ITEMS_PER_SLICE = 500
-- How often the frame clock is read inside a slice.
Scan.CLOCK_CHECK_EVERY = 64
-- A requested listing that has not arrived after this is taken as lost.
Scan.NO_REPLY_SECONDS = 180
-- The same listing announced again this soon after it was saved is not read twice.
Scan.DUPLICATE_SECONDS = 60
-- A listing that keeps changing under the read is given up after this many restarts.
Scan.MAX_RESTARTS = 3
Scan.EVENT_OWNER = 'scan'
Scan.EVENTS = {
	'AUCTION_HOUSE_SHOW',
	'AUCTION_HOUSE_CLOSED',
	'REPLICATE_ITEM_LIST_UPDATE',
	'AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED',
}

local STATE_BY_PHASE = { rows = 'reading', items = 'packing', followUp = 'comparing' }

-- Helpers live at the bottom of the file; declared here so they stay local.
local newestOf, isRecent, settingOr

local ScannerMethods = {}
ScannerMethods.__index = ScannerMethods

--- A scanner. It does nothing until Enable.
--- @param options table {
---   wow,
---   lastSavedAt = fun(): number|nil   the newest saved snapshot's time for this market,
---   lastRequestedAt = fun(): number|nil  the newest ReplicateItems call by any add-on, saved,
---   onSnapshot = fun(snapshot, followUpResult)  a finished read,
---   newFollowUp = fun(snapshot): job|nil  work to run on the snapshot, a slice per frame,
---                                          before it is saved: job:Step(shouldContinue) ->
---                                          isDone, job:Result(),
---   settings = fun(): { autoScan, graceSeconds, frameBudgetMs }|nil,
---   onError = fun(where, err)|nil }
function Scan.new(options)
	if type(options) ~= 'table' or type(options.wow) ~= 'table' then
		error('Scan.new: options.wow is required', 2)
	end
	if type(options.onSnapshot) ~= 'function' then
		error('Scan.new: options.onSnapshot must be a function', 2)
	end
	return setmetatable({
		wow = options.wow,
		lastSavedAt = options.lastSavedAt,
		lastRequestedAt = options.lastRequestedAt,
		onSnapshot = options.onSnapshot,
		newFollowUp = options.newFollowUp,
		settings = options.settings,
		onError = options.onError,
		isEnabled = false,
		isOpen = false,
		openGeneration = 0,
		job = nil,
		jobGeneration = 0,
	}, ScannerMethods)
end

--- Starts listening to the auction house events.
function ScannerMethods:Enable()
	if self.isEnabled then
		return
	end
	self.isEnabled = true
	for _, event in ipairs(Scan.EVENTS) do
		self.wow:OnEvent(event, function(firedEvent, ...)
			self:HandleEvent(firedEvent, ...)
		end, Scan.EVENT_OWNER)
	end
end

--- Stops listening and drops any read in progress.
function ScannerMethods:Disable()
	if not self.isEnabled then
		return
	end
	self.isEnabled = false
	for _, event in ipairs(Scan.EVENTS) do
		self.wow:OffEvent(event, Scan.EVENT_OWNER)
	end
	self:DropJob('scanning switched off')
	self.isOpen = false
	self.awaitingReplySince = nil
	self.openGeneration = self.openGeneration + 1
end

--- Routes one game event; never throws.
function ScannerMethods:HandleEvent(event)
	self:Guard('event ' .. tostring(event), function()
		if event == 'AUCTION_HOUSE_SHOW' then
			self:OnOpen()
		elseif event == 'AUCTION_HOUSE_CLOSED' then
			self:OnClose()
		elseif event == 'REPLICATE_ITEM_LIST_UPDATE' then
			self:OnListing()
		elseif event == 'AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED' then
			self:OnRefused()
		end
	end)
end

--- Asks for a scan now, under the same 15-minute rule (for /hag scan).
--- @return boolean requested
--- @return string|nil reason when not
function ScannerMethods:RequestNow()
	return self:TryRequest(true)
end

--- What the scan is doing, for status lines and the Scan tab.
--- @return table { state, lastFullScanAt, nextAllowedIn, lastError, rowsRead, rowsTotal }
function ScannerMethods:Status()
	local job = self.job
	local state = 'closed'
	if job then
		state = STATE_BY_PHASE[job.phase]
	elseif self.awaitingReplySince then
		state = 'requested'
	elseif self.isOpen then
		state = 'open'
	end
	return {
		state = state,
		lastFullScanAt = self:LastFullScanAt(),
		nextAllowedIn = self:NextAllowedIn(),
		lastError = self.lastError,
		rowsRead = job and job.index or nil,
		rowsTotal = job and job.count or nil,
	}
end

--- Seconds until the 15-minute rule allows a request (0 when it does).
function ScannerMethods:NextAllowedIn()
	local now = self.wow:Now()
	local blockedSince =
		newestOf(self:LastFullScanAt(), self:ArrivalAt(), self.requestedAt, self.refusedAt, self:LastRequestAt())
	if not blockedSince then
		return 0
	end
	return math.max(0, blockedSince + Scan.MIN_INTERVAL - now)
end

--- The newest full scan: one read to the end this session, or the saved snapshot, never later
--- than now. Nil until one exists; a listing that arrived but was dropped does not count.
function ScannerMethods:LastFullScanAt()
	local savedAt = nil
	if self.lastSavedAt then
		local ok, value = pcall(self.lastSavedAt)
		savedAt = ok and type(value) == 'number' and value or nil
	end
	local newest = newestOf(self.lastSnapshotAt, savedAt)
	-- A time in the future (a clock that ran ahead when it was saved) counts as now, so it
	-- cannot block requests for days.
	return newest and math.min(newest, self.wow:Now()) or nil
end

--- The newest scan request recorded by any add-on (saved across reloads), never later than now.
function ScannerMethods:LastRequestAt()
	if not self.lastRequestedAt then
		return nil
	end
	local ok, value = pcall(self.lastRequestedAt)
	local requestedAt = ok and type(value) == 'number' and value or nil
	return requestedAt and math.min(requestedAt, self.wow:Now()) or nil
end

--- When the newest full listing arrived, read to the end or not, never later than now. It
--- counts for the 15-minute rule only: a listing that was dropped is not a full scan.
function ScannerMethods:ArrivalAt()
	return self.lastListingAt and math.min(self.lastListingAt, self.wow:Now()) or nil
end

-- Events ----------------------------------------------------------------------------------

function ScannerMethods:OnOpen()
	self.isOpen = true
	self.openGeneration = self.openGeneration + 1
	local generation = self.openGeneration
	local grace = settingOr(self, 'graceSeconds', Scan.DEFAULT_GRACE_SECONDS)
	self.wow:After(grace, function()
		self:Guard('grace timer', function()
			if self.isOpen and self.openGeneration == generation then
				self:TryRequest(false)
			end
		end)
	end)
end

function ScannerMethods:OnClose()
	self.isOpen = false
	self.openGeneration = self.openGeneration + 1
	self.awaitingReplySince = nil
	local job = self.job
	if job and job.phase == 'rows' then
		-- The client still holds the listing at this moment; read the rest now or lose it.
		self:ReadRows(job, function()
			return true
		end)
		if self.job and self.job.phase == 'rows' then
			self:DropJob('auction house closed before the listing was read')
		end
	end
end

function ScannerMethods:OnListing()
	local now = self.wow:Now()
	local wasRequested = self.awaitingReplySince ~= nil
	self.awaitingReplySince = nil
	if not self.isOpen then
		return
	end
	if self.job then
		-- A repeat of the event; ReadRows notices a listing that really changed or was cleared.
		return
	end
	if not wasRequested and isRecent(self.lastCompletedAt, now, Scan.DUPLICATE_SECONDS) then
		return
	end
	self:StartJob(wasRequested and 'own' or 'passive', now)
end

function ScannerMethods:OnRefused()
	if self.awaitingReplySince then
		self.refusedAt = self.wow:Now()
		self.awaitingReplySince = nil
		self.lastError = 'the server refused the scan request (15-minute limit)'
	end
end

-- Requests --------------------------------------------------------------------------------

-- Returns true when a request went out, else false and why.
function ScannerMethods:TryRequest(isManual)
	if not self.isOpen then
		return false, 'the auction house is closed'
	end
	if self.job or self.awaitingReplySince then
		return false, 'a scan is already running'
	end
	if not isManual and not settingOr(self, 'autoScan', true) then
		return false, 'auto scan is off'
	end
	local wait = self:NextAllowedIn()
	if wait > 0 then
		return false,
			string.format('the server allows one full scan per 15 minutes; next in %d min', math.ceil(wait / 60))
	end
	local isSent, reason = self.wow:RequestReplicate()
	if not isSent then
		return false, reason
	end
	local now = self.wow:Now()
	self.requestedAt = now
	self.awaitingReplySince = now
	self.wow:After(Scan.NO_REPLY_SECONDS, function()
		self:Guard('reply timer', function()
			if self.awaitingReplySince == now then
				self.awaitingReplySince = nil
				self.lastError = 'no reply to the scan request'
			end
		end)
	end)
	return true
end

-- Reading ---------------------------------------------------------------------------------

function ScannerMethods:StartJob(source, arrivedAt)
	local previous = self.job
	local restarts = previous and (previous.restarts + 1) or 0
	if restarts > Scan.MAX_RESTARTS then
		self:DropJob('the listing kept changing while it was read')
		return
	end
	self.lastListingAt = arrivedAt
	self.jobGeneration = self.jobGeneration + 1
	local count = self.wow:NumReplicateItems()
	if type(count) ~= 'number' or count <= 0 then
		-- An empty answer must never replace the saved snapshot; it still counts for the
		-- 15-minute rule (the request was answered).
		self.job = nil
		self.lastError = 'the listing was empty; nothing saved'
		return
	end
	self.job = {
		generation = self.jobGeneration,
		source = source,
		arrivedAt = arrivedAt,
		phase = 'rows',
		index = 0,
		count = count,
		builder = ns.ScanStore.newBuilder(),
		restarts = restarts,
	}
	self:ScheduleSlice(self.job)
end

function ScannerMethods:ScheduleSlice(job)
	local isScheduled = self.wow:After(0, function()
		self:Guard('scan slice', function()
			if self.job == job and job.generation == self.jobGeneration then
				self:RunSlice(job)
			end
		end)
	end)
	if not isScheduled then
		self:DropJob('no C_Timer on this client')
	end
end

function ScannerMethods:RunSlice(job)
	-- Without a clock, an item (packed, compared, archived) costs more than a row: fewer a slice.
	local shouldContinue = self:SliceBudget(job.phase == 'rows' and Scan.ROWS_PER_SLICE or Scan.ITEMS_PER_SLICE)
	if job.phase == 'rows' then
		self:ReadRows(job, shouldContinue)
	elseif job.phase == 'items' then
		self:PackItems(job, shouldContinue)
	else
		self:RunFollowUp(job, shouldContinue)
	end
	if self.job == job then
		self:ScheduleSlice(job)
	end
end

-- Reads rows while shouldContinue allows; moves the job to packing when every row is read.
function ScannerMethods:ReadRows(job, shouldContinue)
	local live = self.wow:NumReplicateItems()
	if live ~= job.count then
		if live <= 0 then
			self:DropJob('the listing was cleared before it was read')
		else
			-- A new listing: the scan is dated from now, when the read starts on it.
			self:StartJob(job.source, self.wow:Now())
		end
		return
	end
	local wow, builder = self.wow, job.builder
	local index, count = job.index, job.count
	while index < count and shouldContinue() do
		local itemId, stack, buyout, _, timeLeft = wow:ReplicateItem(index)
		builder:Add(itemId, stack, buyout, timeLeft)
		index = index + 1
	end
	job.index = index
	if index >= count then
		job.phase = 'items'
	end
end

function ScannerMethods:PackItems(job, shouldContinue)
	if not job.builder:Pack(shouldContinue) then
		return
	end
	local snapshot = job.builder:Snapshot(job.arrivedAt, job.source)
	job.builder = nil
	local followUp
	if self.newFollowUp then
		local ok, result = pcall(self.newFollowUp, snapshot)
		followUp = ok and result or nil
		if not ok then
			job.followUpError = result
		end
	end
	if followUp then
		job.phase, job.snapshot, job.followUp = 'followUp', snapshot, followUp
		return
	end
	self:CompleteJob(job, snapshot, nil)
end

-- A follow-up that fails costs only its own result: the scan is still saved.
function ScannerMethods:RunFollowUp(job, shouldContinue)
	local followUp = job.followUp
	local ok, isDoneOrError = pcall(followUp.Step, followUp, shouldContinue)
	if ok and not isDoneOrError then
		return
	end
	local result
	if ok then
		ok, result = pcall(followUp.Result, followUp)
	end
	if not ok then
		job.followUpError = result or isDoneOrError
		result = nil
	end
	self:CompleteJob(job, job.snapshot, result)
end

function ScannerMethods:CompleteJob(job, snapshot, followUpResult)
	self.job = nil
	self.lastCompletedAt = self.wow:Now()
	self.lastSnapshotAt = job.arrivedAt
	self.lastError = nil
	if job.followUpError ~= nil then
		self.lastError = 'scan follow-up failed: ' .. tostring(job.followUpError)
		if self.onError then
			pcall(self.onError, 'scan follow-up', job.followUpError)
		end
	end
	self:Guard('saving the scan', self.onSnapshot, snapshot, followUpResult)
end

-- A shouldContinue for one slice: the frame clock budget, or stepsWithoutClock calls without
-- a clock.
function ScannerMethods:SliceBudget(stepsWithoutClock)
	local wow = self.wow
	local startedMs = wow:ClockMs()
	local calls = 0
	if not startedMs then
		return function()
			calls = calls + 1
			return calls <= stepsWithoutClock
		end
	end
	local budgetMs = settingOr(self, 'frameBudgetMs', Scan.DEFAULT_FRAME_BUDGET_MS)
	return function()
		calls = calls + 1
		-- Always make progress: the first call of a slice passes.
		if calls == 1 or calls % Scan.CLOCK_CHECK_EVERY ~= 0 then
			return true
		end
		return (wow:ClockMs() or startedMs) - startedMs < budgetMs
	end
end

function ScannerMethods:DropJob(reason)
	if self.job then
		self.job = nil
		self.jobGeneration = self.jobGeneration + 1
		self.lastError = reason
	end
end

-- Runs fn under pcall; a failure drops the read and is reported, never raised.
function ScannerMethods:Guard(where, fn, ...)
	local ok, err = pcall(fn, ...)
	if ok then
		return
	end
	self:DropJob('scan failed: ' .. tostring(err))
	self.lastError = 'scan failed in ' .. where .. ': ' .. tostring(err)
	if self.onError then
		pcall(self.onError, where, err)
	end
end

-- Helpers ---------------------------------------------------------------------------------

function newestOf(...)
	local newest = nil
	for index = 1, select('#', ...) do
		local value = select(index, ...)
		if type(value) == 'number' and (newest == nil or value > newest) then
			newest = value
		end
	end
	return newest
end

function isRecent(at, now, seconds)
	return type(at) == 'number' and now - at < seconds
end

function settingOr(scanner, key, fallback)
	if not scanner.settings then
		return fallback
	end
	local ok, values = pcall(scanner.settings)
	if not ok or type(values) ~= 'table' or type(values[key]) ~= type(fallback) then
		return fallback
	end
	return values[key]
end

return Scan
