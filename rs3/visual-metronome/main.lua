-- Visual Metronome
--
-- Shows an on-screen indicator that changes on every game tick (0.6s), so the
-- player can see the tick rhythm. Two display modes:
--   box:     a square that alternates between two colours, with the tick number
--   circles: a row of circles, one per tick in the cycle; the current tick's
--            circle is lit
-- The indicator can be dragged to move it. Settings are stored in PersistentDB.
-- No data leaves the plugin.

local EVENT_ID = "visual-metronome"

-- ServerLogic fires per processed server packet, not strictly per tick.
-- Ignore a second fire within this many logic ticks (50 per second).
local MIN_LOGIC_TICKS_BETWEEN = 15

local MAX_TICKS = 8
local MIN_SIZE = 25
local MAX_SIZE = 100

local CIRCLE_COLOUR = 0x2060FFFF
local UNLIT_FILL = 0xFFFFFFFF

local DEFAULTS = {
    shown = true,
    locked = false,
    circles = false,
    tickCount = 2,
    size = 50,
    positionX = 200,
    positionY = 200,
    colour1 = 0xFF0000FF,
    colour2 = 0x00FF00FF,
}

local KEYS = {
    shown = "bool", locked = "bool", circles = "bool",
    tickCount = "int", size = "int", positionX = "int", positionY = "int",
    colour1 = "int", colour2 = "int",
}

local settings = {}

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function loadSettings()
    for key, kind in pairs(KEYS) do
        local value
        if kind == "bool" then value = PersistentDB:GetBool(key) else value = PersistentDB:GetInt(key) end
        if value == nil then value = DEFAULTS[key] end
        settings[key] = value
    end
    settings.tickCount = clamp(settings.tickCount, 1, MAX_TICKS)
    settings.size = clamp(settings.size, MIN_SIZE, MAX_SIZE)
end

local function save(key, value)
    settings[key] = value
    if KEYS[key] == "bool" then PersistentDB:SetBool(key, value) else PersistentDB:SetInt(key, value) end
end

-- Tick state -----------------------------------------------------------------

local logicTick = 0
local lastServerTick = -1000
local tickInCycle = 0   -- 0 .. tickCount-1
local colourIndex = 1

-- UI -------------------------------------------------------------------------

local gameArea   -- the game area component everything is attached to
local box        -- container for the indicator
local dragLayer  -- invisible click area used to drag the box
local rect       -- box mode: the coloured square
local label      -- box mode: the tick number
local fills, rings, nums = {}, {}, {}   -- circles mode: one of each per tick
local dragging, grabX, grabY = false, 0, 0
local dragLayerStretching = false   -- true until one frame after the press

local function destroyUI()
    if box then box:Destroy() end
    if dragLayer then dragLayer:Destroy() end
    gameArea, box, dragLayer, rect, label = nil, nil, nil, nil, nil
    dragging = false
    fills, rings, nums = {}, {}, {}
end

