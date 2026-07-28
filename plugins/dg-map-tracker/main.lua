local bolt = require("bolt")
bolt.checkversion(1, 0)

-- ============================================================================
-- SET: consolidated settings module + helpers
-- ============================================================================
-- All settings state and helper functions live on this one table to keep the
-- main chunk's local-slot count below Lua 5.1's 200 limit. Also gathers
-- bundle-seed logic, dev-flag gating, and panel-position clamping.
--
-- Fields:
--   SET.settings    : current settings.json contents as a Lua table
--   SET.DEV         : bool, dev-diagnostics flag
--   SET.get(k, def) : read setting (default if missing)
--   SET.set(k, v)   : write setting (persists to settings.json)
--   SET.save()      : force-persist current SET.settings
--   SET.decode(raw) : parse a settings.json string
--   SET.read_bundled(key)       : read data/<key> from install dir
--   SET.load_or_seed(key)       : user config OR seed from data/<key>
--   SET.dev_save(k, v)          : bolt.saveconfig gated by SET.DEV
--   SET.clamp(x, y, w, h)       : keep browser rect inside game window
local SET = { settings = {}, DEV = false }

local json = require("json")

-- Force our own modules to reload from disk on every plugin toggle. require()
-- caches modules by name in package.loaded, and a toggle re-runs main.lua in
-- the SAME Lua state without clearing it -- so a redeployed module kept serving
-- its stale cached body (a sync.lua crash-fix silently never took, 2026-07-20;
-- the deps were passed to the OLD cached function that ignored them). Clearing
-- here makes each require below re-read its file.
for _, _m in ipairs({ "parity", "examine", "icons", "sync", "resources",
                      "settings_panel" }) do
  package.loaded[_m] = nil
end

do
  local function _bool_of(text, default_value)
    if text == nil then return default_value end
    text = text:gsub("%s+", ""):lower()
    if text == "true" or text == "1" or text == "on"  or text == "yes" then return true  end
    if text == "false" or text == "0" or text == "off" or text == "no" then return false end
    return default_value
  end

  SET.decode = json.decode

  function SET.save() bolt.saveconfig("settings.json", json.encode(SET.settings)) end
  function SET.get(k, default)
    local v = SET.settings[k]
    if v == nil then return default end
    return v
  end
  function SET.set(k, value)
    -- Read-modify-write to preserve other keys written by the settings panel
    -- between our reads (tiny race window; click-frequency writes tolerate it).
    local raw = bolt.loadconfig("settings.json")
    if raw and #raw > 0 then SET.settings = SET.decode(raw) end
    SET.settings[k] = value
    SET.save()
  end

  function SET.read_bundled(key) return bolt.loadfile("data/" .. key) or "" end
  function SET.load_or_seed(key)
    local raw = bolt.loadconfig(key)
    if not raw or #raw == 0 then
      raw = SET.read_bundled(key)
      if #raw > 0 then bolt.saveconfig(key, raw) end
    end
    return raw
  end

  -- Migration from pre-0.2 per-file .txt toggles. Runs only when settings.json
  -- doesn't already exist; harmless leftover .txt files are ignored afterward.
  local function migrate(bool_keys, int_keys, xy_keys, xywh_keys)
    local raw = bolt.loadconfig("settings.json")
    if raw and #raw > 0 then SET.settings = SET.decode(raw); return end
    for _, k in ipairs(bool_keys or {}) do
      local t = bolt.loadconfig(k .. ".txt")
      if t then SET.settings[k] = _bool_of(t, nil) end
    end
    for _, k in ipairs(int_keys or {}) do
      local t = bolt.loadconfig(k .. ".txt")
      if t then SET.settings[k] = tonumber((t:gsub("%s+", ""))) end
    end
    for _, k in ipairs(xy_keys or {}) do
      local t = bolt.loadconfig(k .. ".txt")
      if t then
        local a, b = t:match("^(-?%d+),(-?%d+)")
        if a and b then SET.settings[k] = { tonumber(a), tonumber(b) } end
      end
    end
    for _, k in ipairs(xywh_keys or {}) do
      local t = bolt.loadconfig(k .. ".txt")
      if t then
        local a, b, c, d = t:match("^(-?%d+),(-?%d+),(-?%d+),(-?%d+)")
        if a and b and c and d then
          SET.settings[k] = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
        end
      end
    end
    SET.save()
  end
  migrate(
    { "enabled", "region_visible", "keybag_region_visible",
      "tracker_panel_visible", "res_panel_visible", "icon_panel_visible",
      "rooms_panel_visible", "keys_panel_visible", "scan_range_visible",
      "dev_mode" },
    { "scan_range_tiles" },
    { "rooms_panel_pos", "keys_panel_pos", "tracker_pos", "res_panel_pos", "icon_panel_pos" },
    { "region", "keybag_region" })
end

-- Diagnostics are ALWAYS ON (2026-07-27); the old dev_mode toggle is gone. Every silent failure this plugin has had was only diagnosable
-- because these files existed; the write cost is trivial.
SET.DEV = true
function SET.dev_save(key, contents)
  if SET.DEV then bolt.saveconfig(key, contents) end
end

-- Panel-position sanitizer: keep a browser rectangle fully inside the game
-- window so a stale saved position or a hard-coded default from a higher-res
-- dev machine doesn't spawn the panel off-screen. Returns the clamped x, y.
-- Falls through untouched if the game-window size isn't available yet.
function SET.clamp(x, y, w, h)
  local ww, wh = bolt.gamewindowsize()
  if ww and ww > 0 then
    if x + w > ww then x = ww - w end
    if x < 0 then x = 0 end
  end
  if wh and wh > 0 then
    if y + h > wh then y = wh - h end
    if y < 0 then y = 0 end
  end
  return x, y
end

-- ============================================================================
-- Settings polled from settings.json (the in-plugin settings panel writes it).
-- ============================================================================
-- Initial values seeded from settings.json (which was migrated from the old
-- per-file toggles above at plugin load). Subsequent updates come from the
-- poll below, which re-reads settings.json each tick.
local PLUGIN_ENABLED         = SET.get("enabled",               true)
-- ONE toggle for all three capture-zone overlays (MAP / KEYBAG / WORLD MAP).
-- Replaces region_visible + keybag_region_visible + exam_region_visible, which
-- as three separate dev-tucked switches were impossible to discover on a fresh
-- install (feedback 2026-07-27). Old keys in existing configs are ignored.
local CAPTURE_ZONES_VISIBLE  = SET.get("show_capture_zones",    true)
local TRACKER_PANEL_VISIBLE  = SET.get("tracker_panel_visible", false)
local RES_PANEL_VISIBLE      = SET.get("res_panel_visible",     false)
local ICON_PANEL_VISIBLE     = SET.get("icon_panel_visible",    false)
local ROOMS_PANEL_VISIBLE    = SET.get("rooms_panel_visible",   true)
-- Keys panel defaults CLOSED: panels are opt-in (fresh-install feedback).
local KEYS_PANEL_VISIBLE     = SET.get("keys_panel_visible",    false)
local SCAN_RANGE_VISIBLE     = SET.get("scan_range_visible",    false)

-- Line Draw feature state (merged from the former standalone line-draw plugin).
-- Everything hangs off this ONE table -- and the module body lives in its own
-- function scope below -- specifically so the merge adds no new locals to the
-- main chunk, which already sits just under Lua 5.1's 200-local ceiling (the
-- reason SET itself exists). Populated fully by the do-once function further
-- down; only `visible` is needed this early, for the panel toggle in the poll.
SET.line = { visible = SET.get("line_panel_visible", false), browser = nil }

-- Floor timer state (self-timed stopwatch; its own window). Same rationale as
-- SET.line: everything hangs off one SET field so the feature adds no main-chunk
-- locals. Floor detection + display live in a do-once function further down.
SET.timer = {
  -- The HUD panel was DELETED outright (2026-07-27): no window, no toggle.
  -- The timer/detection machinery below it stays -- key-log stamps and floor
  -- detection consume it -- so `visible` survives as a constant false.
  visible = false,
  -- Floor-start detection method: false = position jump (>128-tile teleport,
  -- the original), true = load-screen (player position goes unavailable during
  -- the inter-floor load, then returns). Switchable so the original is retained
  -- as a fallback if the alternate proves less accurate in-game.
  alt_detect = SET.get("floor_timer_alt_detect", false),
  browser = nil, start_us = nil, last_ptx = nil, last_ptz = nil,
  nil_frames = 0, _last = nil,
  -- Keybag timer reader: read the game's own floor clock out of the keybag
  -- region instead of self-timing. Auto-calibrates the digit glyphs by watching
  -- the seconds digit tick, so no manual training. glyph_seq is refilled each
  -- frame from onrender2d; glyphmap (learned) persists across reloads.
  read = SET.get("floor_timer_read", false),
  glyph_seq = nil, glyphmap = nil, learn = nil, read_str = nil, cal_n = 0,
}

-- Game-messages region: a draggable/resizable capture rect (like the DG map
-- region and keybag region) the user parks over their chat box, so skill-door
-- examine text can be OCR'd from a static, known area. On SET (not main-chunk
-- locals) to stay under Lua 5.1's 200-local ceiling; open/close defined below.

-- Skill-door examine reader state (chat-digit OCR + the box scan). Stub here so
-- the poll can flip `calibrate` before the module body (further down) runs.
SET.examine = {}   -- box-OCR examine reader; module body further down
-- Party-sync sidecar state; open/close defined by the sync module below.
SET.sync = { browser = nil }
local SCAN_RANGE_TILES       = SET.get("scan_range_tiles",      64)

local region_browser   -- forward decls
local keybag_region_browser
local tracker_browser
local rooms_browser
local keys_browser
-- Forward-declare browser open/close functions so poll_settings
-- can reference them safely at plugin load, before they're defined below.
local open_region_browser, close_region_browser
local open_keybag_region_browser, close_keybag_region_browser
local open_tracker_browser, close_tracker_browser
local open_rooms_browser, close_rooms_browser
local open_keys_browser, close_keys_browser
-- Forward-declared so open_rooms_browser (defined earlier than the atlas
-- helpers) can push both atlases to the rooms panel at open time.
local build_img_atlas_msg

