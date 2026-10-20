local Dungeon = require("dungeon")
local Party = require("party")
local MapReader = require("mapreader")
local Keys = require("keys")
local Enums = require("enums")

local DgUtils = {}

-- DgUtils.KeyName[room.blocker.value], e.g. [41] = "Purple triangle"
DgUtils.KeyName = Enums.KeyName

-- Bool
function DgUtils.InDungeon()
    return Dungeon.isInDungeon()
end

-- {{ slot = 1, name = "Name1", cell = 16 }, ...} cell is nil outside a dungeon
function DgUtils.GetParty()
    return Party.getMembers()
end

-- Int
function DgUtils.GetFloorNumber()
    return Party.getFloorNumber()
end

-- String
function DgUtils.GetTheme()
    return Party.getTheme()
end

-- 1 for low, 2 for high
function DgUtils.GetComplexity()
    return Party.getComplexity()
end

-- { 12, 15, ... } key numbers held, same values as room.blocker.value
function DgUtils.GetKeys()
    return Keys.getHeld()
end

-- { GATE_GREEN = cell, GATE_RED = cell, GATE_GROUP = cell }
function DgUtils.GetGatestones()
    return MapReader.getGatestoneCells()
end

-- { column, row } of the template room the cell was built from
function DgUtils.GetRoomTemplateAt(cell)
    return Dungeon.getRoomTemplate(cell)
end

-- "BASE", "BOSS", "NORMAL" or a PUZZLE_* name (enums.lua). Only trustworthy for cells in GetMap().rooms.
function DgUtils.GetRoomTypeAt(cell)
    return Dungeon.getRoomType(cell)
end

-- { seed, version, root, boss, rooms = { [cell] = room } }
-- room = { cell, col, row, opened, openedAt, exits, blocker = { type = "none" | "key" | "skill", value = key number | SkillType }, parent, north, east, south, west }
-- Tree rooted at the base. Directions link to neighbouring rooms (nil = no door). Shared live table, don't modify; version increments on any change.
function DgUtils.GetMap()
    return MapReader.getMap()
end

function PluginShutdown()
    Dungeon.endTracking()
    MapReader.endTracking()
end

Dungeon.beginTracking()
MapReader.beginTracking()

return DgUtils
