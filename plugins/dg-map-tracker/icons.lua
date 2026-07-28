-- ============================================================================
-- icons.lua -- icon cataloging: fingerprint capture (onrendericon /
-- onrenderbigicon), catalog + ignore + queue state, the icons.html panel,
-- classification persistence, and the keys-panel mesh atlas.
-- ============================================================================
-- Extracted verbatim from main.lua (history lives there). Loaded with
--   require("icons")({ ... deps ... })
-- and installs its interface on SET.icons. Injected accessors exist because
-- the underlying main-chunk locals are REBOUND (room_observations per frame,
-- the region rects on reposition); held references would go stale.
return function (deps)
local bolt = require("bolt")
local SET, S        = deps.SET, deps.S
local key_lower     = deps.key_lower
local observe       = deps.observe        -- feed a classified icon into the room graph
local dg_region     = deps.dg_region      -- x, y, w, h of the DG map region
local keybag_region = deps.keybag_region  -- x, y, w, h of the keybag region
local plugin_enabled = deps.plugin_enabled

local ICONS = {}
SET.icons = ICONS

local icon_browser
local open_icon_browser, close_icon_browser

-- Icon queue (populated by the onrendericon / onrenderbigicon handlers).
local icons_learned = {}
-- Icons the user has ignored, but still seen — kept in a parallel map so the
-- panel can render an "Ignored" tab for inspection / un-ignoring.
local icons_ignored_seen = {}
local last_dumped_ignored_icons_list = {}
-- Classified icons that have been observed live — for the Classified tab.
-- Populated on the icons_catalog fast-path so we get pts/mvp for previewing.
local icons_classified_seen = {}
local last_dumped_classified_icons_list = {}
-- Persistent mesh data (pts / mvp / sw / sh) per classified icon, so previews
-- work across reloads without re-sighting the icon. Loaded from
-- icons_data.txt at plugin load; appended to on auto-classify or first live
-- sighting of a catalog entry.
local icons_data = {}   -- key -> { sw, sh, mvp, pts }
-- Icon catalog state hoisted here so build_keys_atlas_msg (defined further
-- down but before reload_icons) can close over the SAME tables reload_icons
-- fills at plugin load. Otherwise the closure captured a nil upvalue.
local icons_catalog = {}    -- key -> { name, kind }
local icons_ignored = {}    -- key -> true
local icons_by_n    = {}    -- n -> list of parsed catalog entries (for scorer)
-- icons_data.txt is written ONLY by this plugin (panels read it via Lua
-- messages), so after the one load at plugin start the in-memory copy is
-- authoritative: appends accumulate in icons_data_pending and flush behind a
-- short timer. The old path paid a full disk read + rebuild + write + reparse
-- of the whole (10+ MB) file per NEW icon key, which landed as a visible
-- stall on door open -- a new room is exactly when new icons appear.
local icons_data_raw = nil       -- file contents as loaded / last flushed
local icons_data_pending = {}    -- lines appended since the last flush
local icons_data_flush_due = nil -- bolt.time() deadline for the next flush
local ICONS_DATA_FLUSH_US = 2 * 1000 * 1000
-- Snapshot of the most recently sent icon queue, so the Ignore-all handler
-- knows what to append to icon_ignored.txt.
local last_dumped_icons_list = {}
local last_ign_icons_raw = nil
-- ============================================================================
-- Icon classification (onrendericon / onrenderbigicon).
--
-- Icons rendered by the game include on-map indicators (key requirements,
-- puzzle markers, etc. in the DG minimap area). We fingerprint each unique
-- icon mesh so users can name/ignore them the same way we do with 3D
-- resources. Both event kinds are captured — a "kind" prefix in the key
-- keeps them from colliding.
--
-- Fingerprint format: "<kind>|<mcount>|<n>|IDX,X,Y,Z,R,G,B|... (5 spot verts
-- sampled from model 1's local vertex buffer). Same shape as resources so
-- the tolerant / sort+min-col scorer can be reused later if needed.
-- ============================================================================
-- icons_catalog / icons_ignored / icons_by_n are declared up near the file
-- top so build_keys_atlas_msg (which lives above reload_icons) can close over
-- them. The initial value is {} in both places; only reload_icons mutates.
local last_icons_raw = nil
-- last_ign_icons_raw forward-declared at top for the panel-message handler.

