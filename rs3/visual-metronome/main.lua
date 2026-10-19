-- Visual Metronome: an on-screen box that changes colour on game ticks.

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
    x = 200,
    y = 200,
    colour1 = 0xFF0000FF,
    colour2 = 0x00FF00FF,
}

local KEYS = {
    shown = "bool", locked = "bool", circles = "bool",
    tickCount = "int", size = "int", x = "int", y = "int",
    colour1 = "int", colour2 = "int",
}

local S = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function loadSettings()
    for k, kind in pairs(KEYS) do
        local v
        if kind == "bool" then v = PersistentDB:GetBool(k) else v = PersistentDB:GetInt(k) end
        if v == nil then v = DEFAULTS[k] end
        S[k] = v
    end
    S.tickCount = clamp(S.tickCount, 1, MAX_TICKS)
    S.size = clamp(S.size, MIN_SIZE, MAX_SIZE)
end

local function save(k, v)
    S[k] = v
    if KEYS[k] == "bool" then PersistentDB:SetBool(k, v) else PersistentDB:SetInt(k, v) end
end

-- Tick state -----------------------------------------------------------------

local logicTick = 0
local lastServerTick = -1000
local tickInCycle = 0   -- 0 .. tickCount-1
local colourIndex = 1

-- UI -------------------------------------------------------------------------

local gameArea, box, rect, label, hit
local fills, rings, nums = {}, {}, {}
local drag = nil

local function destroyUI()
    if box then box:Destroy() end
    if hit then hit:Destroy() end
    gameArea, box, rect, label, hit, drag = nil, nil, nil, nil, nil, nil
    fills, rings, nums = {}, {}, {}
end

