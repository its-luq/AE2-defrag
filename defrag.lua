--[[
	AE2 Item disk defragmentation
	Original program by feryaz for OpenPeripheral in 2017
	Heavily modified and updated by luq for AdvancedPeripherals in 2026
	(the only thing that remains is the monitor functions)
]]--

local monitor = peripheral.wrap("top") 

zlocal monitorDelay = false -- 0.1

-- how long we should wait for a new drive to be inserted before trying again
local newDriveWait = 10

-- how many stacks of items to move at once
-- default is 9, the maximum number of slots on an interface
-- if using extended AE interfaces, this can be increased (probably, havent tested)
local stacks = 9

-- should we attempt to evenly distribute items across storage cells
-- example: if we have two storage cells, and exactly two items, 
-- with this setting on, the items will be put on seperate drives. 
-- with this setting off, they will be on the same drive 
local evenlyDistribute = true

-- how long to wait before performing any operation. 
-- default is 0.05s, or a single game tick
local tick = 0.05

local mainBridge = peripheral.wrap("me_bridge_0")
local bufferBridge = peripheral.wrap("me_bridge_1")
local insertionBridge = peripheral.wrap("me_bridge_2")

local bufferInterfaceId = "ae2:interface_1"
local insertionInterfaceId = "ae2:interface_2"

local insertionDrive = peripheral.wrap("ae2:drive_5")

-- all storage drives on the main network, along with their coordinates
local drives = {
	[{x = 3288, y = 66, z = -5005}] = peripheral.wrap("ae2:drive_6"),
	[{x = 3287, y = 66, z = -5005}}] = peripheral.wrap("ae2:drive_7"),
	[{x = 3288, y = 65, z = -5005}] = peripheral.wrap("ae2:drive_8"),
	[{x = 3287, y = 65, z = -5005}}] = peripheral.wrap("ae2:drive_9"),
}

----- 							END OF CONFIG                         -----

local w, h = monitor.getSize()
local finishedItems = {}
local finishedItemsCount = 0
local totalItems

function findDrive(position)
	for k, v in pairs(drives) do
		if k.x == position.x and k.y == position.y and k.z == position.z then
			return v
		end
	end
end

function itemKey(item)
	local key = item.name
	if item.nbt then
		key = key .. "/" .. item.nbt
	end
	return key
end

function itemFilter(item, count)
	return {
		name = item.name,
		count = count and (item.count > item.maxStackSize * stacks and item.maxStackSize * stacks or item.count),
		components = item.components,
		nbtHash = item.nbt
	}
end

function defragAll() 
	for _, item in pairs(mainBridge.getItems()) do
		if not totalItems then 
			totalItems = #mainBridge.getItems()
		end
		updateProgress()
		updateTask("Finding next item", colors.lightGray, 0)
		local key = itemKey(item)
		if not finishedItems[key] then
			defrag(item)
			finishedItems[key] = true
			finishedItemsCount = finishedItemsCount	+ 1
		end
	end
	updateProgress()
end

function moveToBuffer(item)
	local inBuffer = 0
	local count = item.count
	while item and count > 0 do
		updateTask("Exporting to buffer", colors.lightGray, 100/(count+inBuffer)*inBuffer)
		local filter = itemFilter(item, true)
		mainBridge.exportItem(bufferInterfaceId, filter)
		count = count - filter.count
		inBuffer = inBuffer + filter.count
		sleep(tick)
	end
	updateTask("Exporting to buffer", colors.lightGray, 100)
end

function importItem(item)
	local inCell = 0
	local count = item.count
	while item and count > 0 do
		updateTask("Importing to cell", colors.lightGray, 100/(count+inCell)*inCell)
		local filter = itemFilter(item, true)
		bufferBridge.exportItem(insertionInterfaceId, filter)
		count = count - filter.count
		inCell = inCell + filter.count
		sleep(tick)
	end
	updateTask("Importing to cell", colors.lightGray, 100)
end

function cellData(drive, slot, cell, cost)
	return {
		drive=findDrive(drive.position),
		maxBytes=cell.maxBytes,
		maxTypes=cell.maxTypes,
		usedBytes=cell.usedBytes,
		freeBytes=cell.maxBytes - cell.usedBytes,
		freeAfterInsertion = (cell.maxBytes - cell.usedBytes) - cost,
		cost = cost,
		slot = slot,
	}
end

function removeLowestCost(candiates)
	local bestCell
	for _, candiate in pairs(candiates) do
		if bestCell == nil 
			or candiate.cost < bestCell.cost 
			or (candiate.cost == bestCell.cost 
				and evenlyDistribute
				and candiate.freeAfterInsertion > bestCell.freeAfterInsertion) then 
			bestCell = candiate
		end
	end
	if bestCell then candiates[bestCell.cost] = nil end

	return bestCell
