local MapReader = require("mapreader")

local Party = {}

local PARTY_SIZE = 5

local THEMES = {
    { lastFloor = 11, name = "Frozen" },
    { lastFloor = 17, name = "Abandoned 1" },
    { lastFloor = 29, name = "Furnished" },
    { lastFloor = 35, name = "Abandoned 2" },
    { lastFloor = 47, name = "Occult" },
    { lastFloor = 60, name = "Warped" },
}

function Party.getMembers()
    local members = {}
    local cells = MapReader.getPlayerCells()
    for slot = 1, PARTY_SIZE do
        local name = var.VarClient["RAND_PARTY_MEM" .. slot .. "_NAME"].value
        if name ~= "" then
            members[#members + 1] = { slot = slot, name = name, cell = cells[slot] }
        end
    end
    return members
end

function Party.getFloorNumber()
    local floor = var.VarClient.RAND_PARTY_FLOOR.value
    return floor > 0 and floor or nil
end

function Party.getTheme()
    local floor = Party.getFloorNumber()
    if floor == nil then return nil end

    for _, theme in ipairs(THEMES) do
        if floor <= theme.lastFloor then return theme.name end
    end
    return nil
end

function Party.getComplexity()
    local complexity = var.VarClient.RAND_PARTY_COMPLEXITY.value
    return complexity > 0 and complexity or nil
end

return Party
