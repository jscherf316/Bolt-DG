-- ============================================================================
-- sync.lua -- party sync, as a module.
-- ============================================================================
-- Extracted verbatim from main.lua (history lives there). Loaded with
--   require("sync")({ ... deps ... })
-- and mutates the SET.sync stub main.lua creates early. keys_state arrives
-- as an ACCESSOR (main rebinds it on floor wipe); key_lower and
-- bind_resource_cell pass by value (assigned before this loads, never
-- rebound).
-- ============================================================================
-- Party sync -- stage 1: transport only. A hidden 2x2 embedded browser
-- (sync.html) bridges Lua to a WebSocket relay: the Lua sandbox has no
-- sockets, but plugin pages can open ws/wss to any host (bolt intercepts
-- only plugin:// and bolt-api). Design in SYNC_PLAN.md. All state on
-- SET.sync (no main-chunk locals).
--
-- Config: `sync_enabled` (control-panel toggle), `sync_url` and `sync_room`
-- (settings.json, hand-edited for now). The room code is hashed client-side
-- so the relay only ever sees the digest. Stage 1 sends a presence heartbeat
-- and logs traffic to sync_diag.txt (dev); stage 2 adds the evidence events
-- and merge handlers where marked below.
--
-- The sidecar browser sits at 0,0. NB: the client clamps embedded browsers
-- to 60x60 minimum (WINDOW_MIN_SIZE), so this occupies a 60x60 rect in the
-- top-left corner and swallows clicks inside it. Offscreen parking at
-- negative coords was tried and VERIFIED WORKING (page runs, socket
-- connects, signed-rect hit-test can't match) but abandoned by choice
-- (2026-07-17) -- restore it if the corner dead-zone ever matters.
-- ============================================================================
return function (deps)
local bolt = require("bolt")
local SET, S             = deps.SET, deps.S
local key_lower          = deps.key_lower
local bind_resource_cell = deps.bind_resource_cell
local keys_state         = deps.keys_state
local RES_TILE_UNITS     = deps.RES_TILE_UNITS
local world_room_to_grid = deps.world_room_to_grid

local SY = SET.sync
local json = require("json")

SY.status = "off"
SY.peers  = 0
SY.tx_n, SY.rx_n = 0, 0
SY.log = {}

local function slog(line)
  SY.log[#SY.log + 1] = line
  if #SY.log > 20 then table.remove(SY.log, 1) end
end

-- djb2 over the party code: the relay and its logs only ever see the digest.
-- Not cryptographic -- it hides the plaintext from casual inspection, which
-- is all a room key needs (knowing the code IS the trust boundary). Lua 5.1
-- has no bit ops; multiply-add stays exact inside doubles.
local function room_key(code)
  local h = 5381
  for i = 1, #code do
    h = (h * 33 + string.byte(code, i)) % 4294967296
  end
  return string.format("r%08x", h)
end

SY.peer_pos = {}   -- peer name -> { c = "gx,gz"|nil, t = last-seen us, f = floor id }

-- Floor identity: evidence must NEVER merge across floors. map_origin is the
-- world room of dungeon cell 0,0 -- intrinsic to the floor instance, needing
-- zero coordination IF party members share instance coordinates. That is the
-- UNVERIFIED assumption from SYNC_PLAN.md: the first two-player session must
-- confirm both clients derive the same value (compare `f` in each other's
-- presence lines in sync_diag.txt). nil until base calibration -> no events.
local function floor_id()
  local o = S.map_origin
  if not o then return nil end
  return o.wrx .. ":" .. o.wrz
end

-- Remote input validation: cells are "gx,gz" inside the 8x8 grid, and every
-- payload carries a floor id matching ours. When in doubt, drop -- a skipped
-- merge costs an inference; a poisoned one can kill the floor.
local function valid_cell(c)
  if type(c) ~= "string" then return false end
  local gx, gz = c:match("^(%d),(%d)$")
  if not gx then return false end
  return tonumber(gx) <= 7 and tonumber(gz) <= 7
end
local function floor_match(ev)
  local f = floor_id()
  return f ~= nil and ev.f == f
end

SY.open = function ()
  if SY.browser then return end
  -- Raw values as read (tostring'd, untrimmed): SY.cfg mirrors these so the
  -- settings poll can detect an edit-while-connected by raw comparison. Only
  -- the hash input is trimmed -- a stray space in a typed party code would
  -- otherwise hash to a different room and fail silently.
  local raw_room = tostring(SET.get("sync_room", ""))
  local raw_url  = tostring(SET.get("sync_url", "wss://feral-hare-9468.dg.deno.net"))
  local code = raw_room:gsub("^%s+", ""):gsub("%s+$", "")
  if code == "" then
    SY.status = "no party code"
    return
  end
  SY.cfg = { room = raw_room, url = raw_url }
  SY.browser = bolt.createembeddedbrowser(0, 0, 2, 2, "plugin://sync.html")
  SY.browser:onmessage(function (msg)
    if msg:sub(1, 3) == "st:" then
      local ok, st = pcall(json.decode, msg:sub(4))
      if ok and type(st) == "table" then
        SY.status = st.s or "?"
        if st.peers then SY.peers = st.peers end
        -- Peer count is per-connection state: a drop means we no longer know
        -- who is in the room until the rejoin's 'joined' frame re-seeds it.
        if st.s == "closed" or st.s == "stopped" then SY.peers = 0 end
        slog("st " .. msg:sub(4, 160))
      end
    elseif msg:sub(1, 3) == "rx:" then
      SY.rx_n = SY.rx_n + 1
      local ok, ev = pcall(json.decode, msg:sub(4))
      if ok and type(ev) == "table" then
        if ev.t == "peer_join" then
          SY.peers = SY.peers + 1
          -- Late-join catch-up is peer-to-peer (the relay stores nothing):
          -- every member snapshots its evidence to the room on each join.
          SY.snapshot()
        elseif ev.t == "peer_leave" then SY.peers = math.max(0, SY.peers - 1)
        elseif ev.t == "key_found" then SY.merge_key(ev)
        elseif ev.t == "resource" then SY.merge_resource(ev)
        elseif ev.t == "skill_door" then SY.merge_skill(ev)
        elseif ev.t == "presence" and type(ev.n) == "string" and #ev.n <= 32 then
          SY.peer_pos[ev.n] = { c = ev.c, f = ev.f, t = bolt.time() or 0 }
        end
        slog("rx " .. msg:sub(4, 160))
      end
    end
  end)
  SY.browser:sendmessage("cfg:" .. json.encode({
    url  = raw_url,
    room = room_key(code),
    name = bolt.charactername() or "unknown",
  }))
  SY.status = "connecting"
  slog("open")
end

SY.close = function ()
  if not SY.browser then return end
  SY.browser:sendmessage("stop")
  SY.browser:close()
  SY.browser = nil
  SY.cfg = nil
  SY.status = "off"
  SY.peers = 0
  slog("close")
end

-- Send one event table to the room. Origin name is stamped on every event
-- so merge reasons and contradictions are attributable ([[SYNC_PLAN.md]]).
SY.send = function (ev)
  if not SY.browser then return false end
  ev.n = bolt.charactername() or "unknown"
  SY.tx_n = SY.tx_n + 1
  SY.browser:sendmessage("tx:" .. json.encode(ev))
  return true
end

-- Emit one EVIDENCE event: floor-tagged, dropped when the floor has no
-- identity yet (pre-calibration evidence can't be safely attributed).
-- Local detection sites call this; merge handlers never do (no ping-pong).
SY.emit = function (ev)
  local f = floor_id()
  if not f then return false end
  ev.f = f
  return SY.send(ev)
end

-- ---- merge handlers: remote evidence -> the same sticky stores local
-- detection feeds. Grow-only, first-write-wins; conflicts are logged and the
-- local value kept (a wrong remote claim then collides in the engine as a
-- contradiction with the peer's name in the reason string).
SY.merge_key = function (ev)
  if not floor_match(ev) or not valid_cell(ev.c) then return end
  local kn = type(ev.k) == "string" and key_lower(ev.k) or nil
  if not kn then return end
  keys_state()[kn] = keys_state()[kn] or {}
  if keys_state()[kn].found == nil then
    keys_state()[kn].found = ev.c
    slog("merged key_found " .. kn .. "@" .. ev.c .. " from " .. tostring(ev.n))
  elseif keys_state()[kn].found ~= ev.c then
    SET.dev_save("keys_diag.txt",
      ("sync: %s says %s found at %s; local says %s -- kept local (first write wins)\n")
      :format(tostring(ev.n), kn, ev.c, keys_state()[kn].found))
  end
end

SY.merge_resource = function (ev)
  if not floor_match(ev) or not valid_cell(ev.c) then return end
  if type(ev.r) ~= "string" or #ev.r > 32 or not ev.r:match("^[%w_]+$") then return end
  bind_resource_cell(ev.c, ev.r, true)
  slog("merged resource " .. ev.r .. "@" .. ev.c .. " from " .. tostring(ev.n))
end

SY.merge_skill = function (ev)
  if not floor_match(ev) or not valid_cell(ev.c) then return end
  if type(ev.s) ~= "string" or #ev.s > 16 or not ev.s:match("^%a+$") then return end
  local v = tonumber(ev.v)
  if not v or v < 1 or v > 120 then return end
  local why = ("skill door examined by %s: requires level %d %s (guaranteed-%s tier)")
    :format(tostring(ev.n), v, ev.s, tostring(ev.p))
  if ev.p == "bonus" then
    if not S.skill_bonus[ev.c] then
      S.skill_bonus[ev.c] = why
      slog("merged skill_door bonus @" .. ev.c .. " from " .. tostring(ev.n))
    end
  elseif ev.p == "crit" then
    if not S.skill_crit[ev.c] then
      S.skill_crit[ev.c] = why
      slog("merged skill_door crit @" .. ev.c .. " from " .. tostring(ev.n))
    end
  end
end

-- Full evidence snapshot to the room -- runs on every peer_join so late
-- joiners catch up without the relay holding state. Dozens of tiny events at
-- most; receivers dedupe via the same first-write-wins merges as live flow.
SY.snapshot = function ()
  if not floor_id() then return end
  for kn, st in pairs(keys_state()) do
    if st.found then SY.emit({ t = "key_found", k = kn, c = st.found }) end
  end
  for ck, bag in pairs(S.resource_sightings) do
    for name in pairs(bag) do
      SY.emit({ t = "resource", c = ck, r = name })
    end
  end
  for ck, b in pairs(S.bound_doors) do
    local p = (S.skill_bonus[ck] and "bonus") or (S.skill_crit[ck] and "crit") or nil
    if p then SY.emit({ t = "skill_door", c = ck, s = b.skill, v = b.v, p = p }) end
  end
end

-- Heartbeat + diag; called every swap from onswapbuffers.
local last_beat, last_diag = 0, 0
SY.tick = function ()
  if not SY.browser then return end
  local now = bolt.time() or 0
  -- Snapshot on our own floor-id transition: peers snapshot to us on OUR
  -- join, but those frames are dropped if our origin isn't calibrated yet.
  -- Instead every member re-broadcasts once ITS identity for the new floor
  -- exists -- members calibrate within seconds of spawning in base, so the
  -- room converges at floor start with no coordination.
  local f = floor_id()
  if f ~= SY.last_f then
    SY.last_f = f
    if f then SY.snapshot() end
  end
  if now - last_beat > 5e6 then
    last_beat = now
    -- Presence carries the floor id and our cell when derivable -- the floor
    -- ids in each other's presence lines are how the two-player session
    -- verifies the map_origin-identity assumption (SYNC_PLAN.md).
    local ev = { t = "presence", f = floor_id() }
    if ev.f then
      local pp = bolt.playerposition()
      if pp then
        local px, _, pz = pp:get()
        local gx, gz = world_room_to_grid(
          math.floor(px / RES_TILE_UNITS / 16), math.floor(pz / RES_TILE_UNITS / 16))
        if gx then ev.c = gx .. "," .. gz end
      end
    end
    SY.send(ev)
  end
  if SET.DEV and now - last_diag > 1e6 then
    last_diag = now
    local pp_lines = {}
    for name, p in pairs(SY.peer_pos) do
      pp_lines[#pp_lines + 1] = string.format("  %s  cell=%s  floor=%s  seen %.0fs ago",
        name, tostring(p.c), tostring(p.f), (now - p.t) / 1e6)
    end
    -- Per-CHARACTER diag file: two accounts on one machine share this plugin's
    -- config dir, so a single sync_diag.txt would have the two clients
    -- clobbering each other -- you could never see both sides of a session.
    local dnm = (bolt.charactername() or "unknown"):gsub("[^%w]", "_")
    SET.dev_save("sync_diag_" .. dnm .. ".txt", string.format(
      "status=%s  peers=%d  tx=%d  rx=%d  floor_id=%s\n\npeers:\n%s\n\nlast events (newest last):\n%s\n",
      tostring(SY.status), SY.peers, SY.tx_n, SY.rx_n, tostring(floor_id()),
      #pp_lines > 0 and table.concat(pp_lines, "\n") or "  (none)",
      #SY.log > 0 and table.concat(SY.log, "\n") or "(none)"))
  end
end

if SET.get("sync_enabled", false) then SY.open() end
return SET.sync
end