end

function findBestCell(count, exclude) 
	-- go over all cells, and for the ones that can store this many items,
	-- save them as a candiate for holding this item 
	-- since larger drives also require more bytes to store an additional type
	-- the smallest capacity drive capable of storing this item will have the
	-- lowest cost 
	local candiates = {}
	if not exclude then exclude = {} end
	local totalCells = #mainBridge.getCells()
	local cellCount = 0
	for _, drive in pairs(mainBridge.getDrives()) do
		for slot, cell in pairs(drive.cells) do
			cellCount = cellCount + 1
			local cost = math.ceil(count/8) + cell.bytesPerType
			local data = cellData(drive, slot, cell, cost)
			updateTask("Finding best cell", colors.lightGray, 100 * (cellCount/totalCells))
			if cost <= data.freeBytes and exclude[data] == nil then 
				candiates[#candiates + 1] = data
			end
		end
	end
	return candiates
end

function moveCellToInsertion(cell)
	cell.drive.pushItems(peripheral.getName(insertionDrive), cell.slot)
end

function returnCell(cell)
	cell.drive.pullItems(peripheral.getName(insertionDrive), 1, 1, cell.slot)
end

function verifyCell(cell)
	if not cell then return false end

	local types = #insertionBridge.getItems()
	return types < cell.maxTypes
end

function itemCountToCellSize(count)
	local bytes = math.ceil(count / 8)
	if bytes > 65536 then
		return "256k"
	elseif bytes > 16384 then 
		return "64k"
	elseif bytes > 4096 then 
		return "16k"
	else 
		return "1k"
	end 
end

function returnCellAndPrintError(cell, count) 
	if cell then
		returnCell(cell)
		sleep(tick)
	end
	print("No cell found capable of holding " .. count .. " items. Please add in a new cell. Trying again in " .. newDriveWait .. "s.")
	updateTask("Insert >=" .. itemCountToCellSize(count) .. " cell", colors.red, 0)
	sleep(newDriveWait)
end

function tryCells(count)
	local exclude = {}
	local candiates = findBestCell(count, exclude)
	local cell
	while not cell do
		cell = removeLowestCost(candiates)
		if cell then
			updateTask("Moving cell to insertion", colors.lightGray, 50)
			moveCellToInsertion(cell)
			sleep(tick)
			updateTask("Verifying cell", colors.lightGray, 50)
		end

		if not cell or not verifyCell(cell) then
			if cell then exclude[cell] = true end
			cell = nil
			returnCellAndPrintError(cell, count)
			candiates = findBestCell(count, exclude)
		end
		
	end
	return cell
end

function defrag(item)
	drawText(2, 8, colors.white, "Current Item:" .. item.name)
	moveToBuffer(item)
	local cell = tryCells(item.count)
	importItem(item)
	updateTask("Returning cell", colors.lightGray, 50)
	returnCell(cell)
	updateTask("Returning cell", colors.lightGray, 100)
end


function drawText(x, y, text, text_color, bg_color)
  monitor.setBackgroundColor(bg_color)
  monitor.setTextColor(text_color)
  monitor.setCursorPos(x,y)
  monitor.write(text)
end
 
function drawLine(x, y, length, color)
    monitor.setBackgroundColor(color)
    monitor.setCursorPos(x,y)
    monitor.write(string.rep(" ", length))
end

function clearLine(...)
	local arg = {...}
    for _,y in ipairs(arg) do
	    monitor.setCursorPos(1,y)
		monitor.clearLine()
	end
end

function updateTask(msg, color, percent)
	percent = math.floor(percent)
	monitor.setBackgroundColor(colors.black)
	clearLine(6,7)
	
	drawText(2, 6, "Task", colors.white, colors.black)
	
	drawText(math.floor(w - string.len(percent.."%")), 6, percent.."%", colors.white, colors.black)

	drawText(2, 7, msg, color, colors.black)
	

	if monitorDelay then
		sleep(monitorDelay)
	end
end

function updateProgress()
	monitor.setBackgroundColor(colors.black)
	monitor.clear()
	drawText(2, 2, "Progress ", colors.white, colors.black)
	local percent = math.floor(100/totalItems*finishedItemsCount)
	local percentString = percent.."%"
	drawText(math.floor(w - string.len(percentString)), 2, percentString, colors.white, colors.black)

	drawText(2, 3, finishedItemsCount.."/"..totalItems, colors.lightGray, colors.black)
	
	local barLength = w-2
	local barBreak = math.ceil(barLength/100*percent)
	drawLine(2, 4, barBreak, colors.green)
	drawLine(2+barBreak, 4, w-barBreak-2, colors.gray)
end

defragAll()