-- Circles mode lays out one circle per tick in the cycle.
local function circleGap()
    return math.max(2, S.size // 4)
end

local function boxDims()
    if not S.circles then return S.size, S.size end
    local n = S.tickCount
    return n * S.size + (n - 1) * circleGap(), S.size
end

-- Largest bold font that fits the circle.
local function circleFont()
    if S.size >= 36 then return id.Font.MUSEO_SANS_19PT_BOLD end
    if S.size >= 26 then return id.Font.MUSEO_SANS_15PT_BOLD end
    return id.Font.MUSEO_SANS_13PT_BOLD
end

local function currentColour()
    return colourIndex == 1 and S.colour1 or S.colour2
end

local function refresh()
    if not box then return end
    box.hidden = not S.shown
    hit.hidden = not S.shown
    hit.clickthrough = S.locked
    rect.hidden = S.circles
    if S.circles then
        -- Lit: solid circle colour. Unlit: unlit fill inside a circle-colour ring.
        -- Circles are white anti-aliased PNGs tinted through rgba.
        local pitch = S.size + circleGap()
        for i = 1, MAX_TICKS do
            local used = i <= S.tickCount
            local lit = i - 1 == tickInCycle
            fills[i].hidden = not used
            rings[i].hidden = not used or lit
            nums[i].hidden = not used
            if used then
                nums[i]:SetPos((i - 1) * pitch, 0)
                nums[i]:SetSize(S.size, S.size)
                nums[i].font = circleFont()
                nums[i].rgba = lit and 0xFFFFFFFF or CIRCLE_COLOUR
                fills[i]:SetPos((i - 1) * pitch, 0)
                fills[i]:SetSize(S.size, S.size)
                fills[i].rgba = lit and CIRCLE_COLOUR or UNLIT_FILL
                rings[i]:SetPos((i - 1) * pitch, 0)
                rings[i]:SetSize(S.size, S.size)
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

local function placeBox()
    if not box then return end
    local w, h = boxDims()
    S.x = clamp(S.x, 0, math.max(0, gameArea.width - w))
    S.y = clamp(S.y, 0, math.max(0, gameArea.height - h))
    box:SetPos(S.x, S.y)
    box:SetSize(w, h)
    if not drag then
        hit:SetPos(S.x, S.y)
        hit:SetSize(w, h)
    end
end

-- Raw mouse is in window pixels; hook coordinates are interface units.
-- Derive the ratio from the click itself, falling back to the interface scale.
local function interfaceScale()
    local o = game and game.options and game.options.InterfaceScale
    local pct = o and tonumber(o.setting) or 100
    if pct <= 0 then pct = 100 end
    return pct / 100
end

local function measureScale(raw, ix, iy)
    local c = {}
    if math.abs(ix) >= 32 then c[#c + 1] = raw.x / ix end
    if math.abs(iy) >= 32 then c[#c + 1] = raw.y / iy end
    if #c == 2 and math.abs(c[1] - c[2]) <= (c[1] + c[2]) / 2 * 0.1 then
        return (c[1] + c[2]) / 2
    elseif #c == 1 and c[1] >= 0.5 and c[1] <= 4 then
        return c[1]
    end
    return interfaceScale()
end

local function onClick(_, x, y)
    if S.locked then return false end
    local raw = Mouse.GetPosition()
    if raw == nil then return false end
    local g = hit.xyGlobal
    drag = {
        scale = measureScale(raw, g.x + x, g.y + y),
        grabX = x,
        grabY = y,
        originX = gameArea.xyGlobal.x,
        originY = gameArea.xyGlobal.y,
    }
    -- Expand the hit layer so the drag keeps receiving hold events
    -- when the cursor outruns the box.
    hit:SetPos(0, 0)
    hit:SetSize(0, 0, 1.0, 1.0)
    hit:MoveToFront()
    return false
end

local function onHold()
    if not drag then return false end
    local raw = Mouse.GetPosition()
    if raw == nil then return false end
    S.x = math.floor(raw.x / drag.scale - drag.originX - drag.grabX + 0.5)
    S.y = math.floor(raw.y / drag.scale - drag.originY - drag.grabY + 0.5)
    placeBox()
    return false
end

local function onRelease()
    if not drag then return false end
    drag = nil
    placeBox()
    save("x", S.x)
    save("y", S.y)
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

    hit = ui.Layer.new(gameArea)
    hit:Subscribe(ui.Hook.ONCLICK, onClick)
    hit:Subscribe(ui.Hook.ONHOLD, onHold)
    hit:Subscribe(ui.Hook.ONRELEASE, onRelease)
    hit:Subscribe(ui.Hook.ONDRAGCOMPLETE, onRelease)

    placeBox()
    refresh()
    return true
end

-- Ticks ----------------------------------------------------------------------

local function onServerTick()
    if logicTick - lastServerTick < MIN_LOGIC_TICKS_BETWEEN then return end
    lastServerTick = logicTick
    tickInCycle = (tickInCycle + 1) % S.tickCount
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
        { text = "Show metronome", value = "shown", selected = S.shown },
        { text = "Lock position (click-through)", value = "locked", selected = S.locked },
        { text = "Show as a row of circles", value = "circles", selected = S.circles },
    }, {
        onChange = function(_, _, key, selected)
            save(key, selected == true)
            placeBox()
            refresh()
        end,
    })

    local countText = settingsView:AddText({ text = "", width = 344, height = 28, maxLines = 1 })
    local function updateCountText()
        countText.content = "Ticks in cycle: " .. S.tickCount
    end
    updateCountText()
    settingsView:AddSlider({
        min = 1, max = MAX_TICKS, step = 1, value = S.tickCount,
        onChange = function(_, value)
            local n = clamp(math.floor(value + 0.5), 1, MAX_TICKS)
            if n == S.tickCount then return end
            save("tickCount", n)
            tickInCycle = 0
            updateCountText()
            placeBox()
            refresh()
        end,
    })

    local sizeText = settingsView:AddText({ text = "", width = 344, height = 28, maxLines = 1 })
    local function updateSizeText()
        sizeText.content = "Size: " .. S.size
    end
    updateSizeText()
    settingsView:AddSlider({
        min = MIN_SIZE, max = MAX_SIZE, step = 5, value = S.size,
        onChange = function(_, value)
            local n = clamp(math.floor(value + 0.5), MIN_SIZE, MAX_SIZE)
            if n == S.size then return end
            save("size", n)
            updateSizeText()
            placeBox()
            refresh()
        end,
    })

    local pickers = {
        { key = "colour1", text = "Box: color 1" },
        { key = "colour2", text = "Box: color 2" },
    }
    for _, p in ipairs(pickers) do
        local key = p.key
        settingsView:AddText({ text = p.text, width = 296, height = 32, maxLines = 1 })
        settingsView:AddColourPicker({
            inline = true, width = 40, height = 32,
            value = S[key], alphaSlider = true,
            windowTitle = p.text,
            onChange = function(_, colour)
                save(key, colour)
                refresh()
            end,
        })
    end
end

-- Lifecycle ------------------------------------------------------------------

loadSettings()

Event.Logic.Subscribe(EVENT_ID, function(e) logicTick = e.logicTick end)
Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
Event.Draw.Subscribe(EVENT_ID, function()
    if ensureMounted() and drag then onHold() end
end)
Event.SettingsLayerReady.Subscribe(EVENT_ID, function(e) mountSettings(e.component) end)
Event.GameStateChanged.Subscribe(EVENT_ID, function(e)
    if e.newState ~= GameState.GAME then
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