local function poll_settings()
  local raw = bolt.loadconfig("settings.json")
  if not raw or #raw == 0 then return end
  local s = SET.decode(raw)
  -- Refresh the cache BEFORE applying toggles: handlers below (e.g.
  -- SET.sync.open) read config through SET.get, which serves SET.settings --
  -- assigning it last meant a room code typed and toggled on inside one poll
  -- window connected with the stale value.
  SET.settings = s

  if s.enabled ~= nil then PLUGIN_ENABLED = s.enabled end

  -- Toggle helper: apply a bool toggle that opens/closes a browser.
  local function apply_toggle(key, cur, open_fn, close_fn, setter)
    local val = s[key]
    if val == nil then return cur end
    if val ~= cur then
      if val then
        if open_fn then open_fn() end
      else
        if close_fn then close_fn() end
      end
    end
    return val
  end

  CAPTURE_ZONES_VISIBLE  = apply_toggle("show_capture_zones",    CAPTURE_ZONES_VISIBLE,
    function ()
      open_region_browser()
      open_keybag_region_browser()
      if SET.examine.open_region then SET.examine.open_region() end
    end,
    function ()
      close_region_browser()
      close_keybag_region_browser()
      if SET.examine.close_region then SET.examine.close_region() end
    end)
  TRACKER_PANEL_VISIBLE  = apply_toggle("tracker_panel_visible", TRACKER_PANEL_VISIBLE, open_tracker_browser,       close_tracker_browser)
  RES_PANEL_VISIBLE      = apply_toggle("res_panel_visible",     RES_PANEL_VISIBLE,     SET.res and SET.res.open_panel, SET.res and SET.res.close_panel)
  -- Full-mesh preview capture is only needed while the resource panel is open;
  -- gating it here saves ~10k bolt calls per unique mesh in normal play.
  if SET.res and SET.res.set_capture then SET.res.set_capture(RES_PANEL_VISIBLE) end
  ICON_PANEL_VISIBLE     = apply_toggle("icon_panel_visible",    ICON_PANEL_VISIBLE,    SET.icons and SET.icons.open_panel, SET.icons and SET.icons.close_panel)
  ROOMS_PANEL_VISIBLE    = apply_toggle("rooms_panel_visible",   ROOMS_PANEL_VISIBLE,   open_rooms_browser,         close_rooms_browser)
  KEYS_PANEL_VISIBLE     = apply_toggle("keys_panel_visible",    KEYS_PANEL_VISIBLE,    open_keys_browser,          close_keys_browser)
  SET.line.visible       = apply_toggle("line_panel_visible",    SET.line.visible,      SET.line.open,              SET.line.close)
  -- Belt-and-braces state sync for the line panel: the push at open() can land
  -- before the page exists, and its "refresh" reply raced often enough that the
  -- panel showed stale toggles (bug list 2026-07-27). Re-push on the poll
  -- cadence; push_state dedupes by body so a quiet panel costs nothing.
  if SET.line.push_state then SET.line.push_state() end
  if s.floor_timer_alt_detect ~= nil then SET.timer.alt_detect = s.floor_timer_alt_detect end
  if s.floor_timer_read ~= nil then SET.timer.read = s.floor_timer_read end
  if s.sync_enabled ~= nil and SET.sync.open then
    if s.sync_enabled and not SET.sync.browser then SET.sync.open()
    elseif not s.sync_enabled and SET.sync.browser then SET.sync.close() end
  end
  -- Reconnect when the room code or relay URL changed while connected: open()
  -- recorded the values it connected with in SET.sync.cfg, so a mismatch means
  -- the user edited them (settings panel or hand-edit) after the socket came up.
  -- Both sides compare the RAW setting value (tostring'd, untrimmed) so a
  -- cosmetic difference can't oscillate into a reconnect loop.
  if SET.sync.browser and SET.sync.cfg then
    local room = tostring(s.sync_room or "")
    local url  = tostring(s.sync_url or "wss://feral-hare-9468.dg.deno.net")
    if room ~= SET.sync.cfg.room or url ~= SET.sync.cfg.url then
      SET.sync.close()
      SET.sync.open()
    end
  end
  if s.scan_range_visible ~= nil then SCAN_RANGE_VISIBLE = s.scan_range_visible end
  if type(s.scan_range_tiles) == "number" and s.scan_range_tiles >= 1 and s.scan_range_tiles <= 64 then
    SCAN_RANGE_TILES = s.scan_range_tiles
  end
  -- Map size: recreate the rooms panel at the new scale (no resize API on
  -- embedded browsers; aspect stays locked because both dims scale together).
  local msc = tonumber(s.rooms_panel_scale) or 100
  if msc >= 60 and msc <= 200 and msc ~= (SET.rooms_scale or 100) then
    SET.rooms_scale = msc
    if rooms_browser then close_rooms_browser(); open_rooms_browser() end
  end

end
poll_settings()

-- ============================================================================
-- Region overlay: a draggable, resizable rectangle. The region is persisted
-- and cached in-memory so onrender2d can screen-bounds-filter cheaply.
-- ============================================================================
-- Default zone rects were captured live from a fresh-install session the user
-- aligned by hand (2026-07-27); absolute pixels, accepted as resolution-specific.
local region_x, region_y, region_w, region_h = 275, 33, 312, 311
do
  local saved = SET.get("region", nil)
  if saved then
    region_x, region_y, region_w, region_h = saved[1], saved[2], saved[3], saved[4]
  end
end

-- Create/destroy region_browser on demand. Bolt's OSR click routing goes by
-- geometry only, so a "hidden but present" browser still swallows clicks —
-- fully closing it is the only reliable way to make the area click-through.
open_region_browser = function ()
  if region_browser then return end
  region_x, region_y = SET.clamp(region_x, region_y, region_w, region_h)
  region_browser = bolt.createembeddedbrowser(
    region_x, region_y, region_w, region_h, "plugin://overlay.html")
  region_browser:onreposition(function (event)
    local x, y, w, h = event:xywh()
    region_x, region_y, region_w, region_h = x, y, w, h
    SET.set("region", { x, y, w, h })
  end)
  -- Zone identity for the shared overlay page (label + border colour).
  region_browser:onmessage(function (msg)
    if msg == "cfg?" and region_browser then
      region_browser:sendmessage("cfg:MAP|e04040")
    end
  end)
end
close_region_browser = function ()
  if not region_browser then return end
  region_browser:close(); region_browser = nil
end
if CAPTURE_ZONES_VISIBLE then open_region_browser() end

-- Keybag region: independent draggable capture rect for the DG keybag UI.
-- Reuses overlay.html - same visual + reposition wiring as the DG map region.
local keybag_x, keybag_y = 153, 80
local keybag_w, keybag_h = 118, 110
do
  local saved = SET.get("keybag_region", nil)
  if saved then
    keybag_x, keybag_y, keybag_w, keybag_h = saved[1], saved[2], saved[3], saved[4]
  end
end
open_keybag_region_browser = function ()
  if keybag_region_browser then return end
  keybag_x, keybag_y = SET.clamp(keybag_x, keybag_y, keybag_w, keybag_h)
  keybag_region_browser = bolt.createembeddedbrowser(
    keybag_x, keybag_y, keybag_w, keybag_h, "plugin://overlay.html")
  keybag_region_browser:onreposition(function (event)
    local x, y, w, h = event:xywh()
    keybag_x, keybag_y, keybag_w, keybag_h = x, y, w, h
    SET.set("keybag_region", { x, y, w, h })
  end)
  keybag_region_browser:onmessage(function (msg)
    if msg == "cfg?" and keybag_region_browser then
      keybag_region_browser:sendmessage("cfg:KEYBAG|4a90e0")
    end
  end)
end
close_keybag_region_browser = function ()
  if not keybag_region_browser then return end
  keybag_region_browser:close(); keybag_region_browser = nil
end
if CAPTURE_ZONES_VISIBLE then open_keybag_region_browser() end

-- ============================================================================
-- Signature catalog + ignored list.
--   img_signatures.txt:  name|w|h|hex_bytes
--   img_ignored.txt:     w|h|hex_bytes  (bare hex also accepted)
-- ============================================================================
local function hex_to_bytes(hex)
  local out = {}
  for pair in hex:gmatch("%x%x") do
    out[#out + 1] = string.char(tonumber(pair, 16))
  end
  return table.concat(out)
end

local signature_catalog = {}   -- byte_string -> name
local signature_names   = {}   -- name -> byte_string
local signature_meta    = {}   -- name -> { w, h }
local ignored_by_sig    = {}   -- byte_string -> { w, h }
local known_dims        = {}   -- w*65536+h -> true

local last_sig_raw, last_ign_raw = nil, nil

local function reload_signatures()
  local raw = SET.load_or_seed("img_signatures.txt")
  if raw == last_sig_raw then return false end
  last_sig_raw = raw
  signature_catalog = {}
  signature_names   = {}
  signature_meta    = {}
  -- Rebuild known_dims from scratch (ignored contributes too — done below).
  known_dims        = {}
  if raw then
    for line in raw:gmatch("[^\r\n]+") do
      if not line:match("^%s*#") and not line:match("^%s*$") then
        local name, w, h, hex = line:match("^%s*([%w_]+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%x+)%s*$")
        if name and hex and #hex == tonumber(w) * tonumber(h) * 4 * 2 then
          local bytes = hex_to_bytes(hex)
          signature_catalog[bytes] = name
          signature_names[name]    = bytes
          signature_meta[name]     = { w = tonumber(w), h = tonumber(h) }
          known_dims[tonumber(w) * 65536 + tonumber(h)] = true
        end
      end
    end
  end
  return true
end

local function reload_ignored()
  local raw = SET.load_or_seed("img_ignored.txt")
  if raw == last_ign_raw then return false end
  last_ign_raw = raw
  ignored_by_sig = {}
  if raw then
    for line in raw:gmatch("[^\r\n]+") do
      if not line:match("^%s*#") and not line:match("^%s*$") then
        local w, h, hex = line:match("^%s*(%d+)%s*|%s*(%d+)%s*|%s*(%x+)%s*$")
        local wv, hv
        if hex then wv, hv = tonumber(w), tonumber(h) end
        if not hex then hex = line:match("^%s*(%x+)%s*$") end
        if hex and #hex >= 4 and (#hex % 8) == 0 then
          local bytes = hex_to_bytes(hex)
          ignored_by_sig[bytes] = { w = wv, h = hv }
          if wv and hv then known_dims[wv * 65536 + hv] = true end
        end
      end
    end
  end
  return true
end
reload_signatures()
reload_ignored()

-- ============================================================================
-- Learned signatures — new images captured inside the region that we haven't
-- named or ignored yet.
-- ============================================================================
local learned = {}     -- sig -> { w, h, surface }
local panel_dirty = true
local panel_last_hash = ""
local panel_last_named = ""
local sidebar_mode = "queue"   -- queue | ignored | classified

local function make_surface_from_bytes(bytes, w, h)
  local buf = bolt.createbuffer(#bytes)
  buf:setstring(0, bytes)
  return bolt.createsurfacefromrgba(w, h, buf)
end

-- ============================================================================
-- Persistent per-atlas-region signature cache: avoids re-reading pixels for the same atlas region across many events.
-- Cleared periodically so shifting atlases eventually re-sync.
-- ============================================================================
local frame_sigs = {}
local frame_sigs_ttl_counter = 0
local FRAME_SIGS_TTL = 300

-- ============================================================================
-- Room graph. Collected each frame from every image whose signature matches
-- one of img_signatures.txt's entries. Positions get grid-snapped and merged
-- so an UNOPENED_* template plus a key-icon on top land in one cell.
--
--   room_observations : reset per frame, populated in onrender2d.
--   rooms_by_cell     : "gx,gz" -> { gx, gz, sx, sy, images = {name, ...} }
--                       Sticky across frames; each frame refreshes the images
--                       currently visible in that cell.
-- ============================================================================
local room_observations = {}
local rooms_by_cell = {}
local rooms_last_hash = ""

-- ============================================================================
-- Shared low-level helpers, hung off SET to spare main-chunk locals (the
-- chunk runs close to Lua 5.1's 200-local ceiling). These replace five
-- hand-rolled copies of the pixel-signature read, four of the cached-sig
-- lookup, four of the vertex-bbox measure, and two of the door census.
--   SET.atlas_sig     : raw-byte signature of an atlas region (nil on read
--                       failure). THE pixel-identity primitive.
--   SET.cached_sig    : atlas_sig through the frame_sigs cache. Failures
--                       cache as false so a bad region is not re-read until
--                       the TTL clear; callers just see nil.
--   SET.vertex_bounds : screen bbox over an image's vertices (nil if none
--                       resolved).
--   SET.door_cells    : ck -> skill for every DOOR_<SKILL> map icon, plus
--                       the ICON_BASE cell as a second return.
-- ============================================================================
function SET.atlas_sig(event, ax, ay, aw, ah)
  local row_bytes = aw * 4
  local rows = {}
  for r = 0, ah - 1 do
    local ok, row = pcall(event.texturedata, event, ax, ay + r, row_bytes)
    if not ok or not row then return nil end
    rows[#rows + 1] = row
  end
  return table.concat(rows)
end

function SET.cached_sig(event, ax, ay, aw, ah)
  local key = ax .. "," .. ay .. "," .. aw .. "," .. ah
  local sig = frame_sigs[key]
  if sig == nil then
    sig = SET.atlas_sig(event, ax, ay, aw, ah) or false
    frame_sigs[key] = sig
  end
  if sig == false then return nil end
  return sig
end

function SET.vertex_bounds(event, first_vert, vpi)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for v = 0, vpi - 1 do
    local ok, sx, sy = pcall(event.vertextargetxy, event, first_vert + v)
    if ok and sx then
      if sx < x0 then x0 = sx end
      if sy < y0 then y0 = sy end
      if sx > x1 then x1 = sx end
      if sy > y1 then y1 = sy end
    end
  end
  if x0 == math.huge then return nil end
  return x0, y0, x1, y1
end

function SET.door_cells()
  local doors, base_ck = {}, nil
  for ck, cell in pairs(rooms_by_cell) do
    for _, nn in ipairs(cell.images) do
      local sk = nn:match("^DOOR_(%u+)$")
      if sk then doors[ck] = sk:lower() end
      if nn == "ICON_BASE" then base_ck = ck end
    end
  end
  return doors, base_ck
end
-- Per-key runtime state: name -> { found = "gx,gz" | nil, lock = "gx,gz" | nil,
-- parity = "unknown" | "bonus" | "crit" }. Absent-key = never seen.
local keys_state = {}

-- Canonical color/shape lists, hoisted inside the key_lower closure so they
-- don't burn 2 of the main chunk's 200 local-variable slots.
local key_lower
do
  local COLORS = { blue=true, purple=true, green=true, silver=true,
                   orange=true, crimson=true, gold=true, yellow=true }
  local SHAPES = { triangle=true, rectangle=true, wedge=true, corner=true,
                   pentagon=true, diamond=true, shield=true, crescent=true }
  key_lower = function (name)
    if not name then return nil end
    local ln = name:lower()
    local color, shape = ln:match("^([^_]+)_(.+)$")
    if color and shape and COLORS[color] and SHAPES[shape] then return ln end
    return nil
  end
end

-- Parity / keybag / world-calibration state, all consolidated into one table
-- because Lua's main chunk has a 200-local cap and this file was already close
-- to it. Constants (60, 128, 512,
-- 16) are inlined at their use sites to save further slots.
--   S.keybag_tick        : monotonic frame counter for TTL smoothing.
--   S.keybag_state       : lower_name -> tick_last_seen (icon in keybag).
--   S.map_origin         : { wrx, wrz } -- the WORLD ROOM that dungeon cell
--                          (0,0) sits at, i.e. where the map's NORTHWEST corner
--                          lands in the world. LATCHED; invariant per floor.
--                          Apply ONLY via world_room_to_grid.
--   S.in_base            : was the player in base last frame? Monotone within a
--                          floor, so false->true means a NEW floor.
--   S.resource_sightings : "gx,gz" -> { name = true, ... }, sticky per floor.
--   S.parity_facts       : "gx,gz" -> { val, reason }. PROVEN parity, sticky per
--                          floor. Parity is a property of the floor fixed at
--                          generation, so a proof holds until the floor ends.
--   S.floor_dead         : nil, or the fatal contradiction that killed the
--                          floor. Once set, parity is frozen and no further
--                          categorisation happens -- only a new floor clears it.
--   S.last_ptx/S.last_ptz: previous frame's player tile, floor-jump detector.
local S = {
  keybag_tick = 0, keybag_state = {},
  map_origin = nil, resource_sightings = {}, opened_at = {},
  in_base = false,
  -- Sticky "another player has been seen on this floor" flag. Only ever set,
  -- never cleared within a floor -- see the ev.solo construction for why the
  -- one-way direction is the safe one.
  group_seen = false,
  -- Sticky "our own PLAYER_RED marker has been classified this floor" flag --
  -- proof that marker detection is working at all, without which the absence
  -- of other players' markers means nothing.
  player_seen = false,
  -- "gx,gz" -> reason string. Rooms proven BONUS / CRIT by a skill-door
  -- examine whose requirement fell inside exactly one of the skill's
  -- guaranteed ranges (skill_doors.txt). Fed to the parity engine as
  -- ev.skill_bonus / ev.skill_crit. Per-floor; wiped with the rest.
  skill_bonus = {},
  skill_crit  = {},
  -- "gx,gz" -> { skill, v, word }. Doors already identified by an examine this
  -- floor. Excluded from the icon census (a resolved door can't keep blocking
  -- the count for its skill), and re-examines are recognised by skill+level.
  bound_doors = {},
  -- Resource fingerprint memo (perf): (tile,vertexcount) -> key | false. Lets
  -- onrender3d skip re-sampling static meshes every scan. Reset on floor wipe.
  res_fp_memo = {},
  parity_facts = {}, floor_dead = nil,
  -- Per-floor causal ledger: every persisted parity fact and every key-found
  -- binding / rejection / discarded conflict, timestamped floor-relative.
  -- Dumped in the death report -- reconstructing WHEN a fact was minted from
  -- a frozen snapshot cost an archaeology session (purple_corner, 2026-07-17).
  parity_ledger = {},
  -- FLOOR GATE: last FLOOR_ICON sighting (us) + current in-floor state.
  -- floor_icon_us is stamped by a dedicated 2D pass; floor_active flips in
  -- the swap handler on presence edges. Deliberately NOT wiped per floor --
  -- the gate is what DRIVES the wipes.
  floor_icon_us = nil, floor_active = false,
  last_ptx = nil, last_ptz = nil,
  -- Sticky auto-anchor: first CLOSE_BUTTON sighting seeds this, subsequent
  -- frames must find the button within a tolerance box or the hit is rejected.
  -- Prevents an unrelated 15x15 X icon elsewhere in the UI (e.g. boss-room
  -- overlay controls) from hijacking the region and blanking the room graph.
  close_anchor_x = nil, close_anchor_y = nil,
}

-- Unix seconds, for naming death dumps so they catalogue in time order.
--
-- bolt.time() is NOT this: it returns MONOTONIC microseconds (uptime), which is
-- for measuring durations, not for naming anything. bolt.datetime() is the only
-- wall clock bolt exposes, and it hands back six UTC integers rather than an
-- epoch -- so we convert. It is already UTC (the C side uses gmtime), which is
-- what makes this exact: there is no timezone to guess at, and bolt documents
-- that it cannot tell us the user's anyway.
--
-- days-from-civil (Hinnant). Verified against Python's calendar.timegm across
-- the epoch, leap days, and century boundaries.
local function unix_now()
  local y, mo, d, h, mi, s = bolt.datetime()
  if not y then return nil end
  local yy  = y - (mo <= 2 and 1 or 0)
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s
end

-- Wipe every per-floor accumulator. Two triggers, both in
-- process_room_observations: a player-tile jump larger than the max DG-floor
-- extent (128 tiles), and -- the exact one -- the in-base flag going false to
-- true, which can only mean a new floor.

-- Append a timestamped line to the per-floor causal ledger (see the field's
-- comment on S). Always on, not dev-gated: the ledger ships in the death
-- report, which must always be written. Ring-capped as a runaway guard;
-- a normal floor mints well under 150 lines.
function SET.ledger(fmt, ...)
  local t0 = (SET.timer and SET.timer.start_us) or 0
  local now = bolt.time() or 0
  local led = S.parity_ledger
  led[#led + 1] = string.format("%7.1fs  ", (now - t0) / 1e6) .. string.format(fmt, ...)
  if #led > 400 then table.remove(led, 1) end
end

local function wipe_floor_state()
  S.keybag_state       = {}
  S.resource_sightings = {}
  S.map_origin         = nil
  S.in_base            = false
  S.opened_at          = {}
  S.group_seen         = false
  S.player_seen        = false
  S.parity_facts       = {}
  S.parity_ledger      = {}
  -- v2 fingerprint memo + shadow-log dedupe are floor-scoped (module state).
  if SET.res and SET.res.floor_wipe then SET.res.floor_wipe() end
  S.skill_bonus        = {}
  S.skill_crit         = {}
  S.bound_doors        = {}
  S.floor_dead         = nil
  S.death_saved        = nil
  S.boss_ledgered      = nil
  S.res_fp_memo        = {}   -- resource fingerprint cache is floor-scoped
  S.close_anchor_x     = nil
  S.close_anchor_y     = nil
  S.close_fresh_us     = nil
  -- Base-stability gate (process_room_observations): a new floor's base slides
  -- into a new position, so reset or a stale still-timer could pass the gate
  -- before the panel settles.
  S.base_px            = nil
  S.base_py            = nil
  S.base_still_us      = nil
  S.rpm_last           = "0.0"   -- header RPM resets to 0.0 on a new floor
  S.key_match_seen     = nil     -- ground-key match tuning log (dev)
  S.key_match_log      = nil
  S.guardian_seen      = nil     -- guardian-door detections (sticky per floor)
  S.guardian_log       = nil
  S.base_cell          = nil     -- first base cell seen this floor (parity guard)
  keys_state = {}
  -- Floor-scoped state owned by the HUD / line-draw / examine modules. The
  -- timer keeps its own jump/load detectors (they work even with the tracker
  -- disabled), but this wipe ALSO fires on the in-base transition -- which is
  -- exact and catches consecutive floors whose coordinate ranges are too close
  -- for the >128-tile jump heuristic. Without the reset here, that case left
  -- the floor clock running and the HUD key log carrying the previous floor's
  -- keys. A double reset when both detectors fire is harmless.
  SET.timer.start_us   = bolt.time()
  SET.line.key_log     = {}
  SET.line.key_order   = 0
  SET.line.collected   = {}
  -- Examine transients: an unconsumed reading must not survive into the new
  -- floor's door census; the box rect and pending double-read die with the
  -- floor too.
  SET.examine.level        = nil
  SET.examine.pending      = nil
  SET.examine.rect         = nil
  SET.examine.last_reads   = {}
  SET.examine.opened_guard = {}
  SET.examine.door_prev    = nil
  SET.examine.t_rect       = nil
  SET.examine.t_first_parse = nil
  -- Base re-appears on the new floor; its first sighting counts as a move,
  -- which holds guard arming off through the settle window automatically.
  SET.examine.base_ck_prev  = nil
  SET.examine.base_moved_us = nil
  -- Retire any previous floor's death report. saveconfig OVERWRITES and cannot
  -- delete, so without this an old floor_dead.txt sits there looking like it
  -- describes the floor you are standing on right now.
  bolt.saveconfig("floor_dead.txt", "(no contradiction -- floor alive)\n")
end

-- Which images are room-body types (each cell should have at most one). Doors
-- and player markers are overlays and get accumulated into their cell.
local ROOM_BODY_PREFIXES = {
  ["2WAY_"] = true, ["3WAY_"] = true, ["4WAY"] = true,
  ["DE_"]   = true, ["UNOPENED_"] = true,
  ["ICON_BASE"] = true, ["ICON_BOSS"] = true,
}
local function is_room_body(name)
  for pfx, _ in pairs(ROOM_BODY_PREFIXES) do
    if name == pfx or name:sub(1, #pfx) == pfx then return true end
  end
  return false
end
-- Signatures that DO match img_signatures.txt but aren't part of the DG map
-- grid (close button, background chrome). Excluded from room graph entirely.
local NON_ROOM_NAMES = {
  ["BUTTON_CLOSE"] = true,
}

-- Histogram-mode grid-step estimator (buckets pairwise diffs into 4-px bins).
-- Rooms are wider than any jitter, so the mode is the true tile pitch. Only
-- diffs in [20, 100] px count -- filters near-duplicates and huge outliers.
local function estimate_grid_step(vals)
  if #vals < 2 then return nil end
  local sorted = {}
  for _, v in ipairs(vals) do sorted[#sorted + 1] = v end
  table.sort(sorted)
  local buckets = {}
  for i = 2, #sorted do
    local d = sorted[i] - sorted[i - 1]
    if d >= 20 and d <= 100 then
      local b = math.floor(d / 4)
      buckets[b] = (buckets[b] or 0) + 1
    end
  end
  local best_b, best_c = nil, 0
  for b, c in pairs(buckets) do
    if c > best_c then best_b, best_c = b, c end
  end
  if not best_b then return nil end
  return best_b * 4 + 2
end

-- Forward declarations. Both are defined further down but called from above --
-- and a call to a local that is not yet in scope silently compiles to a GLOBAL
-- read, which is nil at runtime. Valid syntax, so the parse check does not catch
-- it; the only symptom is the call failing at runtime.
--   base_if_player_in_it : needs cell_doors / NEI_DELTA, declared below, but
--                          process_room_observations calls it.
local base_if_player_in_it

-- Is the FLOOR_ICON gate armed? Only once the icon is cataloged -- without
-- the catalog entry the plugin behaves exactly as before (legacy heuristics).
local function floor_gate_armed()
  return signature_names["FLOOR_ICON"] ~= nil
end

local function process_room_observations()
  if floor_gate_armed() and not S.floor_active then
    -- Between floors (FLOOR_ICON absent): the game can keep rendering the
    -- old map for a few frames, and the keep-previous sanity guard below
    -- would happily carry the whole previous floor's graph across the wipe
    -- (rooms=51->4 in floor_diag; the phantom-door bind came from exactly
    -- this). Drop the frame's observations unprocessed until the icon
    -- returns and the rising edge restarts mapping sterile.
    room_observations = {}
    return
  end
  -- Stabilize window: for the first STABILIZE_US after the floor icon reappears
  -- (the rising edge), hold off processing observations. On floor entry the
  -- first frames are still settling -- rooms half-rendered, positions jittering
  -- -- and building the map / parity from them produces garbage. Wait for
  -- settled frames instead of rendering immediately.
  local STABILIZE_US = 100000   -- 100ms
  if S.floor_rise_us and (bolt.time() or 0) - S.floor_rise_us < STABILIZE_US then
    room_observations = {}
    return
  end
  if #room_observations == 0 then return end
  -- Base-stability gate: the whole grid is anchored to the minimap panel (cells
  -- are pixel deltas from the close-button anchor), and that panel SLIDES during
  -- floor start and floor end. The base icon rides the slide, so its raw screen
  -- position is a direct "panel settled" signal -- more reliable than the
  -- floor-icon timers (the 4s floor-active falling debounce keeps processing
  -- right through a floor-end slide otherwise). While the base icon is still
  -- moving, early-return so the LAST good map stays on screen instead of
  -- rendering the slide; resume only after it has held still for a beat. When
  -- ICON_BASE isn't visible this frame, fall through -- the confirmed symptom is
  -- the grid translating as one WHILE base is visible, and the floor gates above
  -- already cover the icon-absent cases.
  local BASE_STABLE_US = 200000   -- 200ms of stillness before we trust it
  local BASE_TOL       = 3        -- px; jitter below this is "not moving"
  local bx, by
  for _, o in ipairs(room_observations) do
    if o.name == "ICON_BASE" then bx, by = o.x, o.y; break end
  end
  if bx then
    if not S.base_px
       or math.abs(bx - S.base_px) > BASE_TOL
       or math.abs(by - S.base_py) > BASE_TOL then
      S.base_px, S.base_py = bx, by
      S.base_still_us = bolt.time() or 0
      return                       -- base moved: panel still sliding, hold
    end
    if (bolt.time() or 0) - (S.base_still_us or 0) < BASE_STABLE_US then
      return                       -- base holding, but not long enough yet
    end
  end
  -- Grid step comes from ROOM-BODY positions only. Overlays (players / doors /
  -- keys) sit slightly off-centre and would poison the pairwise histogram.
  local body_xs, body_ys = {}, {}
  for _, o in ipairs(room_observations) do
    if is_room_body(o.name) then
      body_xs[#body_xs + 1] = o.x
      body_ys[#body_ys + 1] = o.y
    end
  end
  if #body_xs < 2 and #body_ys < 2 then return end
  local step_x = estimate_grid_step(body_xs)
  local step_y = estimate_grid_step(body_ys)
  local step = math.min(step_x or math.huge, step_y or math.huge)
  if step == math.huge then return end

  -- Grid phase (sub-pixel origin): mode of (body_x mod step). Every cell centre
  -- lands on the same phase, so snapping via (x - phase + step/2) / step puts
  -- overlays into the same cell as their room body regardless of small offsets.
  local function estimate_phase(vals)
    local buckets = {}
    for _, v in ipairs(vals) do
      local b = math.floor((v % step) + 0.5)
      buckets[b] = (buckets[b] or 0) + 1
    end
    local best_b, best_c = 0, 0
    for b, c in pairs(buckets) do
      if c > best_c then best_b, best_c = b, c end
    end
    return best_b
  end
  local x_phase = estimate_phase(body_xs)
  local y_phase = estimate_phase(body_ys)

  -- Snap each observation to a cell. When we have a CLOSE_BUTTON anchor, skip
  -- phase estimation entirely: cell coords are derived by rounding the pixel
  -- delta from the close button, assumed to sit at phantom (LAST_COL+1, -1).
  -- The phase-based path was unstable because y_phase drifts by a couple of
  -- pixels as new rooms come into view, and that drift shifted every room's
  -- gz by 1 -- rows overflowed past gz=7 and got clipped by the panel.
  local LAST_COL = 7                       -- large map; TODO: 3 for medium/small
  local raw = {}
  local min_gx, min_gz = math.huge, math.huge
  -- The sticky auto-anchor is the only source. There used to be a fallback to a
  -- close_button_pos stashed by a per-frame on_render2d handler -- but no such
  -- handler ever existed, so it was nil on every read and the fallback was
  -- decoration.
  local anchor_x = S.close_anchor_x
  local anchor_y = S.close_anchor_y
  local use_close = (anchor_x ~= nil)
  for _, o in ipairs(room_observations) do
    local gx, gz
    if use_close then
      gx = math.floor((o.x - anchor_x) / step + 0.5) + LAST_COL + 1
      gz = math.floor((o.y - anchor_y) / step + 0.5) - 1
    else
      gx = math.floor((o.x - x_phase + step * 0.5) / step)
      gz = math.floor((o.y - y_phase + step * 0.5) / step)
    end
    if gx < min_gx then min_gx = gx end
    if gz < min_gz then min_gz = gz end
    raw[#raw + 1] = { gx = gx, gz = gz, o = o }
  end
  local origin_gx, origin_gz
  if use_close then
    origin_gx, origin_gz = 0, 0            -- rooms already in dungeon coords
  else
    origin_gx, origin_gz = min_gx, min_gz  -- fallback: top-left observed = (0,0)
  end
  local frame_cells = {}   -- "gx,gz" -> { gx, gz, sx, sy, images = {name, ...} }
  for _, r in ipairs(raw) do
    local gx = r.gx - origin_gx
    local gz = r.gz - origin_gz
    local o = r.o
    local k = gx .. "," .. gz
    local cell = frame_cells[k]
    if not cell then
      cell = { gx = gx, gz = gz, sx = 0, sy = 0, images = {}, seen = {} }
      frame_cells[k] = cell
    end
    if not cell.seen[o.name] then
      cell.seen[o.name] = true
      cell.images[#cell.images + 1] = o.name
      -- Update centre using the room-body position when available (that's the
      -- "true" cell centre; overlays like keys / players offset slightly).
      if is_room_body(o.name) or cell.sx == 0 then
        cell.sx = o.x; cell.sy = o.y
      end
    end
  end
  -- Sanity guard: if not a single computed cell lands in the valid 0..7 dungeon
  -- range, the anchor or step estimate must be wrong (e.g. boss-room UI shift).
  -- Keep the previous rooms_by_cell rather than blank the panel with garbage.
  local any_in_range = false
  for _, c in pairs(frame_cells) do
    if c.gx >= 0 and c.gx <= 7 and c.gz >= 0 and c.gz <= 7 then
      any_in_range = true; break
    end
  end
  if any_in_range then
    -- Relocate every PLAYER_* marker to the same cell as its NEAREST
    -- room-body. The raw icon-snap uses the marker's own screen position,
    -- which the game renders above the room-body center; rounding that y
    -- would place the marker 1 row above the room the player is actually
    -- standing in. Snapping to the nearest room-body cell fixes the display
    -- AND lets map_origin (below) calibrate from a correct player_gx instead
    -- of self-referencing the buggy snap. (Generalised from PLAYER_RED-only
    -- when PLAYER_TWO was cataloged; each marker relocates independently.)
    local done_players = {}
    for _, o in ipairs(room_observations) do
      local pname = o.name
      if pname:sub(1, 7) == "PLAYER_" and not done_players[pname] then
        done_players[pname] = true
        local best_cell, best_d = nil, math.huge
        for _, c in pairs(frame_cells) do
          local has_body = false
          for _, n in ipairs(c.images) do
            if is_room_body(n) then has_body = true; break end
          end
          if has_body then
            local dx = c.sx - o.x
            local dy = c.sy - o.y
            local d = dx * dx + dy * dy
            if d < best_d then best_d = d; best_cell = c end
          end
        end
        -- Strip the marker from wherever the raw snap put it.
        for _, c in pairs(frame_cells) do
          for i, n in ipairs(c.images) do
            if n == pname then
              table.remove(c.images, i); c.seen[n] = nil; break
            end
          end
        end
        -- Add it to the nearest room-body cell (if that cell is in the valid
        -- 0..7 range -- otherwise drop the marker rather than place it wrong).
        if best_cell and best_cell.gx >= 0 and best_cell.gx <= 7
                     and best_cell.gz >= 0 and best_cell.gz <= 7 then
          if not best_cell.seen[pname] then
            best_cell.images[#best_cell.images + 1] = pname
            best_cell.seen[pname] = true
          end
        end
      end
    end
    -- Drop cells left with no images. The PLAYER_RED relocation above strips
    -- the marker from the cell the raw snap chose, and since the game draws the
    -- marker above the room-body centre that cell is usually the empty row
    -- above the real room -- so stripping leaves an image-less cell behind. An
    -- empty cell is not a room: it renders as a phantom badge in the panel, and
    -- it weakens the rooms_by_cell membership test that on_render3d uses to
    -- reject UI key icons projecting onto bogus world tiles.
    for k, c in pairs(frame_cells) do
      if #c.images == 0 then frame_cells[k] = nil end
    end
    rooms_by_cell = frame_cells
  end

  -- Player tile position: drives floor-change detection and map_origin
  -- calibration. Note this needs no PLAYER_RED: the marker is not an input to
  -- calibration any more (base is), so there is deliberately no scan for it
  -- here. floor(ptx/16) is exact wherever in the room the player stands.
  local pp = bolt.playerposition()
  if pp then
    local ppx, ppy, ppz = pp:get()
    local ptx = math.floor(ppx / 512)
    local ptz = math.floor(ppz / 512)
    -- x/z only: y is constant within a dungeon, so it carries no signal.
    local jumped = S.last_ptx ~= nil and
       (math.abs(ptx - S.last_ptx) > 128 or
        math.abs(ptz - S.last_ptz) > 128)
    if jumped then wipe_floor_state() end
    -- Floor-transition diagnostic. The open question is whether a new floor
    -- actually trips this wipe: if it does not, the previous floor's
    -- close_anchor / map_origin survive and can block detection until the
    -- plugin is restarted. Logged only on a jump, on the first few frames, and
    -- whenever the room count collapses -- a per-frame log would churn at 4Hz.
    if SET.DEV then
      S.diag_n = (S.diag_n or 0) + 1
      local nrooms = 0
      for _ in pairs(rooms_by_cell) do nrooms = nrooms + 1 end
      if jumped or S.diag_n <= 3 or (S.diag_rooms or 0) > 0 and nrooms == 0 then
        S.diag_log = (S.diag_log or "") .. string.format(
          "n=%d jumped=%s tile=%d,%d last=%s,%s rooms=%d->%d offset=%s anchor=%s,%s\n",
          S.diag_n, tostring(jumped), ptx, ptz,
          tostring(S.last_ptx), tostring(S.last_ptz),
          S.diag_rooms or 0, nrooms,
          S.map_origin and ("origin=" .. S.map_origin.wrx .. "," .. S.map_origin.wrz) or "nil",
          tostring(S.close_anchor_x), tostring(S.close_anchor_y))
        SET.dev_save("floor_diag.txt", S.diag_log)
      end
      S.diag_rooms = nrooms
    end
    S.last_ptx, S.last_ptz = ptx, ptz
    -- MAP ORIGIN calibration: the world room that dungeon cell (0,0) sits at.
    -- Consumed by world_room_to_grid, the ONLY place it may be applied.
    --
    -- EXACT, not estimated. Both inputs are precise: floor(ptx/16) is the
    -- player's world room regardless of where in the room they stand, and
    -- base_if_player_in_it() proves the player is in base by pure graph logic.
    -- So the subtraction is right the first time and every time, and there is
    -- nothing to latch, confirm, gate or tolerate. The pile of filtering that
    -- used to live here existed to tame PLAYER_RED's relocation noise; using
    -- base instead removes the noise rather than filtering it.
    --
    -- Recomputed every frame the player is in base -- it yields the identical
    -- value each time, then holds once they leave, which is correct because the
    -- origin is a property of where the floor sits and cannot change within it.
    --
    -- FLOOR CHANGE: in-base is monotone within a floor (true at spawn, false
    -- forever once you open a door), so a false->true transition means a NEW
    -- floor. That is exact, unlike the >128-tile jump guess above -- which is
    -- kept as a belt-and-braces for leaving the dungeon entirely, but is no
    -- longer what this depends on.
    local base = base_if_player_in_it()
    -- Anchor gate: base.gx/base.gz feed map_origin, which must never be
    -- computed from relative fallback coordinates (see compute_parity's
    -- gate). The in-base wipe below still fires anchorless -- clearing stale
    -- state needs no coordinates -- but calibration waits for the anchor.
    if base and not S.close_anchor_x then
      if not S.in_base then
        S.in_base = true
        wipe_floor_state()
        S.in_base = true
      end
    elseif base then
      if not S.in_base then
        -- false->true: new floor. Wipe BEFORE calibrating, or the wipe would
        -- immediately clear the origin we just worked out.
        S.in_base = true
        wipe_floor_state()
        S.in_base = true                     -- wipe_floor_state clears this
      end
      -- gx = wrx - origin.wrx  =>  origin.wrx = pwrx - base.gx
      -- gz = origin.wrz - wrz  =>  origin.wrz = pwrz + base.gz
      S.map_origin = { wrx = math.floor(ptx / 16) - base.gx,
                       wrz = math.floor(ptz / 16) + base.gz }
    else
      S.in_base = false
    end
  end
end

-- ============================================================================
-- Parity propagation.
--
-- Given the room graph rooted at ICON_BASE, propagate crit / bonus / unknown
-- parity down the tree. Rules (see project_dg_parity_constraints memory for
-- full detail):
--   1. Base is always crit; boss is always crit.
--   2. Bonus is inherited by all tree descendants (unconditional).
--   3. Crit by elimination -- DEFERRED, not yet implemented.
--   4. Key parity: a key picked up in a bonus room implies its matching lock
--      cell is bonus. Bidirectional trigger. Fires here whenever
--      keys_state[K].found and .lock are both known.
-- ============================================================================

-- Door directions per room-body name. UNOPENED variants have their single
-- door on the side facing the room we came from (so the "back" edge exists).
local ROOM_DOORS = {
  ["DE_NORTH"] = { n=true }, ["DE_SOUTH"] = { s=true },
  ["DE_EAST"]  = { e=true }, ["DE_WEST"]  = { w=true },
  ["2WAY_NS"]  = { n=true, s=true }, ["2WAY_EW"] = { e=true, w=true },
  ["2WAY_NE"]  = { n=true, e=true }, ["2WAY_NW"] = { n=true, w=true },
  ["2WAY_ES"]  = { e=true, s=true }, ["2WAY_SW"] = { s=true, w=true },
  ["3WAY_NES"] = { n=true, e=true, s=true },
  ["3WAY_NEW"] = { n=true, e=true, w=true },
  ["3WAY_NSW"] = { n=true, s=true, w=true },
  ["3WAY_ESW"] = { e=true, s=true, w=true },
  ["4WAY"]     = { n=true, e=true, s=true, w=true },
  ["UNOPENED_NORTH_TEMPLATE"] = { n=true },
  ["UNOPENED_SOUTH_TEMPLATE"] = { s=true },
  ["UNOPENED_EAST_TEMPLATE"]  = { e=true },
  ["UNOPENED_WEST_TEMPLATE"]  = { w=true },
  ["UNOPENED_NORTH_QUESTION"] = { n=true },
  ["UNOPENED_SOUTH_QUESTION"] = { s=true },
  ["UNOPENED_EAST_QUESTION"]  = { e=true },
  ["UNOPENED_WEST_QUESTION"]  = { w=true },
}
local NEI_DELTA = { n = {0,-1}, e = {1,0}, s = {0,1}, w = {-1,0} }
local NEI_OPP   = { n = "s", e = "w", s = "n", w = "e" }

local function cell_doors(cell)
  local out = {}
  for _, name in ipairs(cell.images) do
    local d = ROOM_DOORS[name]
    if d then for k, _ in pairs(d) do out[k] = true end end
  end
  return out
end

-- World room -> dungeon cell. THE ONLY place S.map_origin may be applied: this
-- used to be copy-pasted inline into the resource path and the ground-key path,
-- which is how the axis bug below could have been fixed in one and not the
-- other.
--
-- Both axes are measured from ONE named point -- S.map_origin, the world room
-- that dungeon cell (0,0) sits at, i.e. the map's NORTHWEST corner:
--
--   gx = wrx - origin.wrx     columns count EAST from it, and the world's x
--                             also runs east, so this is a plain subtraction.
--   gz = origin.wrz - wrz     rows count SOUTH from it, but the world's z runs
--                             NORTH -- so this one subtracts BACKWARDS. It is a
--                             reflection, not a shift.
--
-- THAT ASYMMETRY IS THE WHOLE BUG. The DG map is drawn NORTH-UP and rows are
-- counted DOWN the screen (NEI_DELTA: north is gz-1), so dungeon rows run
-- opposite to world z. The old code added a delta on BOTH axes, and no constant
-- delta can express a reflection.
--
-- It hid for months because it is EXACTLY RIGHT for the player's own room by
-- construction: calibrating from the player guarantees the player's own cell
-- maps back to itself whichever way the axis points. And nearly every sighting
-- IS same-room -- not because walls block the view, but because on_render3d
-- discards anything past SCAN_RANGE_TILES (15) of the player, and a room is 16
-- tiles wide. The scan window barely leaves the room you are standing in. So the
-- map looked fine, while the rare cross-room sighting landed mirrored to the far
-- side of the player, wrong by twice the distance. That is the "one-room drift"
-- in dg-open-bugs; it was never a drift, it was a reflection.
--
-- Returns nil when uncalibrated, so callers must handle it.
local function world_room_to_grid(wrx, wrz)
  if not S.map_origin then return nil end
  return wrx - S.map_origin.wrx, S.map_origin.wrz - wrz
end

-- Is the player standing in base? Returns base's cell if so, else nil.
--
-- TRUE IFF EVERY CELL ADJACENT TO BASE IS UNOPENED. This is exact, not a
-- heuristic: reaching any room other than base means traversing one of base's
-- neighbours, and traversing a room opens it. So if all of them are still
-- unopened, nobody has left base, so the player is in it.
--
-- This is what lets calibration be exact (see process_room_observations). It
-- replaces pairing PLAYER_RED's cell with the player's world room -- a marker
-- that has to be relocated to the nearest room-body because the game draws it
-- above the body centre, which is ambiguous near a room edge and can sit wrong
-- for as long as you stand by a door. ICON_BASE needs no relocation: it IS a
-- room body. All the latching, confirm windows and mid-room gating that used to
-- live here were filters for noise this approach does not have.
--
-- MONOTONE WITHIN A FLOOR: true at spawn, false the moment you open your first
-- door, and rooms never un-open. So a false->true transition IS a floor change
-- -- exact, and independent of the >128-tile jump guess.
--
-- CONSERVATIVE ON GAPS: an adjacent cell MISSING from the graph is a detection
-- gap, not evidence of anything, so we decline rather than guess. Skipping a
-- frame costs nothing; a wrong origin costs the whole floor.
-- NB: assigns the forward-declared local above -- no `local` keyword here, or it
-- would shadow it and the call site would go back to reading a nil global.
function base_if_player_in_it()
  local bck, base
  for ck, c in pairs(rooms_by_cell) do
    for _, n in ipairs(c.images) do
      if n == "ICON_BASE" then bck, base = ck, c; break end
    end
    if base then break end
  end
  if not base then return nil end
  for dir in pairs(cell_doors(base)) do
    local d  = NEI_DELTA[dir]
    local nb = rooms_by_cell[(base.gx + d[1]) .. "," .. (base.gz + d[2])]
    if not nb then return nil end            -- gap: decline, do not guess
    local is_unopened = false
    for _, n in ipairs(nb.images) do
      if n:sub(1, 9) == "UNOPENED_" then is_unopened = true; break end
    end
    if not is_unopened then return nil end   -- someone left base
  end
  return base
end

-- ----------------------------------------------------------------------------
-- Resource-tier parity signal.
--
-- Constants + shared state (512, 16, S.map_origin,
-- S.resource_sightings) declared near the top of the file so calibration inside
-- process_room_observations can see them.
--
-- Rule: only the top two tiers of a resource type can appear in crit rooms.
-- Any sighting of tier < (max-1) proves the cell is bonus.
-- ----------------------------------------------------------------------------



-- Computed each dump from scratch: state per cell + parent-link per cell.
local parity_state  = {}
local parity_parent = {}

-- ============================================================================
-- Parity engine -- lives in parity.lua.
-- ============================================================================
-- Pure function of (rooms, ev) -> P, parent, diag, why, meta. Its four floor-
-- geometry dependencies are injected here rather than read as globals, so the
-- module has no hidden coupling to this file and test/spec.py exercises the
-- shipped parity.lua directly.
local solve_parity = require("parity")({
  cell_doors = cell_doors, key_lower = key_lower,
  NEI_DELTA = NEI_DELTA, NEI_OPP = NEI_OPP,
})
-- Thin wrapper: gather live observations into a plain snapshot, then solve.
--
-- PROVEN PARITY IS PERSISTED (S.parity_facts) and re-seeded every tick. Parity
-- is fixed at floor generation, so a proof is true for the life of the floor and
-- is not re-earned each tick. This replaces an earlier "nothing derived is
-- persisted" rule, which was justified on the grounds that re-derivation lets a
-- corrected observation heal the graph -- but the evidence layer is already
-- sticky (sightings and key bindings only accumulate), so re-derivation
-- reproduced the same answer anyway and bought almost nothing. What it did do
-- was DISCARD any conclusion whose premise was transient: the frontier rule's
-- above all, since the frontier moves as you explore, so rooms went crit and
-- then fell back to unknown.
--
-- The bigger win is diagnostic. Facts that stick COLLIDE. A bad inference that
-- used to appear and quietly evaporate is invisible; one that persists meets a
-- later inference and fires a contradiction naming both claims -- which is what
-- actually finds the lying observation. Re-derivation was hiding bugs by
-- rearranging the map instead of reporting them.
local function compute_parity()
  -- Dead floor: a contradiction proved something upstream is lying, so every
  -- further inference would be built on it. Freeze at the moment of death.
  -- Nothing here recovers; only a new floor does, via wipe_floor_state.
  if S.floor_dead then return end
  -- COORDINATE-STABILITY GATE: until the close-button anchor locks, cell
  -- coordinates come from the relative fallback ("top-left observed = 0,0")
  -- and shift when the view changes. Facts persisted under relative coords
  -- outlive the snap to absolute ones -- seen twice: a base seed pinned to a
  -- non-base cell painted whole false-crit chains ("crit UP: ancestor of
  -- crit room 1,0" across six rooms). Nothing persistent may derive from
  -- anchorless frames; the anchor locks within ~200ms of the map opening.
  if not S.close_anchor_x then return end
  local ev = { resource_bonus = {}, keys = {}, facts = S.parity_facts,
               skill_bonus = S.skill_bonus, skill_crit = S.skill_crit }
  -- Only sub-top-tier sightings carry information: the top two tiers spawn in
  -- crit AND bonus, so T9/T10 proves nothing. Keep the resource NAME, not just
  -- a flag, so the audit trail can say which sighting drove the call.
  for ck, bag in pairs(S.resource_sightings) do
    for name, _ in pairs(bag) do
      if SET.res.verdict(name) == "bonus" then ev.resource_bonus[ck] = name; break end
    end
  end
  for kn, st in pairs(keys_state) do
    ev.keys[kn] = { found = st.found, lock = st.lock }
  end
  -- Keys currently in the bag (TTL-live). Once boss is on the map these are
  -- provably bonus keys: the crit tree is fully opened, so no locked crit door
  -- remains for them to open.
  -- First-opened stamps (bolt.time() micros). The engine refuses to trust
  -- "holds no key" for 0.1s after a room opens: rooms open on the minimap
  -- instantly, ground keys are proximity-scanned, and evaluating absence in
  -- that gap is how the boss key at 0,2 got a floor killed.
  local now = bolt.time()
  for ck, c in pairs(rooms_by_cell) do
    if not S.opened_at[ck] then
      for _, n in ipairs(c.images) do
        if is_room_body(n) and n:sub(1, 9) ~= "UNOPENED_" then
          S.opened_at[ck] = now; break
        end
      end
    end
  end
  ev.opened_at = S.opened_at
  ev.now = now
  -- Disturbance clock for the frontier rule's quiet gate. Any change to what
  -- is discovered, opened, found or held resets it; the engine refuses to run
  -- the frontier argument until the world has been still for 0.1s. Both dead
  -- floors died of proofs fired inside the minimap-vs-proximity gap (rooms and
  -- locked doors appear instantly; the keys inside them only when approached),
  -- and a graph flicker (a room missing for one frame) shrinks the frontier
  -- the same way -- so the ROOM COUNT is part of the signature too.
  local nsig = 0
  for _ in pairs(rooms_by_cell) do nsig = nsig + 1 end
  local parts = { tostring(nsig) }
  for ck in pairs(S.opened_at) do parts[#parts + 1] = ck end
  for kn, st in pairs(keys_state) do
    if st.found then parts[#parts + 1] = kn .. "@" .. st.found end
  end
  -- NB: ev.keybag does not exist yet (built a few lines below) -- reading it
  -- here was pairs(nil), which killed the plugin on enable. Use the TTL-live
  -- view of the bag directly, same test the ev.keybag construction uses.
  for name, tick in pairs(S.keybag_state) do
    if S.keybag_tick - tick <= 60 then parts[#parts + 1] = "bag:" .. name end
  end
  table.sort(parts)
  local sig = table.concat(parts, "|")
  if sig ~= S.world_sig then S.world_sig = sig; S.last_change = now end
  ev.last_change = S.last_change
  ev.keybag = {}
  for name, tick in pairs(S.keybag_state) do
    if S.keybag_tick - tick <= 60 then ev.keybag[name] = true end
  end
  -- Is this a LARGE floor? Gates the branch-capacity rule, whose 18-room crit
  -- minimum is a large-floor bound; medium/small bounds are unknown, so firing
  -- it on a smaller floor would invent crit out of nothing.
  --
  -- Proven-large test: a room seen at gx>=4 AND a room seen at gz>=4. On the
  -- assumed 4x4 / 4x8 / 8x8 size ladder, needing BOTH axes past 3 rules out 4x4
  -- and either orientation of 4x8, leaving only 8x8. Deliberately conservative:
  -- a false negative just costs us an inference, a false positive marks rooms
  -- crit that are not. Revisit if the size ladder is ever confirmed.
  local max_gx, max_gz = -1, -1
  for _, c in pairs(rooms_by_cell) do
    if c.gx > max_gx then max_gx = c.gx end
    if c.gz > max_gz then max_gz = c.gz end
  end
  ev.floor_is_large = max_gx >= 4 and max_gz >= 4
  -- SOLO floor? PLAYER_RED is us; PLAYER_TWO..FIVE are the other party slots,
  -- so any of those having been seen means this is a group floor. Gates the
  -- engine's "unobserved lock => bonus key" rule, which is only sound when
  -- nobody else could have opened a key door before we saw it locked.
  --
  -- STICKY, and one-way on purpose. A teammate standing in a room that is off
  -- the current minimap view drops their marker for a frame, so an
  -- instantaneous test would read group floors as solo intermittently -- and
  -- that is the direction that kills floors (a false solo marks crit rooms
  -- bonus). Once any other marker is seen the floor stays group until
  -- wipe_floor_state clears it.
  --
  -- And solo is only claimed once PLAYER_RED has actually been classified this
  -- floor. "No other markers seen" is absence evidence, and it reads identically
  -- whether the floor is solo or the marker classifier is simply not matching
  -- anything -- these markers come from the minimap IMAGE catalog
  -- (img_signatures.txt), not the 3D icon catalog, so a missing signature makes
  -- a group floor look empty. Seeing our OWN marker proves classification is
  -- working, which is what makes the absence of the others meaningful.
  for _, c in pairs(rooms_by_cell) do
    for _, n in ipairs(c.images) do
      if n:sub(1, 7) == "PLAYER_" then
        if n == "PLAYER_RED" then S.player_seen = true
        else S.group_seen = true end
      end
    end
    if S.group_seen and S.player_seen then break end
  end
  ev.solo = S.player_seen and not S.group_seen
  local ps, pp, diag, why, meta = solve_parity(rooms_by_cell, ev)

  -- Base-cell guard. The base room is fixed per floor, but solve_parity finds it
  -- by scanning ICON_BASE every call, so a map shift / anchor glitch that briefly
  -- lands the base icon on a different grid cell makes it re-seed "base is crit by
  -- definition" THERE and poison the tree (a phantom base at 1,6 once dragged 1,5
  -- crit via elimination and killed the floor). Lock in the FIRST base cell seen;
  -- ignore any later frame whose base cell differs -- keep the prior state, mint
  -- nothing, don't die on its contradiction. Reset by wipe_floor_state.
  if meta.base then
    if not S.base_cell then
      S.base_cell = meta.base
    elseif meta.base ~= S.base_cell then
      return
    end
  end
  parity_state, parity_parent = ps, pp

  -- Stamp the boss's discovery time in the ledger, once. The frontier rule
  -- ONLY fires while the boss is undiscovered (parity.lua), so this timestamp
  -- is what decides whether a later frontier crit proof was legitimate (boss
  -- not yet seen) or made on a stale premise. Reset by wipe_floor_state.
  if meta.boss and not S.boss_ledgered then
    S.boss_ledgered = true
    SET.ledger("boss discovered at %s", tostring(meta.boss))
  end

  if meta.fatal then
    -- The floor just died. Keep the state as it stood when the contradiction
    -- fired -- that snapshot IS the evidence -- and stop categorising.
    S.floor_dead = meta.fatal
  else
    -- Promote this tick's conclusions to proven facts. They will be re-seeded
    -- next tick and every tick after, and any later inference that disagrees
    -- with one of them is a contradiction rather than a silent reshuffle.
    --
    -- FIRST PROOF WINS -- never overwrite. Two reasons. The original reason is
    -- the useful one: it names the evidence that actually established the fact,
    -- which is what you need when tracing a bad call, whereas a later tick would
    -- overwrite it with whichever propagator happened to re-derive it. And
    -- re-storing would fold the "proved earlier -- " tag back in every tick,
    -- growing the string without bound.
    for ck, val in pairs(parity_state) do
      if not S.parity_facts[ck] then
        S.parity_facts[ck] = { val = val, reason = why[ck] }
        SET.ledger("%s %s -- %s", ck, val, why[ck] or "(no reason)")
      end
    end
  end

  -- The dump is DEV-only, but a death report is NOT a diagnostic -- it is the
  -- whole output of a floor that just failed, and it must be written
  -- unconditionally (SET.DEV is always true now anyway).
  if not (SET.DEV or S.floor_dead) then return end

  -- Full-picture dump. Parity alone is not analysable: to argue about whether a
  -- verdict is right you need the verdict, the reason for it, the tree it rode
  -- on, and the raw evidence that fed it -- all from the same tick. Written
  -- unconditionally (including when clean) because saveconfig overwrites, so a
  -- conditional write leaves a stale file looking live.
  local out = {}
  local function w(s) out[#out + 1] = s end
  -- Death banner first: this file is read in a hurry, and the two colliding
  -- claims are the entire point of it. One of them is the bug.
  if S.floor_dead then
    local f = S.floor_dead
    w("*** FLOOR DEAD -- parity contradiction. Mapping stopped. ***")
    w("")
    w("  " .. f.text)
    w("")
    w(("  cell %s"):format(f.cell))
    w(("    had: %-6s  because %s"):format(f.had, f.had_why))
    w(("    got: %-6s  because %s"):format(f.got, f.got_why))
    w("")
    w("  Parity is fixed at floor generation, so both cannot be true: one of")
    w("  those two claims comes from a bug. Everything below is the state as it")
    w("  stood at the moment of death, frozen.")
    w("")
    w(("  map_origin=%s  player_tile=%s,%s"):format(
      S.map_origin and (S.map_origin.wrx .. "," .. S.map_origin.wrz) or "nil",
      tostring(S.last_ptx), tostring(S.last_ptz)))
    w("")
  end
  -- solo is shown because it GATES a rule (an unobserved lock counts as a bonus
  -- key only when nobody else could have opened a door before we saw it locked)
  -- and is otherwise invisible. Both halves are printed: solo requires our own
  -- marker to have been classified AND no other party slot to have been seen,
  -- so "player_seen=false" tells you marker detection never worked, which is a
  -- different problem from actually being in a group.
  w(("base=%s  boss=%s  rooms=%s  crit=%s  rounds=%s  unmatched_locks=%s")
    :format(tostring(meta.base), tostring(meta.boss), tostring(meta.nrooms),
            tostring(meta.ncrit), tostring(meta.rounds), tostring(meta.unmatched_locks)))
  w(("solo=%s  (player_seen=%s  group_seen=%s)")
    :format(tostring(S.player_seen and not S.group_seen),
            tostring(S.player_seen), tostring(S.group_seen)))
  w("")
  w("CELLS  (parity | parent | reason | images)")
  local order = {}
  for ck in pairs(rooms_by_cell) do order[#order + 1] = ck end
  table.sort(order, function (a, b)
    local ax, ay = a:match("^(%-?%d+),(%-?%d+)$")
    local bx, by = b:match("^(%-?%d+),(%-?%d+)$")
    ay, by = tonumber(ay), tonumber(by)
    if ay ~= by then return ay < by end
    return tonumber(ax) < tonumber(bx)
  end)
  for _, ck in ipairs(order) do
    local c = rooms_by_cell[ck]
    w(("  %-6s %-8s parent=%-6s  %s"):format(ck, parity_state[ck] or "unknown",
      parity_parent[ck] or "-", table.concat(c.images, ",")))
    w(("           reason: %s"):format(why[ck] or "(none -- never assigned)"))
  end
  w("")
  w("EVIDENCE -- resource sightings (all, with verdict)")
  local any = false
  for ck, bag in pairs(S.resource_sightings) do
    for name in pairs(bag) do
      any = true
      w(("  %-6s %-28s verdict=%s"):format(ck, name,
        tostring(SET.res.verdict(name) or "no inference (top tier)")))
    end
  end
  if not any then w("  (none)") end
  w("")
  w("EVIDENCE -- keys")
  any = false
  for kn, st in pairs(keys_state) do
    any = true
    w(("  %-18s found=%-6s lock=%-6s trusted_found=%s"):format(kn,
      tostring(st.found), tostring(st.lock), tostring(meta.found_of[kn])))
  end
  if not any then w("  (none)") end
  w("")
  w("EVIDENCE -- keybag (held, TTL-live)")
  any = false
  for name, tick in pairs(S.keybag_state) do
    if S.keybag_tick - tick <= 60 then any = true; w("  " .. name) end
  end
  if not any then w("  (none)") end
  w("")
  -- Causal ledger: fact mints + key-found events in the order they happened,
  -- floor-relative timestamps. This is the "run it back" view a frozen
  -- snapshot cannot give -- WHEN each proof was minted and what key evidence
  -- arrived before it (the purple_corner death took an archaeology session
  -- to reconstruct exactly this ordering from reason-string fossils).
  w("FACT LEDGER (mint order)")
  if #(S.parity_ledger or {}) == 0 then w("  (empty)") else
    for _, line in ipairs(S.parity_ledger) do w("  " .. line) end
  end
  w("")
  w("DIAGNOSTICS")
  if #diag == 0 then w("  (clean)") else
    for _, d in ipairs(diag) do w("  " .. d) end
  end
  local text = table.concat(out, "\n") .. "\n"
  SET.dev_save("parity_dump.txt", text)
  -- Death reports are CATALOGUED, one file per death, named by unix time so they
  -- sort chronologically. A floor can only die once (compute_parity returns
  -- early afterwards), so there is no collision to worry about. Written
  -- unconditionally, unlike everything else here -- this is not a diagnostic,
  -- it is the entire output of a floor that failed.
  --
  -- FLAT FILES, NOT A deathDumps/ SUBDIR. saveconfig cannot create directories:
  -- the C side is a bare fopen(path, "wb"), and bolt's whole filesystem surface
  -- is loadconfig / saveconfig / loadfile -- there is no mkdir to call and no
  -- way to fake one. A subdir would therefore work only where somebody had
  -- already made it by hand, so every fresh install would silently lose its
  -- dumps. The prefix groups these files the same way a folder would, and
  -- unix seconds are fixed-width until 2286, so plain name sort IS time order.
  if S.floor_dead and not S.death_saved then
    S.death_saved = true
    local ts = unix_now()
    bolt.saveconfig(("deathdump_%s.txt"):format(ts and tostring(ts) or "unknown"), text)
    -- Latest death also at a fixed path: one place to look that does not need
    -- you to work out which timestamp is newest. Reset to "alive" by
    -- wipe_floor_state, so it always describes the floor you are on.
    bolt.saveconfig("floor_dead.txt", text)
  end
end

-- Serialise rooms_by_cell to rooms.txt, sorted for stability. Only rewrites
-- the file when the hash changes so tools tailing it don't re-fire.
local function dump_rooms()
  compute_parity()
  local cells = {}
  for _, c in pairs(rooms_by_cell) do cells[#cells + 1] = c end
  table.sort(cells, function (a, b)
    if a.gz ~= b.gz then return a.gz < b.gz end
    return a.gx < b.gx
  end)
  local lines = {}
  for _, c in ipairs(cells) do
    lines[#lines + 1] = string.format("%d,%d|%d,%d|%s",
      c.gx, c.gz, math.floor(c.sx + 0.5), math.floor(c.sy + 0.5),
      table.concat(c.images, ","))
  end
  local out = table.concat(lines, "\n") .. "\n"
  local h = string.format("%d|%s", #cells, out:sub(1, 80))
  if h ~= rooms_last_hash then
    rooms_last_hash = h
    SET.dev_save("rooms.txt", out)
  end

  -- Derive key.lock coords from the graph. Any color_shape overlay found in
  -- an UNOPENED cell is the key required to open that door -> that cell's
  -- coords are the lock.
  --
  -- STICKY, like .found and resource_sightings: only a floor wipe clears it.
  -- A lock is a permanent FACT about the floor (keys pair 1:1 with doors, fixed
  -- at generation), not an ephemeral observation. It was previously rebuilt from
  -- scratch every dump from the currently-visible overlays, which made it
  -- self-defeating: the overlay only exists while the door is CLOSED, but the
  -- inference needs the door OPENED. Concretely -- door shut: lock=0,7 known but
  -- the key's pickup room is not, so nothing can be inferred; door opened:
  -- pickup room learned and proven bonus, so the lock is provably bonus too --
  -- and lock has just been erased. The two halves of the evidence could never
  -- coexist, which is the whole point of the temporal propagator: keys and their
  -- doors are seen at different times.
  --
  -- The stale-entry risk the old code feared is handled by distrusting a
  -- CONFLICTING re-binding rather than by forgetting every tick.
  -- KEY_COLORS / KEY_SHAPES / key_lower are declared at file scope so both
  -- this loop and on_icon_event's keybag path share the same canonical set.
  -- Anchor gate: lock bindings are STICKY and keyed by cell -- persisting
  -- them from relative fallback coordinates plants them on wrong cells
  -- forever (same failure class as the base-seed poisoning).
  for _, c in ipairs(S.close_anchor_x and cells or {}) do
    local is_unopened = false
    for _, n in ipairs(c.images) do
      if n:sub(1, 9) == "UNOPENED_" then is_unopened = true; break end
    end
    if is_unopened then
      for _, n in ipairs(c.images) do
        local kn = key_lower(n)
        if kn then
          local ck = string.format("%d,%d", c.gx, c.gz)
          keys_state[kn] = keys_state[kn] or {}
          local prior = keys_state[kn].lock
          if prior and prior ~= ck then
            -- One key opens one door. Two different cells claiming the same key
            -- means a detection error, so trust neither: drop the binding and
            -- report it rather than silently keeping whichever came last.
            SET.dev_save("keys_diag.txt", ("CRITICAL: key %s claimed by two locks (%s and %s) -- binding dropped\n")
              :format(kn, prior, ck))
            keys_state[kn].lock = false      -- false == poisoned, distinct from nil
          elseif keys_state[kn].lock == nil then
            keys_state[kn].lock = ck
          end
        end
      end
    end
  end

  -- Ship key state to the keys panel. Deduped so a stable set doesn't cause
  -- 4x/sec DOM rebuilds. Merges keys_state (found/lock/parity) with the live
  -- keybag TTL set (held) so a key can be shown even if it's never been
  -- observed on the map yet.
  if keys_browser then
    local merged = {}
    for name, st in pairs(keys_state) do
      merged[name] = { found = st.found, lock = st.lock, parity = st.parity }
    end
    for name, seen_tick in pairs(S.keybag_state) do
      if S.keybag_tick - seen_tick <= 60 then
        merged[name] = merged[name] or {}
        merged[name].held = true
      end
    end
    local kj = { "{" }
    local first = true
    for name, st in pairs(merged) do
      if not first then kj[#kj + 1] = "," end
      first = false
      kj[#kj + 1] = string.format('"%s":{"found":%s,"lock":%s,"parity":"%s","held":%s}',
        name,
        st.found and ('"' .. st.found .. '"') or "null",
        st.lock  and ('"' .. st.lock  .. '"') or "null",
        st.parity or "unknown",
        st.held and "true" or "false")
    end
    kj[#kj + 1] = "}"
    local kmsg = "key_state:" .. table.concat(kj)
    if kmsg ~= _keys_state_msg_last then
      _keys_state_msg_last = kmsg
      keys_browser:sendmessage(kmsg)
    end
  end

  -- Send held-key list to the rooms panel so it can white-outline key doors
  -- whose key we're carrying. Reuses S.keybag_state (TTL-based liveness).
  if rooms_browser then
    local held = {}
    for name, seen_tick in pairs(S.keybag_state) do
      if S.keybag_tick - seen_tick <= 60 then held[#held + 1] = name end
    end
    table.sort(held)
    local hmsg = "held_keys:" .. table.concat(held, ",")
    if hmsg ~= _held_keys_msg_last then
      _held_keys_msg_last = hmsg
      rooms_browser:sendmessage(hmsg)
    end
  end

  -- Send to the rooms panel too. Deduped by message body so a stable graph
  -- doesn't force the DOM to rebuild every dump tick.
  if rooms_browser then
    -- Self-healing push: every ~5s (20 dumps at 4/s) clear the dedupe caches
    -- so a full re-send goes out even when nothing changed. A message dropped
    -- anywhere (page-load race, recreated browser) then heals within one
    -- interval instead of persisting until the map happens to change.
    S.force_push_n = (S.force_push_n or 0) + 1
    if S.force_push_n >= 20 then
      S.force_push_n = 0
      _rooms_msg_last = ""
      _held_keys_msg_last = ""
      S.hdr_msg_last = nil
      S.dead_msg_last = nil
    end
    -- Floor-dead banner. The grid freezes on death (compute_parity returns
    -- early), and a frozen grid is indistinguishable from a live one -- so the
    -- panel has to say so out loud, or you go on trusting a map that stopped
    -- being true. Empty reason = alive, which is what a new floor sends.
    local dmsg = "dead:" .. (S.floor_dead and S.floor_dead.text or "")
    if dmsg ~= S.dead_msg_last then
      S.dead_msg_last = dmsg
      rooms_browser:sendmessage(dmsg)
    end
    -- NB: named jbuf, not json -- a local called `json` here would shadow the
    -- json module for the whole block. Encode the image list with json.encode
    -- rather than by hand: the hand-rolled version emitted [""] (an array
    -- holding one empty string) for an empty list, which the panel rendered as
    -- a blank grey badge. Array encoding walks ipairs, so the output stays
    -- byte-stable and the message dedupe below still works.
    local jbuf = { "[" }
    for i, c in ipairs(cells) do
      if i > 1 then jbuf[#jbuf + 1] = "," end
      local pk = c.gx .. "," .. c.gz
      jbuf[#jbuf + 1] = string.format('{"gx":%d,"gz":%d,"parity":"%s","images":%s}',
        c.gx, c.gz, parity_state[pk] or "unknown", json.encode(c.images))
    end
    jbuf[#jbuf + 1] = "]"
    local msg = "rooms:" .. table.concat(jbuf)
    if msg ~= _rooms_msg_last then
      _rooms_msg_last = msg
      rooms_browser:sendmessage(msg)
    end
    -- Header stats: "opened / crit-opened" (right) and rooms/min (left).
    -- RPM = OPENED rooms (body is not an UNOPENED_ template) / minutes since
    -- floor start (SET.timer.start_us, reset every floor change).
    local open_n, crit_open_n = 0, 0
    for _, c in ipairs(cells) do
      local body
      for _, nm in ipairs(c.images) do if is_room_body(nm) then body = nm; break end end
      if body and body:sub(1, 9) ~= "UNOPENED_" then
        open_n = open_n + 1
        if parity_state[c.gx .. "," .. c.gz] == "crit" then crit_open_n = crit_open_n + 1 end
      end
    end
    -- RPM freeze on leave / reset on new floor. ONLY a real in-floor reading
    -- (>=0.1 min elapsed on the floor timer) updates the stored figure; every
    -- other state holds it. This is what stops the leave-floor 0.0 flash: on
    -- leaving, the floor timer's start_us resets on the load jump ~4s before
    -- S.floor_active falls (its debounce), so the live branch used to divide
    -- open_n by a near-zero clock, clamp to "0.0", and -- worst of all --
    -- overwrite S.rpm_last with that 0.0, so the freeze then held 0.0. Now a
    -- sub-0.1-min clock just freezes the last real value instead. wipe_floor_state
    -- resets S.rpm_last to "0.0" on a new floor, so entry still shows 0.0 (the
    -- clamped placeholder the header wants) and climbs from there.
    local rpm
    local t0   = SET.timer and SET.timer.start_us
    local mins = t0 and ((bolt.time() - t0) / 60e6) or 0
    if (S.floor_active or not floor_gate_armed()) and mins >= 0.1 then
      rpm = string.format("%.1f", open_n / mins)
      S.rpm_last = rpm
    else
      rpm = S.rpm_last or "0.0"
    end
    -- Sync badge: present while the sidecar exists OR the user has the toggle
    -- on (so "no party code" is visible as a red dot instead of silence); an
    -- empty third field tells the panel to hide the indicator entirely.
    local sync_part = ""
    if SET.sync and (SET.sync.browser or SET.get("sync_enabled", false)) then
      -- SY.peers counts OTHERS (relay's joined.peers excludes the joiner);
      -- the badge shows the room total including ourself.
      sync_part = "|" .. tostring(SET.sync.status) .. "|" .. tostring((SET.sync.peers or 0) + 1)
    end
    local hdr = "hdr:" .. rpm .. "|" .. open_n .. " / " .. crit_open_n .. sync_part
    if hdr ~= S.hdr_msg_last then
      S.hdr_msg_last = hdr
      rooms_browser:sendmessage(hdr)
    end
  end
end

-- ============================================================================
-- Path drawing (disabled for now — kept for later): draws a line from the
-- ICON_BASE room, through connected passage rooms (2WAY/3WAY/4WAY/DE),
-- to the PLAYER_RED room. DE_* label swap in img_signatures.txt stays
-- applied. Uncomment this block and the two others below to re-enable.
-- ============================================================================
--[[
local LINE_R, LINE_G, LINE_B, LINE_A = 255, 217, 90, 220   -- gold-ish
local line_surface
do
  local buf = bolt.createbuffer(4)
  buf:setuint8(0, LINE_R)
  buf:setuint8(1, LINE_G)
  buf:setuint8(2, LINE_B)
  buf:setuint8(3, LINE_A)
  line_surface = bolt.createsurfacefromrgba(1, 1, buf)
end
local LINE_THICKNESS = 4

local function name_should_tint(name)
  if not name then return false end
  local pfx = name:sub(1, 4)
  return pfx == "2WAY" or pfx == "3WAY" or pfx == "4WAY" or name:sub(1, 3) == "DE_"
end

-- Door signature per room type. On screen: N = -y, S = +y, E = +x, W = -x.
local ROOM_DOORS = {
  ["DE_NORTH"] = { n=true },
  ["DE_SOUTH"] = { s=true },
  ["DE_EAST"]  = { e=true },
  ["DE_WEST"]  = { w=true },
  ["2WAY_NS"]  = { n=true, s=true },
  ["2WAY_EW"]  = { e=true, w=true },
  ["2WAY_NE"]  = { n=true, e=true },
  ["2WAY_NW"]  = { n=true, w=true },
  ["2WAY_ES"]  = { e=true, s=true },
  ["2WAY_SW"]  = { s=true, w=true },
  ["3WAY_NES"] = { n=true, e=true, s=true },
  ["3WAY_NEW"] = { n=true, e=true, w=true },
  ["3WAY_NSW"] = { n=true, s=true, w=true },
  ["3WAY_ESW"] = { e=true, s=true, w=true },
  ["4WAY"]     = { n=true, e=true, s=true, w=true },
}
ROOM_DOORS["3WAY_NORTH_EAST_SOUTH"] = ROOM_DOORS["3WAY_NES"]
ROOM_DOORS["3WAY_NORTH_EAST_WEST"]  = ROOM_DOORS["3WAY_NEW"]
ROOM_DOORS["3WAY_NORTH_SOUTH_WEST"] = ROOM_DOORS["3WAY_NSW"]
ROOM_DOORS["3WAY_EAST_SOUTH_WEST"]  = ROOM_DOORS["3WAY_ESW"]

local path_base     = nil
local path_player   = nil
local path_passages = {}
--]]

-- ============================================================================
-- Tracker panel — hidden by default; TRACKER_PANEL_VISIBLE controls display.
-- ============================================================================
local TRACKER_W, TRACKER_H = 440, 560
local tracker_x, tracker_y = 40, 40
do
  local saved = SET.get("tracker_pos", nil)
  if saved then tracker_x, tracker_y = saved[1], saved[2] end
end
local function attach_tracker_handlers(b)
  b:onreposition(function (event)
    local nx, ny = event:xywh()
    SET.set("tracker_pos", { nx, ny })
  end)
  b:onmessage(function (msg)
    -- Handlers wired in the block below; forwarded through a shared function
    -- when we adopt the browser here.
    if _tracker_on_msg then _tracker_on_msg(msg) end
  end)
end
open_tracker_browser = function ()
  if tracker_browser then return end
  tracker_x, tracker_y = SET.clamp(tracker_x, tracker_y, TRACKER_W, TRACKER_H)
  tracker_browser = bolt.createembeddedbrowser(
    tracker_x, tracker_y, TRACKER_W, TRACKER_H, "plugin://panel.html")
  attach_tracker_handlers(tracker_browser)
  panel_dirty = true   -- resend state to the freshly-opened panel
  -- Hash dedup must not skip a fresh browser: push_panel compares against the
  -- last SENT state, but this browser instance has received nothing. Without
  -- the reset, reopening the panel over an unchanged queue shows empty.
  panel_last_hash = ""
  panel_last_named = ""
end
close_tracker_browser = function ()
  if not tracker_browser then return end
  tracker_browser:close(); tracker_browser = nil
end
if TRACKER_PANEL_VISIBLE then open_tracker_browser() end

-- Resource panel — a compact live list of unnamed 3D models near the player.

-- Icon panel — dedicated browser for the icon queue and ignored list. Kept
-- independent from the resource panel so their positions/visibility can be
-- toggled separately.

-- Rooms panel - live 8x8 grid showing the detected room graph. Independent
-- position + visibility flag so it can sit alongside the other panels.
local ROOMS_PANEL_W, ROOMS_PANEL_H = 382, 402
-- Default = the user's live position (top-right corner area), captured
-- 2026-07-27 alongside the capture-zone defaults. SET.clamp pulls it on-screen
-- for smaller windows.
local rooms_x, rooms_y = 1721, 16
do
  local saved = SET.get("rooms_panel_pos", nil)
  if saved then rooms_x, rooms_y = saved[1], saved[2] end
end
local _rooms_msg_last = ""
local _held_keys_msg_last = ""

-- Persistent per-shape camera rotation (pitch/yaw/roll/scale/tx/ty) used by
-- both panels' key rasterisers. Loaded here so open_rooms_browser and
-- open_keys_browser (defined below) can close over the helpers.
local _shape_rot_body = SET.load_or_seed("shape_rot.txt") or ""
local function shape_rot_msg()
  if #_shape_rot_body == 0 then return nil end
  return "shape_rot:" .. _shape_rot_body
end
-- Persists to disk and forwards to the other panel so both stay in sync.
local function on_shape_rot_save(body, from)
  if type(body) ~= "string" or #body == 0 then return end
  _shape_rot_body = body
  bolt.saveconfig("shape_rot.txt", body)
  local msg = "shape_rot:" .. body
  if from ~= "keys"  and keys_browser  then keys_browser:sendmessage(msg)  end
  if from ~= "rooms" and rooms_browser then rooms_browser:sendmessage(msg) end
end

-- ============================================================================
-- Click-through map. rooms_browser is now map.html: a 60px header BAR (visible,
-- draggable) that ALSO renders the grid off-DOM -- the real CSS chrome via a
-- data:-URI SVG foreignObject, icons composited on top -- and POSTs "px:<E>|"
-- + RGBA frames. Lua feeds them into a surface and blits it below the bar, so
-- the map area is pure pixels and intercepts no input (clicks / middle-drag
-- pass through). The map renders 1:1 at the on-screen edge E = 382 * scale.
-- ============================================================================
-- The bar browser is MAP_HEADER_H tall (the client's 60px minimum) but only the
-- top MAP_VIS_H is a visible thin header; the map surface is drawn starting just
-- below the visible bar, on top of the transparent remainder (that overlapped
-- strip stays a small click dead-zone -- the accepted cost of the slim header).
local MAP_HEADER_H = 60
local MAP_VIS_H = 20
local function map_edge() return math.floor(ROOMS_PANEL_W * ((SET.rooms_scale or 100) / 100) + 0.5) end

-- Re-ship atlases + shape rot, tell the page its render size, reset dedupe
-- caches so a freshly (re)loaded page repaints fully. Shared by open + ready.
local function reprime_map()
  if not rooms_browser then return end
  rooms_browser:sendmessage("size:" .. map_edge())
  if SET.icons then local a = SET.icons.keys_atlas_msg(); if #a > 9 then rooms_browser:sendmessage(a) end end
  if build_img_atlas_msg then local a = build_img_atlas_msg(); if a and #a > 0 then rooms_browser:sendmessage(a) end end
  local srmsg = shape_rot_msg(); if srmsg then rooms_browser:sendmessage(srmsg) end
  _rooms_msg_last = ""; _held_keys_msg_last = ""
  S.hdr_msg_last = nil; S.dead_msg_last = nil
end

open_rooms_browser = function ()
  if rooms_browser then return end
  if not S.map_surface then S.map_surface = bolt.createsurface(1024, 1024) end
  local edge = map_edge()
  rooms_x, rooms_y = SET.clamp(rooms_x, rooms_y, edge, MAP_VIS_H + edge)
  rooms_browser = bolt.createembeddedbrowser(
    rooms_x, rooms_y, edge, MAP_HEADER_H, "plugin://map.html")
  rooms_browser:onreposition(function (event)
    local nx, ny = event:xywh()
    rooms_x, rooms_y = nx, ny
    SET.set("rooms_panel_pos", { nx, ny })
  end)
  rooms_browser:onmessage(function (msg)
    -- Pixel frame: "px:<edge>|" + edge*edge*4 RGBA -> surface region.
    if msg:sub(1, 3) == "px:" then
      local bar = msg:find("|", 4, true)
      if bar and S.map_surface then
        local e = tonumber(msg:sub(4, bar - 1))
        if e and e >= 1 and e <= 1024 then
          S.map_surface:subimage(0, 0, e, e, msg:sub(bar + 1))
          S.map_frame_edge = e
          S.map_frame_ready = true
        end
      end
      return
    end
    if msg == "ready" then
      reprime_map()
      if #_rooms_msg_last > 0 then rooms_browser:sendmessage(_rooms_msg_last) end
      _rooms_msg_last = ""
      return
    end
    if msg:sub(1, 11) == "render_err:" then
      SET.dev_save("render_err.txt", msg:sub(12) .. "\n")
      return
    end
    local sr = msg:match("^save_shape_rot:(.+)$")
    if sr then on_shape_rot_save(sr, "rooms"); return end
  end)
  reprime_map()
end
close_rooms_browser = function ()
  if rooms_browser then rooms_browser:close(); rooms_browser = nil end
  -- Surface + last frame kept so a reopen / size change shows the last map
  -- immediately; the swap blit is gated on rooms_browser so nothing shows closed.
end


-- Same wire format as the keys atlas but sourced from dg-map-tracker's own
-- img_signatures.txt - contains ICON_BASE / ICON_BOSS / DOOR_* / passages.
local _img_atlas_msg = nil
build_img_atlas_msg = function ()
  if _img_atlas_msg then return _img_atlas_msg end
  local raw = SET.load_or_seed("img_signatures.txt")
  if not raw then return "" end
  local lines = {}
  for line in raw:gmatch("[^\r\n]+") do
    local name, w, h, hex = line:match("^%s*([%w_]+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%x+)%s*$")
    if name and w and h and hex then
      lines[#lines + 1] = string.format("%s|%s|%s|%s", name, w, h, hex)
    end
  end
  _img_atlas_msg = "img_atlas:" .. table.concat(lines, "\n")
  return _img_atlas_msg
end

if ROOMS_PANEL_VISIBLE then open_rooms_browser() end

-- Keys panel - 8x8 matrix of the 63 key icons (gold_shield missing). Cells
-- render the icon from the bundled key-icon atlas plus where the key was found and
-- where its lock is. Dim if not seen yet; border colour tracks parity.
local KEYS_PANEL_W, KEYS_PANEL_H = 520, 576
local keys_x, keys_y = 1130, 640
do
  local saved = SET.get("keys_panel_pos", nil)
  if saved then keys_x, keys_y = saved[1], saved[2] end
end
local _keys_state_msg_last = ""
open_keys_browser = function ()
  if keys_browser then return end
  keys_x, keys_y = SET.clamp(keys_x, keys_y, KEYS_PANEL_W, KEYS_PANEL_H)
  keys_browser = bolt.createembeddedbrowser(
    keys_x, keys_y, KEYS_PANEL_W, KEYS_PANEL_H, "plugin://keys.html")
  keys_browser:onreposition(function (event)
    local nx, ny = event:xywh()
    SET.set("keys_panel_pos", { nx, ny })
  end)
  keys_browser:onmessage(function (msg)
    local body = msg:match("^save_shape_rot:(.+)$")
    if body then on_shape_rot_save(body, "keys") end
  end)
  -- Ship the atlas the moment the browser is up.
  local msg = SET.icons and SET.icons.keys_atlas_msg() or ""
  if #msg > 0 then keys_browser:sendmessage(msg) end
  local srmsg = shape_rot_msg()
  if srmsg then keys_browser:sendmessage(srmsg) end
  _keys_state_msg_last = ""    -- force a fresh state push next tick
end
close_keys_browser = function ()
  if not keys_browser then return end
  keys_browser:close(); keys_browser = nil
end
if KEYS_PANEL_VISIBLE then open_keys_browser() end

-- Look up dims for a given hex signature by consulting the learned queue.
-- Panel sends the signature bytes back to us so index-race is impossible; we
-- still need the (w, h) which the panel doesn't include in the message.
local function lookup_dims_by_hex(hex)
  local wanted = hex_to_bytes(hex)
  local meta = learned[wanted]
  if meta then return meta.w, meta.h, wanted end
  return nil
end

_tracker_on_msg = function (msg)
  if msg == "mode:queue"         then sidebar_mode = "queue";      panel_dirty = true; return
  elseif msg == "mode:ignored"    then sidebar_mode = "ignored";    panel_dirty = true; return
  elseif msg == "mode:classified" then sidebar_mode = "classified"; panel_dirty = true; return
  elseif msg == "clear_queue"     then learned = {}; panel_dirty = true; return
  end
  -- name:<hex>:<name>
  local hex, name = msg:match("^name:(%x+):([%w_]+)$")
  if hex and name then
    -- Reject duplicates by name.
    if signature_names[name] then return end
    local w, h, bytes = lookup_dims_by_hex(hex)
    if not w or not h then return end
    local prior = SET.load_or_seed("img_signatures.txt") or ""
    if not prior:match("\n$") and #prior > 0 then prior = prior .. "\n" end
    bolt.saveconfig("img_signatures.txt", prior .. name .. "|" .. w .. "|" .. h .. "|" .. hex .. "\n")
    -- Update runtime state immediately so the icon moves out of queue without
    -- waiting for the next reload cycle.
    signature_catalog[bytes] = name
    signature_names[name]    = bytes
    signature_meta[name]     = { w = w, h = h }
    learned[bytes]           = nil
    known_dims[w * 65536 + h] = true
    panel_dirty = true
    return
  end
  -- ignore:<hex>
  local ign_hex = msg:match("^ignore:(%x+)$")
  if ign_hex then
    local w, h, bytes = lookup_dims_by_hex(ign_hex)
    if not w or not h then return end
    local prior = SET.load_or_seed("img_ignored.txt") or ""
    if not prior:match("\n$") and #prior > 0 then prior = prior .. "\n" end
    bolt.saveconfig("img_ignored.txt", prior .. w .. "|" .. h .. "|" .. ign_hex .. "\n")
    ignored_by_sig[bytes] = { w = w, h = h }
    learned[bytes]        = nil
    known_dims[w * 65536 + h] = true
    panel_dirty = true
    return
  end
end
-- _tracker_on_msg forward-referenced by attach_tracker_handlers. Trailing
-- `end` closes the assignment expression above.

-- ============================================================================
-- Render2d handler — the core capture loop.
-- ============================================================================
bolt.onrender2d(function (event)
  if not PLUGIN_ENABLED then return end
  local vpi = event:verticesperimage()
  -- vertexcount/vpi == the fork's imagecount(); computed portably so the
  -- plugin runs on stock bolt (imagecount only exists on the hidden_mask fork).
  local n = math.floor(event:vertexcount() / vpi)
  -- Floor timer: read the game clock out of the keybag region (if enabled).
  -- Shared 5Hz gate: a seconds-resolution clock gains nothing from 60Hz.
  if SET.timer.read and SET.scan_frame then SET.timer.scan2d(event, vpi, n) end
  SET.examine.scan2d(event, vpi, n)   -- skill-door examine box: corner scan
  -- FLOOR_ICON pass: ground-truth floor presence (drives the floor gate in
  -- the swap handler -- present = inside a DG floor, absent = outside or
  -- between floors). Dims-prefiltered like the close button; FRESH pixel
  -- reads, because reused atlas slots cache stale sigs exactly at floor
  -- transitions, the moment this signal matters most. 5Hz gate is fine:
  -- the 0.8s debounce upstream tolerates 200ms detection latency.
  local floor_icon_sig = signature_names["FLOOR_ICON"]
  -- Outer-gate diagnostics: dims34=0 alone cannot distinguish "pass skipped"
  -- from "pass ran, no 34x34 drawn". Count batches, flag-true batches, and
  -- pass entries separately so the next read pins which gate is the dead one.
  S.fg_batches = (S.fg_batches or 0) + 1
  if SET.scan_frame then
    S.fg_scan2d = (S.fg_scan2d or 0) + 1
    S.scan2d_seen = true   -- consumption mark: lets the swap handler retire the flag
  end
  if not floor_icon_sig then S.fg_nosig = (S.fg_nosig or 0) + 1 end
  if floor_icon_sig and SET.scan_frame then
    S.fg_pass = (S.fg_pass or 0) + 1
    local fim = signature_meta["FLOOR_ICON"]
    local fiw, fih = fim and fim.w or 0, fim and fim.h or 0
    for fi = 0, n - 1 do
      local fv = fi * vpi + 1
      local ax, ay, aw, ah = event:vertexatlasdetails(fv)
      if aw == fiw and ah == fih then
        -- Fresh read + cache refresh: transition-time staleness matters here.
        local fkey = ax .. "," .. ay .. "," .. aw .. "," .. ah
        local fsig = SET.atlas_sig(event, ax, ay, aw, ah) or false
        frame_sigs[fkey] = fsig
        -- Gate diagnostics (dev): count every decision this pass makes, so a
        -- silent never-stamping gate is readable from draw_dbg instead of
        -- indistinguishable from a closed map.
        S.fg_dims = (S.fg_dims or 0) + 1
        -- Catalog match (many-to-one) so icon variants can share the name.
        if fsig and signature_catalog[fsig] == "FLOOR_ICON" then
          S.fg_hit = (S.fg_hit or 0) + 1
          S.floor_icon_us = bolt.time()
          break
        elseif fsig then
          S.fg_miss = (S.fg_miss or 0) + 1
        else
          S.fg_readfail = (S.fg_readfail or 0) + 1
        end
      end
    end
  end

  -- Auto-anchor pass: look for CLOSE_BUTTON anywhere on screen, ignoring the
  -- user-configured region. If found, snap the effective region to bracket it
  -- so the plugin works at any resolution / DG-map position without manual
  -- config. Falls back to region.txt if the close button isn't visible.
  local close_sig = signature_names["BUTTON_CLOSE"]
  local close_cx, close_cy
  -- Shared 5Hz gate: the anchor is sticky and its freshness window is 0.5s,
  -- so 200ms detection latency is inside margins. Skipped frames fall back
  -- to S.close_anchor_* exactly as frames where the button wasn't found.
  if close_sig and SET.scan_frame then
    -- Cache the atlas dims of the close button so pass 1 only touches 15x15
    -- (or whatever dims) images -- avoids sig computation for every icon.
    local meta = signature_meta["BUTTON_CLOSE"]
    local cw, ch = meta and meta.w or 0, meta and meta.h or 0
    for i = 0, n - 1 do
      local first_vert = i * vpi + 1
      local ax, ay, aw, ah = event:vertexatlasdetails(first_vert)
      if aw == cw and ah == ch then
        local sig = SET.cached_sig(event, ax, ay, aw, ah)
        if sig == close_sig then
          local xmin, ymin, xmax, ymax = SET.vertex_bounds(event, first_vert, vpi)
          if xmin then
            local cx = (xmin + xmax) * 0.5
            local cy = (ymin + ymax) * 0.5
            -- Seed guard: the candidate must land inside the configured scan
            -- region. Without this the anchor was seeded by whichever X-shaped
            -- icon rendered FIRST anywhere on screen: the sticky guard below
            -- only stops the anchor MOVING once set, it never validated the
            -- initial seed, and wipe_floor_state() clears the anchor on every
            -- floor change. Seen live -- anchor seeded at (1332.5, 466.5) while
            -- the real close button sits near (540, 54); the derived region
            -- (anchor - 880,40, 900x900) then missed the map entirely, no
            -- signatures matched, and the map stayed blank until a restart
            -- re-rolled the race. The sticky guard made it worse by then
            -- defending the wrong anchor against the real button.
            -- PADDED seed test. The close button sits at the region's top-right
            -- corner by construction (the region brackets the map), so its
            -- CENTRE rides the region edge -- and a strict test rejects it on a
            -- sub-pixel misalignment. Seen live 2026-07-27: centre 578.5 vs
            -- right edge 578.0, rejected by half a pixel on every scan, anchor
            -- never seeded, map_origin never calibrated, door highlights and
            -- ground keys dead. The seed guard exists to stop an X-icon across
            -- the screen from seeding (1332,466 vs 540,54 -- hundreds of px);
            -- a few pixels of slack does not weaken that.
            local SEED_PAD = 12
            local in_scan = cx >= region_x - SEED_PAD
                        and cx <= region_x + region_w + SEED_PAD
                        and cy >= region_y - SEED_PAD
                        and cy <= region_y + region_h + SEED_PAD
            -- Sticky-anchor guard: reject hits far from the last accepted
            -- position so a boss-room UI X-icon can't hijack an established
            -- anchor. On floor change, S.close_anchor_* is wiped so the next
            -- fresh sighting reseeds -- now only from inside the scan region.
            local ANCHOR_TOL = 150   -- px; well over camera jitter, under UI drift
            local accept = in_scan
            if accept and S.close_anchor_x and S.close_anchor_y then
              local dx = cx - S.close_anchor_x
              local dy = cy - S.close_anchor_y
              if dx * dx + dy * dy > ANCHOR_TOL * ANCHOR_TOL then accept = false end
            end
            if accept then
              S.close_anchor_x, S.close_anchor_y = cx, cy
              close_cx, close_cy = cx, cy
              -- Freshness stamp: the close button renders every frame the DG
              -- map is open, so a recent accepted sighting == map is open.
              S.close_fresh_us = bolt.time()
              break
            end
          end
        end
      end
    end
  end

  -- Region bounds. Auto-derived from CLOSE_BUTTON if we found it this frame,
  -- OR from the sticky cache if a prior frame accepted one. Falls back to the
  -- user-configured region.txt only if nothing has ever anchored (fresh floor).
  local rx1, ry1, rx2, ry2
  local anchor_x = close_cx or S.close_anchor_x
  local anchor_y = close_cy or S.close_anchor_y
  if anchor_x then
    rx1 = math.floor(anchor_x - 880)
    ry1 = math.floor(anchor_y - 40)
    rx2 = rx1 + 900
    ry2 = ry1 + 900
  else
    rx1, ry1 = region_x, region_y
    rx2, ry2 = region_x + region_w, region_y + region_h
  end

  -- Map-open gate for queue learning. The close-button anchor is STICKY so
  -- the region can keep filtering cheaply, but that means the region rect
  -- hovers over open gameview once the DG map is closed -- and the learner
  -- was queueing every uncataloged glyph that crossed it (timers, overhead
  -- text; proven live, every stray admission was map-gated with gameview
  -- positions). Learning now requires the close button accepted within
  -- the last 0.5s, i.e. the map is actually open. 0.5s of slack covers a
  -- frame or two of the button being obscured. Region-bounds FILTERING for
  -- matched images is unchanged.
  local fresh_now = bolt.time()
  local map_fresh = S.close_fresh_us ~= nil and fresh_now ~= nil
    and (fresh_now - S.close_fresh_us) < 500000

  for i = 0, n - 1 do
    local first_vert = i * vpi + 1
    local ax, ay, aw, ah = event:vertexatlasdetails(first_vert)

    -- Dims BEFORE bounds: the screen bbox costs up to 6 pcall round-trips per
    -- image, and no consumer of this loop wants anything outside 2..200 --
    -- filtering on atlas dims first (already in hand, zero extra calls) lets
    -- oversized panels and 1px separators skip the expensive measurement.
    -- Per-consumer minimums (4 for the map path) are still applied below.
    if aw and ah and aw >= 2 and aw <= 200 and ah >= 2 and ah <= 200 then

    -- Screen bounds — collect min/max over all image vertices.
    local x_min, y_min, x_max, y_max = SET.vertex_bounds(event, first_vert, vpi)
    if x_min then
      -- Only consider images whose bounding box INTERSECTS the map region --
      -- or the detected examine-box rect (see the examine module), which
      -- floats over the game view wherever the examined door is.
      local in_region = x_max >= rx1 and x_min <= rx2 and y_max >= ry1 and y_min <= ry2
      local in_exb = SET.examine.in_rect
        and SET.examine.in_rect(x_min, y_min, x_max, y_max)
      local in_exr = SET.examine.in_capture
        and SET.examine.in_capture(x_min, y_min, x_max, y_max)
      if in_region or in_exb or in_exr then
        local min_dim = (in_exb or in_exr) and 2 or 4   -- glyphs can be 2-3px narrow
        if aw >= min_dim and aw <= 200 and ah >= min_dim and ah <= 200 then
          -- Cache by atlas region; re-use sig if we've computed it already.
          local sig = SET.cached_sig(event, ax, ay, aw, ah)
          if sig then
            -- New signature? Add to learned queue -- only while the map is
            -- provably open (map_fresh) AND inside the USER-CONFIGURED region
            -- rect: the anchored 900x900 box exists as slack for
            -- room-signature MATCHING, but admitting from it sweeps up the
            -- HUD around the map (timers, counters -- seen live).
            local in_cfg = x_max >= region_x and x_min <= region_x + region_w
                       and y_max >= region_y and y_min <= region_y + region_h
            -- Queue admission: the map path, a DELIBERATE shift+click capture,
            -- or the four-corner-verified examine rect -- so uncataloged
            -- glyphs inside a REAL box surface for naming automatically (a
            -- rejected reading's missing characters land here by themselves).
            -- The structural-fallback rect never admits (heuristic).
            if ((in_cfg and map_fresh) or in_exr
                or (in_exb and SET.examine.rect_trusted()))
               and not signature_catalog[sig] and not ignored_by_sig[sig] and not learned[sig] then
              local ok_s, surf = pcall(make_surface_from_bytes, sig, aw, ah)
              learned[sig] = { w = aw, h = ah, surface = ok_s and surf or nil }
              panel_dirty = true
            end
            local matched_name = signature_catalog[sig]
            -- Examine reader input: cataloged glyphs inside the box rect.
            if matched_name and in_exb and matched_name:sub(1, 6) == "GLYPH_" then
              SET.examine.add_glyph(matched_name, x_min, y_min, x_max, y_max)
            end
            -- Room-graph collector: any matched image inside the region gets
            -- its screen-centre stashed. Grid-snap + merge happens in the
            -- swap-buffers tick below. in_region is REQUIRED here: a
            -- room-template lookalike elsewhere on screen must not feed
            -- the graph.
            if matched_name and in_region then
              if matched_name == "BUTTON_CLOSE" then
                -- Ignored here; the auto-anchor first pass already validated
                -- and cached the accepted position in S.close_anchor_*.
              elseif not NON_ROOM_NAMES[matched_name]
                     and not matched_name:match("^GLYPH_")
                     and not matched_name:match("^EXAMINE_") then
                -- Glyph/box-chrome catalog entries are text, never rooms --
                -- text matched over the open map must not feed the graph.
                room_observations[#room_observations + 1] = {
                  name = matched_name,
                  x = (x_min + x_max) * 0.5,
                  y = (y_min + y_max) * 0.5,
                }
              end
            end
          end
        end
      end
    end
    end   -- dims prefilter (2..200)
  end
end)

-- ============================================================================
-- Panel push — binary buffer format so we can reuse
-- the same JS decoder shape. Mode ids:
--   0 = queue (learned & unnamed & unignored)
--   1 = ignored
--   2 = classified (named)
-- ============================================================================
local function push_panel()
  if not tracker_browser or not panel_dirty then return end
  panel_dirty = false

  local q, ig, cl = {}, {}, {}
  for sig, meta in pairs(learned) do
    if not signature_catalog[sig] and not ignored_by_sig[sig] and meta.surface then
      q[#q + 1] = { w = meta.w, h = meta.h, sig = sig, surface = meta.surface }
    end
  end
  -- Ignored are shown from ignored_by_sig; build surfaces lazily.
  for sig, meta in pairs(ignored_by_sig) do
    if meta.w and meta.h then
      if not meta.surface then
        local ok, surf = pcall(make_surface_from_bytes, sig, meta.w, meta.h)
        if ok then meta.surface = surf end
      end
      if meta.surface then
        ig[#ig + 1] = { w = meta.w, h = meta.h, sig = sig, surface = meta.surface }
      end
    end
  end
  -- Classified: signature_names.
  for name, sig in pairs(signature_names) do
    local meta = signature_meta[name]
    if meta then
      local ok, surf = pcall(make_surface_from_bytes, sig, meta.w, meta.h)
      if ok then
        cl[#cl + 1] = { w = meta.w, h = meta.h, sig = sig, surface = surf, name = name }
      end
    end
  end

  local cmp_dim = function (a, b)
    if a.w ~= b.w then return a.w < b.w end
    if a.h ~= b.h then return a.h < b.h end
    return a.sig < b.sig
  end
  table.sort(q,  cmp_dim)
  table.sort(ig, cmp_dim)
  -- Classified is sorted by name so similar entries group together — easier
  -- to spot mislabels visually. Icon buffer and named-list are built from the
  -- same `cl` array, so they stay in sync automatically.
  table.sort(cl, function (a, b) return a.name < b.name end)

  local list
  local mode_id
  if     sidebar_mode == "queue"      then list = q;  mode_id = 0
  elseif sidebar_mode == "ignored"    then list = ig; mode_id = 1
  else                                     list = cl; mode_id = 2
  end

  local total = 16
  for _, e in ipairs(list) do
    total = total + 8 + e.w * e.h * 4
  end
  local buf = bolt.createbuffer(total)
  buf:setuint32(0,  mode_id)
  buf:setuint32(4,  #list)
  buf:setuint32(8,  #q)
  buf:setuint32(12, #ig + #cl)   -- placeholder; JS shows queue vs (ig+cl)
  local off = 16
  for _, e in ipairs(list) do
    buf:setuint32(off, e.w); off = off + 4
    buf:setuint32(off, e.h); off = off + 4
    buf:setstring(off, e.sig); off = off + e.w * e.h * 4
  end
  local hash = string.format("%d|%d|%d|%d|%d", mode_id, #list, #q, #ig, #cl)
  if hash ~= panel_last_hash then
    panel_last_hash = hash
    tracker_browser:sendmessage(buf)
    -- Also dump the queue in sidebar order so the external process.py-like
    -- script can look up entries by index.
    local snap = {}
    for _, e in ipairs(q) do
      local hex = {}
      for k = 1, #e.sig do hex[k] = string.format("%02x", string.byte(e.sig, k)) end
      snap[#snap + 1] = string.format("%d|%d|%s", e.w, e.h, table.concat(hex))
    end
    SET.dev_save("queue_snapshot.txt", table.concat(snap, "\n") .. "\n")
  end

  -- Named list — sent in the SAME order as the classified icon buffer so the
  -- panel can look up namedList[i] by the visible cell index. `cl` is already
  -- sorted by (w, h, sig).
  local names = {}
  for _, e in ipairs(cl) do names[#names + 1] = e.name end
  local named_msg = "named:" .. table.concat(names, ",")
  if named_msg ~= panel_last_named then
    panel_last_named = named_msg
    tracker_browser:sendmessage(named_msg)
  end
end

-- ============================================================================
-- Path computation + drawing (disabled — kept for later).
-- ============================================================================
--[==[
local function draw_line_segment(x1, y1, x2, y2)
  -- Only cardinal segments are needed (adjacent grid rooms are always
  -- horizontally or vertically neighbouring). Snap and stretch a 1x1 pixel
  -- surface to a thin rectangle.
  local half = math.floor(LINE_THICKNESS / 2)
  if math.abs(x1 - x2) >= math.abs(y1 - y2) then
    -- Horizontal-ish.
    local xa, xb = math.min(x1, x2), math.max(x1, x2)
    local y = math.floor((y1 + y2) * 0.5) - half
    line_surface:drawtoscreen(0, 0, 1, 1, xa, y, xb - xa, LINE_THICKNESS)
  else
    local ya, yb = math.min(y1, y2), math.max(y1, y2)
    local x = math.floor((x1 + x2) * 0.5) - half
    line_surface:drawtoscreen(0, 0, 1, 1, x, ya, LINE_THICKNESS, yb - ya)
  end
end

function draw_path()
  -- 1. Merge base + player + passages into one raw point set. Duplicates
  --    across BASE + room-icon at the same cell are handled after we snap to
  --    grid coords (below) — deduping by pixel distance here would drop the
  --    room-passage under the BASE/PLAYER marker.
  local pts = {}
  local function push_pt(x, y, tag)
    pts[#pts + 1] = { x = x, y = y, tag = tag }
  end
  push_pt(path_base.x, path_base.y, "base")
  push_pt(path_player.x, path_player.y, "player")
  for _, p in ipairs(path_passages) do push_pt(p.x, p.y, "pass") end
  if #pts < 2 then return end

  -- 2. Estimate the grid step: smallest positive pairwise dx/dy above a floor
  --    (skips near-duplicates). Do it separately per axis in case aspect
  --    differs, then take the minimum non-zero.
  -- Grid step estimator: histogram consecutive pairwise diffs into 4-px bins
  -- and pick the most common bin. Rooms are wider than any within-cell jitter,
  -- so the mode should be the true step. Falls back to a floor of 20.
  local function estimate_step(vals)
    local sorted = {}
    for _, v in ipairs(vals) do sorted[#sorted + 1] = v end
    table.sort(sorted)
    local buckets = {}
    for i = 2, #sorted do
      local d = sorted[i] - sorted[i - 1]
      if d >= 20 and d <= 100 then
        local b = math.floor(d / 4)
        buckets[b] = (buckets[b] or 0) + 1
      end
    end
    local best_b, best_c = nil, 0
    for b, c in pairs(buckets) do
      if c > best_c then best_b, best_c = b, c end
    end
    if not best_b then return nil end
    return best_b * 4 + 2   -- centre of bucket
  end
  local xs, ys = {}, {}
  for _, p in ipairs(pts) do xs[#xs + 1] = p.x; ys[#ys + 1] = p.y end
  local step_x = estimate_step(xs)
  local step_y = estimate_step(ys)
  if not step_x and not step_y then return end
  local step = math.min(step_x or math.huge, step_y or math.huge)

  -- 3. Snap to grid coords relative to base. Any grid cell hit by more than
  --    one raw point is considered a single cell — this is how we merge the
  --    BASE (or PLAYER) marker with the passage-room icon it's drawn on top of.
  local base_x, base_y = path_base.x, path_base.y
  local function snap(p)
    return math.floor((p.x - base_x) / step + 0.5),
           math.floor((p.y - base_y) / step + 0.5)
  end
  -- Cells hold their screen centre and a door set from whatever passage icon
  -- lands in them. BASE / PLAYER cells that don't have a passage icon get a
  -- permissive fallback (all 4 doors) so the endpoints don't dead-end.
  local cells = {}       -- "gx,gz" -> { x, y, gx, gz, doors, tags }
  local FULL = { n=true, e=true, s=true, w=true }
  for _, p in ipairs(pts) do
    local gx, gz = snap(p)
    local key = gx .. "," .. gz
    local doors = nil
    if p.tag == "pass" then
      -- Look up by original point → we don't store the passage name on the
      -- point, so re-scan path_passages for this exact centre.
    end
    local cell = cells[key]
    if not cell then
      cell = { x = p.x, y = p.y, gx = gx, gz = gz, doors = nil, tags = {} }
      cells[key] = cell
    end
    cell.tags[p.tag] = true
  end
  -- Attach door sets from the passage list (they carry .name).
  for _, p in ipairs(path_passages) do
    local gx, gz = snap(p)
    local cell = cells[gx .. "," .. gz]
    if cell and not cell.doors then
      cell.doors = ROOM_DOORS[p.name]
    end
  end
  -- Endpoints without a known passage type default to all-open so the path
  -- can enter/leave them.
  for _, cell in pairs(cells) do
    if not cell.doors and (cell.tags.base or cell.tags.player) then
      cell.doors = FULL
    end
    if not cell.doors then cell.doors = FULL end   -- safety
  end
  local base_key   = "0,0"
  local player_gx, player_gz = snap(path_player)
  local player_key = player_gx .. "," .. player_gz

  -- 4. BFS through cardinal neighbours, gated on the current cell's door set
  --    (one-sided — we don't require the neighbour to reciprocate).
  local prev = { [base_key] = false }
  local queue = { base_key }
  local head = 1
  -- dx, dy, door key for that direction.
  local NEI = { {1, 0, "e"}, {-1, 0, "w"}, {0, 1, "s"}, {0, -1, "n"} }
  while head <= #queue do
    local k = queue[head]; head = head + 1
    if k == player_key then break end
    local p = cells[k]
    local doors = p.doors or FULL
    for _, d in ipairs(NEI) do
      if doors[d[3]] then
        local ngx, ngz = p.gx + d[1], p.gz + d[2]
        local nk = ngx .. "," .. ngz
        if cells[nk] and prev[nk] == nil then
          prev[nk] = k
          queue[#queue + 1] = nk
        end
      end
    end
  end
  -- Diagnostic snapshot every ~1 s.
  _draw_dbg_counter = (_draw_dbg_counter or 0) + 1
  if _draw_dbg_counter >= 60 then
    _draw_dbg_counter = 0
    local sorted_keys = {}
    for k, _ in pairs(cells) do sorted_keys[#sorted_keys + 1] = k end
    table.sort(sorted_keys)
    local lines = {
      "step=" .. tostring(step),
      "base_screen=(" .. base_x .. "," .. base_y .. ")",
      "player_screen=(" .. path_player.x .. "," .. path_player.y .. ")",
      "player_grid=(" .. player_gx .. "," .. player_gz .. ")",
      "cells=" .. #sorted_keys,
      "cell_keys=" .. table.concat(sorted_keys, " "),
      "prev_has_player=" .. tostring(prev[player_key] ~= nil),
      "queue_visited=" .. tostring(#queue),
    }
    SET.dev_save("path_dbg.txt", table.concat(lines, "\n") .. "\n")
  end
  if prev[player_key] == nil then return end   -- no path via matched rooms

  -- 5. Reconstruct + draw.
  local path = {}
  local cur = player_key
  while cur do
    path[#path + 1] = cells[cur]
    cur = prev[cur]
  end
  for i = 1, #path - 1 do
    draw_line_segment(path[i].x, path[i].y, path[i+1].x, path[i+1].y)
  end
end
--]==]

-- ============================================================================
-- Resource cataloguing (render3d). We continuously fingerprint 3D models that
-- render close to the player's world position and keep a table of unknowns
-- for identification. Fingerprints are compared against `resources.txt` and
-- `resource_ignored.txt`. Each frame we dump a snapshot of the closest
-- unknowns to `resource_queue.txt` so `tracker.py` can name them by index.
-- ============================================================================
local RES_TILE_UNITS    = 512           -- world units per game tile
-- RES_NEAR_UNITS_SQ is derived from SCAN_RANGE_TILES at call time.
local ORIGIN_PT = bolt.point(0, 0, 0)

-- ============================================================================
-- Resource detection -- catalog IO, verdicts, sighting binds, queue, panel
-- live in resources.lua (interface on SET.res), as does the v2 identity
-- matcher that classification runs through (SET.res.classify).
-- ============================================================================
require("resources")({
  SET = SET, S = S,
  world_room_to_grid = world_room_to_grid,
  is_room_body = is_room_body,
  cell_at = function (ck) return rooms_by_cell[ck] end,
  unix_now = unix_now,
})
if RES_PANEL_VISIBLE then SET.res.open_panel() end

-- ============================================================================
-- Icon cataloging -- lives in icons.lua (capture, catalog, queue, panel,
-- keys-panel mesh atlas). Interface installed on SET.icons; accessors are
-- injected because room_observations and the region rects are rebound here.
-- ============================================================================
require("icons")({
  SET = SET, S = S,
  key_lower = key_lower,
  observe = function (o) room_observations[#room_observations + 1] = o end,
  dg_region = function () return region_x, region_y, region_w, region_h end,
  keybag_region = function () return keybag_x, keybag_y, keybag_w, keybag_h end,
  plugin_enabled = function () return PLUGIN_ENABLED end,
})
if ICON_PANEL_VISIBLE then SET.icons.open_panel() end

-- ============================================================================
-- Settings panel + trigger button -- merged from the former bolt-control-panel
-- plugin (2026-07-28), lives in settings_panel.lua. Self-contained: rows are
-- THIS plugin's settings via SET; the poll above applies whatever it writes.
-- ============================================================================
require("settings_panel")({ SET = SET })



-- Shader for world-space scan-range square. Vec3 position per vertex; single
-- solid colour uniform. We build 4 thin rectangles (one per edge of the
-- scan square) around the player each frame and draw them with this program.
local sr_vs = bolt.createvertexshader(
  "layout(location=0) in highp vec3 aPos;" ..
  "layout(location=1) uniform highp mat4 uViewProj;" ..
  "void main(){" ..
    "highp vec4 clip = uViewProj * vec4(aPos, 1.0);" ..
    "gl_Position = vec4(clip.x, -clip.y, clip.z, clip.w);" ..
  "}")
local sr_fs = bolt.createfragmentshader(
  "layout(location=0) out highp vec4 outColor;" ..
  "layout(location=2) uniform highp vec4 uColor;" ..
  "void main(){ outColor = uColor; }")
local sr_program = bolt.createshaderprogram(sr_vs, sr_fs)
local sr_bytes_per_vert = 12   -- vec3 float = 12 bytes
-- aPos = vec3 float32 at offset 0, stride 12. Required so the shader can bind
-- the vertex buffer's layout — missing this = silent zero draws.
sr_program:setattribute(0, 4, true, true, 3, 0, sr_bytes_per_vert)
-- Depth-occluded variant of sr_program: samples the scene depth buffer and
-- discards fragments that sit BEHIND other geometry, so a box reads as lying on
-- the floor and UNDER walls / props / players (the player-grid occlusion
-- technique). Same vertex shader + layout; adds uDepth (loc 3) + uScreenSize
-- (loc 4). Lift the quads slightly above the floor at draw time so the floor's
-- own depth doesn't occlude them (that's the "except the floor" part).
local sr_fs_occ = bolt.createfragmentshader(
  "layout(location=0) out highp vec4 outColor;" ..
  "layout(location=2) uniform highp vec4 uColor;" ..
  "layout(location=3) uniform highp sampler2D uDepth;" ..
  "layout(location=4) uniform highp vec2 uScreenSize;" ..
  "void main(){" ..
    "highp vec2 uv = vec2(gl_FragCoord.x / uScreenSize.x, 1.0 - gl_FragCoord.y / uScreenSize.y);" ..
    "highp float depthHere = texture(uDepth, uv).r;" ..
    "if (depthHere + 0.0002 < gl_FragCoord.z) discard;" ..
    "outColor = uColor;" ..
  "}")
local sr_program_occ = bolt.createshaderprogram(sr_vs, sr_fs_occ)
sr_program_occ:setattribute(0, 4, true, true, 3, 0, sr_bytes_per_vert)
local sr_view_proj = nil       -- captured from onrender3d for later drawing

local function sr_push_quad(buf, off, x1, z1, x2, z2, y)
  local function put(x, z)
    buf:setfloat32(off,     x)
    buf:setfloat32(off + 4, y)
    buf:setfloat32(off + 8, z)
    off = off + sr_bytes_per_vert
  end
  put(x1, z1); put(x2, z1); put(x2, z2)
  put(x1, z1); put(x2, z2); put(x1, z2)
  return off
end

-- Per-frame accumulator of classified-resource tile boxes to draw. Reset in
-- onrendergameview after draw. Each entry: { tx, tz, tier, y }.
local resource_boxes = {}
-- Puzzle-ghost tiles seen this frame: { tx, tz, y, lum }. Which one is
-- vulnerable is decided at DRAW time by comparing luminance across them, so
-- nothing is carried between frames -- the game rotates the vulnerable ghost on
-- a timer and a stale pick would point at the wrong target. Reset after draw.
local ghost_boxes = {}
-- Ground-key tile highlights. Populated in on_render3d whenever a mesh matches
-- a color_shape key AND passes the "grounded" guard. Reset in on_rendergameview
-- after drawing so stale entries can't linger a frame.
local key_boxes = {}
-- Meshes whose fingerprint is banked in the review queue: pink outline so
-- banked specimens are recognisable on sight. Reset each frame after draw.
local review_boxes = {}

-- Line Draw (merged from the former standalone line-draw plugin).
--
-- Renders a camera-facing ribbon either between two manual world points, or --
-- in keys mode -- from the player to every ground key the tracker's own
-- detector flagged THIS frame (the key_boxes list above, populated in
-- onrender3d). Path mode routes each key line through the room graph
-- (rooms_by_cell + S.map_origin) the tracker already maintains, instead of a
-- straight line.
--
-- The ENTIRE module body runs inside its own immediately-invoked function so
-- its ~20 helper locals get a fresh Lua-5.1 200-local budget instead of piling
-- onto the main chunk, which already sits just under that ceiling. Nothing here
-- adds a main-chunk local: state + entry points hang off SET.line (declared up
-- top), and the render/panel hooks below reach the module through it.
-- ============================================================================
;(function ()
local LD = SET.line
-- Defaults revised per the 2026-07-27 bug list: enabled ON, key tracking ON,
-- through-walls ON. keys_mode and through_walls also lost their panel rows --
-- the settings keys persist and are honoured, there is just no UI for them.
LD.enabled         = SET.get("line_enabled",        true)
LD.through_walls   = SET.get("line_through_walls",  true)
LD.keys_mode       = SET.get("line_keys_mode",      true)
LD.path_mode       = SET.get("line_path_mode",      false)
LD.thickness       = SET.get("line_thickness",      32.0)
LD.frame_keys      = {}   -- name -> {x,y,z}; rebuilt each frame from key_boxes
LD.last_keys_count = 0    -- for the panel status line only
-- Persistent per-floor key log for the HUD: name -> { clock, order }. The clock
-- is the floor-timer value captured the moment the key's mesh was first
-- identified this floor. Cleared on floor change by SET.timer.
LD.key_log         = {}
LD.key_order       = 0
-- Keys picked up (seen in the keybag) this floor: dropped from key_log and never
-- re-logged. Cleared on floor change alongside key_log.
LD.collected       = {}
LD.cam_x, LD.cam_y, LD.cam_z = 0, 0, 0
do
  local c = SET.get("line_color", { 255, 70, 70, 255 })
  LD.cr, LD.cg, LD.cb, LD.ca = c[1], c[2], c[3], c[4]
  local a = SET.get("line_point_a", { 0, 0, 0 })
  local b = SET.get("line_point_b", { 500, 0, 0 })
  LD.a = { x = a[1], y = a[2], z = a[3] }
  LD.b = { x = b[1], y = b[2], z = b[3] }
end

-- Attribute layout: vec3 pos (12) + vec4 color (16) + float edge (4) = 32 bytes.
LD.BYTES_PER_VERTEX = 32
do
  local vs = bolt.createvertexshader(
    "layout(location=0) in highp vec3 aPos;" ..
    "layout(location=1) in highp vec4 aColor;" ..
    "layout(location=2) in highp float aEdge;" ..
    "layout(location=2) uniform highp mat4 uViewProj;" ..
    "out highp vec4 vColor;" ..
    "out highp float vEdge;" ..
    "void main() {" ..
      "vColor = aColor;" ..
      "vEdge = aEdge;" ..
      "highp vec4 clip = uViewProj * vec4(aPos, 1.0);" ..
      "gl_Position = vec4(clip.x, -clip.y, clip.z, clip.w);" ..
    "}")
  -- Depth-tested: the line disappears behind walls/terrain.
  local fs = bolt.createfragmentshader(
    "in highp vec4 vColor;" ..
    "in highp float vEdge;" ..
    "layout(location=3) uniform highp sampler2D uDepth;" ..
    "layout(location=4) uniform highp vec2 uScreenSize;" ..
    "out highp vec4 fragColor;" ..
    "void main() {" ..
      "highp vec2 uvHere = vec2(gl_FragCoord.x / uScreenSize.x, 1.0 - gl_FragCoord.y / uScreenSize.y);" ..
      "highp float depthHere = texture(uDepth, uvHere).r;" ..
      "if (depthHere + 0.0002 < gl_FragCoord.z) discard;" ..
      "highp float feather = fwidth(vEdge);" ..
      "highp float coverage = 1.0 - smoothstep(1.0 - feather, 1.0, abs(vEdge));" ..
      "fragColor = vec4(vColor.rgb, vColor.a * coverage);" ..
    "}")
  -- Overlay: no depth test, so the line draws through walls/terrain.
  local fs_overlay = bolt.createfragmentshader(
    "in highp vec4 vColor;" ..
    "in highp float vEdge;" ..
    "layout(location=3) uniform highp sampler2D uDepth;" ..
    "layout(location=4) uniform highp vec2 uScreenSize;" ..
    "out highp vec4 fragColor;" ..
    "void main() {" ..
      "highp float feather = fwidth(vEdge);" ..
      "highp float coverage = 1.0 - smoothstep(1.0 - feather, 1.0, abs(vEdge));" ..
      "fragColor = vec4(vColor.rgb, vColor.a * coverage);" ..
    "}")
  LD.program         = bolt.createshaderprogram(vs, fs)
  LD.program_overlay = bolt.createshaderprogram(vs, fs_overlay)
  for _, p in ipairs({ LD.program, LD.program_overlay }) do
    p:setattribute(0, 4, true, true, 3, 0,  LD.BYTES_PER_VERTEX)  -- aPos   vec3  @ 0
    p:setattribute(1, 4, true, true, 4, 12, LD.BYTES_PER_VERTEX)  -- aColor vec4  @ 12
    p:setattribute(2, 4, true, true, 1, 28, LD.BYTES_PER_VERTEX)  -- aEdge  float @ 28
  end
end
local LD_UNIFORM_VIEWPROJ    = 2
local LD_UNIFORM_DEPTHBUFFER = 3
local LD_UNIFORM_SCREENSIZE  = 4
local LD_ROOM_GRID_STEP      = 16   -- tiles per room cell; matches the tracker

local function ld_push_v(buf, off, x, y, z, edge, r, g, b, a)
  buf:setfloat32(off,      x)
  buf:setfloat32(off + 4,  y)
  buf:setfloat32(off + 8,  z)
  buf:setfloat32(off + 12, r)
  buf:setfloat32(off + 16, g)
  buf:setfloat32(off + 20, b)
  buf:setfloat32(off + 24, a)
  buf:setfloat32(off + 28, edge)
  return off + LD.BYTES_PER_VERTEX
end

-- Build the 4 corners of a camera-facing billboard quad for segment A->B.
local function ld_billboard_corners(ax, ay, az, bx, by, bz, cx, cy, cz, half_w)
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 0.001 then return nil end
  dx, dy, dz = dx / len, dy / len, dz / len

  local mx, my, mz = (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2
  local tx, ty, tz = cx - mx, cy - my, cz - mz
  local tlen = math.sqrt(tx * tx + ty * ty + tz * tz)
  if tlen < 0.001 then tx, ty, tz, tlen = 0, 1, 0, 1 end
  tx, ty, tz = tx / tlen, ty / tlen, tz / tlen

  local rx = dy * tz - dz * ty
  local ry = dz * tx - dx * tz
  local rz = dx * ty - dy * tx
  local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
  if rlen < 0.001 then
    rx, ry, rz = dy * 0 - dz * 1, dz * 0 - dx * 0, dx * 1 - dy * 0
    rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
    if rlen < 0.001 then rx, ry, rz, rlen = 1, 0, 0, 1 end
  end
  rx, ry, rz = rx / rlen * half_w, ry / rlen * half_w, rz / rlen * half_w

  return {
    { x = ax + rx, y = ay + ry, z = az + rz, e = -1 },
    { x = ax - rx, y = ay - ry, z = az - rz, e =  1 },
    { x = bx - rx, y = by - ry, z = bz - rz, e =  1 },
    { x = bx + rx, y = by + ry, z = bz + rz, e = -1 },
  }
end

-- Path mode: route a key line through the room graph instead of straight. Reuses
-- the tracker's OWN door mapping + connectivity (cell_doors / NEI_DELTA /
-- NEI_OPP) and its world<->grid calibration (world_room_to_grid + S.map_origin),
-- so it stays consistent with the parity BFS. Cells are keyed "gx,gz" and gz runs
-- opposite world z -- see world_room_to_grid.

-- World position -> this floor's minimap grid cell (nil,nil if uncalibrated).
local function ld_world_to_grid_cell(wx, wz)
  local wrx = math.floor(math.floor(wx / RES_TILE_UNITS) / LD_ROOM_GRID_STEP)
  local wrz = math.floor(math.floor(wz / RES_TILE_UNITS) / LD_ROOM_GRID_STEP)
  return world_room_to_grid(wrx, wrz)
end

-- Minimap grid cell -> approximate world-space center of that room. Inverse of
-- world_room_to_grid: wrx = gx + origin.wrx ; wrz = origin.wrz - gz.
local function ld_grid_cell_center_world(gx, gz)
  if not S.map_origin then return nil, nil end
  local wrx = gx + S.map_origin.wrx
  local wrz = S.map_origin.wrz - gz
  local cx = (wrx * LD_ROOM_GRID_STEP + LD_ROOM_GRID_STEP / 2) * RES_TILE_UNITS
  local cz = (wrz * LD_ROOM_GRID_STEP + LD_ROOM_GRID_STEP / 2) * RES_TILE_UNITS
  return cx, cz
end

-- BFS through door connectivity, same reciprocal-door rule the tracker's parity
-- BFS uses. Returns an ordered list of "gx,gz" keys start->goal, or nil.
local function ld_find_room_path(start_key, goal_key)
  if start_key == goal_key then return { start_key } end
  if not rooms_by_cell[start_key] then return nil end
  local prev = { [start_key] = false }
  local queue = { start_key }
  local head = 1
  while head <= #queue do
    local ck = queue[head]; head = head + 1
    if ck == goal_key then
      local path, cur = {}, ck
      while cur do path[#path + 1] = cur; cur = prev[cur] end
      local n = #path
      for i = 1, math.floor(n / 2) do path[i], path[n - i + 1] = path[n - i + 1], path[i] end
      return path
    end
    local cell = rooms_by_cell[ck]
    local doors = cell_doors(cell)
    for dir, _ in pairs(doors) do
      local d = NEI_DELTA[dir]
      local nk = (cell.gx + d[1]) .. "," .. (cell.gz + d[2])
      if prev[nk] == nil then
        local ncell = rooms_by_cell[nk]
        if ncell and cell_doors(ncell)[NEI_OPP[dir]] then
          prev[nk] = ck
          queue[#queue + 1] = nk
        end
      end
    end
  end
  return nil
end

-- Segment chain from a live position to a live target, routed through the room
-- graph. Returns nil if pathing isn't possible right now (uncalibrated /
-- unmapped / disconnected) -- in path mode the caller draws nothing in that
-- case rather than a misleading straight line through walls.
--
-- Geometry: the line threads the DOOR between each consecutive room pair -- the
-- midpoint of the two cell centres, which lands on the middle of their shared
-- edge (where Dungeoneering doors sit). Because every room cell is convex, each
-- resulting segment stays wholly inside one room: player -> first door (inside
-- the player's room), door -> door (across the room between them, both points on
-- that room's boundary), last door -> key (inside the key's room). So the drawn
-- line never crosses a wall, and turns are hugged correctly.
local function ld_build_path_segments(px, py, pz, kx, ky, kz)
  if not S.map_origin then return nil end
  local pgx, pgz = ld_world_to_grid_cell(px, pz)
  local kgx, kgz = ld_world_to_grid_cell(kx, kz)
  if not pgx or not kgx then return nil end
  local cell_path = ld_find_room_path(pgx .. "," .. pgz, kgx .. "," .. kgz)
  if not cell_path then return nil end

  local hops = #cell_path
  local waypoints = { { x = px, y = py, z = pz } }
  for i = 1, hops - 1 do
    local ax, az = cell_path[i]:match("^(-?%d+),(-?%d+)$")
    local bx, bz = cell_path[i + 1]:match("^(-?%d+),(-?%d+)$")
    local acx, acz = ld_grid_cell_center_world(tonumber(ax), tonumber(az))
    local bcx, bcz = ld_grid_cell_center_world(tonumber(bx), tonumber(bz))
    if acx and bcx then
      local t = i / hops   -- linear Y lerp player -> key across the door crossings
      waypoints[#waypoints + 1] = {
        x = (acx + bcx) / 2, y = py + (ky - py) * t, z = (acz + bcz) / 2,
      }
    end
  end
  waypoints[#waypoints + 1] = { x = kx, y = ky, z = kz }

  local segs = {}
  for i = 1, #waypoints - 1 do
    local a, b = waypoints[i], waypoints[i + 1]
    segs[#segs + 1] = { a.x, a.y, a.z, b.x, b.y, b.z }
  end
  return segs
end

-- Ground-key identification, independent of the tracker's tile/room-gated
-- detector: fingerprint THIS mesh against the in-memory icon catalog and, on a
-- match, record the key's EXACT world position from its model matrix (passed in
-- as wx/wy/wz). Called from onrender3d for every rendered mesh; accumulates into
-- LD.frame_keys across the frame (consumed by LD.render, reset each swap). Only
-- a ground-height guard is applied -- which rejects the floating door-key map
-- indicators -- so a key line appears for any real ground key whose model is
-- actually being drawn, with no scan-range or calibration precondition.
local LD_IK_CUTOFF    = 400            -- absolute reject (sum-of-colour metric; see below)
local LD_IK_MARGIN    = 120            -- winner must beat nearest other key by this
local LD_IK_WINDOW    = 1              -- +/- vertex-count slack for LOD variants
local LD_GROUND_Y_TOL = RES_TILE_UNITS * 2
function LD.detect(event, wx, wy, wz, py)
  if math.abs(wy - py) > LD_GROUND_Y_TOL then return end   -- reject floating indicators
  local n = event:vertexcount()
  local has_bucket = false
  for dn = -LD_IK_WINDOW, LD_IK_WINDOW do
    if SET.icons.by_n(n + dn) then has_bucket = true; break end
  end
  if not has_bucket then return end    -- cheap bail before sampling anything
  -- Sample 5 evenly-spaced verts (position + colour), sorted by y so the compare
  -- is order-invariant -- the same fingerprint the icon catalog was built with.
  local step = math.max(1, math.floor(n / 6))
  local live = {}
  for i = 1, 5 do
    local idx = math.min(n, i * step)
    local ok_p, p = pcall(event.vertexpoint, event, idx)
    if not ok_p or not p then return end
    local x, y, z = p:get()
    local ok_c, r, g, b = pcall(event.vertexcolour, event, idx)
    if not ok_c then return end
    live[i] = {
      x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5),
      r = math.floor(r * 255 + 0.5), g = math.floor(g * 255 + 0.5), b = math.floor(b * 255 + 0.5),
    }
  end
  table.sort(live, function (a, b) return a.y < b.y end)
  -- Nearest-neighbour score against the catalog, SAME metric as the ground-key
  -- found matcher: position L1 + SUM of per-vertex colour distance (the min was
  -- blind to colour for same-shape keys -- see that matcher's note). Bind
  -- rival-relative: winner must beat the nearest DIFFERENT key by LD_IK_MARGIN.
  local best_score, best_name = math.huge, nil
  local rival_score = math.huge
  for dn = -LD_IK_WINDOW, LD_IK_WINDOW do
    local bucket = SET.icons.by_n(n + dn)
    if bucket then
      for _, entry in ipairs(bucket) do
        local pos_sum, col_sum, ok_all = 0, 0, true
        local ev_list = entry.verts_sorted
        for i = 1, 5 do
          local ev, lv = ev_list[i], live[i]
          if not ev or not lv then ok_all = false; break end
          pos_sum = pos_sum + math.abs(ev.x - lv.x) + math.abs(ev.y - lv.y) + math.abs(ev.z - lv.z)
          col_sum = col_sum + math.abs(ev.r - lv.r) + math.abs(ev.g - lv.g) + math.abs(ev.b - lv.b)
        end
        if ok_all then
          local score = pos_sum + 2 * col_sum
          if score < best_score then
            if best_name and best_name ~= entry.name and best_score < rival_score then rival_score = best_score end
            best_score, best_name = score, entry.name
          elseif (not best_name or entry.name ~= best_name) and score < rival_score then
            rival_score = score
          end
        end
      end
    end
  end
  if best_name and best_score <= LD_IK_CUTOFF and (rival_score - best_score) >= LD_IK_MARGIN then
    local kn = key_lower(best_name)   -- keep only genuine color_shape keys
    if kn then
      LD.frame_keys[kn] = { x = wx, y = wy, z = wz }
      -- First identification of this key this floor: stamp the floor-clock value.
      -- Skip if already collected (in the keybag) so a picked-up key can't return.
      if not LD.key_log[kn] and not LD.collected[kn] then
        LD.key_order = LD.key_order + 1
        LD.key_log[kn] = { clock = SET.timer.current or "-", order = LD.key_order }
      end
    end
  end
end

-- Draw the line overlay for this frame. Called near the top of onrendergameview.
-- Consumes LD.frame_keys (filled by LD.detect during this frame's onrender3d
-- passes). sr_view_proj / LD.cam_* also come from onrender3d.
function LD.render(event)
  if not LD.enabled or not sr_view_proj then return end

  local segments
  if LD.keys_mode then
    local names = {}
    for name, _ in pairs(LD.frame_keys) do names[#names + 1] = name end
    LD.last_keys_count = #names
    if #names > 0 then
      local pos = bolt.playerposition()
      if pos then
        local px, py, pz = pos:get()
        segments = {}
        for _, name in ipairs(names) do
          local k = LD.frame_keys[name]
          if LD.path_mode then
            -- Only draw a key line when a real route exists; no straight-line
            -- fallback, which would otherwise cut through walls.
            local path_segs = ld_build_path_segments(px, py, pz, k.x, k.y, k.z)
            if path_segs then
              for _, s in ipairs(path_segs) do segments[#segments + 1] = s end
            end
          else
            segments[#segments + 1] = { px, py, pz, k.x, k.y, k.z }
          end
        end
      end
    end
  elseif LD.path_mode then
    -- Manual A->B routed through the room graph. No straight-line fallback: if
    -- there's no valid route, nothing is drawn (rather than cutting through
    -- walls). Turn path mode off for a plain straight line.
    segments = ld_build_path_segments(LD.a.x, LD.a.y, LD.a.z, LD.b.x, LD.b.y, LD.b.z)
  else
    segments = { { LD.a.x, LD.a.y, LD.a.z, LD.b.x, LD.b.y, LD.b.z } }
  end
  if not segments or #segments == 0 then return end

  local vw, vh = event:size()
  local half_w = LD.thickness / 2
  local r, g, b, a = LD.cr / 255.0, LD.cg / 255.0, LD.cb / 255.0, LD.ca / 255.0
  local buf = bolt.createbuffer(#segments * 6 * LD.BYTES_PER_VERTEX)
  local off = 0
  local vertex_count = 0
  for _, seg in ipairs(segments) do
    local corners = ld_billboard_corners(
      seg[1], seg[2], seg[3], seg[4], seg[5], seg[6],
      LD.cam_x, LD.cam_y, LD.cam_z, half_w)
    if corners then
      off = ld_push_v(buf, off, corners[1].x, corners[1].y, corners[1].z, corners[1].e, r, g, b, a)
      off = ld_push_v(buf, off, corners[2].x, corners[2].y, corners[2].z, corners[2].e, r, g, b, a)
      off = ld_push_v(buf, off, corners[3].x, corners[3].y, corners[3].z, corners[3].e, r, g, b, a)
      off = ld_push_v(buf, off, corners[1].x, corners[1].y, corners[1].z, corners[1].e, r, g, b, a)
      off = ld_push_v(buf, off, corners[3].x, corners[3].y, corners[3].z, corners[3].e, r, g, b, a)
      off = ld_push_v(buf, off, corners[4].x, corners[4].y, corners[4].z, corners[4].e, r, g, b, a)
      vertex_count = vertex_count + 6
    end
  end
  if vertex_count == 0 then return end

  local m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16 = sr_view_proj:get()
  local prog = LD.through_walls and LD.program_overlay or LD.program
  prog:setuniformmatrix4f(LD_UNIFORM_VIEWPROJ, false,
    m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16)
  prog:setuniformdepthbuffer(LD_UNIFORM_DEPTHBUFFER, event)
  prog:setuniform2f(LD_UNIFORM_SCREENSIZE, vw, vh)
  local sbuf = bolt.createshaderbuffer(buf)
  prog:drawtogameview(event, sbuf, vertex_count)
end

-- ---- Line Draw panel (opened as its own sub-window, toggled from the control
-- panel via line_panel_visible, same as the rooms/keys panels). --------------
local LINE_PANEL_W, LINE_PANEL_H = 160, 220   -- narrow layout, no section chrome (2026-07-27)
local line_x, line_y = 30, 120
do
  local saved = SET.get("line_panel_pos", nil)
  if saved then line_x, line_y = saved[1], saved[2] end
end

function LD.build_state_json()
  return string.format(
    "{\"enabled\":%s,\"thickness\":%s," ..
    "\"color\":{\"r\":%d,\"g\":%d,\"b\":%d,\"a\":%d}," ..
    "\"keysCount\":%d,\"pathMode\":%s,\"pathAvailable\":%s}",
    tostring(LD.enabled), tostring(LD.thickness),
    LD.cr, LD.cg, LD.cb, LD.ca,
    LD.last_keys_count, tostring(LD.path_mode),
    tostring(S.map_origin ~= nil))
end

-- UNCONDITIONAL push, every poll tick, no dedupe. Dedupe poisoned itself
-- twice: a push sent before the page finished loading is dropped by CEF but
-- was cached as delivered, and with a static body (keysCount only changes
-- in-floor) nothing ever re-sent -- the panel sat on defaults while the
-- plugin ran the real values. ~150 bytes at 2Hz is nothing; the page guards
-- focused inputs so identical re-applies are invisible.
function LD.push_state()
  if not LD.browser then return end
  LD.push_n = (LD.push_n or 0) + 1
  LD.browser:sendmessage("state:" .. LD.build_state_json())
  -- Diag: every 20th push, record both directions' counters so a dead leg
  -- (page->plugin vs plugin->page) is readable from ld_diag.txt directly.
  if LD.push_n % 20 == 1 then
    SET.dev_save("ld_diag.txt", string.format(
      "pushes=%d  msgs_received=%d  last_msg=%s  enabled=%s keys=%s walls=%s thick=%s\n",
      LD.push_n, LD.msg_n or 0, tostring(LD.msg_last),
      tostring(LD.enabled), tostring(LD.keys_mode), tostring(LD.through_walls),
      tostring(LD.thickness)))
  end
end

function LD.on_msg(msg)
  LD.msg_n = (LD.msg_n or 0) + 1
  LD.msg_last = msg
  if msg == "refresh" then LD.push_state(); return end

  -- Header X: persist the closed state FIRST so the settings poll agrees, then
  -- close. LD.visible must flip too or apply_toggle would re-close a browser
  -- that is already gone (harmless) or fight a stale true on the next poll.
  if msg == "close_panel" then
    SET.set("line_panel_visible", false)
    LD.visible = false
    LD.close()
    return
  end

  local en = msg:match("^set_enabled:(%a+)$")
  if en then LD.enabled = (en == "true"); SET.set("line_enabled", LD.enabled); return end

  local tw = msg:match("^set_through_walls:(%a+)$")
  if tw then LD.through_walls = (tw == "true"); SET.set("line_through_walls", LD.through_walls); return end

  local km = msg:match("^set_keys_mode:(%a+)$")
  if km then
    LD.keys_mode = (km == "true"); SET.set("line_keys_mode", LD.keys_mode)
    LD.push_state(); return
  end

  local pm = msg:match("^set_path_mode:(%a+)$")
  if pm then
    LD.path_mode = (pm == "true"); SET.set("line_path_mode", LD.path_mode)
    LD.push_state(); return
  end

  local th = msg:match("^set_thickness:([%d%.]+)$")
  if th then LD.thickness = tonumber(th) or LD.thickness; SET.set("line_thickness", LD.thickness); return end

  local cr, cg, cb, ca = msg:match("^set_color:(%d+),(%d+),(%d+),(%d+)$")
  if cr then
    LD.cr, LD.cg, LD.cb, LD.ca = tonumber(cr), tonumber(cg), tonumber(cb), tonumber(ca)
    SET.set("line_color", { LD.cr, LD.cg, LD.cb, LD.ca })
    return
  end
  -- (set_a / set_b / use_player_* removed with the POINT A/B UI, 2026-07-27.
  -- LD.a/LD.b still exist for the dormant manual-line render path.)
end

LD.open = function ()
  if LD.browser then return end
  line_x, line_y = SET.clamp(line_x, line_y, LINE_PANEL_W, LINE_PANEL_H)
  LD.browser = bolt.createembeddedbrowser(
    line_x, line_y, LINE_PANEL_W, LINE_PANEL_H, "plugin://line_panel.html")
  LD.browser:onreposition(function (event)
    local nx, ny = event:xywh()
    line_x, line_y = nx, ny
    SET.set("line_panel_pos", { nx, ny })
  end)
  LD.browser:onmessage(LD.on_msg)
  -- NO push here. A push this early lands before the page loads AND poisons
  -- the dedupe cache (_state_last records a body nobody received, so the
  -- poll's re-push skips itself -- the exact "panel shows stale toggles" bug,
  -- round two). The page pulls: it sends "refresh" repeatedly until the first
  -- state lands, and refresh clears _state_last.
end
LD.close = function ()
  if not LD.browser then return end
  LD.browser:close(); LD.browser = nil
end

if LD.visible then LD.open() end
end)()   -- run the Line Draw module body (own function scope, own local budget)

-- Floor timer (self-timed stopwatch). Own function scope so its helpers don't
-- touch the main chunk's local budget (same reason as the Line Draw module).
-- Everything lives on SET.timer. tick() runs every frame from onswapbuffers and
-- does its own floor-change detection (large player-tile jump, same >128-tile
-- heuristic dg uses at process_room_observations), independent of whether the DG
-- map is being observed -- so the clock starts on floor entry and resets on each
-- floor change without waiting for the room graph.
-- ============================================================================
;(function ()
local T = SET.timer

-- (window geometry + opacity removed with the HUD window, 2026-07-27)

local function fmt(secs)
  if secs < 0 then secs = 0 end
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  local s = secs % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local TILE = 512          -- world units per tile (matches RES_TILE_UNITS)
local JUMP_TILES = 128    -- floor change => player tile moves more than this
local LOAD_GAP_FRAMES = 8 -- consecutive position-unavailable frames = a floor load

-- ============================================================================
-- Keybag timer reader. Reads the game's own floor clock out of the keybag
-- region (the timer is a row of font-glyph quads in the 2D batch) and
-- auto-calibrates the digits by watching the seconds digit tick, so there's no
-- manual training. glyphmap (learned sig->digit) persists across reloads.
-- ============================================================================
local GLYPH_MAX_PIX = 24 * 32   -- skip quads bigger than a glyph (key icons etc.)
local GLYPH_MAX_H   = 22        -- timer digits are short
local Y_TOL         = 4         -- glyphs within this many px share the timer row

local function bytes_to_hex(b)
  return (b:gsub(".", function (c) return string.format("%02x", string.byte(c)) end))
end
local function hex_to_bytes(h)
  return (h:gsub("%x%x", function (cc) return string.char(tonumber(cc, 16)) end))
end

local CAL_VERSION = 3            -- bump to force everyone to re-learn the glyphs
T.glyphmap = {}                 -- sig(raw bytes) -> digit char '0'..'9'
do
  if SET.get("floor_timer_cal_ver", 0) == CAL_VERSION then
    local raw = SET.get("floor_timer_glyphs", nil)
    if type(raw) == "table" then
      for hex, digit in pairs(raw) do T.glyphmap[hex_to_bytes(hex)] = digit end
    end
  else
    -- Algorithm changed since this calibration was saved -- discard it.
    SET.set("floor_timer_glyphs", {})
    SET.set("floor_timer_cal_ver", CAL_VERSION)
  end
  -- Fresh install (nothing learned yet): seed from the bundled
  -- data/timer_glyphs.txt ("hex|digit" lines, saved at CAL_VERSION 3) so the
  -- clock reads immediately; self-learning still refines/replaces as usual.
  if next(T.glyphmap) == nil then
    for line in SET.read_bundled("timer_glyphs.txt"):gmatch("[^\r\n]+") do
      local hex, d = line:match("^(%x+)|(%d)$")
      if hex then T.glyphmap[hex_to_bytes(hex)] = d end
    end
  end
end
T.learn = { last_units = nil, last_tens = nil, next_val = nil, pending = {} }

local function persist_glyphs()
  local out = {}
  for sig, digit in pairs(T.glyphmap) do out[bytes_to_hex(sig)] = digit end
  SET.set("floor_timer_glyphs", out)
end

local DEDUP_PX    = 3    -- same atlas glyph within this many px = shadow copy
local COLON_MAX_W = 3    -- colon/narrow separator max width (observed 2px)
local DIGIT_MIN_W = 4    -- a digit glyph is at least this wide (observed 4-6px)

-- Scan one 2D batch for the timer inside the keybag region. Collects glyph-sized
-- quads, de-shadows them, groups into text rows, and extracts the M:SS run (a
-- narrow colon flanked by digit-width glyphs) from whichever row contains it --
-- so a label like "Floor time:" on another row is ignored. Fills T.glyph_seq =
-- { {sig,x,w,h}, ... } left-to-right (minutes .. colon .. seconds).
function T.scan2d(event, vpi, n)
  local kx1, ky1 = keybag_x, keybag_y
  local kx2, ky2 = keybag_x + keybag_w, keybag_y + keybag_h
  local cands = {}
  for i = 0, n - 1 do
    local fv = i * vpi + 1
    local ax, ay, aw, ah = event:vertexatlasdetails(fv)
    if aw and ah and aw > 0 and ah > 0 and ah <= GLYPH_MAX_H and (aw * ah) <= GLYPH_MAX_PIX then
      local xmin, ymin, xmax, ymax = SET.vertex_bounds(event, fv, vpi)
      if xmin then
        local cx, cy = (xmin + xmax) * 0.5, (ymin + ymax) * 0.5
        if cx >= kx1 and cx <= kx2 and cy >= ky1 and cy <= ky2 then
          cands[#cands + 1] = { x = xmin, y = cy, ax = ax, ay = ay, aw = aw, ah = ah }
        end
      end
    end
  end
  -- onrender2d fires once per 2D batch; an empty batch must NOT wipe the result
  -- a batch with the timer produced earlier this frame. Frame reset happens in
  -- T.tick instead.
  if #cands == 0 then return end

  -- Group into rows (by y), de-shadowing within each row: a quad drawing the
  -- same atlas glyph within DEDUP_PX of the previous one is the shadow copy.
  table.sort(cands, function (a, b)
    if math.abs(a.y - b.y) > Y_TOL then return a.y < b.y end
    return a.x < b.x
  end)
  local rows = {}
  for _, g in ipairs(cands) do
    local r = rows[#rows]
    if not r or math.abs(g.y - r.y) > Y_TOL then
      rows[#rows + 1] = { y = g.y, gl = { g } }
    else
      local last = r.gl[#r.gl]
      local dup = last.ax == g.ax and last.ay == g.ay and last.aw == g.aw
        and last.ah == g.ah and math.abs(g.x - last.x) <= DEDUP_PX
      if not dup then r.gl[#r.gl + 1] = g end
    end
  end

  -- Extract the timer: the maximal contiguous run of digit/colon glyphs that
  -- holds at least one colon, across all rows -- so the WHOLE clock is captured
  -- (e.g. HH:MM:SS), not just the first group. That keeps the rightmost glyph as
  -- the fast-ticking seconds digit, which is what the auto-calibrator watches.
  local function cls(g)
    if g.aw <= COLON_MAX_W then return "c"
    elseif g.aw >= DIGIT_MIN_W then return "d" end
    return "o"
  end
  local best
  for _, r in ipairs(rows) do
    local gl = r.gl
    local i = 1
    while i <= #gl do
      if cls(gl[i]) ~= "o" then
        local j = i
        while j <= #gl and cls(gl[j]) ~= "o" do j = j + 1 end
        local run = {}
        for k = i, j - 1 do run[#run + 1] = gl[k] end
        while #run > 0 and cls(run[1]) == "c" do table.remove(run, 1) end
        while #run > 0 and cls(run[#run]) == "c" do table.remove(run) end
        local ncol = 0
        for _, g in ipairs(run) do if cls(g) == "c" then ncol = ncol + 1 end end
        if #run >= 3 and ncol >= 1 then best = run; break end
        i = j
      else
        i = i + 1
      end
    end
    if best then break end
  end

  if SET.DEV then
    local dbg = {}
    for _, r in ipairs(rows) do
      local ws = {}
      for _, g in ipairs(r.gl) do ws[#ws + 1] = g.aw .. "x" .. g.ah end
      dbg[#dbg + 1] = string.format("y=%d n=%d [%s]", math.floor(r.y), #r.gl, table.concat(ws, " "))
    end
    T._rows_dbg = table.concat(dbg, "\n")
  end

  if not best then return end   -- rows but no timer pattern; leave prior glyph_seq
  local seq = {}
  for _, g in ipairs(best) do
    local sig = SET.atlas_sig(event, g.ax, g.ay, g.aw, g.ah)
    if sig then seq[#seq + 1] = { sig = sig, x = g.x, w = g.aw, h = g.ah } end
  end
  T.glyph_seq = seq
end

-- Lock a digit only after seeing sig->val twice (the same digit recurs every 10s
-- as the units tick), so a one-frame scan glitch can't poison the map.
local function learn_digit(sig, val)
  if T.glyphmap[sig] then return end
  local L = T.learn
  if L.pending[sig] == val then
    T.glyphmap[sig] = val; L.pending[sig] = nil; persist_glyphs()
  else
    L.pending[sig] = val
  end
end

-- Auto-calibrate from the ticking seconds-units glyph (rightmost). A tick where
-- the seconds-TENS glyph also changed is a 9->0 rollover, which anchors "0";
-- subsequent ticks are 1,2,...,9 in order. Minutes reuse the same glyphs, so
-- learning the 10 digits from the units column reads the whole clock.
local function calibrate(seq)
  if not seq or #seq < 4 then return end
  local units, tens = seq[#seq].sig, seq[#seq - 1].sig
  local L = T.learn
  if L.last_units ~= nil and units ~= L.last_units then
    if L.last_tens ~= nil and tens ~= L.last_tens then
      learn_digit(units, "0"); L.next_val = 1
    elseif L.next_val ~= nil then
      learn_digit(units, tostring(L.next_val))
      L.next_val = L.next_val + 1
      if L.next_val > 9 then L.next_val = nil end
    end
  end
  L.last_units, L.last_tens = units, tens
  local c = 0; for _ in pairs(T.glyphmap) do c = c + 1 end
  T.cal_n = c
end

-- Assemble the clock string. Valid only when exactly one glyph is unknown (the
-- colon) and it isn't at an end -- which self-gates until every visible digit is
-- learned, so we never show a half-read time.
local function read_time(seq)
  if not seq or #seq < 3 then return nil end
  local out, ncol = {}, 0
  for _, g in ipairs(seq) do
    if g.w <= COLON_MAX_W then           -- colon(s), identified by width
      out[#out + 1] = ":"; ncol = ncol + 1
    else
      local d = T.glyphmap[g.sig]        -- digit: needs to be learned first
      if not d then return nil end
      out[#out + 1] = d
    end
  end
  if ncol < 1 or out[1] == ":" or out[#out] == ":" then return nil end
  return table.concat(out)
end

-- Parse a clock string ("H:MM:SS" or "M:SS") to whole seconds.
local function clock_to_secs(s)
  local n = {}
  for p in s:gmatch("%d+") do n[#n + 1] = tonumber(p) end
  if #n == 3 then return n[1] * 3600 + n[2] * 60 + n[3] end
  if #n == 2 then return n[1] * 60 + n[2] end
  if #n == 1 then return n[1] end
  return 0
end

-- Build + push the combined HUD state (deduped so it doesn't spam every frame):
-- clock, rooms opened this floor, rooms/min, and the per-floor key log (each key
-- with the clock value captured when its mesh was first identified).
local _diag_ctr = 0
local function push_display()
  if not T.browser then return end
  -- 1) Clock string: game clock if reading + calibrated, else the stopwatch.
  local clock, stat
  if T.read then
    calibrate(T.glyph_seq)
    local rd = read_time(T.glyph_seq)
    if rd then
      T.read_str = rd; clock = rd; stat = "game clock"
    else
      clock = T.start_us and fmt(math.floor((bolt.time() - T.start_us) / 1000000)) or "0:00"
      -- Only advertise calibration while the timer is actually on screen. With no
      -- timer visible (no active dungeon / keybag closed) there's nothing to
      -- learn, so show no status rather than a misleading "learning digits".
      if T.glyph_seq then stat = "learning digits " .. T.cal_n .. "/10" end
    end
    if SET.DEV then
      _diag_ctr = _diag_ctr + 1
      if _diag_ctr >= 30 then
        _diag_ctr = 0
        local parts = {}
        if T.glyph_seq then
          for _, g in ipairs(T.glyph_seq) do
            parts[#parts + 1] = string.format("%dx%d@%d %s:%s",
              g.w, g.h, math.floor(g.x), T.glyphmap[g.sig] or "?", bytes_to_hex(g.sig):sub(1, 8))
          end
        end
        SET.dev_save("floor_timer_read.txt", string.format(
          "read=%s cal=%d/10 region=%d,%d,%d,%d\nrows (deduped):\n%s\ntimer_seq (%d): %s\n",
          tostring(T.read_str), T.cal_n, keybag_x, keybag_y, keybag_w, keybag_h,
          T._rows_dbg or "(none)", T.glyph_seq and #T.glyph_seq or 0,
          #parts > 0 and table.concat(parts, " | ") or "(no timer pattern found)"))
      end
    end
  else
    clock = T.start_us and fmt(math.floor((bolt.time() - T.start_us) / 1000000)) or "0:00"
  end
  T.current = clock   -- exposed so key detection can stamp match-times

  -- 2) Rooms opened this floor (S.opened_at is sticky; wipe_floor_state clears
  --    it, so this resets on floor change). Includes base.
  local rooms = 0
  for _ in pairs(S.opened_at) do rooms = rooms + 1 end

  -- 3) Rooms per minute over the floor's elapsed time (guarded early on).
  local elapsed = clock_to_secs(clock)
  local rpm = (elapsed >= 5) and (rooms / (elapsed / 60)) or 0

  -- 4) Key log, sorted by identification order. First drop any key that is now
  --    in the keybag (TTL-live) -- picked up, so it no longer needs collecting --
  --    and remember it so detect() won't re-log it this floor.
  for kn, seen in pairs(S.keybag_state) do
    if S.keybag_tick - seen <= 60 then
      SET.line.key_log[kn] = nil
      SET.line.collected[kn] = true
    end
  end
  local order = {}
  for name, e in pairs(SET.line.key_log) do
    order[#order + 1] = { name = name, clock = e.clock, o = e.order }
  end
  table.sort(order, function (a, b) return a.o < b.o end)
  local kj = {}
  for _, e in ipairs(order) do
    kj[#kj + 1] = string.format('{"n":"%s","t":"%s"}', e.name, e.clock)
  end

  -- 5) One combined message, deduped.
  local msg = string.format(
    'hud:{"clock":"%s","rooms":%d,"rpm":"%.1f","stat":"%s","keys":[%s]}',
    clock, rooms, rpm, stat or "", table.concat(kj, ","))
  if msg ~= T._last then T._last = msg; T.browser:sendmessage(msg) end
end

-- Method A: position jump. Reset when the player's tile teleports far (>128
-- tiles), which happens when a new floor loads them into a fresh room.
local function tick_jump()
  local pos = bolt.playerposition()
  if not pos then return end
  local ppx, _, ppz = pos:get()
  local ptx = math.floor(ppx / TILE)
  local ptz = math.floor(ppz / TILE)
  if T.last_ptx ~= nil
     and (math.abs(ptx - T.last_ptx) > JUMP_TILES or math.abs(ptz - T.last_ptz) > JUMP_TILES) then
    T.start_us = bolt.time()          -- new floor
    SET.line.key_log = {}; SET.line.key_order = 0; SET.line.collected = {}  -- new floor
  elseif T.start_us == nil then
    T.start_us = bolt.time()          -- first floor / first sighting
  end
  T.last_ptx, T.last_ptz = ptx, ptz
end

-- Method B: load screen. During the inter-floor load the player position goes
-- unavailable; when it returns after a gap of >= LOAD_GAP_FRAMES, that return is
-- the moment we land on the new floor. Works even if two floors share a
-- coordinate range (where the position-jump method would miss the transition).
local function tick_load()
  local pos = bolt.playerposition()
  if not pos then
    T.nil_frames = (T.nil_frames or 0) + 1
    return
  end
  if (T.nil_frames or 0) >= LOAD_GAP_FRAMES then
    T.start_us = bolt.time()          -- returned from a load => new floor
    SET.line.key_log = {}; SET.line.key_order = 0; SET.line.collected = {}  -- new floor
  elseif T.start_us == nil then
    T.start_us = bolt.time()          -- first floor / first sighting
  end
  T.nil_frames = 0
end

function T.tick()
  if T.alt_detect then tick_load() else tick_jump() end
  push_display()
  -- Reset only ahead of a scanning frame (shared 5Hz gate): the last-read
  -- clock persists across the ~11 unscanned frames in between, so the HUD
  -- doesn't flicker to fallback; a timer that genuinely stops rendering
  -- still falls back within 200ms. Empty 2D batches mid-frame can't wipe a
  -- good scan. _rows_dbg is left as last-seen for the diagnostic.
  if SET.scan_frame then T.glyph_seq = nil end
end

-- The HUD window itself was deleted 2026-07-27 (T.open/T.close/on_msg and
-- dg_hud.html are gone). T.tick keeps running headless: floor detection and
-- the key-log timestamps it computes are consumed elsewhere, and its browser
-- pushes are guarded on a T.browser that is now never created.
end)()

-- ============================================================================
-- Skill-door examine detector (box OCR) -- lives in examine.lua.
-- ============================================================================
-- Everything the module needs from this chunk is injected, mirroring the
-- parity.lua pattern. The signature registries and the room graph are passed
-- as ACCESSORS, not tables: this chunk REBINDS those locals
-- (reload_signatures, the per-frame graph rebuild), and a direct table
-- reference inside the module would silently go stale.
require("examine")({
  SET = SET, S = S,
  sig_names   = function () return signature_names end,
  sig_catalog = function () return signature_catalog end,
  sig_meta    = function () return signature_meta end,
  cell_at     = function (ck) return rooms_by_cell[ck] end,
  plugin_enabled   = function () return PLUGIN_ENABLED end,
  floor_gate_armed = floor_gate_armed,
})

-- ============================================================================
-- Party sync -- lives in sync.lua (transport sidecar, event emit/merge,
-- heartbeat). Interface stays on SET.sync. keys_state is injected as an
-- accessor because this chunk rebinds it on floor wipe.
-- ============================================================================
require("sync")({
  SET = SET, S = S,
  key_lower = key_lower,
  bind_resource_cell = function (ck, name, remote) return SET.res.bind_cell(ck, name, remote) end,
  keys_state = function () return keys_state end,
  -- The presence heartbeat derives the player's cell from world coords; these
  -- two were main-chunk locals left dangling as nil globals when sync.lua was
  -- extracted (crashed the swap handler the moment a player entered a floor).
  RES_TILE_UNITS = RES_TILE_UNITS,
  world_room_to_grid = world_room_to_grid,
})

bolt.onrender3d(function (event)
  -- Capture view-projection + camera every frame BEFORE the enabled gate so the
  -- merged Line Draw overlay can still render its manual A->B line even when the
  -- tracker itself is disabled. Key lines have no targets in that case (key
  -- detection lives past the gate), which is the intended behaviour.
  -- Frame-constant reads (view-proj, camera, player position) are identical for
  -- every mesh in a frame, but onrender3d fires PER MESH -- reading them per
  -- mesh meant thousands of redundant bolt calls per frame when zoomed out,
  -- which is the FPS drop. Cache once per frame; onswapbuffers clears S.f3d.
  -- Once-per-frame block (first mesh only). Reading the frame-constant
  -- view/camera/player here AND setting the overlay state here was the key
  -- fix: sr_view_proj + the three SET.line.cam writes are frame-constant, but
  -- doing them per mesh (~900x/frame) cost ~1.6ms/frame of redundant table
  -- writes -- the steady cost measured on non-scan frames. Set them once.
  local f3d = S.f3d
  if not f3d then
    f3d = { vp = event:viewprojmatrix() }
    f3d.cx, f3d.cy, f3d.cz = event:cameraposition()
    local pp = bolt.playerposition()
    if pp then f3d.px, f3d.py, f3d.pz = pp:get() end
    S.f3d = f3d
    sr_view_proj = f3d.vp
    if f3d.cx then SET.line.cam_x, SET.line.cam_y, SET.line.cam_z = f3d.cx, f3d.cy, f3d.cz end
  end
  -- Scan-frame gate FIRST: 11/12 frames are non-scan, so return here with the
  -- fewest per-mesh ops. The detection below is all of STATIC things
  -- (resources / ground keys don't move), so the shared ~5Hz cadence loses
  -- nothing. Nil scan_frame (before the first swap) reads as false.
  if not PLUGIN_ENABLED then return end
  if not f3d.px then return end
  local px, py, pz = f3d.px, f3d.py, f3d.pz
  -- Vertexcount first (one bolt call). It decides whether this mesh could be a
  -- GROUND KEY (a cataloged icon vertexcount). Ground-key detection feeds the
  -- parity found_of records and is CORRECTNESS-CRITICAL, so it must run EVERY
  -- frame -- gating it to 5Hz (as an earlier perf pass did) delayed key finds
  -- up to 200ms and let the frontier rule fire before a ground key was
  -- recorded, poisoning a floor. Resource detection is cosmetic and stays 5Hz.
  -- So: skip any mesh that is neither a key candidate nor on a scan frame,
  -- BEFORE paying for the position read.
  local mn = event:vertexcount()
  local is_key_n = SET.icons.by_n(mn) ~= nil
  if not SET.scan_frame and not is_key_n then return end
  -- Per-mesh world position (needed for the scan-range cull below).
  local ok, wp = pcall(ORIGIN_PT.transform, ORIGIN_PT, event:modelmatrix())
  if not ok or not wp then return end
  local wx, wy, wz = wp:get()

  -- ==== PUZZLE GHOSTS ========================================================
  -- Runs BEFORE the scan-range cull below, and that placement is the point.
  -- Resources are static scenery you walk up to, so a 3x3-tile scan box around
  -- the player is the right frame for them; ghosts are combat targets spread
  -- across a room. Culled to 3x3 they only ever registered when you stood on
  -- top of one, and the "darkest on screen" comparison never had a second ghost
  -- to compare against, so it fell back to the absolute split every time.
  -- Anything the client renders is a candidate here; the vertexcount gate is a
  -- table lookup, so non-ghost meshes pay almost nothing.
  --
  -- NOT resources: this RETURNS, so a ghost can never queue, bind a sighting or
  -- reach the parity evidence.
  if SET.scan_frame and SET.res.ghost_n and SET.res.ghost_n(mn) then
    local lum = SET.res.ghost_lum(event, mn)
    if lum then
      ghost_boxes[#ghost_boxes + 1] = {
        tx = math.floor(wx / RES_TILE_UNITS),
        tz = math.floor(wz / RES_TILE_UNITS),
        y = py, lum = lum,
      }
      return
    end
  end

  -- Line Draw: key lines (keys mode) OR HUD key log.
  if SET.line.keys_mode or SET.timer.visible then
    SET.line.detect(event, wx, wy, wz, py)
  end

  -- Grid-snapped scan: SCAN_RANGE_TILES = 1 means a 3x3 block of tiles
  -- centred on the player's tile. Match by tile-index diff, not raw distance,
  -- so what we see (visual outline) matches what we detect.
  local ptx = math.floor(px / RES_TILE_UNITS)
  local ptz = math.floor(pz / RES_TILE_UNITS)
  local mtx = math.floor(wx / RES_TILE_UNITS)
  local mtz = math.floor(wz / RES_TILE_UNITS)
  if math.abs(mtx - ptx) > SCAN_RANGE_TILES or math.abs(mtz - ptz) > SCAN_RANGE_TILES then
    return
  end
  local dist2 = math.abs(mtx - ptx) + math.abs(mtz - ptz)   -- tile Manhattan for queue sort

  -- ==== GROUND-KEY DETECTION (every frame; parity-critical found_of) ========
  -- Keys render as onrender3d meshes but fingerprint-match their on_rendericon
  -- catalog entry exactly, so we identify them from the same 5-vert sample.
  local live_sorted = nil
  if is_key_n then
    local step = math.max(1, math.floor(mn / 6))
    local live = {}
    local ok_all = true
    for i = 1, 5 do
      local idx = math.min(mn, i * step)
      local ok_p, p = pcall(event.vertexpoint, event, idx)
      if not ok_p or not p then ok_all = false; break end
      local x, y, z = p:get()
      local ok_c, r, g, b = pcall(event.vertexcolour, event, idx)
      if not ok_c then ok_all = false; break end
      live[i] = {
        x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5),
        r = math.floor(r * 255 + 0.5), g = math.floor(g * 255 + 0.5), b = math.floor(b * 255 + 0.5),
      }
    end
    if ok_all then
      live_sorted = { live[1], live[2], live[3], live[4], live[5] }
      table.sort(live_sorted, function (a, b) return a.y < b.y end)
    end
  end
  local n = mn   -- ground-key + resource code below refer to `n`
  if live_sorted and S.map_origin then
    -- Nearest-neighbour match against the ICON catalog.
    -- Colour distance is the SUM over the 5 sampled verts (== mean, up to the
    -- constant weight). It was the MIN, which was blind to colour for same-shape
    -- keys: all 8 corners share identical positions AND two neutral outline verts
    -- (75,72,68 / 69,67,64), so the min always found a matching vert -> col term
    -- ~0 for EVERY corner, the 8 entries tied on position, and the winner was
    -- decided by loop order + sub-unit noise. green_corner (and others)
    -- systematically lost the tie and never bound (found=nil across many floors,
    -- incl. boss keys). Summing makes the coloured shape-verts discriminate:
    -- green_corner beats blue_corner by ~270 now instead of ~0.
    -- Binding is rival-relative: the winner must beat the nearest DIFFERENT key
    -- by IK_MARGIN, so we only bind when colour genuinely resolves the identity
    -- (no absolute drift threshold to guess at). IK_CUTOFF still rejects non-keys.
    local IK_CUTOFF = 400
    local IK_MARGIN = 120
    local IK_WINDOW = 0
    local best_kscore, best_kentry = math.huge, nil
    local rival_kscore = math.huge
    for dn = -IK_WINDOW, IK_WINDOW do
      local bucket = SET.icons.by_n(n + dn)
      if bucket then
        for _, entry in ipairs(bucket) do
          local pos_sum, col_sum, ok_all = 0, 0, true
          local ev_list = entry.verts_sorted
          for i = 1, 5 do
            local ev = ev_list[i]
            local lv = live_sorted[i]
            if not ev or not lv then ok_all = false; break end
            pos_sum = pos_sum + math.abs(ev.x - lv.x) + math.abs(ev.y - lv.y) + math.abs(ev.z - lv.z)
            col_sum = col_sum + math.abs(ev.r - lv.r) + math.abs(ev.g - lv.g) + math.abs(ev.b - lv.b)
          end
          if ok_all then
            local score = pos_sum + 2 * col_sum
            if score < best_kscore then
              -- old best (if a different key) becomes the nearest rival
              if best_kentry and best_kentry.name ~= entry.name and best_kscore < rival_kscore then
                rival_kscore = best_kscore
              end
              best_kscore, best_kentry = score, entry
            elseif (not best_kentry or entry.name ~= best_kentry.name) and score < rival_kscore then
              rival_kscore = score
            end
          end
        end
      end
    end
    -- Tuning log (dev): one line per distinct detected key per floor, so the
    -- cutoff/margin can be set from real drift data. Cleared on floor wipe.
    if SET.DEV and best_kentry then
      S.key_match_seen = S.key_match_seen or {}
      if not S.key_match_seen[best_kentry.name] then
        S.key_match_seen[best_kentry.name] = true
        S.key_match_log = (S.key_match_log or "") .. string.format(
          "%-18s best=%.0f  rival=%.0f  margin=%.0f  %s\n",
          best_kentry.name, best_kscore, rival_kscore, rival_kscore - best_kscore,
          (best_kscore <= IK_CUTOFF and (rival_kscore - best_kscore) >= IK_MARGIN) and "BOUND" or "rejected")
        SET.dev_save("key_match.txt", S.key_match_log)
      end
    end
    if best_kentry and best_kscore <= IK_CUTOFF and (rival_kscore - best_kscore) >= IK_MARGIN then
      local kn = key_lower(best_kentry.name)
      -- Guard: DG-map key icons also render as on_render3d passes and hit the
      -- same fingerprint since they're the same mesh. Distinguish real ground
      -- keys from UI icons by requiring:
      --   1) Model y is near the player's floor (same room, ground plane).
      --   2) Derived cell exists in the current room graph (UI icons project
      --      to bogus world tiles that don't map to any observed cell).
      local Y_TOL = RES_TILE_UNITS * 2      -- ~2 tiles above/below player
      local looks_grounded = math.abs(wy - py) <= Y_TOL
      if kn and looks_grounded then
        local btx = math.floor(wx / RES_TILE_UNITS)
        local btz = math.floor(wz / RES_TILE_UNITS)
        local gx, gz = world_room_to_grid(math.floor(btx / 16), math.floor(btz / 16))
        local found_ck = gx and string.format("%d,%d", gx, gz)
        local cell2 = found_ck and rooms_by_cell[found_ck]
        if cell2 then
          -- OPENED-ROOM INVARIANT: a ground key can only lie in an opened
          -- room. A binding landing in an unopened cell is a world->grid
          -- boundary artifact (seen live 2026-07-17: purple_corner "found"
          -- in never-opened 5,0 killed a floor from both ends of the key
          -- rules). Reject rather than snap to a neighbour: a straddling
          -- read cannot say which side it belongs to.
          local room_opened = true
          for _, nn in ipairs(cell2.images) do
            if nn:sub(1, 9) == "UNOPENED_" then room_opened = false; break end
          end
          keys_state[kn] = keys_state[kn] or {}
          if not room_opened then
            if keys_state[kn].found_rej ~= found_ck then
              keys_state[kn].found_rej = found_ck
              SET.ledger("key %s ground-detect at UNOPENED %s -- rejected", kn, found_ck)
            end
          elseif keys_state[kn].found == nil then
            -- FIRST DETECTION WINS -- never overwrite. A later boundary
            -- mis-bind moved purple_corner 0,4 -> 5,0 mid-floor and the
            -- moved record contradicted facts minted from the original.
            keys_state[kn].found = found_ck
            SET.ledger("key %s found -> %s", kn, found_ck)
            -- Party sync: pickup CELLS are the one key datum the game does
            -- not share (the keys UI is party-wide, render distance is not).
            if SET.sync.emit then
              SET.sync.emit({ t = "key_found", k = kn, c = found_ck })
            end
          elseif keys_state[kn].found ~= found_ck then
            -- Conflicting later sighting: discarded per first-wins, but it
            -- IS evidence -- record it so a dead floor shows the discard.
            if keys_state[kn].found_alt ~= found_ck then
              keys_state[kn].found_alt = found_ck
              SET.ledger("key %s ground-detect at %s conflicts with found=%s -- kept first",
                kn, found_ck, keys_state[kn].found)
            end
          end
          -- In-world highlight: bright outline drawn in on_rendergameview so
          -- ground keys are impossible to walk past. Anchored at player Y.
          key_boxes[#key_boxes + 1] = { tx = btx, tz = btz, y = py, name = kn }
        end
      end
    end
  end

  -- ==== RESOURCE DETECTION (5Hz only; cosmetic, latency-tolerant) ===========
  if not SET.scan_frame then return end
  -- Guardian doors: a separate 3D-mesh catalog (guardian_doors.txt). Detected
  -- meshes are recorded (sticky per floor) as world positions; the door-highlight
  -- pass forward-matches them to door wall-centres. Strict match, one print per
  -- floor. Skip the resource path afterwards so a guardian never queues/binds.
  if SET.res.guardian_n and SET.res.guardian_n(mn) then
    local gname = SET.res.guardian_hit(event, mn)
    if gname then
      local gtx, gtz = math.floor(wx / RES_TILE_UNITS), math.floor(wz / RES_TILE_UNITS)
      local gk = gtx .. "," .. gtz
      S.guardian_seen = S.guardian_seen or {}
      if not S.guardian_seen[gk] then
        S.guardian_seen[gk] = { wx = wx, wz = wz }
        if SET.DEV then
          S.guardian_log = (S.guardian_log or "") .. string.format(
            "%s at world %d,%d  (tile %d,%d)\n", gname, math.floor(wx), math.floor(wz), gtx, gtz)
          SET.dev_save("guardian_diag.txt", S.guardian_log)
        end
      end
      return
    end
  end
  -- Fingerprint memo: (tile,vertexcount) -> key | false, so static meshes are
  -- not re-sampled every scan; classify + bind still run each scan from the key.
  local mkey = mtx .. ":" .. mtz .. ":" .. mn
  local memo = S.res_fp_memo
  local key = memo[mkey]
  if key == nil then                       -- unseen tile+n: sample once, memoise
    key = SET.res.fingerprint(event)
    memo[mkey] = key or false
  end
  if not key then return end               -- memoised non-resource, or nil
  if SET.res.is_ignored(key) then return end
  if SET.res.is_reviewed(key) then
    review_boxes[#review_boxes + 1] = { tx = mtx, tz = mtz, y = py }
  end
  local classified, match_score, match_ambig = SET.res.classify(event, key, n)
  _res_seen = _res_seen or {}
  _res_seen[n] = (_res_seen[n] or 0) + 1
  if classified then
    local btx = math.floor(wx / RES_TILE_UNITS)
    local btz = math.floor(wz / RES_TILE_UNITS)
    -- No canopy-lean correction. A tree's trunk sits on the room's wall, but
    -- the wall IS the room's outer edge tile -- it is inside the 16x16 cell --
    -- so floor(tile/16) already resolves to the right room and no nudge is
    -- needed. The old code sampled 7 verts, took a centroid, and shifted the
    -- tile one step along the dominant axis of (centroid - origin). On a trunk
    -- sitting on an outer edge tile, a single step is exactly enough to cross
    -- the boundary, so the "correction" could only ever move a correctly-placed
    -- tree INTO THE NEIGHBOURING ROOM -- and did: one T1_TREE_4 bound to both
    -- 3,0 and 4,0, marking 3,0 bonus off a tree that was never in it.
    -- Diag: catch false-positive matches at (or right next to) the player's
    -- tile. Something animated on the player is triggering a bonus-tier match;
    -- log which cataloged entry it is so we can excise it.
    if math.abs(btx - ptx) <= 1 and math.abs(btz - ptz) <= 1 then
      _crit_at_player = _crit_at_player or {}
      local k = string.format("%s|t%d|n%d", classified.name or "?", classified.tier or 0, n)
      _crit_at_player[k] = (_crit_at_player[k] or 0) + 1
    end
    -- One-shot pts + mvp capture per unique fingerprint so the Matches tab
    -- can render a full triangle preview on click. Skips re-capture on later
    -- sightings of the same key.
    SET.res.record_match(event, key, n, classified.name or "?",
      classified.tier or 0, btx, btz, wx, wz, match_score, dist2, match_ambig)
    resource_boxes[#resource_boxes + 1] = {
      tx = btx,
      tz = btz,
      tier = classified.tier or 0,
      name = classified.name,
      -- Anchor at player Y (ground of the current room) so highlights don't
      -- sink below the floor for resources whose model origin sits at y=0.
      y = py,
    }
    -- Parity signal: bind sighting to its minimap cell via the calibrated
    -- world->minimap offset. Sticky - never removed until plugin reload.
    if classified.name and not match_ambig then
      SET.res.bind_sighting(btx, btz, classified.name)
    end
    return
  end  SET.res.queue_unknown(event, key, n, wx, wy, wz, dist2)
end)



-- ============================================================================
-- Frame housekeeping.
-- ============================================================================
local _settings_poll_counter = 0
local _reload_counter = 0
local _res_snap_counter = 0
-- Resource tile boxes + scan-range outline. Draws each classified resource's
-- ground tile filled with a colour that hints at crit/bonus (yellow = bonus,
-- since tiers 1–8 only spawn on bonus paths; grey = ambiguous, since tiers
-- 9–10 can appear on either — real classification comes with Phase 3
-- room-state propagation).
local _diag_render_counter = 0
bolt.onrendergameview(function (event)
  _diag_render_counter = _diag_render_counter + 1
  if _diag_render_counter % 60 == 0 then
    local all_ns = {}
    for k, v in pairs(_res_seen or {}) do all_ns[#all_ns + 1] = { k, v } end
    table.sort(all_ns, function (a, b) return a[2] > b[2] end)
    local top = {}
    for i, kv in ipairs(all_ns) do
      if i > 20 then break end
      top[#top + 1] = string.format("n%d(%d)", kv[1], kv[2])
    end
    local catalog_ns = SET.res.catalog_ns()
    local crit_list = {}
    for k, v in pairs(_crit_at_player or {}) do crit_list[#crit_list + 1] = { k, v } end
    table.sort(crit_list, function (a, b) return a[2] > b[2] end)
    local crit_lines = {}
    for _, kv in ipairs(crit_list) do
      crit_lines[#crit_lines + 1] = string.format("%s x%d", kv[1], kv[2])
    end
    -- Ghost diag: how many carried the colour signature this scan and at what
    -- luminance, so a missing highlight can be told apart from a missing
    -- detection (signature too tight) at a glance.
    local glums = {}
    for _, b in ipairs(ghost_boxes) do
      glums[#glums + 1] = string.format("%.0f@%d,%d", b.lum, b.tx, b.tz)
    end
    -- Floor-gate + anchor state: the two silent gates that make "map open but
    -- nothing tracks" otherwise undiagnosable. stamped_ago answers "is the
    -- FLOOR_ICON pass firing"; the counters say WHERE it dies when it is not
    -- (dims candidates seen / catalog hits / pixel-mismatches / read failures).
    local fg_now = bolt.time() or 0
    local fg_ago = S.floor_icon_us and
      string.format("%.1fs ago", (fg_now - S.floor_icon_us) / 1e6) or "NEVER"
    SET.dev_save("draw_dbg.txt", string.format(
      "enabled=%s res_boxes=%d ghost_boxes=%d\nghost_lums=[%s]\n"
        .. "floor_gate: active=%s stamped=%s dims34=%d hit=%d miss=%d readfail=%d\n"
        .. "gates: batches=%d scan_true=%d pass=%d nosig=%d swaps=%d nowg=%.0f\n"
        .. "anchor=%s,%s\n"
        .. "catalog_ns=[%s]\ntop_seen=[%s]\ncrit_at_player=[%s]\n",
      tostring(PLUGIN_ENABLED), #resource_boxes, #ghost_boxes,
      table.concat(glums, " "),
      tostring(S.floor_active), fg_ago,
      S.fg_dims or 0, S.fg_hit or 0, S.fg_miss or 0, S.fg_readfail or 0,
      S.fg_batches or 0, S.fg_scan2d or 0, S.fg_pass or 0, S.fg_nosig or 0,
      S.sw_total or 0, S.sw_nowg or -1,
      tostring(S.close_anchor_x), tostring(S.close_anchor_y),
      table.concat(catalog_ns, " "),
      table.concat(top, " "),
      table.concat(crit_lines, " | ")))
    _res_seen = {}
    -- keep _crit_at_player accumulating so rare hits (every few seconds) persist
  end
  -- Line Draw overlay. Runs BEFORE the enabled gate so the manual A->B line
  -- shows even when the tracker is disabled; key lines read this frame's grounded
  -- key set (empty when disabled).
  SET.line.render(event)
  if not PLUGIN_ENABLED or not sr_view_proj then
    resource_boxes = {}
    review_boxes = {}
    key_boxes = {}
    ghost_boxes = {}
    return
  end
  -- Shared tile-drawing setup. Hoisted out of the resource block so the ghost
  -- pass below can reuse it -- both draw the same tile outlines, and the view
  -- matrix only needs setting once per frame.
  local m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16 = sr_view_proj:get()
  sr_program:setuniformmatrix4f(1, false,
    m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16)
  local BOX_THICK = 32   -- world units per outline edge
  local function draw_group(bs, r, g, bb, a, thick)
    if #bs == 0 then return end
    local t = thick or BOX_THICK
    -- Each tile → 4 edge quads (N/S/W/E) = 4 quads * 6 verts.
    local gb = bolt.createbuffer(#bs * 4 * 6 * sr_bytes_per_vert)
    local goff = 0
    for _, b in ipairs(bs) do
      local x1 = b.tx * RES_TILE_UNITS
      local x2 = (b.tx + 1) * RES_TILE_UNITS
      local z1 = b.tz * RES_TILE_UNITS
      local z2 = (b.tz + 1) * RES_TILE_UNITS
      local y  = (b.y or 0) + 4
      goff = sr_push_quad(gb, goff, x1, z1 - t, x2, z1 + t, y)   -- north
      goff = sr_push_quad(gb, goff, x1, z2 - t, x2, z2 + t, y)   -- south
      goff = sr_push_quad(gb, goff, x1 - t, z1, x1 + t, z2, y)   -- west
      goff = sr_push_quad(gb, goff, x2 - t, z1, x2 + t, z2, y)   -- east
    end
    sr_program:setuniform4f(2, r, g, bb, a)
    local sbuf = bolt.createshaderbuffer(gb)
    sr_program:drawtogameview(event, sbuf, #bs * 4 * 6)
  end
  -- Solid tile fill, sat just under the outline so the two do not z-fight.
  local function draw_fill(bs, r, g, bb, a)
    if #bs == 0 then return end
    local gb = bolt.createbuffer(#bs * 6 * sr_bytes_per_vert)
    local goff = 0
    for _, b in ipairs(bs) do
      goff = sr_push_quad(gb, goff,
        b.tx * RES_TILE_UNITS, b.tz * RES_TILE_UNITS,
        (b.tx + 1) * RES_TILE_UNITS, (b.tz + 1) * RES_TILE_UNITS,
        (b.y or 0) + 2)
    end
    sr_program:setuniform4f(2, r, g, bb, a)
    local sbuf = bolt.createshaderbuffer(gb)
    sr_program:drawtogameview(event, sbuf, #bs * 6)
  end
  -- 1) Resource tile boxes. Split by colour group (bonus vs ambiguous).
  local has_queue = SET.res.has_queue()
  if #resource_boxes > 0 or #review_boxes > 0 or has_queue then
    local groups = { bonus = {}, other = {}, unknown = {}, dino = {}, dino_unknown = {} }
    for _, b in ipairs(resource_boxes) do
      local t = b.tier or 0
      -- Dinos share a mesh across tiers; tier is only distinguished by colour,
      -- so classification is fragile. T1-T8 -> yellow, unknown tier -> green
      -- (confirm manually), T9/T10 -> gray like other top-tier resources.
      if b.name and b.name:find("DINO", 1, true) then
        if t >= 1 and t <= 8 then groups.dino[#groups.dino + 1] = b
        elseif t == 0 then groups.dino_unknown[#groups.dino_unknown + 1] = b
        else groups.other[#groups.other + 1] = b end
      elseif t == 0 then
        -- tier=0 → crit/bonus can't be determined (fishing spots, chests, etc.)
        groups.unknown[#groups.unknown + 1] = b
      elseif t > 0 and t <= 8 then
        groups.bonus[#groups.bonus + 1] = b
      else
        groups.other[#groups.other + 1] = b
      end
    end
    draw_group(groups.bonus, 1.0, 0.95, 0.0, 1.0)     -- saturated yellow
    draw_group(groups.other, 0.65, 0.65, 0.65, 1.0)   -- neutral gray
    draw_group(groups.dino,  1.0, 0.90, 0.15, 1.0)    -- yellow (T1-T8 dinos)
    draw_group(groups.dino_unknown, 0.0, 1.0, 0.2, 1.0)  -- green (unknown-tier dinos)
    -- Review-banked meshes: hot pink = "already marked, specimen in the
    -- bank". (Replaced the old all-unknowns pink, removed 2026-07-19.)
    draw_group(review_boxes, 1.0, 0.15, 0.75, 1.0)

    -- Unknown-crit resources (fishing spots, large chests, anything cataloged
    -- with tier=0): dashed cyan-blue outline as a "check manually" hint.
    -- 4 dashes per edge (dash + gap × 4 = 8 segments, draw the 4 dash segments).
    if #groups.unknown > 0 then
      local DASHES_PER_EDGE = 4
      local total_segs = #groups.unknown * 4 * DASHES_PER_EDGE
      local gb = bolt.createbuffer(total_segs * 6 * sr_bytes_per_vert)
      local goff = 0
      for _, b in ipairs(groups.unknown) do
        local x1 = b.tx * RES_TILE_UNITS
        local x2 = (b.tx + 1) * RES_TILE_UNITS
        local z1 = b.tz * RES_TILE_UNITS
        local z2 = (b.tz + 1) * RES_TILE_UNITS
        local y  = (b.y or 0) + 4
        -- Divide each edge into 2*DASHES segments and emit the even-index ones
        -- (0, 2, 4, ...) as dashes; odd indices are the gaps.
        local N = DASHES_PER_EDGE * 2
        local step_x = (x2 - x1) / N
        local step_z = (z2 - z1) / N
        for i = 0, N - 1, 2 do
          local sx1 = x1 + i * step_x
          local sx2 = x1 + (i + 1) * step_x
          local sz1 = z1 + i * step_z
          local sz2 = z1 + (i + 1) * step_z
          -- North edge (z = z1)
          goff = sr_push_quad(gb, goff, sx1, z1 - BOX_THICK, sx2, z1 + BOX_THICK, y)
          -- South edge (z = z2)
          goff = sr_push_quad(gb, goff, sx1, z2 - BOX_THICK, sx2, z2 + BOX_THICK, y)
          -- West edge (x = x1)
          goff = sr_push_quad(gb, goff, x1 - BOX_THICK, sz1, x1 + BOX_THICK, sz2, y)
          -- East edge (x = x2)
          goff = sr_push_quad(gb, goff, x2 - BOX_THICK, sz1, x2 + BOX_THICK, sz2, y)
        end
      end
      sr_program:setuniform4f(2, 0.15, 0.60, 1.0, 1.0)    -- vivid cyan-blue
      local sbuf = bolt.createshaderbuffer(gb)
      sr_program:drawtogameview(event, sbuf, total_segs * 6)
    end
  end

  -- 1b) PUZZLE GHOSTS. Identical geometry, and the only difference is baked
  -- brightness -- the DARK ghost is the one that can take damage. The game
  -- rotates which ghost that is on a timer, so this is recomputed every frame
  -- and nothing is remembered: a stale pick would point at an invulnerable
  -- target, which is worse than no highlight at all.
  --
  -- Vulnerable = DARKEST on screen, not "below a threshold". The two states
  -- differ by a uniform x1.22 brightness scale, and that scale rides on the
  -- room's lighting -- so an absolute cutoff drifts, while a relative test does
  -- not. The 1.10 band is comfortably inside the 1.22 gap while still tolerating
  -- ghosts lit slightly differently across the room. With a single ghost in
  -- view there is nothing to compare against, so fall back to the midpoint of
  -- the two cataloged luminances (ghosts.txt).
  if #ghost_boxes > 0 then
    local min_lum = math.huge
    for _, b in ipairs(ghost_boxes) do
      if b.lum < min_lum then min_lum = b.lum end
    end
    local split = SET.res.ghost_split and SET.res.ghost_split() or nil
    local good, bad = {}, {}
    for _, b in ipairs(ghost_boxes) do
      local is_good
      if #ghost_boxes > 1 then
        is_good = b.lum <= min_lum * 1.10
      else
        is_good = (split ~= nil) and (b.lum <= split)
      end
      if is_good then good[#good + 1] = b else bad[#bad + 1] = b end
    end
    -- Pulse so the target is unmissable in a fight. ~1.2s period off
    -- bolt.time() (microseconds, monotonic); no accumulator to drift.
    local phase = (bolt.time() % 1200000) / 1200000
    local pulse = 0.55 + 0.45 * math.sin(phase * math.pi * 2)
    -- The other ghosts get a thin, dim red outline: enough to see the set and
    -- confirm detection is working, quiet enough not to compete with the target.
    draw_group(bad, 0.75, 0.10, 0.10, 0.55, 16)
    -- The vulnerable one: filled green tile + a heavy pulsing outline.
    draw_fill(good, 0.10, 1.0, 0.25, 0.30 * pulse)
    draw_group(good, 0.20, 1.0, 0.30, pulse, 96)
  end

  -- Door-adjacent tile highlights for the 3x3 of rooms centred on the player's
  -- room. For each present, OPENED room (skip empty cells + unopened templates)
  -- and each wall that ACTUALLY CONNECTS (cell_doors), highlight tiles just
  -- inside that door. n=+Z (north) edge, s=-Z, e=+X, w=-X, matching
  -- world_room_to_grid (gz = origin.wrz - wrz). Grid cell -> world room tile
  -- origin: rtx = (gx+origin.wrx)*16, rtz = (origin.wrz-gz)*16. Shapes (tile
  -- sets, rendered as a merged outline / corner brackets):
  --   plain door        -> the 2 tiles directly in front (solid)
  --   skill / keydoor    -> a C wrapping the 2-tile lock, opening at the door
  --                         (block minus the 2 lock tiles)
  --   keydoor, key found -> C solid;  key NOT yet found -> C in corner brackets
  do
    local pp = bolt.playerposition()
    if pp and S.map_origin then
      local px, py, pz = pp:get()
      local pgx, pgz = world_room_to_grid(
        math.floor(math.floor(px / RES_TILE_UNITS) / 16),
        math.floor(math.floor(pz / RES_TILE_UNITS) / 16))
      -- Skill doors with a physical obstacle in front (rocks/fire/altar/obelisk/
      -- dig site/magic barrier) get the C too, same as a keydoor lock.
      local CHEV_DOORS = {
        DOOR_MINING = true, DOOR_FIREMAKING = true, DOOR_MAGIC = true,
        DOOR_PRAYER = true, DOOR_SUMMONING = true, DOOR_ARCHAEOLOGY = true,
        DOOR_RUNECRAFTING = true,
      }
      -- "solid" | "brackets" for a chevron/C door, nil for a plain door. A
      -- keydoor whose key we have NOT yet found renders as corner brackets.
      local function chevron_style(cgx, cgz, dir)
        local d = NEI_DELTA[dir]
        local nc = rooms_by_cell[(cgx + d[1]) .. "," .. (cgz + d[2])]
        if not nc then return nil end
        local unopened, keyname, skilled = false, nil, false
        for _, nm in ipairs(nc.images) do
          if nm:sub(1, 9) == "UNOPENED_" then unopened = true
          elseif CHEV_DOORS[nm] then skilled = true
          else local k = key_lower(nm); if k then keyname = k end end
        end
        if not unopened then return nil end
        if keyname then
          local ks = keys_state[keyname]
          return (ks and ks.found) and "solid" or "brackets"
        end
        return skilled and "solid" or nil
      end
      -- Outline colour by the parity of the room the door LEADS TO: proven
      -- bonus -> gray, crit -> green, still unknown -> yellow.
      local function door_color(cgx, cgz, dir)
        local d = NEI_DELTA[dir]
        local p = parity_state[(cgx + d[1]) .. "," .. (cgz + d[2])]
        if p == "bonus" then return "gray"
        elseif p == "crit" then return "green"
        else return "yellow" end
      end
      -- Guardian door: neighbour is an unopened QUESTION room (guardian doors
      -- only entrance those) AND a detected guardian mesh sits near this door's
      -- wall centre (forward-match against S.guardian_seen, sticky per floor).
      -- Becomes false once the room is opened (no longer a QUESTION room).
      local function guardian_door(cgx, cgz, dir, rtx, rtz)
        if not S.guardian_seen then return false end
        local d = NEI_DELTA[dir]
        local nc = rooms_by_cell[(cgx + d[1]) .. "," .. (cgz + d[2])]
        if not nc then return false end
        local isq = false
        for _, nm in ipairs(nc.images) do
          if nm:sub(1, 9) == "UNOPENED_" and nm:find("_QUESTION", 1, true) then isq = true; break end
        end
        if not isq then return false end
        local T = RES_TILE_UNITS
        local dcx, dcz
        if dir == "n" then dcx, dcz = (rtx+8)*T, (rtz+16)*T
        elseif dir == "s" then dcx, dcz = (rtx+8)*T, rtz*T
        elseif dir == "e" then dcx, dcz = (rtx+16)*T, (rtz+8)*T
        else               dcx, dcz = rtx*T, (rtz+8)*T end
        local TOL = T * 1.5
        for _, g in pairs(S.guardian_seen) do
          if math.abs(g.wx - dcx) <= TOL and math.abs(g.wz - dcz) <= TOL then return true end
        end
        return false
      end
      local shapes = {}   -- { tiles = {{tx,tz}...}, mode = "solid"|"brackets" }
      if pgx then
        for dz = -1, 1 do
          for dx = -1, 1 do
            local cgx, cgz = pgx + dx, pgz + dz
            local cell = rooms_by_cell[cgx .. "," .. cgz]
            local opened = cell ~= nil
            if cell then
              for _, nm in ipairs(cell.images) do
                if nm:sub(1, 9) == "UNOPENED_" then opened = false; break end
              end
            end
            if cell and opened then
              local rtx = (cgx + S.map_origin.wrx) * 16
              local rtz = (S.map_origin.wrz - cgz) * 16
              local FRONT = {   -- 2 tiles directly in front of the door
                n = { {rtx+7,rtz+14}, {rtx+8,rtz+14} },
                s = { {rtx+7,rtz+1 }, {rtx+8,rtz+1 } },
                e = { {rtx+14,rtz+7}, {rtx+14,rtz+8} },
                w = { {rtx+1,rtz+7 }, {rtx+1,rtz+8 } },
              }
              local CSHAPE = {  -- C around the 2-tile lock: 2 flanks + far column
                n = { {rtx+6,rtz+14},{rtx+9,rtz+14}, {rtx+6,rtz+13},{rtx+7,rtz+13},{rtx+8,rtz+13},{rtx+9,rtz+13} },
                s = { {rtx+6,rtz+1 },{rtx+9,rtz+1 }, {rtx+6,rtz+2 },{rtx+7,rtz+2 },{rtx+8,rtz+2 },{rtx+9,rtz+2 } },
                e = { {rtx+14,rtz+6},{rtx+14,rtz+9}, {rtx+13,rtz+6},{rtx+13,rtz+7},{rtx+13,rtz+8},{rtx+13,rtz+9} },
                w = { {rtx+1,rtz+6 },{rtx+1,rtz+9 }, {rtx+2,rtz+6 },{rtx+2,rtz+7 },{rtx+2,rtz+8 },{rtx+2,rtz+9 } },
              }
              -- If ANY door of this room is a guardian door (-> unopened ? room),
              -- every door marker in the room gets a second RED outline, until
              -- that ? room is opened (guardian_door then goes false). Never for
              -- the base room.
              local is_base = false
              for _, nm in ipairs(cell.images) do
                if nm == "ICON_BASE" then is_base = true; break end
              end
              local room_guard = false
              if not is_base then
                for dir in pairs(cell_doors(cell)) do
                  if FRONT[dir] and guardian_door(cgx, cgz, dir, rtx, rtz) then
                    room_guard = true; break
                  end
                end
              end
              for dir in pairs(cell_doors(cell)) do
                if FRONT[dir] then
                  local style = chevron_style(cgx, cgz, dir)
                  local color = door_color(cgx, cgz, dir)
                  -- Openability distinction (solid vs corner brackets) is PARKED:
                  -- draw the C solid regardless. `style` still carries
                  -- "solid"/"brackets" and the bracket renderer is intact -- swap
                  -- `"solid"` back to `style` to re-enable it.
                  local tiles = style and CSHAPE[dir] or FRONT[dir]
                  shapes[#shapes + 1] = { tiles = tiles, mode = "solid", color = color, red = room_guard }
                end
              end
            end
          end
        end
      end
      if #shapes > 0 then
        local m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16 = sr_view_proj:get()
        sr_program_occ:setuniformmatrix4f(1, false,
          m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16)
        sr_program_occ:setuniformdepthbuffer(3, event)   -- occlude behind models
        local vw, vh = event:size()
        sr_program_occ:setuniform2f(4, vw, vh)
        local T  = RES_TILE_UNITS
        local Tk = 32          -- outline half-thickness (world units)
        local TK = 176         -- corner-bracket tick length
        local RD, RT, RO = 62, 18, 80   -- red 2nd outline: offset out, half-thick, corner extend
        local y  = py + 20     -- lift above the floor (occlusion, see shader)
        -- Build the outline quads, bucketed by colour (parity of the room the
        -- door leads to). Merged perimeter: draw a tile edge only when the
        -- neighbouring tile is NOT in the same shape (no internal lines). Corner
        -- brackets: a tick along each boundary edge at every corner.
        local buckets = { gray = {}, green = {}, yellow = {}, red = {} }
        local fills   = { gray = {}, green = {}, yellow = {} }   -- per-colour tile fills
        for _, sh in ipairs(shapes) do
          local quads = buckets[sh.color]
          local fillq = fills[sh.color]
          local rq = sh.red and buckets.red or nil   -- second (red) outline sink
          local set = {}
          for _, t in ipairs(sh.tiles) do set[t[1] .. "," .. t[2]] = true end
          for _, t in ipairs(sh.tiles) do            -- fill matches the outline colour
            fillq[#fillq+1] = { t[1]*T, t[2]*T, (t[1]+1)*T, (t[2]+1)*T }
          end
          if sh.mode == "solid" then
            -- Merged perimeter: draw a tile edge only where the neighbouring
            -- tile is not in the shape (shared edges vanish -> no inner lines).
            -- If flagged, also emit that edge shifted OUTWARD (RD) as the red 2nd
            -- outline, extended by RO at the ends so its corners close.
            for _, t in ipairs(sh.tiles) do
              local tx, tz = t[1], t[2]
              local x1, x2, z1, z2 = tx*T, (tx+1)*T, tz*T, (tz+1)*T
              if not set[tx .. "," .. (tz-1)] then
                quads[#quads+1] = {x1, z1-Tk, x2, z1+Tk}
                if rq then rq[#rq+1] = {x1-RO, z1-RD-RT, x2+RO, z1-RD+RT} end
              end
              if not set[tx .. "," .. (tz+1)] then
                quads[#quads+1] = {x1, z2-Tk, x2, z2+Tk}
                if rq then rq[#rq+1] = {x1-RO, z2+RD-RT, x2+RO, z2+RD+RT} end
              end
              if not set[(tx-1) .. "," .. tz] then
                quads[#quads+1] = {x1-Tk, z1, x1+Tk, z2}
                if rq then rq[#rq+1] = {x1-RD-RT, z1-RO, x1-RD+RT, z2+RO} end
              end
              if not set[(tx+1) .. "," .. tz] then
                quads[#quads+1] = {x2-Tk, z1, x2+Tk, z2}
                if rq then rq[#rq+1] = {x2+RD-RT, z1-RO, x2+RD+RT, z2+RO} end
              end
            end
          else
            -- Corner brackets at EVERY corner -- outer convex AND inner concave
            -- (the C's notch). Grid-point method: at each tile-corner look at the
            -- 4 surrounding tiles; where a horizontal and a vertical boundary edge
            -- meet is a corner. Tick along each boundary edge from that point.
            local pts = {}
            for _, t in ipairs(sh.tiles) do
              local tx, tz = t[1], t[2]
              pts[tx .. "," .. tz]         = {tx, tz}
              pts[(tx+1) .. "," .. tz]     = {tx+1, tz}
              pts[tx .. "," .. (tz+1)]     = {tx, tz+1}
              pts[(tx+1) .. "," .. (tz+1)] = {tx+1, tz+1}
            end
            for _, p in pairs(pts) do
              local cx, cz = p[1], p[2]
              local i00 = set[(cx-1) .. "," .. (cz-1)] ~= nil   -- NW tile
              local i10 = set[cx .. "," .. (cz-1)] ~= nil       -- NE
              local i01 = set[(cx-1) .. "," .. cz] ~= nil       -- SW
              local i11 = set[cx .. "," .. cz] ~= nil           -- SE
              local bN, bS = i00 ~= i10, i01 ~= i11             -- vertical edges up/down
              local bW, bE = i00 ~= i01, i10 ~= i11             -- horizontal edges left/right
              if (bN or bS) and (bW or bE) then                 -- a real corner
                local wx, wz = cx*T, cz*T
                if bN then quads[#quads+1] = {wx-Tk, wz-TK, wx+Tk, wz   } end
                if bS then quads[#quads+1] = {wx-Tk, wz,    wx+Tk, wz+TK} end
                if bW then quads[#quads+1] = {wx-TK, wz-Tk, wx,    wz+Tk} end
                if bE then quads[#quads+1] = {wx,    wz-Tk, wx+TK, wz+Tk} end
              end
            end
          end
        end
        local COLORS = {
          { "gray",   0.62, 0.62, 0.62 },
          { "green",  0.25, 0.90, 0.35 },
          { "yellow", 1.00, 0.90, 0.15 },
          { "red",    1.00, 0.15, 0.15 },   -- guardian-room 2nd outline, drawn last
        }
        -- Fills FIRST, each matching its outline colour, UNDER the lines (a touch
        -- lower so the outline stays crisp on top).
        for _, c in ipairs(COLORS) do
          local fq = fills[c[1]]
          if fq and #fq > 0 then
            sr_program_occ:setuniform4f(2, c[2], c[3], c[4], 0.4)
            local gb = bolt.createbuffer(#fq * 6 * sr_bytes_per_vert)
            local goff = 0
            for _, q in ipairs(fq) do goff = sr_push_quad(gb, goff, q[1], q[2], q[3], q[4], y - 6) end
            local sbuf = bolt.createshaderbuffer(gb)
            sr_program_occ:drawtogameview(event, sbuf, #fq * 6)
          end
        end
        for _, c in ipairs(COLORS) do
          local quads = buckets[c[1]]
          if #quads > 0 then
            sr_program_occ:setuniform4f(2, c[2], c[3], c[4], 0.9)
            local gb = bolt.createbuffer(#quads * 6 * sr_bytes_per_vert)
            local goff = 0
            for _, q in ipairs(quads) do
              goff = sr_push_quad(gb, goff, q[1], q[2], q[3], q[4], y)
            end
            local sbuf = bolt.createshaderbuffer(gb)
            sr_program_occ:drawtogameview(event, sbuf, #quads * 6)
          end
        end
      end
    end
  end
  -- NB: resource_boxes / review_boxes are NOT reset here. The resource scan
  -- that fills them only runs at ~5Hz (onrender3d scan gate), so they must
  -- persist and re-draw every frame between scans -- otherwise they'd blink on
  -- for one frame per 200ms. They're cleared just before each scan instead
  -- (onswapbuffers, when scan_frame goes true).

  -- 1b) Ground-key highlights. Thick BRIGHT-MAGENTA outline + inset white
  --     under-outline for extra pop against dungeon browns. Drawn on top of
  --     the resource layer so it's never occluded by a bonus/tier outline.
  if #key_boxes > 0 then
    local m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16 = sr_view_proj:get()
    sr_program:setuniformmatrix4f(1, false,
      m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16)
    local function draw_key_ring(thickness, r, g, b, a, y_lift)
      local kb = bolt.createbuffer(#key_boxes * 4 * 6 * sr_bytes_per_vert)
      local koff = 0
      for _, b in ipairs(key_boxes) do
        local x1 = b.tx * RES_TILE_UNITS
        local x2 = (b.tx + 1) * RES_TILE_UNITS
        local z1 = b.tz * RES_TILE_UNITS
        local z2 = (b.tz + 1) * RES_TILE_UNITS
        local y  = (b.y or 0) + y_lift
        koff = sr_push_quad(kb, koff, x1, z1 - thickness, x2, z1 + thickness, y)
        koff = sr_push_quad(kb, koff, x1, z2 - thickness, x2, z2 + thickness, y)
        koff = sr_push_quad(kb, koff, x1 - thickness, z1, x1 + thickness, z2, y)
        koff = sr_push_quad(kb, koff, x2 - thickness, z1, x2 + thickness, z2, y)
      end
      sr_program:setuniform4f(2, r, g, b, a)
      local sbuf = bolt.createshaderbuffer(kb)
      sr_program:drawtogameview(event, sbuf, #key_boxes * 4 * 6)
    end
    -- Outer bright-magenta ring, then inset white for a "targeted" halo effect.
    draw_key_ring(80, 1.0, 0.15, 0.85, 1.0, 8)      -- thick magenta
    draw_key_ring(30, 1.0, 1.0, 1.0, 1.0, 12)       -- white inset
  end
  -- NB: key_boxes is NOT reset here -- like resource_boxes it's refilled only on
  -- the 5Hz scan, so it must persist between scans (cleared just before each
  -- scan in onswapbuffers) or the key highlights blink at 5Hz.

  -- 2) Scan-range outline (independent toggle). Snapped to the tile grid so
  --    it aligns with the tile-based detection above: range 1 = a 3x3 block
  --    of tiles around the player's current tile.
  if not SCAN_RANGE_VISIBLE then return end
  local pp = bolt.playerposition()
  if not pp then return end
  local px, py, pz = pp:get()
  local ptx = math.floor(px / RES_TILE_UNITS)
  local ptz = math.floor(pz / RES_TILE_UNITS)
  local x_lo = (ptx - SCAN_RANGE_TILES) * RES_TILE_UNITS
  local x_hi = (ptx + SCAN_RANGE_TILES + 1) * RES_TILE_UNITS
  local z_lo = (ptz - SCAN_RANGE_TILES) * RES_TILE_UNITS
  local z_hi = (ptz + SCAN_RANGE_TILES + 1) * RES_TILE_UNITS
  local thick = 20   -- world units
  local buf = bolt.createbuffer(4 * 6 * sr_bytes_per_vert)
  local off = 0
  local y = py + 8
  -- North edge
  off = sr_push_quad(buf, off, x_lo, z_lo - thick, x_hi, z_lo + thick, y)
  -- South edge
  off = sr_push_quad(buf, off, x_lo, z_hi - thick, x_hi, z_hi + thick, y)
  -- West edge
  off = sr_push_quad(buf, off, x_lo - thick, z_lo, x_lo + thick, z_hi, y)
  -- East edge
  off = sr_push_quad(buf, off, x_hi - thick, z_lo, x_hi + thick, z_hi, y)
  local m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16 = sr_view_proj:get()
  sr_program:setuniformmatrix4f(1, false,
    m1,m2,m3,m4, m5,m6,m7,m8, m9,m10,m11,m12, m13,m14,m15,m16)
  sr_program:setuniform4f(2, 0.4, 0.85, 1.0, 0.85)   -- cyan
  local sbuf = bolt.createshaderbuffer(buf)
  sr_program:drawtogameview(event, sbuf, 4 * 6)
end)

-- ============================================================================
-- Ground-key cursor hint: when a key is detected on the ground, draw that key's
-- minimap icon next to the mouse so the player can see WHICH key is down without
-- looking away. Icons are the full-RGBA key images bundled at
-- data/key_icons.txt ("name|w|h|hex"), built into one cached surface per name.
-- State lives on S (the main chunk is at the Lua 5.1 200-local ceiling).
-- ============================================================================
bolt.onmousemotion(function (event)
  S.cursor_mx, S.cursor_my = event:xy()
end)

local function key_icon(name)
  local surf = S.key_icon_surf
  if not surf then surf = {}; S.key_icon_surf = surf end
  local cached = surf[name]
  if cached ~= nil then return cached or nil end          -- false = no image
  local raw_tbl = S.key_icon_raw
  if not raw_tbl then
    raw_tbl = {}
    local raw = SET.load_or_seed("key_icons.txt") or ""
    for line in raw:gmatch("[^\r\n]+") do
      local nm, w, h, hex = line:match("^%s*([%w_]+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%x+)%s*$")
      if nm then raw_tbl[nm] = { w = tonumber(w), h = tonumber(h), hex = hex } end
    end
    S.key_icon_raw = raw_tbl
  end
  local d = raw_tbl[name]
  if not d then surf[name] = false; return nil end
  local ok, s = pcall(bolt.createsurfacefromrgba, d.w, d.h, hex_to_bytes(d.hex))
  surf[name] = (ok and s) and { surf = s, w = d.w, h = d.h } or false
  return surf[name] or nil
end

bolt.onswapbuffers(function (event)
  -- Invalidate the per-frame onrender3d cache (view-proj/camera/player pos) so
  -- the next frame's first mesh recomputes them. Swap runs after the frame's
  -- 3D passes, so clearing here is safe.
  S.f3d = nil
  -- Shared 5Hz scan gate: the per-batch 2D scanners (close-button anchor,
  -- timer clock OCR, examine corners) only run during frames flagged here --
  -- one full frame per 200ms. Swap runs AFTER the frame's render2d batches,
  -- so the flag set now governs the NEXT frame. Everything these scanners
  -- feed tolerates 200ms of latency by design: the anchor is sticky with a
  -- 0.5s freshness window, the clock is seconds-resolution, the box lives
  -- ~3s with a 1.5s rect persistence.
  -- CONSUMED-FLAG cadence, not edge-timed. The old form set the flag here and
  -- cleared it on the very next swap, assuming swap and 2D passes alternate
  -- strictly one-to-one. When swaps fire more than once between 2D passes
  -- (measured live 2026-07-27: 83k batches, scan_true=0 -- the second swap
  -- lowered the flag before a single batch could read it), every consumer of
  -- the 5Hz gate dies at once: floor gate, close-button anchor, resource scan,
  -- ghosts. Now the flag STAYS UP until a frame's 2D batches have actually run
  -- under it (S.scan2d_seen, set in the 2D handler), and only then retires.
  -- The swap-count fallback (24 swaps ~ 0.2-0.4s) also arms it if bolt.time()
  -- ever returns nothing in this context, which produces the same zero.
  do
    local nowg = bolt.time() or 0
    S.sw_total = (S.sw_total or 0) + 1
    S.sw_nowg = nowg
    S.sw_since = (S.sw_since or 0) + 1
    if SET.scan_frame and S.scan2d_seen then
      SET.scan_frame = false
      S.scan2d_seen = nil
      SET.scan_last = nowg
      S.sw_since = 0
    elseif not SET.scan_frame
           and ((nowg - (SET.scan_last or 0)) >= 200000 or S.sw_since >= 24) then
      SET.scan_frame = true
      S.sw_since = 0
    end
  end
  -- Snapshot ground-key names for the cursor hint EVERY frame, before the scan
  -- clear below can empty key_boxes. Reading key_boxes directly at draw time
  -- (later in this handler, after the clear) blanked the hint for one frame per
  -- scan = the flicker. key_boxes is full here (onrender3d ran this frame).
  do
    local ck = {}
    for _, b in ipairs(key_boxes) do if b.name then ck[b.name] = true end end
    S.cursor_keys = ck
  end
  -- Clear the resource highlight boxes just before the next scan refills them
  -- (the scan runs only on scan_frame). Between scans they persist and re-draw
  -- so the highlights hold steady instead of flickering at 5Hz. Clearing here
  -- (not after draw) also empties them correctly when a scan finds nothing.
  if SET.scan_frame then
    resource_boxes = {}
    review_boxes = {}
    key_boxes = {}
    -- Ghosts clear on the same cadence: detection only runs on scan frames, so
    -- clearing every frame would flicker the highlight 11 frames out of 12. The
    -- cost is that the vulnerable pick can be up to one scan interval (~200ms)
    -- behind the game's rotation.
    ghost_boxes = {}
  end
  -- FLOOR GATE (FLOOR_ICON): ground-truth floor presence. Falling edge ->
  -- freeze all mapping with the finished floor on display (same freeze
  -- philosophy as floor-dead, minus the banner). Rising edge -> sterile
  -- restart: clear the graph and wipe per-floor state BEFORE the new
  -- floor's first observation can land. Runs before the examine tick and
  -- process_room_observations so an edge takes effect this very swap.
  -- Inert until FLOOR_ICON is cataloged.
  if floor_gate_armed() then
    local nowf = bolt.time() or 0
    -- FALLING debounce: the icon can drop out for a second or more mid-floor
    -- (sparse-render frames, brief occlusion, resolution jitter) without the
    -- floor having ended -- and a false FALLING wipes map_origin + the anchor,
    -- which then can't re-calibrate unless the player is back in base (killed
    -- a 2-account sync test, 2026-07-20: a 1.3s blip wiped calibration). A
    -- real floor-end hides the icon for the whole loading screen (many
    -- seconds), and the >128-tile jump detector catches transitions anyway,
    -- so 4s is safely below a real gap and well above a blip.
    local present = S.floor_icon_us ~= nil and (nowf - S.floor_icon_us) < 4000000
    if present and not S.floor_active then
      S.floor_active = true
      S.floor_rise_us = nowf   -- start the stabilize window (process_room_observations)
      rooms_by_cell = {}
      room_observations = {}
      wipe_floor_state()
      if SET.DEV then
        S.diag_log = (S.diag_log or "") .. string.format(
          "floor gate RISING at %.1fs -- graph cleared, floor state wiped\n", nowf / 1e6)
        SET.dev_save("floor_diag.txt", S.diag_log)
      end
    elseif not present and S.floor_active then
      S.floor_active = false
      if SET.DEV then
        S.diag_log = (S.diag_log or "") .. string.format(
          "floor gate FALLING at %.1fs -- mapping frozen\n", nowf / 1e6)
        SET.dev_save("floor_diag.txt", S.diag_log)
      end
    end
  end
  -- Line Draw: clear this frame's identified keys now that onrendergameview has
  -- consumed them. Next frame's onrender3d passes refill from scratch.
  SET.line.frame_keys = {}
  -- Floor timer + HUD: own floor-change detection + display push, every frame.
  SET.timer.tick()
  SET.examine.tick()   -- skill-door examine: extraction + door binding
  SET.sync.tick()      -- party sync: heartbeat + diag
  -- Observation-pipeline diagnostic. It MUST live here rather than inside
  -- process_room_observations: that function early-returns on
  -- `#room_observations == 0` before reaching any instrumentation, which is
  -- precisely the blank-map case we need to see. Logs the raw observation count
  -- alongside the region actually in use, which separates "region is wrong" from
  -- "signatures aren't matching". Transition-triggered, not per-frame, so it
  -- doesn't churn the disk at frame rate.
  if SET.DEV then
    S.obs_n = (S.obs_n or 0) + 1
    local nobs = #room_observations
    local nrooms = 0
    for _ in pairs(rooms_by_cell) do nrooms = nrooms + 1 end
    local flipped = (nobs == 0) ~= ((S.obs_last or 0) == 0)
    if S.obs_n <= 5 or flipped then
      S.obs_log = ((S.obs_log or "") .. string.format(
        "n=%d obs=%d rooms=%d anchor=%s,%s cfg_region=%d,%d,%d,%d\n",
        S.obs_n, nobs, nrooms,
        tostring(S.close_anchor_x), tostring(S.close_anchor_y),
        region_x, region_y, region_w, region_h)):sub(-3000)
      SET.dev_save("obs_diag.txt", S.obs_log)
    end
    S.obs_last = nobs
  end
  -- Room graph: process the observations collected this frame, then reset the
  -- buffer so the next frame starts fresh. Runs BEFORE the reload block so
  -- we're always working with the freshest catalog.
  process_room_observations()
  room_observations = {}
  S.keybag_tick = S.keybag_tick + 1
  _settings_poll_counter = _settings_poll_counter + 1
  if _settings_poll_counter >= 30 then
    _settings_poll_counter = 0
    poll_settings()
  end
  _reload_counter = _reload_counter + 1
  if _reload_counter >= 60 then
    _reload_counter = 0
    local changed = false
    if reload_signatures() then changed = true end
    if reload_ignored()    then changed = true end
    SET.res.reload_all()
    SET.icons.reload_all()
    if changed then
      panel_dirty = true; frame_sigs = {}
      -- img_signatures.txt changed on disk (e.g. a marker cataloged at
      -- runtime): rebuild the cached img atlas and re-ship it, or an open
      -- rooms panel keeps rendering the fallback glyph for the new icon.
      _img_atlas_msg = nil
      if rooms_browser then
        local a = build_img_atlas_msg()
        if a and #a > 0 then rooms_browser:sendmessage(a) end
      end
    end
    -- Re-ship the key atlas to any open panels. If icons_by_n / icons_data
    -- weren't populated when the panels first opened, the atlas message went
    -- out empty; this fires a fresh push once catalogs are actually loaded.
    -- Cheap when the panel already has the icons (dedup is client-side on
    -- ImageData reassignment; still fine to skip if we know it's cached).
    if SET.icons and not SET.icons.keys_atlas_cached() then
      local msg = SET.icons.keys_atlas_msg()
      if #msg > 9 then   -- longer than the "key_mesh:" prefix alone
        if rooms_browser then rooms_browser:sendmessage(msg) end
        if keys_browser  then keys_browser:sendmessage(msg)  end
      end
    end
  end

  -- Resources: age unknowns each frame; dump snapshot 4× per second.
  SET.res.tick()
  SET.icons.tick()
  _res_snap_counter = _res_snap_counter + 1
  if _res_snap_counter >= 15 then
    _res_snap_counter = 0
    SET.res.dump_queue()
    SET.icons.dump_queue()
    dump_rooms()
  elseif SET.parity_kick then
    -- Event-driven repaint: an examine bind just changed parity evidence --
    -- recompute and push to the rooms panel THIS swap instead of waiting out
    -- the dump cadence. Idempotent: sends are hash-deduped, file writes
    -- hash-gated, and kicks only fire on actual binds.
    dump_rooms()
  end
  SET.parity_kick = nil
  -- (Pink outline around queued icons removed — the panel picker is the
  -- primary classification workflow now.)
  frame_sigs_ttl_counter = frame_sigs_ttl_counter + 1
  if frame_sigs_ttl_counter >= FRAME_SIGS_TTL then
    frame_sigs_ttl_counter = 0
    frame_sigs = {}
  end
  push_panel()

  -- Click-through map: blit the pixel surface to screen directly below the
  -- header bar, every frame (the game clears the screen each frame). map.html
  -- renders at device-pixel-ratio (src region = map_frame_edge, e.g. 2x), and
  -- we draw that down to the logical on-screen edge (map_edge()) so it's crisp
  -- on HiDPI. Gated on rooms_browser (closed -> nothing) and map_frame_ready
  -- (never blit an uninitialised surface).
  if rooms_browser and S.map_surface and S.map_frame_ready then
    local src = S.map_frame_edge or 382
    local dst = map_edge()
    S.map_surface:drawtoscreen(0, 0, src, src, rooms_x, rooms_y + MAP_VIS_H, dst, dst)
  end

  -- Ground-key cursor hint: draw the icon of every unique key currently
  -- detected on the ground next to the cursor, stacked. Drawn from the
  -- per-frame S.cursor_keys snapshot (taken above before the scan clear) so it
  -- holds steady instead of flickering. Independent of the map panel, so it
  -- shows even with the map closed. Drawn after the map blit so it sits on top.
  if PLUGIN_ENABLED and S.cursor_mx and S.cursor_keys then
    local oy = 0
    for name in pairs(S.cursor_keys) do
      local ki = key_icon(name)
      if ki then
        local sc = 2
        ki.surf:drawtoscreen(0, 0, ki.w, ki.h,
          S.cursor_mx + 20, S.cursor_my + 20 + oy, ki.w * sc, ki.h * sc)
        oy = oy + ki.h * sc + 3
      end
    end
  end

  --[[  Path draw & diagnostics disabled — kept for later.
  _diag_counter = (_diag_counter or 0) + 1
  if _diag_counter >= 60 then
    _diag_counter = 0
    local sample = {}
    for i, p in ipairs(path_passages) do
      if i > 5 then break end
      sample[i] = string.format("%s@(%d,%d)", p.name, p.x, p.y)
    end
    bolt.saveconfig("path_dbg.txt", string.format(
      "base=%s player=%s passages=%d  first=%s\n",
      path_base and string.format("(%d,%d)", path_base.x, path_base.y) or "nil",
      path_player and string.format("(%d,%d)", path_player.x, path_player.y) or "nil",
      #path_passages,
      table.concat(sample, " ")))
  end
  if path_base and path_player and #path_passages > 0 then
    local ok, err = pcall(draw_path)
    if not ok then bolt.saveconfig("path_err.txt", tostring(err) .. "\n") end
  end
  path_base = nil
  path_player = nil
  path_passages = {}
  --]]
end)
