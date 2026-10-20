local Party = require("party")
local Enums = require("enums")

local Dungeon = {}

local EVENT_ID = "dg-utils-dungeon"

local TILE_SIZE = 512
local ROOM_SIZE = 16
local MAP_SQUARE_SIZE = 64
local GRID_SIZE = 8

local BASE_TEMPLATE_COLUMN = 7
local BASE_TEMPLATE_ROW_MIN = 312
local BASE_TEMPLATE_ROW_MAX = 347
local NORMAL_TEMPLATE_ROW_MAX = 228
local THEME_PUZZLE_COLUMN = 11
local BASE_CHECK_TICKS = 10

local inDungeon = false
local baseChecksLeft = 0

local function floorArea()
    local bounds = World.GetMapSquareBounds()
    if bounds == nil then return nil end

    -- The bounds are one map square larger than the floor on each axis.
    return bounds.x * MAP_SQUARE_SIZE,
           bounds.y * MAP_SQUARE_SIZE,
           (bounds.width - 1) * MAP_SQUARE_SIZE // ROOM_SIZE,
           (bounds.height - 1) * MAP_SQUARE_SIZE // ROOM_SIZE
end

local function templateRoomAt(tileX, tileZ)
    local coord = CoordGrid.new(0, Vector3.new(tileX * TILE_SIZE, 0, tileZ * TILE_SIZE))
    local source = World.GetRegionSourceForCoordGrid(coord)
    if source == nil then return nil end
    return source.x // ROOM_SIZE, source.z // ROOM_SIZE
end

local function isBaseTemplate(column, row)
    return column == BASE_TEMPLATE_COLUMN and
           row >= BASE_TEMPLATE_ROW_MIN and
           row <= BASE_TEMPLATE_ROW_MAX
end

local function floorHasBase()
    local cornerX, cornerZ, cols, rows = floorArea()
    if cornerX == nil or cols > GRID_SIZE or rows > GRID_SIZE then return false end

    for floorCol = 0, cols - 1 do
        for floorRow = 0, rows - 1 do
            local column, row = templateRoomAt(cornerX + floorCol * ROOM_SIZE, cornerZ + floorRow * ROOM_SIZE)
            if column ~= nil and isBaseTemplate(column, row) then return true end
        end
    end
    return false
end

local function templateAt(cell)
    if not inDungeon then return nil end

    local cornerX, cornerZ, cols, rows = floorArea()
    local floorCol, floorRow = cell % GRID_SIZE, cell // GRID_SIZE
    if cornerX == nil or floorCol >= cols or floorRow >= rows then return nil end
    return templateRoomAt(cornerX + floorCol * ROOM_SIZE, cornerZ + floorRow * ROOM_SIZE)
end

local function refreshInDungeon()
    inDungeon = World.IsRegion() and floorHasBase()
end

local function onRegionCreated()
    baseChecksLeft = BASE_CHECK_TICKS
    refreshInDungeon()
end

local function onServerTick()
    if not World.IsRegion() then
        inDungeon = false
    elseif not inDungeon and baseChecksLeft > 0 then
        baseChecksLeft = baseChecksLeft - 1
        refreshInDungeon()
    end
end

function Dungeon.isInDungeon()
    return inDungeon
end

function Dungeon.getRoomTemplate(cell)
    local column, row = templateAt(cell)
    if column == nil then return nil end
    return { column = column, row = row }
end

function Dungeon.getRoomType(cell)
    local column, row = templateAt(cell)
    if column == nil then return nil end

    if isBaseTemplate(column, row) then return "BASE" end
    if row >= BASE_TEMPLATE_ROW_MIN then return "BOSS" end
    if row <= NORMAL_TEMPLATE_ROW_MAX then return "NORMAL" end
    if column == THEME_PUZZLE_COLUMN then return Enums.ThemePuzzle[Party.getTheme()] end
    return Enums.PuzzleByColumn[column]
end

function Dungeon.beginTracking()
    baseChecksLeft = BASE_CHECK_TICKS
    Event.RegionCreated.Subscribe(EVENT_ID, onRegionCreated)
    Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
    refreshInDungeon()
end

function Dungeon.endTracking()
    Event.RegionCreated.Unsubscribe(EVENT_ID)
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return Dungeon