local function parse_icon_catalog_verts(rest)
  local n_str, tail = rest:match("^(%d+)|(.+)$")
  local n = tonumber(n_str)
  if not n then return nil end
  local verts = {}
  for chunk in tail:gmatch("[^|]+") do
    local ix, x, y, z, r, g, b = chunk:match(
      "^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
    if ix then
      verts[#verts + 1] = {
        idx = tonumber(ix),
        x = tonumber(x), y = tonumber(y), z = tonumber(z),
        r = tonumber(r), g = tonumber(g), b = tonumber(b),
      }
    end
    if #verts == 5 then break end
  end
  if #verts ~= 5 then return nil end
  return n, verts
end

-- icons.txt line format: <name>|<kind>|<mcount>|<n>|<idx,x,y,z,r,g,b>|... (5)
-- Prune icons_classified_seen entries whose catalog line is gone.
local function prune_classified_seen()
  for k, _ in pairs(icons_classified_seen) do
    if not icons_catalog[k] then icons_classified_seen[k] = nil end
  end
end
local function reload_icons()
  local raw = SET.load_or_seed("icons.txt")
  if raw == last_icons_raw then return end
  last_icons_raw = raw
  icons_catalog = {}
  icons_by_n = {}
  if not raw then return end
  for line in raw:gmatch("[^\r\n]+") do
    if not line:match("^%s*#") and not line:match("^%s*$") then
      local name, kind, mcount, rest = line:match("^%s*([%w_]+)|(%w+)|(%d+)|(.+)$")
      if name and kind and rest then
        local n, verts = parse_icon_catalog_verts(rest)
        if n and verts then
          -- Sort by y once for the scorer; keep unsorted for exact-key rebuild.
          local vs = { verts[1], verts[2], verts[3], verts[4], verts[5] }
          table.sort(vs, function (a, b) return a.y < b.y end)
          local entry = { name = name, kind = kind, mcount = tonumber(mcount),
                          n = n, verts = verts, verts_sorted = vs }
          icons_by_n[n] = icons_by_n[n] or {}
          icons_by_n[n][#icons_by_n[n] + 1] = entry
          -- Exact-key fast path (kind|mcount|n|verts).
          local rebuilt = string.format("%s|%s|%s", kind, mcount, rest)
          icons_catalog[rebuilt] = { name = name, kind = kind }
        end
      end
    end
  end
  prune_classified_seen()
  -- Purge any queue entries that now match the (possibly new) catalog. Runs
  -- exact-match first, tolerant-match second. Fixes the case where the user
  -- named a queue entry via tracker.py / the panel and the icon isn't
  -- currently rendering — without this the queue entry would linger.
  for key, e in pairs(icons_learned) do
    if icons_catalog[key] then
      icons_learned[key] = nil
    else
      -- Reparse the 5 sample verts out of the fingerprint key for tolerant match.
      local samples = {}
      local first_skips = 0
      for chunk in key:gmatch("[^|]+") do
        if first_skips < 3 then
          first_skips = first_skips + 1
        else
          local ix, x, y, z, r, g, b = chunk:match(
            "^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
          if ix then
            samples[#samples + 1] = {
              x = tonumber(x), y = tonumber(y), z = tonumber(z),
              r = tonumber(r), g = tonumber(g), b = tonumber(b),
            }
          end
        end
      end
      if #samples == 5 and icons_by_n[e.n] then
        table.sort(samples, function (a, b) return a.y < b.y end)
        local COL_WEIGHT = 2
        local REJECT_CUTOFF = 100
        local best_score, best_entry = math.huge, nil
        for dn = -2, 2 do
          local bucket = icons_by_n[e.n + dn]
          if bucket then
            for _, entry in ipairs(bucket) do
              local pos_sum, col_sum = 0, 0
              for i = 1, 5 do
                local ev = entry.verts_sorted[i]
                local lv = samples[i]
                if not ev or not lv then pos_sum = math.huge; break end
                pos_sum = pos_sum + math.abs(ev.x - lv.x) + math.abs(ev.y - lv.y) + math.abs(ev.z - lv.z)
                col_sum = col_sum + math.abs(ev.r - lv.r) + math.abs(ev.g - lv.g) + math.abs(ev.b - lv.b)
              end
              if pos_sum ~= math.huge then
                local score = pos_sum + COL_WEIGHT * col_sum
                if score < best_score then best_score = score; best_entry = entry end
              end
            end
          end
        end
        if best_entry and best_score <= REJECT_CUTOFF then
          icons_catalog[key] = { name = best_entry.name, kind = best_entry.kind }
          icons_learned[key] = nil
        end
      end
    end
  end
end

-- icons_data.txt format: <key>|SW=<n>|SH=<n>|MVP=<16 floats>|PTS=<catalog>\n
-- The KEY may contain '|' characters, so we anchor on the SW= sentinel.
local function reload_icons_data()
  if icons_data_raw ~= nil then return end  -- loaded once; memory is authority
  local raw = SET.load_or_seed("icons_data.txt")
  icons_data_raw = raw or ""
  icons_data = {}
  if not raw then return end
  for line in raw:gmatch("[^\r\n]+") do
    if not line:match("^%s*#") and #line > 0 then
      -- Split "key|SW=…|SH=…|MVP=…|PTS=…" by locating the first "|SW=".
      local sw_at = line:find("|SW=", 1, true)
      if sw_at then
        local key = line:sub(1, sw_at - 1)
        local tail = line:sub(sw_at + 1)
        local sw = tail:match("^SW=(%-?%d+)|")
        local sh = tail:match("|SH=(%-?%d+)|")
        local mvp = tail:match("|MVP=([^|]+)|")
        local pts = tail:match("|PTS=(.+)$")
        if sw and sh and mvp and pts then
          icons_data[key] = {
            sw = tonumber(sw), sh = tonumber(sh),
            mvp = mvp, pts = pts,
          }
        end
      end
    end
  end
end

-- Append one icons_data.txt line if we don't already have data for this key.
-- NB: assigns the local forward-declared above -- the manual-classify handler
-- calls this from further UP the file, and a call to a not-yet-declared local
-- silently compiles to a nil global read. It did exactly that, and the pcall
-- around that handler swallowed the error into classify_err.txt, so manual
-- classification quietly never persisted its rasterisation data. The two live
-- call sites below the declaration were unaffected, which is why icons_data.txt
-- kept growing and hid it.
function persist_icon_data(key, sw, sh, mvp, pts)
  if not key or key == "" then return end
  if icons_data[key] then return end
  if not pts or pts == "" or not mvp or mvp == "" then return end
  icons_data[key] = { sw = sw or 0, sh = sh or 0, mvp = mvp, pts = pts }
  icons_data_pending[#icons_data_pending + 1] = string.format(
    "%s|SW=%d|SH=%d|MVP=%s|PTS=%s\n", key, sw or 0, sh or 0, mvp, pts)
  if not icons_data_flush_due then
    icons_data_flush_due = (bolt.time() or 0) + ICONS_DATA_FLUSH_US
  end
end

local function reload_ignored_icons()
  local raw = SET.load_or_seed("icon_ignored.txt")
  if raw == last_ign_icons_raw then return end
  last_ign_icons_raw = raw
  icons_ignored = {}
  if raw then
    for line in raw:gmatch("[^\r\n]+") do
      if not line:match("^%s*#") and not line:match("^%s*$") then
        icons_ignored[line] = true
      end
    end
  end
  -- Prune the display-only mirror: anything no longer in icons_ignored should
  -- disappear from the Ignored tab. Without this, entries stay visible even
  -- after the file has been cleared out.
  for k, _ in pairs(icons_ignored_seen) do
    if not icons_ignored[k] then icons_ignored_seen[k] = nil end
  end
end
reload_icons()
reload_ignored_icons()
reload_icons_data()

-- Seed the Classify picker in the icons panel with the bundled signature-name
-- snapshot (data/mm_signatures.txt) -- self-contained, no dependency on any
-- other plugin being installed.
local minimap_names = {}
local last_mmhide_names_raw = nil
local function reload_minimap_names()
  local raw = SET.read_bundled("mm_signatures.txt")
  if raw == last_mmhide_names_raw then return end
  last_mmhide_names_raw = raw
  minimap_names = {}
  if #raw == 0 then return end
  for line in raw:gmatch("[^\r\n]+") do
    local name = line:match("^([%w_]+)|%d+|%d+|")
    if name then minimap_names[#minimap_names + 1] = name end
  end
  table.sort(minimap_names)
end
reload_minimap_names()

-- Rehydrate the icon queue from persisted mesh data. Any key in icons_data
-- that isn't classified and isn't ignored is a queued (unnamed) icon — pull
-- it back so a plugin reload doesn't lose the queue.
for key, d in pairs(icons_data) do
  if not icons_catalog[key] and not icons_ignored[key] and not icons_learned[key] then
    local kind, _, n_s = key:match("^([^|]+)|([^|]+)|(%d+)|")
    icons_learned[key] = {
      key = key, kind = kind or "icon", n = tonumber(n_s) or 0,
      sx = 0, sy = 0, sw = d.sw, sh = d.sh,
      seen = 1, ttl = ICONS_LEARNED_TTL,
      pts = d.pts, mvp = d.mvp,
    }
  end
end


local ICONS_LEARNED_TTL = 300   -- ~5s @ 60fps of not being seen → drop from queue
local function fingerprint_icon(event, kind)
  local mcount = event:modelcount()
  if not mcount or mcount < 1 then return nil end
  local n_total = 0
  for m = 1, mcount do
    n_total = n_total + (event:modelvertexcount(m) or 0)
  end
  if n_total < 4 then return nil end
  local n1 = event:modelvertexcount(1) or 0
  if n1 < 5 then return nil end
  local step = math.max(1, math.floor(n1 / 6))
  local parts = { kind, tostring(mcount), tostring(n_total) }
  local live = {}
  for i = 1, 5 do
    local idx = math.min(n1, i * step)
    local ok_p, p = pcall(event.modelvertexpoint, event, 1, idx)
    if not ok_p or not p then return nil end
    local x, y, z = p:get()
    local ok_c, r, g, b = pcall(event.modelvertexcolour, event, 1, idx)
    if not ok_c then return nil end
    local ix = math.floor(x + 0.5)
    local iy = math.floor(y + 0.5)
    local iz = math.floor(z + 0.5)
    local ir = math.floor(r * 255 + 0.5)
    local ig = math.floor(g * 255 + 0.5)
    local ib = math.floor(b * 255 + 0.5)
    parts[#parts + 1] = string.format("%d,%d,%d,%d,%d,%d,%d", idx, ix, iy, iz, ir, ig, ib)
    live[i] = { x = ix, y = iy, z = iz, r = ir, g = ig, b = ib }
  end
  return table.concat(parts, "|"), n_total, live
end

local function on_icon_event(event, kind)
  if not plugin_enabled() then return end
  -- Screen position first: confine the queue to whatever's currently inside
  -- the draggable region overlay. Icons outside are ignored entirely — no
  -- fingerprint, no dedupe cost, no dump.
  local sx, sy, sw, sh = 0, 0, 0, 0
  local ok_xy = pcall(function () sx, sy, sw, sh = event:xywh() end)
  if not ok_xy then return end
  local cx, cy = sx + sw * 0.5, sy + sh * 0.5
  local region_x, region_y, region_w, region_h = dg_region()
  local keybag_x, keybag_y, keybag_w, keybag_h = keybag_region()
  local in_dg = cx >= region_x and cx <= region_x + region_w
             and cy >= region_y and cy <= region_y + region_h
  local in_keybag = cx >= keybag_x and cx <= keybag_x + keybag_w
             and cy >= keybag_y and cy <= keybag_y + keybag_h
  if not in_dg and not in_keybag then return end
  local key, n, live = fingerprint_icon(event, kind)
  if not key then return end
  -- Tolerant-match against the same-n bucket if the exact key misses. This is
  -- the same sort-by-y + min-color scorer we use for resources, so per-frame
  -- lighting jitter (43,71,62 vs 44,71,62 etc.) doesn't drop icons back into
  -- the queue every time they render. Caches the winning fingerprint into
  -- icons_catalog so subsequent frames hit the fast path immediately.
  if not icons_catalog[key] and icons_by_n[n] and live then
    -- Sum-of-diffs scoring (stricter than the resource scorer's min-col trick,
    -- which is only right when SOME verts are lighting-tinted — icons never are).
    -- Tight cutoff: only accepts near-identical fingerprints (per-frame jitter
    -- of ~1-2 channels) so same-mesh different-colour families (all diamonds,
    -- all corners, etc.) never bleed into each other.
    local COL_WEIGHT = 2
    local REJECT_CUTOFF = 100
    local N_WINDOW = 2
    local live_sorted = { live[1], live[2], live[3], live[4], live[5] }
    table.sort(live_sorted, function (a, b) return a.y < b.y end)
    local best_score, best_entry = math.huge, nil
    for dn = -N_WINDOW, N_WINDOW do
      local bucket = icons_by_n[n + dn]
      if bucket then
        for _, entry in ipairs(bucket) do
          local pos_sum, col_sum = 0, 0
          local ev_list = entry.verts_sorted
          for i = 1, 5 do
            local ev = ev_list[i]
            local lv = live_sorted[i]
            if not ev or not lv then pos_sum = math.huge; break end
            pos_sum = pos_sum + math.abs(ev.x - lv.x) + math.abs(ev.y - lv.y) + math.abs(ev.z - lv.z)
            col_sum = col_sum + math.abs(ev.r - lv.r) + math.abs(ev.g - lv.g) + math.abs(ev.b - lv.b)
          end
          if pos_sum ~= math.huge then
            local score = pos_sum + COL_WEIGHT * col_sum
            if score < best_score then best_score = score; best_entry = entry end
          end
        end
      end
    end
    if best_entry and best_score <= REJECT_CUTOFF then
      icons_catalog[key] = { name = best_entry.name, kind = best_entry.kind }
    end
  end
  -- Keybag path: if this icon rendered inside the keybag region and matches
  -- a color_shape key name, stamp it into S.keybag_state and stop. Skip the
  -- queue / ignored / classified processing below - the keybag is UI chrome,
  -- not a DG-map observation.
  if in_keybag then
    local matched = icons_catalog[key]
    local kn = matched and key_lower(matched.name)
    if kn then S.keybag_state[kn] = S.keybag_tick end
    return
  end
  if icons_ignored[key] then
    -- Still track pts/mvp/screen-pos so the Ignored tab can preview it.
    -- Capture once (like the learned queue) for cheap dedupe.
    local ie = icons_ignored_seen[key]
    if not ie then
      -- Snapshot the same fields as icons_learned so the panel + preview
      -- handler can treat them interchangeably.
      local mvp_str = ""
      local ok_mvp, mvp = pcall(event.modelviewprojmatrix, event, 1)
      if ok_mvp and mvp then
        local m = { mvp:get() }
        local strs = {}
        for i = 1, 16 do strs[i] = tostring(m[i]) end
        mvp_str = table.concat(strs, ",")
      end
      local pts = {}
      local budget = 3000
      for mi = 1, event:modelcount() do
        if budget <= 0 then break end
        local nm = event:modelvertexcount(mi) or 0
        for vi = 1, nm do
          if budget <= 0 then break end
          local ok_p, p = pcall(event.modelvertexpoint, event, mi, vi)
          if not ok_p or not p then break end
          local vx, vy, vz = p:get()
          local ok_c, r, g, b = pcall(event.modelvertexcolour, event, mi, vi)
          if not ok_c then break end
          pts[#pts + 1] = string.format("%d,%d,%d,%d,%d,%d",
            math.floor(vx + 0.5), math.floor(vy + 0.5), math.floor(vz + 0.5),
            math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
          budget = budget - 1
        end
      end
      icons_ignored_seen[key] = {
        key = key, kind = kind, n = n,
        sx = sx, sy = sy, sw = sw, sh = sh,
        pts = table.concat(pts, ";"),
        mvp = mvp_str,
      }
    else
      ie.sx = sx; ie.sy = sy; ie.sw = sw; ie.sh = sh
    end
    return
  end
  local classified = icons_catalog[key]
  if classified then
    -- Feed this icon into the room-graph pipeline. It's in the region and
    -- has a name; process_room_observations will grid-snap it onto the same
    -- 8x8 grid the 2D signature detector uses, so key icons land in the room
    -- cell they're drawn over.
    observe({
      name = classified.name,
      x = sx + sw * 0.5,
      y = sy + sh * 0.5,
    })
    -- Track for the Classified tab. Capture pts/mvp once so the preview modal
    -- can render the actual mesh (mirrors the ignored-seen path).
    local ce = icons_classified_seen[key]
    if not ce then
      local mvp_str = ""
      local ok_mvp, mvp = pcall(event.modelviewprojmatrix, event, 1)
      if ok_mvp and mvp then
        local m = { mvp:get() }
        local strs = {}
        for i = 1, 16 do strs[i] = tostring(m[i]) end
        mvp_str = table.concat(strs, ",")
      end
      local pts = {}
      local budget = 3000
      for mi = 1, event:modelcount() do
        if budget <= 0 then break end
        local nm = event:modelvertexcount(mi) or 0
        for vi = 1, nm do
          if budget <= 0 then break end
          local ok_p, p = pcall(event.modelvertexpoint, event, mi, vi)
          if not ok_p or not p then break end
          local vx, vy, vz = p:get()
          local ok_c, r, g, b = pcall(event.modelvertexcolour, event, mi, vi)
          if not ok_c then break end
          pts[#pts + 1] = string.format("%d,%d,%d,%d,%d,%d",
            math.floor(vx + 0.5), math.floor(vy + 0.5), math.floor(vz + 0.5),
            math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
          budget = budget - 1
        end
      end
      local pts_str = table.concat(pts, ";")
      icons_classified_seen[key] = {
        key = key, kind = kind, n = n,
        name = classified.name or "?",
        sx = sx, sy = sy, sw = sw, sh = sh,
        pts = pts_str,
        mvp = mvp_str,
      }
      -- No persist here: a recognized icon's mesh is already in icons_data
      -- under the catalog's canonical fingerprint (the only key the atlas
      -- reads). Jittered re-sightings of known icons must never re-save.
    else
      ce.sx = sx; ce.sy = sy; ce.sw = sw; ce.sh = sh
    end
    return
  end
  local entry = icons_learned[key]
  if not entry then
    -- First sighting: capture every vertex position + colour of every model
    -- into a CSV blob (x,y,z,r,g,b;…). Displayed in the modal as a top-down
    -- scatter so the user can eyeball what the icon actually looks like —
    -- no texture is exposed for icons, so this reconstructed silhouette is
    -- the best "preview" we can offer.
    local pts = {}
    local budget = 3000
    for m = 1, event:modelcount() do
      if budget <= 0 then break end
      local nm = event:modelvertexcount(m) or 0
      for vi = 1, nm do
        if budget <= 0 then break end
        local ok_p, p = pcall(event.modelvertexpoint, event, m, vi)
        if not ok_p or not p then break end
        local vx, vy, vz = p:get()
        local ok_c, r, g, b = pcall(event.modelvertexcolour, event, m, vi)
        if not ok_c then break end
        pts[#pts + 1] = string.format("%d,%d,%d,%d,%d,%d",
          math.floor(vx + 0.5), math.floor(vy + 0.5), math.floor(vz + 0.5),
          math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
        budget = budget - 1
      end
    end
    -- Capture the MVP matrix of model 1 so the modal can project the mesh
    -- into the icon's on-screen box the way the game does.
    local mvp_str = ""
    local ok_mvp, mvp = pcall(event.modelviewprojmatrix, event, 1)
    if ok_mvp and mvp then
      local m = { mvp:get() }
      local strs = {}
      for i = 1, 16 do strs[i] = tostring(m[i]) end
      mvp_str = table.concat(strs, ",")
    end
    local pts_str = table.concat(pts, ";")
    icons_learned[key] = {
      key = key, kind = kind, n = n,
      sx = sx, sy = sy, sw = sw, sh = sh,
      seen = 1, ttl = ICONS_LEARNED_TTL,
      pts = pts_str,
      mvp = mvp_str,
    }
    -- No persist for queue entries: icons_data.txt holds exactly one mesh
    -- per CATALOGED icon and is written only when an icon is named (the
    -- classify handler). Queue previews live in memory; a reload before
    -- naming just means re-sighting the icon once.
  else
    entry.sx = sx; entry.sy = sy; entry.sw = sw; entry.sh = sh
    entry.seen = entry.seen + 1
    entry.ttl = ICONS_LEARNED_TTL
    -- Lazy MVP refresh: matrix can drift with camera moves; refresh cheaply.
    if not entry.mvp or entry.mvp == "" then
      local ok_mvp, mvp = pcall(event.modelviewprojmatrix, event, 1)
      if ok_mvp and mvp then
        local m = { mvp:get() }
        local strs = {}
        for i = 1, 16 do strs[i] = tostring(m[i]) end
        entry.mvp = table.concat(strs, ",")
      end
    end
    -- Lazy pts capture: entries created before the pts logic existed have an
    -- empty pts field. Backfill on the next sighting so a click on the preview
    -- shows the full mesh.
    if (not entry.pts or entry.pts == "") then
      local pts = {}
      local budget = 3000
      for m = 1, event:modelcount() do
        if budget <= 0 then break end
        local nm = event:modelvertexcount(m) or 0
        for vi = 1, nm do
          if budget <= 0 then break end
          local ok_p, p = pcall(event.modelvertexpoint, event, m, vi)
          if not ok_p or not p then break end
          local vx, vy, vz = p:get()
          local ok_c, r, g, b = pcall(event.modelvertexcolour, event, m, vi)
          if not ok_c then break end
          pts[#pts + 1] = string.format("%d,%d,%d,%d,%d,%d",
            math.floor(vx + 0.5), math.floor(vy + 0.5), math.floor(vz + 0.5),
            math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
          budget = budget - 1
        end
      end
      entry.pts = table.concat(pts, ";")
    end
  end
end

bolt.onrendericon(function (event)    on_icon_event(event, "icon")    end)
bolt.onrenderbigicon(function (event) on_icon_event(event, "bigicon") end)

-- Batched flush of new icons_data lines: one concat + one write per burst of
-- new icons, at most every ICONS_DATA_FLUSH_US, instead of a full file round
-- trip per icon on the frame it first renders.
local function flush_icons_data()
  if #icons_data_pending == 0 then return end
  local raw = icons_data_raw or ""
  if #raw > 0 and not raw:match("\n$") then raw = raw .. "\n" end
  icons_data_raw = raw .. table.concat(icons_data_pending)
  icons_data_pending = {}
  icons_data_flush_due = nil
  bolt.saveconfig("icons_data.txt", icons_data_raw)
end

local function tick_icons()
  -- Queue entries are sticky: once an icon has been sighted, it stays in the
  -- queue until it's explicitly named or ignored. No TTL aging — the user
  -- may need to re-enter a scene to remember what a candidate looked like.
  if icons_data_flush_due and (bolt.time() or 0) >= icons_data_flush_due then
    flush_icons_data()
  end
end

local _icons_msg_last, _iignored_msg_last, _iclassified_msg_last, _names_msg_last = "", "", "", ""
local _res_msg_last, _matches_msg_last = "", ""
local function dump_icon_queue()
  local list = {}
  for _, e in pairs(icons_learned) do list[#list + 1] = e end
  -- Stable sort by fingerprint key. Live-changing fields (seen, sx/sy) would
  -- reshuffle rows every dump and make entries impossible to click.
  table.sort(list, function (a, b) return a.key < b.key end)
  last_dumped_icons_list = list
  local out = {}
  for _, e in ipairs(list) do
    out[#out + 1] = string.format("%s|%d|%d|%d|%d|%d|%d",
      e.key, e.n, e.sx, e.sy, e.sw, e.sh, e.seen)
  end
  SET.dev_save("icon_queue.txt", table.concat(out, "\n") .. "\n")

  -- Ship the same info to the panel as JSON so the Icons tab can render it.
  local function build_icon_json(src_list, cap)
    local json = { "[" }
    for i, e in ipairs(src_list) do
      if i > cap then break end
      if i > 1 then json[#json + 1] = "," end
      local samples = {}
      local first_skips = 0
      for chunk in e.key:gmatch("[^|]+") do
        if first_skips < 3 then
          first_skips = first_skips + 1
        else
          local ix, x, y, z, r, g, bl = chunk:match(
            "^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
          if ix then
            samples[#samples + 1] = string.format(
              '{"x":%s,"y":%s,"z":%s,"r":%s,"g":%s,"b":%s}',
              x, y, z, r, g, bl)
          end
        end
      end
      -- Drop live-frame fields (sx/sy/seen) so the dedupe hash stays stable
      -- when only the counter or screen position ticks. sw/sh are stable per
      -- icon so they're safe to include for the row display.
      json[#json + 1] = string.format(
        '{"k":"%s","n":%d,"sw":%d,"sh":%d,"v":[%s]}',
        e.kind, e.n, e.sw, e.sh, table.concat(samples, ","))
    end
    json[#json + 1] = "]"
    return table.concat(json)
  end

  if icon_browser then
    -- Dedupe: only push a message when the JSON actually changed. Skips DOM
    -- rebuilds inside the panel when the list is stable (which is most of the
    -- time now that queue entries are sticky). Big win for scroll smoothness.
    local icons_msg = "icons:" .. build_icon_json(list, 80)
    if icons_msg ~= _icons_msg_last then
      _icons_msg_last = icons_msg
      icon_browser:sendmessage(icons_msg)
    end

    local ilist = {}
    for _, e in pairs(icons_ignored_seen) do ilist[#ilist + 1] = e end
    table.sort(ilist, function (a, b)
      if a.key ~= b.key then return a.key < b.key end
      return false
    end)
    last_dumped_ignored_icons_list = ilist
    local iignored_msg = "iignored:" .. build_icon_json(ilist, 80)
    if iignored_msg ~= _iignored_msg_last then
      _iignored_msg_last = iignored_msg
      icon_browser:sendmessage(iignored_msg)
    end

    -- Classified list: every entry in icons.txt. Live pts/mvp/screen data is
    -- merged in from icons_classified_seen when available (so the preview
    -- modal shows the real mesh); otherwise the row still lists the name and
    -- catalog metadata but preview will be empty until the icon renders once.
    local clist = {}
    for key, cat in pairs(icons_catalog) do
      local seen = icons_classified_seen[key]
      local data = icons_data[key]
      local entry
      if seen then
        entry = seen
      else
        local kind, _, n_s = key:match("^([^|]+)|([^|]+)|(%d+)|")
        entry = {
          key = key, kind = kind or cat.kind or "icon",
          n = tonumber(n_s) or 0,
          name = cat.name,
          sx = 0, sy = 0, sw = 0, sh = 0,
          pts = "", mvp = "",
        }
      end
      -- Fill any missing mesh data from the persistent icons_data cache. Lets
      -- previews work for icons that haven't been rendered this session.
      if data then
        if (not entry.pts) or entry.pts == "" then entry.pts = data.pts end
        if (not entry.mvp) or entry.mvp == "" then entry.mvp = data.mvp end
        if (entry.sw or 0) == 0 then entry.sw = data.sw end
        if (entry.sh or 0) == 0 then entry.sh = data.sh end
      end
      entry.name = cat.name
      clist[#clist + 1] = entry
    end
    table.sort(clist, function (a, b)
      if a.name ~= b.name then return a.name < b.name end
      return a.key < b.key
    end)
    last_dumped_classified_icons_list = clist
    local json = { "[" }
    for i, e in ipairs(clist) do
      if i > 200 then break end
      if i > 1 then json[#json + 1] = "," end
      -- Strip live-frame fields (sx/sy) from the JSON so scroll-jitter caused
      -- by frame-to-frame rerenders is eliminated. Sw/Sh are stable per icon.
      json[#json + 1] = string.format(
        '{"k":"%s","n":%d,"sw":%d,"sh":%d,"name":"%s","live":%s}',
        e.kind, e.n, e.sw or 0, e.sh or 0,
        e.name, ((e.pts or "") ~= "") and "true" or "false")
    end
    json[#json + 1] = "]"
    local iclass_msg = "iclassified:" .. table.concat(json)
    if iclass_msg ~= _iclassified_msg_last then
      _iclassified_msg_last = iclass_msg
      icon_browser:sendmessage(iclass_msg)
    end

    -- Unassigned names for the Classify picker: the 63 bundled names
    -- minus anything already taken by an icons.txt entry (case-insensitive).
    local taken = {}
    for _, cat in pairs(icons_catalog) do
      taken[string.lower(cat.name)] = true
    end
    local free = {}
    for _, name in ipairs(minimap_names) do
      if not taken[string.lower(name)] then free[#free + 1] = name end
    end
    local names_msg = "unassigned:" .. table.concat(free, ",")
    if names_msg ~= _names_msg_last then
      _names_msg_last = names_msg
      icon_browser:sendmessage(names_msg)
    end
  end
end

-- Build a per-key mesh atlas the rooms panel can use to rasterise every
-- catalogued key icon at any size. Cached once so a browser reopen doesn't
-- re-serialise the whole set. Uses OUR OWN icons_data.
local _keys_atlas_msg = nil
build_keys_atlas_msg = function ()
  if _keys_atlas_msg then return _keys_atlas_msg end
  -- Rebuild each key
  -- icon from OUR OWN mesh data: icons_by_n has the name+kind per catalogued
  -- fingerprint, icons_data has the sw/sh/mvp/pts for that fingerprint. Join
  -- them and ship the mesh -- the panel rasterises via projection + barycentric
  -- fill (same math as icons.html's preview). Keys with no mesh data yet are
  -- silently skipped; they'll get shipped once observed live.
  local lines = {}
  -- Non-color_shape icons that we also want the panels to rasterise (rendered
  -- centred in the cell instead of as the coloured-square corner marker).
  local EXTRA_MESH_NAMES = {
    ["PGT_GREEN"] = "pgt_green", ["PGT_RED"] = "pgt_red",
    ["GROUP_GATESTONE"] = "group_gatestone",
  }
  for _, bucket in pairs(icons_by_n) do
    for _, entry in ipairs(bucket) do
      local kn = key_lower(entry.name) or EXTRA_MESH_NAMES[entry.name]
      if kn then
        -- Reconstruct the canonical fingerprint key the same way reload_icons
        -- did: "kind|mcount|n|v1|v2|v3|v4|v5".
        local vs = {}
        for _, v in ipairs(entry.verts) do
          vs[#vs + 1] = string.format("%d,%d,%d,%d,%d,%d,%d",
            v.idx or 0, v.x, v.y, v.z, v.r, v.g, v.b)
        end
        local rest = string.format("%d|%s", entry.n, table.concat(vs, "|"))
        local rebuilt = string.format("%s|%s|%s", entry.kind, entry.mcount, rest)
        local d = icons_data[rebuilt]
        if d and d.mvp and d.pts and d.sw and d.sh then
          lines[#lines + 1] = string.format("%s|%d|%d|%s|%s",
            kn, d.sw, d.sh, d.mvp, d.pts)
        end
      end
    end
  end
  local msg = "key_mesh:" .. table.concat(lines, "\n")
  -- Don't cache an empty result: the catalog reloads run AFTER the panel
  -- initially opens, so the first call here happens before icons_by_n /
  -- icons_data have any content. Caching empty would freeze the panel with
  -- zero key icons until a plugin reload.
  if #lines > 0 then _keys_atlas_msg = msg end
  return msg
end

local ICON_PANEL_W, ICON_PANEL_H = 320, 400
local icon_x, icon_y = 380, 640
do
  local saved = SET.get("icon_panel_pos", nil)
  if saved then icon_x, icon_y = saved[1], saved[2] end
end
open_icon_browser = function ()
  if icon_browser then return end
  icon_x, icon_y = SET.clamp(icon_x, icon_y, ICON_PANEL_W, ICON_PANEL_H)
  icon_browser = bolt.createembeddedbrowser(
    icon_x, icon_y, ICON_PANEL_W, ICON_PANEL_H, "plugin://icons.html")
  icon_browser:onreposition(function (event)
    local nx, ny = event:xywh()
    SET.set("icon_panel_pos", { nx, ny })
  end)
  icon_browser:onmessage(function (msg)
    local ipi = msg:match("^preview_icon:(%d+)$")
    if ipi then
      local idx = tonumber(ipi)
      local e = last_dumped_icons_list[idx]
      if e and icon_browser then
        local mvp = e.mvp or ""
        icon_browser:sendmessage(string.format("ipts:%d|%d|%d|%s:%s",
          idx, e.sw or 0, e.sh or 0, mvp, e.pts or ""))
        -- Mirror to disk so external tooling can inspect / compare.
        SET.dev_save(string.format("pts_icon_%d.txt", idx), e.pts or "")
        SET.dev_save(string.format("mvp_icon_%d.txt", idx), mvp)
        SET.dev_save(string.format("sz_icon_%d.txt", idx), string.format("%d,%d", e.sw or 0, e.sh or 0))
      end
      return
    end
    local pig = msg:match("^preview_ignored:(%d+)$")
    if pig then
      local idx = tonumber(pig)
      local e = last_dumped_ignored_icons_list[idx]
      if e and icon_browser then
        local mvp = e.mvp or ""
        icon_browser:sendmessage(string.format("ipts:%d|%d|%d|%s:%s",
          idx, e.sw or 0, e.sh or 0, mvp, e.pts or ""))
        -- Mirror to disk so external tooling can inspect / compare.
        SET.dev_save(string.format("pts_icon_%d.txt", idx), e.pts or "")
        SET.dev_save(string.format("mvp_icon_%d.txt", idx), mvp)
        SET.dev_save(string.format("sz_icon_%d.txt", idx), string.format("%d,%d", e.sw or 0, e.sh or 0))
      end
      return
    end
    local pcl = msg:match("^preview_classified:(%d+)$")
    if pcl then
      local idx = tonumber(pcl)
      local e = last_dumped_classified_icons_list[idx]
      if e and icon_browser then
        local mvp = e.mvp or ""
        icon_browser:sendmessage(string.format("ipts:%d|%d|%d|%s:%s",
          idx, e.sw or 0, e.sh or 0, mvp, e.pts or ""))
        -- Mirror to disk so external tooling can inspect / compare.
        SET.dev_save(string.format("pts_icon_%d.txt", idx), e.pts or "")
        SET.dev_save(string.format("mvp_icon_%d.txt", idx), mvp)
        SET.dev_save(string.format("sz_icon_%d.txt", idx), string.format("%d,%d", e.sw or 0, e.sh or 0))
      end
      return
    end
    -- Un-classify: drop the icon's line from icons.txt so it re-enters the queue.
    local ucl = msg:match("^unclassify_icon:(%d+)$")
    if ucl then
      local idx = tonumber(ucl)
      local e = last_dumped_classified_icons_list[idx]
      if e then
        local raw = SET.load_or_seed("icons.txt") or ""
        local keep = {}
        for line in raw:gmatch("[^\r\n]+") do
          -- Match by name+key (line looks like "NAME|kind|mcount|n|verts").
          local prefix = e.name .. "|" .. e.key
          if line ~= prefix then keep[#keep + 1] = line end
        end
        bolt.saveconfig("icons.txt", table.concat(keep, "\n") .. "\n")
        last_icons_raw = nil
        icons_catalog[e.key] = nil
        icons_classified_seen[e.key] = nil
      end
      return
    end
    local unig = msg:match("^unignore_icon:(%d+)$")
    if unig then
      local idx = tonumber(unig)
      local e = last_dumped_ignored_icons_list[idx]
      if e then
        local raw = SET.load_or_seed("icon_ignored.txt") or ""
        local keep = {}
        for line in raw:gmatch("[^\r\n]+") do
          if line ~= e.key then keep[#keep + 1] = line end
        end
        bolt.saveconfig("icon_ignored.txt", table.concat(keep, "\n") .. "\n")
        last_ign_icons_raw = nil
        icons_ignored[e.key] = nil
        icons_ignored_seen[e.key] = nil
      end
      return
    end
    if msg == "ignore_all_icons" then
      local prior = SET.load_or_seed("icon_ignored.txt") or ""
      if #prior > 0 and not prior:match("\n$") then prior = prior .. "\n" end
      local added = {}
      for k, _ in pairs(icons_learned) do added[#added + 1] = k end
      if #added > 0 then
        bolt.saveconfig("icon_ignored.txt",
          prior .. table.concat(added, "\n") .. "\n")
        last_ign_icons_raw = nil
        icons_learned = {}
      end
    end
    -- Classify the first queue entry as the given name (must be alphanumeric
    -- with underscores only; matches whatever the picker sends). Appends a
    -- line to icons.txt in the standard "<name>|<kind>|<mcount>|<n>|verts"
    -- format so the next reload_icons picks it up as a classified entry.
    local cname = msg:match("^classify_first:([%w_]+)$")
    if cname then
      -- Wrap in pcall: the handler runs in the browser IO thread and any
      -- error here would tear the plugin down. Log to a debug file if it
      -- fails so we can diagnose without losing the session.
      local ok, err = pcall(function ()
        local e = last_dumped_icons_list and last_dumped_icons_list[1]
        if not e or not e.key then return end
        local k2, mc2, rest = e.key:match("^([^|]+)|([^|]+)|(.+)$")
        if not (k2 and mc2 and rest) then return end
        local prior = SET.load_or_seed("icons.txt") or ""
        if #prior > 0 and not prior:match("\n$") then prior = prior .. "\n" end
        bolt.saveconfig("icons.txt",
          prior .. string.format("%s|%s|%s|%s\n", cname, k2, mc2, rest))
        last_icons_raw = nil
        icons_learned[e.key] = nil
        icons_catalog[e.key] = { name = cname, kind = k2 }
        persist_icon_data(e.key, e.sw or 0, e.sh or 0, e.mvp or "", e.pts or "")
      end)
      if not ok then
        SET.dev_save("classify_err.txt", tostring(err) .. "\n")
      end
    end
  end)
end
close_icon_browser = function ()
  if not icon_browser then return end
  icon_browser:close(); icon_browser = nil
end

-- ---- Public interface (main.lua reaches everything through SET.icons).
ICONS.open_panel  = function () open_icon_browser() end
ICONS.close_panel = function () close_icon_browser() end
-- Bucket accessor for the 3D matchers (line-draw key pointer, ground-key
-- detection): icons_by_n is rebound on reload, so callers must not hold it.
ICONS.by_n = function (n) return icons_by_n[n] end
ICONS.reload_all = function ()
  reload_icons()
  reload_ignored_icons()
  reload_icons_data()
  reload_minimap_names()
end
ICONS.tick           = function () tick_icons() end
ICONS.dump_queue     = function () dump_icon_queue() end
ICONS.keys_atlas_msg = function () return build_keys_atlas_msg() end
ICONS.keys_atlas_cached = function () return _keys_atlas_msg ~= nil end
return ICONS
end
