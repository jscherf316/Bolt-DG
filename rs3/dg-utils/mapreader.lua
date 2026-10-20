local Enums = require("enums")

local MapReader = {}

local EVENT_ID = "dg-utils-mapreader"

local MAP_INTERFACE = 942
local MAP_CONTAINER = 8
local GRID_SIZE = 8
local ROOM_DYNAMIC_ID = 0
local OVERLAY_DYNAMIC_ID = 1
local PIP_CATEGORY_ID = 68
local GATESTONE_CATEGORY_IDS = { GATE_GREEN = 64, GATE_RED = 65, GATE_GROUP = 66 }
local CELL_PIXELS = 32

local NORTH, EAST, SOUTH, WEST = "north", "east", "south", "west"

local ROOM_SHAPE_BY_SPRITE = {
    -- unopened, plain door
    [2787] = { opened = false, entrance = SOUTH },
    [2788] = { opened = false, entrance = WEST },
    [2789] = { opened = false, entrance = NORTH },
    [2790] = { opened = false, entrance = EAST },
    -- unopened, key or skill door
    [35883] = { opened = false, entrance = SOUTH },
    [35884] = { opened = false, entrance = WEST },
    [35885] = { opened = false, entrance = NORTH },
    [35886] = { opened = false, entrance = EAST },
    -- opened
    [2791] = { opened = true, exits = { SOUTH } },
    [2792] = { opened = true, exits = { WEST } },
    [2793] = { opened = true, exits = { NORTH } },
    [2794] = { opened = true, exits = { EAST } },
    [2795] = { opened = true, exits = { SOUTH, WEST } },
    [2796] = { opened = true, exits = { NORTH, WEST } },
    [2797] = { opened = true, exits = { NORTH, EAST } },
    [2798] = { opened = true, exits = { EAST, SOUTH } },
    [2799] = { opened = true, exits = { NORTH, SOUTH, WEST } },
    [2800] = { opened = true, exits = { NORTH, EAST, WEST } },
    [2801] = { opened = true, exits = { NORTH, EAST, SOUTH } },
    [2802] = { opened = true, exits = { EAST, SOUTH, WEST } },
    [2803] = { opened = true, exits = { NORTH, EAST, SOUTH, WEST } },
    [2804] = { opened = true, exits = { NORTH, SOUTH } },
    [2805] = { opened = true, exits = { EAST, WEST } },
}

local BASE_SPRITE = 2831
local BOSS_SPRITE = 2833
local FIRST_KEY_OBJECT_ID = 18202

local map = { version = 0, seed = 0, rooms = {} }

local function cellInDirection(cell, direction)
    if direction == NORTH then return cell + GRID_SIZE end
    if direction == SOUTH then return cell - GRID_SIZE end
    if direction == EAST then return cell + 1 end
    if direction == WEST then return cell - 1 end
end

