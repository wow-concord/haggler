--[[
	gen-vendor-seed: writes Data/VendorSeed.lua, the base buy prices Haggler ships for items a
	vendor sells, from WoW: Forever's own item table and one or more "sold by a vendor" lists.

	Prices come only from Forever's ItemSparse DB2 (BuyPrice for VendorStackCount units), as
	wago.tools exports it for product wowf. The lists only say which items a vendor sells; no
	price is taken from them:
	  --lpt      LibPeriodicTable-3.1-Tradeskill.lua (LGPL-2.1), set Tradeskill.Mat.BySource.Vendor
	  --cmangos  a CMaNGOS classic-db SQL dump (GPL-3.0), tables npc_vendor and npc_vendor_template;
	             an item every row of which has a maxcount is marked limited
	  --ids      a plain file of item ids, one per line ('#' starts a comment)
	An item is kept when a list names it and ItemSparse gives it a BuyPrice above 0.

	The approach (ItemSparse BuyPrice joined with a vendor list) follows CraftWise's
	tools/gen_vendor.py and SkillUp Forever; this is a fresh implementation, no code is copied.

	  curl -L -o ItemSparse.csv 'https://wago.tools/db2/ItemSparse/csv?product=wowf'
	  luajit tools/gen-vendor-seed.lua --itemsparse ItemSparse.csv --build 1.60.1.71037 \
	    --lpt LibPeriodicTable-3.1-Tradeskill.lua --cmangos ClassicDB.sql --out Data/VendorSeed.lua

	The build is the one in the file name wago.tools sends (ItemSparse.<build>.csv). Loaded with
	dofile, the file returns its functions for tests and runs nothing.
]]

local Gen = {}

local VENDOR_SET = 'Tradeskill.Mat.BySource.Vendor'
local VENDOR_TABLES = { npc_vendor = true, npc_vendor_template = true }
-- npc_vendor columns: entry, item, maxcount, ...
local ITEM_COLUMN, MAXCOUNT_COLUMN = 2, 3

-- Helpers live at the bottom of the file; declared here so they stay local.
local readFile, parseArgs, isWholePositive, splitSqlTuple, sortedKeys