-- Circles mode lays out one circle per tick in the cycle.
local function circleGap()
    return math.max(2, settings.size // 4)
end

local function boxDims()
    if not settings.circles then return settings.size, settings.size end
    local count = settings.tickCount
    return count * settings.size + (count - 1) * circleGap(), settings.size
end

-- Largest bold font that fits the circle.
local function circleFont()
    if settings.size >= 36 then return id.Font.MUSEO_SANS_19PT_BOLD end
    if settings.size >= 26 then return id.Font.MUSEO_SANS_15PT_BOLD end
    return id.Font.MUSEO_SANS_13PT_BOLD
end

local function currentColour()
    return colourIndex == 1 and settings.colour1 or settings.colour2
end

local function refresh()
    if not box then return end
    box.hidden = not settings.shown
    dragLayer.hidden = not settings.shown
    dragLayer.clickthrough = settings.locked
    rect.hidden = settings.circles
    if settings.circles then
        -- Lit: solid circle colour. Unlit: unlit fill inside a circle-colour ring.
        -- Circles are white anti-aliased PNGs tinted through rgba.
        local pitch = settings.size + circleGap()
        for i = 1, MAX_TICKS do
            local used = i <= settings.tickCount
            local lit = i - 1 == tickInCycle
            fills[i].hidden = not used
            rings[i].hidden = not used or lit
            nums[i].hidden = not used
            if used then
                nums[i]:SetPos((i - 1) * pitch, 0)
                nums[i]:SetSize(settings.size, settings.size)
                nums[i].font = circleFont()
                nums[i].rgba = lit and 0xFFFFFFFF or CIRCLE_COLOUR
                fills[i]:SetPos((i - 1) * pitch, 0)
                fills[i]:SetSize(settings.size, settings.size)
                fills[i].rgba = lit and CIRCLE_COLOUR or UNLIT_FILL
                rings[i]:SetPos((i - 1) * pitch, 0)
                rings[i]:SetSize(settings.size, settings.size)
                rings[i].rgba = CIRCLE_COLOUR
            end
        end
        label.hidden = true
    else
        for i = 1, MAX_TICKS do
            fills[i].hidden = true
            rings[i].hidden = true
            nums[i].hidden = true
        end
        rect.rgba = currentColour()
        label.hidden = false
        label.font = circleFont()
        label.content = tostring(tickInCycle + 1)
    end
end

-- Keep the drag layer over the box when no drag is in progress.
local function fitDragLayerToBox()
    local width, height = boxDims()
    dragLayer:SetPos(settings.positionX, settings.positionY)
    dragLayer:SetSize(width, height)
end

local function placeBox()
    if not box then return end
    local width, height = boxDims()
    settings.positionX = clamp(settings.positionX, 0, math.max(0, gameArea.width - width))
    settings.positionY = clamp(settings.positionY, 0, math.max(0, gameArea.height - height))
    box:SetPos(settings.positionX, settings.positionY)
    box:SetSize(width, height)
    if not dragging then fitDragLayerToBox() end
end

-- Dragging ---------------------------------------------------------------------
-- The drag layer is an invisible click area that normally sits over the box.
-- On press it stretches over the whole game area, so a fast mouse move can't
-- leave it. Its hook coordinates are then game-area coordinates, and the box
-- goes to the cursor minus the point where it was grabbed.
-- Hold events in the same frame as the press still use box-relative
-- coordinates, so they are ignored until the next frame.

local function onClick(_, clickX, clickY)
    if settings.locked then return false end
    dragging = true
    dragLayerStretching = true
    grabX, grabY = clickX, clickY
    dragLayer:SetPos(0, 0)
    dragLayer:SetSize(0, 0, 1.0, 1.0)
    return false
end

local function onHold(_, cursorX, cursorY)
    if not dragging or dragLayerStretching then return false end
    settings.positionX = cursorX - grabX
    settings.positionY = cursorY - grabY
    placeBox()
    return false
end

local function onRelease()
    if not dragging then return false end
    dragging = false
    fitDragLayerToBox()
    save("positionX", settings.positionX)
    save("positionY", settings.positionY)
    return false
end

local function ensureMounted()
    local area = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    if area == nil then
        destroyUI()
        return false
    end
    if area ~= gameArea then
        destroyUI()
        gameArea = area
    end
    if box then return true end

    box = ui.Layer.new(gameArea)
    box.clickthrough = true

    rect = ui.Rectangle.new(box)
    rect:SetSize(0, 0, 1.0, 1.0)
    rect.fill = true
    rect.clickthrough = true

    for i = 1, MAX_TICKS do
        fills[i] = ui.Sprite.new(box)
        fills[i].sprite = Plugin.resources.circle_fill
        fills[i].clickthrough = true
        rings[i] = ui.Sprite.new(box)
        rings[i].sprite = Plugin.resources.circle_ring
        rings[i].clickthrough = true
        nums[i] = ui.Text.new(box)
        nums[i].content = tostring(i)
        nums[i]:AlignTo(ui.AlignMode.CENTRE)
        nums[i].clickthrough = true
    end

    label = ui.Text.new(box)
    label:SetSize(0, 0, 1.0, 1.0)
    label.font = id.Font.MUSEO_SANS_15PT_BOLD
    label.rgba = 0xFFFFFFFF
    label.isShadowed = true
    label:AlignTo(ui.AlignMode.CENTRE)
    label.clickthrough = true

    dragLayer = ui.Layer.new(gameArea)
    dragLayer:Subscribe(ui.Hook.ONCLICK, onClick)
    dragLayer:Subscribe(ui.Hook.ONHOLD, onHold)
    dragLayer:Subscribe(ui.Hook.ONRELEASE, onRelease)
    dragLayer:Subscribe(ui.Hook.ONDRAGCOMPLETE, onRelease)

    placeBox()
    refresh()
    return true
end

-- Ticks ----------------------------------------------------------------------

local function onServerTick()
    if logicTick - lastServerTick < MIN_LOGIC_TICKS_BETWEEN then return end
    lastServerTick = logicTick
    tickInCycle = (tickInCycle + 1) % settings.tickCount
    colourIndex = colourIndex == 1 and 2 or 1
    refresh()
end

-- Settings panel -------------------------------------------------------------

local settingsView

local function destroySettings()
    if settingsView then settingsView:Destroy() end
    settingsView = nil
end

local function mountSettings(parent)
    destroySettings()
    settingsView = prettyui.SimpleView.new(parent, {
        width = 0, height = 0, widthAnchor = 1, heightAnchor = 1,
        layout = { startY = 10, paddingLeft = 12, paddingRight = 12, rowGap = 8 },
    })

    settingsView:AddCheckboxButton({
        { text = "Show metronome", value = "shown", selected = settings.shown },
        { text = "Lock position (click-through)", value = "locked", selected = settings.locked },
        { text = "Show as a row of circles", value = "circles", selected = settings.circles },
    }, {
        onChange = function(_, _, key, selected)
            save(key, selected == true)
            placeBox()
            refresh()
        end,
    })

    local countText = settingsView:AddText({ text = "", width = 344, height = 28, maxLines = 1 })
    local function updateCountText()
        countText.content = "Ticks in cycle: " .. settings.tickCount
    end
    updateCountText()
    settingsView:AddSlider({
        min = 1, max = MAX_TICKS, step = 1, value = settings.tickCount,
        onChange = function(_, value)
            local newCount = clamp(math.floor(value + 0.5), 1, MAX_TICKS)
            if newCount == settings.tickCount then return end
            save("tickCount", newCount)
            tickInCycle = 0
            updateCountText()
            placeBox()
            refresh()
        end,
    })

    local sizeText = settingsView:AddText({ text = "", width = 344, height = 28, maxLines = 1 })
    local function updateSizeText()
        sizeText.content = "Size: " .. settings.size
    end
    updateSizeText()
    settingsView:AddSlider({
        min = MIN_SIZE, max = MAX_SIZE, step = 5, value = settings.size,
        onChange = function(_, value)
            local newSize = clamp(math.floor(value + 0.5), MIN_SIZE, MAX_SIZE)
            if newSize == settings.size then return end
            save("size", newSize)
            updateSizeText()
            placeBox()
            refresh()
        end,
    })

    local pickers = {
        { key = "colour1", text = "Box: color 1" },
        { key = "colour2", text = "Box: color 2" },
    }
    for _, picker in ipairs(pickers) do
        local key = picker.key
        settingsView:AddText({ text = picker.text, width = 296, height = 32, maxLines = 1 })
        settingsView:AddColourPicker({
            inline = true, width = 40, height = 32,
            value = settings[key], alphaSlider = true,
            windowTitle = picker.text,
            onChange = function(_, colour)
                save(key, colour)
                refresh()
            end,
        })
    end
end

-- Lifecycle ------------------------------------------------------------------

loadSettings()

Event.Logic.Subscribe(EVENT_ID, function(event) logicTick = event.logicTick end)
Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
-- The game area can be rebuilt (e.g. after loading), so re-check each frame.
Event.Draw.Subscribe(EVENT_ID, function()
    ensureMounted()
    dragLayerStretching = false
end)
Event.SettingsLayerReady.Subscribe(EVENT_ID, function(event) mountSettings(event.component) end)
Event.GameStateChanged.Subscribe(EVENT_ID, function(event)
    if event.newState ~= GameState.GAME then
        destroySettings()
        destroyUI()
    end
end)

function PluginShutdown()
    Event.Logic.Unsubscribe(EVENT_ID)
    Event.ServerLogic.Unsubscribe(EVENT_ID)
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.SettingsLayerReady.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    destroySettings()
    destroyUI()
end
