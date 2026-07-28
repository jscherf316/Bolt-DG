-- Settings panel + trigger button, merged from the standalone
-- bolt-control-panel plugin (2026-07-28).
--
-- SELF-CONTAINED: every row reads and writes THIS plugin's own settings via
-- SET, so the old cross-plugin machinery -- parsing config/plugins.json for
-- peer UUIDs and read-modify-writing ../<uuid>/settings.json from outside --
-- is gone entirely. The page (settings_panel.html) is fed the same state JSON
-- shape the old panel rendered, with a single plugin entry and uuid "self";
-- the tracker's own settings poll applies whatever the panel writes, exactly
-- as it did when the writer was a foreign plugin (SET.set persists to
-- settings.json, the poll re-reads it within ~30 frames).
return function (deps)
  local bolt = require("bolt")   -- module scope has no bolt global; every sibling module self-requires
  local SET = deps.SET
  local PANEL = {}
  SET.cpanel = PANEL

  -- Registry: every row the panel renders. Same schema as the old plugin's
  -- registry.lua: key / type / default / label / category ("dev" rows only
  -- show while Show Dev Tools is on) / group (collapsible sub-area), min /
  -- max / step for steppers, visible_when for dependent rows.
  local REGISTRY = {
    { key = "sync_enabled",         type = "bool",        default = false, label = "Party sync",         category = "normal" },
    -- Only shown while Party sync is on.
    { key = "sync_room",            type = "party",       default = "DGPARTY1", label = "Party code",    category = "normal",
      visible_when = "sync_enabled" },
    { key = "rooms_panel_scale",    type = "int_stepper", default = 100, min = 60, max = 200, step = 10,
      label = "Map size", category = "normal" },
    { key = "scan_range_tiles",     type = "int_stepper", default = 64, min = 32, max = 64, step = 16,
      label = "Scan range", category = "dev" },
    { key = "show_capture_zones",   type = "bool",        default = true,  label = "Show capture zones", category = "normal" },
    -- Puzzle utilities render as their OWN top-level card (section field), a
    -- sibling of the Settings card -- more solvers land here over time.
    { key = "rc_tiles_enabled",     type = "bool",        default = true,  label = "Runecraft Tiles", category = "normal", section = "Puzzles" },
    -- Line draw lives HERE now (2026-07-28) -- its standalone panel is gone.
    -- line_style is a custom row: opacity/thickness steppers with the colour
    -- swatch box to their right; it reads/writes line_color + line_thickness.
    { key = "line_enabled",         type = "bool",        default = true,  label = "Enabled",      category = "normal", group = "line draw" },
    { key = "line_path_mode",       type = "bool",        default = false, label = "Grid aligned", category = "normal", group = "line draw" },
    { key = "line_style",           type = "line_style",  default = false, label = "",             category = "normal", group = "line draw" },
    { key = "rooms_panel_visible",  type = "bool",        default = true,  label = "Rooms",         category = "normal", group = "panels" },
    { key = "keys_panel_visible",   type = "bool",        default = false, label = "Keys - Click headers to customize", category = "normal", group = "panels" },
    { key = "tracker_panel_visible", type = "bool",       default = false, label = "Image Tracker", category = "dev",    group = "panels" },
    { key = "res_panel_visible",    type = "bool",        default = false, label = "Resources",     category = "dev",    group = "panels" },
    { key = "icon_panel_visible",   type = "bool",        default = false, label = "Icons",         category = "dev",    group = "panels" },
  }

  -- ---- state JSON (same shape the page has always rendered) ----------------
  local function json_str(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return "\"" .. s .. "\""
  end
  local function json_bool(v) return v and "true" or "false" end

  local function row_visible(s)
    if not s.visible_when then return true end
    for _, cs in ipairs(REGISTRY) do
      if cs.key == s.visible_when then
        return SET.get(cs.key, cs.default) == true
      end
    end
    return true   -- controlling key not found: fail open, never hide silently
  end

  -- Registry rows carry an optional `section` (default "Settings"); each
  -- section renders as its own top-level card in the panel, so new areas
  -- ("Puzzles", ...) are one field away instead of a page change.
  local SECTIONS = { "Settings", "Puzzles" }

  local function build_state_json()
    local show_dev = SET.get("show_dev_tools", false) == true
    local cards = {}
    for _, section in ipairs(SECTIONS) do
      local rows = {}
      for _, s in ipairs(REGISTRY) do
        if (s.section or "Settings") == section and row_visible(s) then
          local val = SET.get(s.key, s.default)
          local r = { "{\"key\":" .. json_str(s.key) }
          r[#r + 1] = ",\"type\":" .. json_str(s.type)
          r[#r + 1] = ",\"label\":" .. json_str(s.label)
          r[#r + 1] = ",\"category\":" .. json_str(s.category or "normal")
          if s.group then r[#r + 1] = ",\"group\":" .. json_str(s.group) end
          if s.type == "line_style" then
            local c = SET.get("line_color", { 255, 70, 70, 255 })
            local th = tonumber(SET.get("line_thickness", 32)) or 32
            r[#r + 1] = string.format(
              ",\"value\":{\"r\":%d,\"g\":%d,\"b\":%d,\"a\":%d,\"thickness\":%d}",
              tonumber(c[1]) or 255, tonumber(c[2]) or 70,
              tonumber(c[3]) or 70, tonumber(c[4]) or 255, th)
          elseif s.type == "bool" then
            r[#r + 1] = ",\"value\":" .. json_bool(val == true)
          elseif s.type == "int" or s.type == "int_stepper" then
            r[#r + 1] = ",\"value\":" .. tostring(tonumber(val) or s.default)
          else
            r[#r + 1] = ",\"value\":" .. json_str(val)
          end
          if s.type == "int_stepper" then
            if s.min  then r[#r + 1] = ",\"min\":"  .. tostring(s.min)  end
            if s.max  then r[#r + 1] = ",\"max\":"  .. tostring(s.max)  end
            if s.step then r[#r + 1] = ",\"step\":" .. tostring(s.step) end
          end
          r[#r + 1] = "}"
          rows[#rows + 1] = table.concat(r)
        end
      end
      if #rows > 0 then
        cards[#cards + 1] = "{\"uuid\":\"self\",\"name\":" .. json_str(section)
          .. ",\"settings\":[" .. table.concat(rows, ",") .. "]}"
      end
    end
    return "{\"showDevTools\":" .. json_bool(show_dev)
      .. ",\"plugins\":[" .. table.concat(cards, ",") .. "]}"
  end

  -- ---- panel window --------------------------------------------------------
  local PANEL_W, PANEL_H = 420, 520
  local panel_browser

  local function push_state()
    if panel_browser then panel_browser:sendmessage("state:" .. build_state_json()) end
  end

  local function close_panel()
    if panel_browser then panel_browser:close(); panel_browser = nil end
  end

  local function open_panel()
    if panel_browser then return end
    local pos = SET.get("cp_panel_pos", { 100, 100 })
    local px, py = SET.clamp(pos[1], pos[2], PANEL_W, PANEL_H)
    panel_browser = bolt.createembeddedbrowser(px, py, PANEL_W, PANEL_H,
      "plugin://settings_panel.html")
    panel_browser:onreposition(function (ev)
      local nx, ny = ev:xywh()
      SET.set("cp_panel_pos", { nx, ny })
    end)
    panel_browser:onmessage(function (msg)
      if msg == "refresh" then push_state(); return end
      if msg == "close" then close_panel(); return end
      if msg == "toggle_dev_tools" then
        SET.set("show_dev_tools", not (SET.get("show_dev_tools", false) == true))
        push_state()
        return
      end
      -- "set:<uuid>:<key>:<value>" -- uuid is always "self" now but the page
      -- still sends it, so it is parsed and ignored.
      local key, value = msg:match("^set:[^:]+:([^:]+):(.*)$")
      -- The line_style row writes two keys of its own, neither of which is a
      -- registry row: line_color as "r,g,b,a" and line_thickness as an int.
      if key == "line_color" then
        local cr, cg, cb, ca = value:match("^(%d+),(%d+),(%d+),(%d+)$")
        if cr then
          SET.set("line_color",
            { tonumber(cr), tonumber(cg), tonumber(cb), tonumber(ca) })
          push_state()
        end
        return
      end
      if key == "line_thickness" then
        SET.set("line_thickness", tonumber(value) or 32)
        push_state()
        return
      end
      if key then
        for _, s in ipairs(REGISTRY) do
          if s.key == key then
            local converted = value
            if s.type == "bool" then converted = (value == "true") end
            if s.type == "int" or s.type == "int_stepper" then
              converted = tonumber(value) or s.default
            end
            SET.set(key, converted)
            push_state()
            return
          end
        end
      end
    end)
  end

  -- ---- always-on trigger button --------------------------------------------
  -- 60x60 is the client's embedded-browser minimum; the visible button is a
  -- 36px strip at the top of that square.
  local TRIG_W, TRIG_H = 60, 60
  do
    local pos = SET.get("cp_trigger_pos", { 30, 30 })
    local tx, ty = SET.clamp(pos[1], pos[2], TRIG_W, TRIG_H)
    local trigger = bolt.createembeddedbrowser(tx, ty, TRIG_W, TRIG_H,
      "plugin://settings_trigger.html")
    trigger:onreposition(function (ev)
      local nx, ny = ev:xywh()
      SET.set("cp_trigger_pos", { nx, ny })
    end)
    trigger:onmessage(function (msg)
      if msg == "open" then open_panel() end
    end)
    PANEL.trigger = trigger
  end

  PANEL.open = open_panel
  PANEL.close = close_panel
  PANEL.push_state = push_state
end