--- Parses CSV text (RFC 4180: quoted fields, doubled quotes, line breaks inside quotes).
--- @param text string
--- @return table rows, each a list of field strings
function Gen.parseCsv(text)
	local rows, row, field = {}, {}, {}
	local index, length, isQuoted = 1, #text, false
	while index <= length do
		local char = text:sub(index, index)
		if isQuoted then
			if char == '"' and text:sub(index + 1, index + 1) == '"' then
				field[#field + 1] = '"'
				index = index + 1
			elseif char == '"' then
				isQuoted = false
			else
				field[#field + 1] = char
			end
		elseif char == '"' then
			isQuoted = true
		elseif char == ',' then
			row[#row + 1] = table.concat(field)
			field = {}
		elseif char == '\n' or char == '\r' then
			if char == '\r' and text:sub(index + 1, index + 1) == '\n' then
				index = index + 1
			end
			row[#row + 1] = table.concat(field)
			rows[#rows + 1] = row
			row, field = {}, {}
		else
			-- Copy a run of plain characters at once; char by char is slow on a 5 MB file.
			local runEnd = text:find('[",\r\n]', index) or (length + 1)
			field[#field + 1] = text:sub(index, runEnd - 1)
			index = runEnd - 1
		end
		index = index + 1
	end
	if #field > 0 or #row > 0 then
		row[#row + 1] = table.concat(field)
		rows[#rows + 1] = row
	end
	return rows
end

--- The buy price and vendor stack of every item in an ItemSparse CSV.
--- @param text string the CSV
--- @return table { [itemId] = { price, stack } } price in copper for stack units
function Gen.readItemSparse(text)
	local rows = Gen.parseCsv(text)
	local header = rows[1]
	if not header then
		error('ItemSparse: the file is empty')
	end
	local columns = {}
	for index, name in ipairs(header) do
		columns[name] = index
	end
	for _, name in ipairs({ 'ID', 'BuyPrice', 'VendorStackCount' }) do
		if not columns[name] then
			error('ItemSparse: no ' .. name .. ' column')
		end
	end
	local items = {}
	for rowIndex = 2, #rows do
		local row = rows[rowIndex]
		local itemId = tonumber(row[columns.ID])
		local price = tonumber(row[columns.BuyPrice])
		local stack = tonumber(row[columns.VendorStackCount])
		if isWholePositive(itemId) and isWholePositive(price) then
			items[itemId] = { price = price, stack = isWholePositive(stack) and stack or 1 }
		end
	end
	return items
end

--- Item ids of LibPeriodicTable's vendor set.
--- @param text string LibPeriodicTable-3.1-Tradeskill.lua
--- @return table { [itemId] = true }
function Gen.readPeriodicTable(text)
	local list = text:match('%["' .. VENDOR_SET:gsub('%.', '%%.') .. '"%]%s*=%s*"([^"]*)"')
	if not list then
		error('LibPeriodicTable: no ' .. VENDOR_SET .. ' set')
	end
	local ids = {}
	for entry in list:gmatch('[^,]+') do
		-- An entry may carry a value after a colon (itemId:value); only the id counts.
		local itemId = tonumber(entry:match('^%s*(%d+)'))
		if isWholePositive(itemId) then
			ids[itemId] = true
		end
	end
	return ids
end

--- Item ids every vendor row of a CMaNGOS dump names, and whether each is only ever limited.
--- @param text string SQL with INSERT INTO `npc_vendor` / `npc_vendor_template` VALUES (...)
--- @return table { [itemId] = { isLimited } }
function Gen.readCmangosVendors(text)
	local items = {}
	for tableName, values in text:gmatch('INSERT INTO `([%w_]+)` VALUES%s*(.-);\n') do
		if VENDOR_TABLES[tableName] then
			for tuple in values:gmatch('%((.-)%)[,;]?') do
				local fields = splitSqlTuple(tuple)
				local itemId = tonumber(fields[ITEM_COLUMN])
				local maxCount = tonumber(fields[MAXCOUNT_COLUMN]) or 0
				if isWholePositive(itemId) then
					local item = items[itemId] or { isLimited = true }
					item.isLimited = item.isLimited and maxCount > 0
					items[itemId] = item
				end
			end
		end
	end
	return items
end

--- Item ids of a plain list.
--- @param text string one id per line; '#' starts a comment
--- @return table { [itemId] = true }
function Gen.readIdList(text)
	local ids = {}
	for line in (text .. '\n'):gmatch('([^\n]*)\n') do
		local itemId = tonumber((line:gsub('#.*', ''):match('^%s*(%d+)%s*$')))
		if isWholePositive(itemId) then
			ids[itemId] = true
		end
	end
	return ids
end

--- Joins the prices with the vendor lists.
--- @param prices table Gen.readItemSparse
--- @param lists table { { [itemId] = true | { isLimited } }... }
--- @return table { [itemId] = { price, stack, isLimited } }
function Gen.buildSeed(prices, lists)
	local seed = {}
	-- Per item: nil while no list knew about its stock, else whether every list that knew said limited.
	local knownLimits = {}
	for _, list in ipairs(lists) do
		for itemId, info in pairs(list) do
			local price = prices[itemId]
			if price then
				-- A plain id list knows nothing about stock, so it never clears another list's flag.
				if type(info) == 'table' then
					knownLimits[itemId] = knownLimits[itemId] ~= false and info.isLimited == true
				end
				seed[itemId] = {
					price = price.price,
					stack = price.stack,
					isLimited = knownLimits[itemId] == true,
				}
			end
		end
	end
	return seed
end

--- The Lua source of Data/VendorSeed.lua.
--- @param seed table Gen.buildSeed
--- @param meta table { build, date, sources = { string... } }
--- @return string
function Gen.render(seed, meta)
	if type(meta.build) ~= 'string' or meta.build == '' then
		error('render: a build is required')
	end
	local lines = {
		'--[[',
		'\tData/VendorSeed.lua: generated by tools/gen-vendor-seed.lua; never edit by hand.',
		'\tBase vendor buy prices (what a merchant charges, before any reputation discount) for',
		"\titems a vendor sells, from WoW: Forever's ItemSparse (BuyPrice for VendorStackCount units).",
		'',
		'\t  items[itemId] = copper for one unit, or { copper, units } when sold in a stack',
		'\t  limited[itemId] = true when every vendor list that knows says the stock is limited',
		'',
		'\tBuild ' .. meta.build .. ', generated ' .. (meta.date or '?') .. '.',
		'\tVendor lists: ' .. (#(meta.sources or {}) > 0 and table.concat(meta.sources, ', ') or 'none') .. '.',
		'\tRegenerate: see the header of tools/gen-vendor-seed.lua.',
		']]',
		'local _, ns = ...',
		'',
		'ns.VendorSeed = {',
		string.format("\tbuild = '%s',", meta.build),
		string.format("\tgeneratedAt = '%s',", meta.date or ''),
		'\titems = {',
	}
	local ids = sortedKeys(seed)
	local limited = {}
	for _, itemId in ipairs(ids) do
		local entry = seed[itemId]
		if entry.stack > 1 then
			lines[#lines + 1] = string.format('\t\t[%d] = { %d, %d },', itemId, entry.price, entry.stack)
		else
			lines[#lines + 1] = string.format('\t\t[%d] = %d,', itemId, entry.price)
		end
		if entry.isLimited then
			limited[#limited + 1] = itemId
		end
	end
	lines[#lines + 1] = '\t},'
	lines[#lines + 1] = '\tlimited = {'
	for _, itemId in ipairs(limited) do
		lines[#lines + 1] = string.format('\t\t[%d] = true,', itemId)
	end
	lines[#lines + 1] = '\t},'
	lines[#lines + 1] = '}'
	return table.concat(lines, '\n') .. '\n'
end

--- Runs the generator from the command line.
--- @param args table the script's arguments
function Gen.main(args)
	local options = parseArgs(args)
	if not options.itemsparse or not options.build then
		io.stderr:write('usage: luajit tools/gen-vendor-seed.lua --itemsparse FILE --build BUILD\n')
		io.stderr:write('       [--lpt FILE] [--cmangos FILE] [--ids FILE] [--date YYYY-MM-DD] [--out FILE]\n')
		os.exit(2)
	end
	local lists, sources = {}, {}
	if options.lpt then
		lists[#lists + 1] = Gen.readPeriodicTable(readFile(options.lpt))
		sources[#sources + 1] = 'LibPeriodicTable-3.1 ' .. VENDOR_SET .. ' (LGPL-2.1)'
	end
	if options.cmangos then
		lists[#lists + 1] = Gen.readCmangosVendors(readFile(options.cmangos))
		sources[#sources + 1] = 'CMaNGOS classic-db npc_vendor (GPL-3.0)'
	end
	if options.ids then
		lists[#lists + 1] = Gen.readIdList(readFile(options.ids))
		sources[#sources + 1] = options.ids
	end
	local seed = Gen.buildSeed(Gen.readItemSparse(readFile(options.itemsparse)), lists)
	local source =
		Gen.render(seed, { build = options.build, date = options.date or os.date('!%Y-%m-%d'), sources = sources })
	if options.out then
		local file = assert(io.open(options.out, 'wb'))
		file:write(source)
		file:close()
	else
		io.write(source)
	end
	io.stderr:write(string.format('%d items\n', #sortedKeys(seed)))
end

-- Helpers ---------------------------------------------------------------------------------

function readFile(path)
	local file = assert(io.open(path, 'rb'))
	local text = file:read('*a')
	file:close()
	return text
end

function parseArgs(args)
	local options = {}
	local index = 1
	while args[index] do
		local name = args[index]:match('^%-%-([%w]+)$')
		if not name or args[index + 1] == nil then
			error('bad argument ' .. tostring(args[index]))
		end
		options[name] = args[index + 1]
		index = index + 2
	end
	return options
end

function isWholePositive(value)
	return type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0
end

-- Fields of one SQL values tuple; quoted strings may hold commas and escaped quotes.
function splitSqlTuple(tuple)
	local fields, field, isQuoted, index = {}, {}, false, 1
	while index <= #tuple do
		local char = tuple:sub(index, index)
		if isQuoted and char == '\\' then
			field[#field + 1] = tuple:sub(index + 1, index + 1)
			index = index + 1
		elseif char == "'" then
			isQuoted = not isQuoted
		elseif char == ',' and not isQuoted then
			fields[#fields + 1] = table.concat(field)
			field = {}
		else
			field[#field + 1] = char
		end
		index = index + 1
	end
	fields[#fields + 1] = table.concat(field)
	return fields
end

function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

if type(arg) == 'table' and type(arg[0]) == 'string' and arg[0]:match('gen%-vendor%-seed%.lua$') then
	Gen.main(arg)
end

return Gen