local function roomAt(cell)
    local room = map.rooms[cell]
    if room == nil then
        room = { cell = cell, col = cell % GRID_SIZE, row = cell // GRID_SIZE, opened = false }
        map.rooms[cell] = room
    end
    return room
end

local function readBlocker(overlay)
    local objectID = overlay and overlay.associatedObjectID or -1
    local sprite = overlay and overlay.spriteID or -1

    if objectID >= 0 then
        local keyNumber = (objectID - FIRST_KEY_OBJECT_ID) // 2 + 1
        return { type = "key", value = keyNumber }
    end

    if sprite >= 0 then
        return { type = "skill", value = Enums.SkillBySprite[sprite] }
    end

    return { type = "none" }
end

local function markUnopened(room, entrance, overlay)
    if room.blocker ~= nil then return end

    room.parent = roomAt(cellInDirection(room.cell, entrance))
    room[entrance] = room.parent
    room.blocker = readBlocker(overlay)
    map.version = map.version + 1
end

local function markOpened(room, exits, overlay, live)
    local overlaySprite = overlay and overlay.spriteID
    if overlaySprite == BASE_SPRITE then map.root = room end
    if overlaySprite == BOSS_SPRITE then map.boss = room end

    room.opened = true
    room.exits = exits
    if room == map.root then
        room.openedAt = 0
    elseif live then
        local floorTime = var.VarClient.RAND_PARTY_FLOOR_TIME
        room.openedAt = floorTime and floorTime.value
    end
    map.version = map.version + 1
end

local function readCell(container, cell, live)
    local component = container:GetChild(cell, ROOM_DYNAMIC_ID)
    local shape = component and ROOM_SHAPE_BY_SPRITE[component.spriteID]
    if shape == nil then return end

    local room = roomAt(cell)
    local overlay = container:GetChild(cell, OVERLAY_DYNAMIC_ID)
    if not shape.opened then
        markUnopened(room, shape.entrance, overlay)
    elseif not room.opened then
        markOpened(room, shape.exits, overlay, live)
        if not live then return end

        for _, direction in ipairs(shape.exits) do
            local nextCell = cellInDirection(cell, direction)
            readCell(container, nextCell, live)
            room[direction] = map.rooms[nextCell]
        end
    end
end

local function collectCell(component)
    local cell = component.categoryID
    if component.dynamicID == ROOM_DYNAMIC_ID and cell < 64 then
        readCell(component.parent, cell, false)
    end
    return false
end

local function scanAll(container)
    container:IterateDynamicComponents(collectCell)
    if map.root == nil then return end

    local queue, head = { map.root }, 1
    while head <= #queue do
        local room = queue[head]
        head = head + 1
        for _, direction in ipairs(room.exits) do
            local nextRoom = map.rooms[cellInDirection(room.cell, direction)]
            room[direction] = nextRoom
            local needsParent = nextRoom ~= nil and
                                nextRoom.parent == nil and
                                nextRoom ~= map.root
            if needsParent then
                nextRoom.parent = room
                queue[#queue + 1] = nextRoom
            end
        end
    end
end

local function scanUnopened(container)
    local cells = {}
    for cell, room in pairs(map.rooms) do
        if not room.opened then cells[#cells + 1] = cell end
    end

    for _, cell in ipairs(cells) do
        readCell(container, cell, true)
    end
end

local function resetFloor(seed)
    map.seed = seed
    map.version = map.version + 1
    map.root = nil
    map.boss = nil
    for cell in pairs(map.rooms) do map.rooms[cell] = nil end
end

local function readTick()
    local seed = var.VarPlayer.RAND_SEED.value
    if seed ~= map.seed then resetFloor(seed) end
    if seed == 0 then return end

    local container = ui.Interfaces:GetComponent(MAP_INTERFACE, MAP_CONTAINER)
    if container == nil then return end
    if map.root == nil then
        scanAll(container)
    else
        scanUnopened(container)
    end
end

local function mapContainerAndRoot()
    local container = ui.Interfaces:GetComponent(MAP_INTERFACE, MAP_CONTAINER)
    if container == nil or map.root == nil then return nil end
    return container, container:GetChild(map.root.cell, ROOM_DYNAMIC_ID)
end

local function cellAtPixel(rootSprite, x, y)
    local col = map.root.col + (x - rootSprite.x) // CELL_PIXELS
    local row = map.root.row - (y - rootSprite.y) // CELL_PIXELS
    if col < 0 or col >= GRID_SIZE or row < 0 or row >= GRID_SIZE then return nil end
    return row * GRID_SIZE + col
end

function MapReader.getMap()
    return map
end

function MapReader.getPlayerCells()
    local cells = {}
    local container, rootSprite = mapContainerAndRoot()
    if container == nil then return cells end

    local slot = 1
    local pip = container:GetChild(PIP_CATEGORY_ID, slot)
    while pip ~= nil do
        cells[slot] = cellAtPixel(rootSprite, pip.x, pip.y)
        slot = slot + 1
        pip = container:GetChild(PIP_CATEGORY_ID, slot)
    end
    return cells
end

function MapReader.getGatestoneCells()
    local cells = {}
    local container, rootSprite = mapContainerAndRoot()
    if container == nil then return cells end

    for name, categoryID in pairs(GATESTONE_CATEGORY_IDS) do
        local marker = container:GetChild(categoryID, OVERLAY_DYNAMIC_ID)
        if marker ~= nil then cells[name] = cellAtPixel(rootSprite, marker.x, marker.y) end
    end
    return cells
end

function MapReader.beginTracking()
    Event.ServerLogic.Subscribe(EVENT_ID, readTick)
end

function MapReader.endTracking()
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return MapReader
