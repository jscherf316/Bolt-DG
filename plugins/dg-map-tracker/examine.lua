-- ============================================================================
-- examine.lua -- the skill-door examine detector (box OCR), as a module.
-- ============================================================================
-- Extracted verbatim from main.lua (history lives there). Loaded with
--   require("examine")({ ... deps ... })
-- and mutates the SET.examine stub main.lua creates early (the settings
-- poll touches SET.examine fields before this module loads).
-- The signature registries and the room graph arrive as ACCESSOR functions,
-- not tables: main.lua REBINDS those locals (reload_signatures, the
-- per-frame graph rebuild), and a held table reference would go stale.
return function (deps)
local bolt = require("bolt")
local SET, S = deps.SET, deps.S
local sig_names, sig_catalog, sig_meta =
  deps.sig_names, deps.sig_catalog, deps.sig_meta
local cell_at          = deps.cell_at
local plugin_enabled   = deps.plugin_enabled
local floor_gate_armed = deps.floor_gate_armed

-- ============================================================================
-- Skill-door examine detector -- BOX OCR. Reads the floating examine box the
-- game draws over a door (right-click -> Examine): the box is located by its
-- four corners (one image, uv-mirrored -- the context menu uses four DISTINCT
-- corner images, so "exactly 4 placements of ONE signature in rectangle
-- formation" is unique to the box), and cataloged GLYPH_* images inside the
-- rect are decoded into text. No calibration, no clock inference: every glyph
-- was labeled by a human once (the icon-queue naming flow), and matching is
-- exact bytes -- the chat-OCR predecessor died of auto-calibration poisoning
-- its own labels (letter 'd' voted in as digit 2, a '4' variant as 3...).
--
-- BOOTSTRAP: while EXAMINE_CORNER is uncataloged, a structural scan finds
-- candidate boxes; glyphs inside enter the icon queue for naming, and the
-- first box whose text PARSES auto-catalogs its corner signature -- parse
-- success is the validation that a candidate rect really is the examine box.
--
-- A reading must parse identically on two consecutive ticks (the box lives
-- ~3s) before it is trusted -- a one-off assembly glitch can never bind.
-- The reading is bound to a DOOR_<skill> map icon by census, and a level
-- inside exactly one of the skill's guaranteed ranges proves the locked
-- room's parity via S.skill_bonus / S.skill_crit. All state hangs off
-- SET.examine (no main-chunk locals).
-- ============================================================================
local EX = SET.examine
EX.status = "idle"
EX.rect = nil            -- {x0,y0,x1,y1,t, sig/w/h when structural}
EX.frame_glyphs = {}     -- GLYPH_* matches inside the rect (accumulated per tick)
EX.frame_sq = {}         -- structural-mode corner candidates (deduped by position)
EX.pending = nil         -- first of the two agreeing reads
EX.last_text = nil
EX.last_reads = {}       -- skill -> {v, t}: most recent confirmed reading
EX.opened_guard = {}     -- skill -> {v|nil, t}: a door of this skill just opened
EX.door_prev = nil       -- ck -> skill: DOOR_* icons seen on the previous tick
EX.base_ck_prev = nil    -- ICON_BASE cell last tick: a change = grid re-key
EX.base_moved_us = nil   -- when base last moved; guard arming held for 2s after

-- ---- Promotion-loop trace: frame-accurate evidence for read latency bugs.
-- Ring buffer of every consequential tick event (glyph counts, parse
-- outcomes, pending/promote/suppress decisions, bind verdicts), dumped to
-- examine_trace.txt on the diag cadence. Added after three examines showed
-- an identical, unexplained 4.02-4.03s gap between first parse and the
-- double-read confirm -- theories kept dying, so now the loop testifies.
EX.trace = {}
function EX.tr(fmt, ...)
  if not SET.DEV then return end
  local msg = string.format(fmt, ...)
  local t = (bolt.time() or 0) / 1e6
  -- Consecutive-duplicate collapse: retry loops emit the same line per swap;
  -- fold them into one entry with a repeat count (timestamp = most recent).
  if msg == EX.tr_lastmsg and #EX.trace > 0 then
    EX.tr_rep = (EX.tr_rep or 1) + 1
    EX.trace[#EX.trace] = string.format("%.3f  %s (x%d)", t, msg, EX.tr_rep)
    return
  end
  EX.tr_lastmsg, EX.tr_rep = msg, 1
  EX.trace[#EX.trace + 1] = string.format("%.3f  ", t) .. msg
  if #EX.trace > 600 then table.remove(EX.trace, 1) end
end
-- State-change logging: chatty per-swap sites (parse outcome, promotion
-- decision) interleave A,B,A,B and defeat the consecutive dedup -- the
-- first trace flooded the whole ring in 0.84s and evicted the one event
-- that mattered (the first bind verdict). Each key logs only when its
-- message CHANGES; identical repeats are silent.
EX.tr_keys = {}
function EX.trd(key, msg)
  if EX.tr_keys[key] == msg then return end
  EX.tr_keys[key] = msg
  EX.tr("%s", msg)
end

-- ---- Cataloging capture: a draggable region + a deliberate shift+click
-- trigger. The passive rect path reads; THIS path catalogs -- examine a
-- door, wait for the box, then shift+click: for ~0.6s every image inside
-- the region is queue-eligible, regardless of rect detection. Sequencing
-- beats geometry for cleanliness: the context menu is long gone by the
-- time the user triggers. Position the region once over where boxes
-- appear, then toggle the overlay OFF (it swallows clicks while visible).
EX.arm_until = 0
-- Visibility rides the shared "show_capture_zones" toggle (one switch for all
-- three zones; the old per-zone exam_region_visible key is ignored). Default
-- rect captured live from a hand-aligned fresh-install session (2026-07-27).
EX.region_visible = SET.get("show_capture_zones", true)
EX.rx, EX.ry, EX.rw, EX.rh = 2500, 304, 60, 68
do
  local saved = SET.get("exam_region", nil)
  if saved then EX.rx, EX.ry, EX.rw, EX.rh = saved[1], saved[2], saved[3], saved[4] end
end
EX.open_region = function ()
  if EX.browser then return end
  EX.rx, EX.ry = SET.clamp(EX.rx, EX.ry, EX.rw, EX.rh)
  EX.browser = bolt.createembeddedbrowser(EX.rx, EX.ry, EX.rw, EX.rh, "plugin://overlay.html")
  EX.browser:onreposition(function (event)
    local x, y, w, h = event:xywh()
    EX.rx, EX.ry, EX.rw, EX.rh = x, y, w, h
    SET.set("exam_region", { x, y, w, h })
  end)
  EX.browser:onmessage(function (msg)
    if msg == "cfg?" and EX.browser then
      EX.browser:sendmessage("cfg:WORLD MAP|3fbf5f")
    end
  end)
end
EX.close_region = function ()
  if not EX.browser then return end
  EX.browser:close(); EX.browser = nil
end
if EX.region_visible then EX.open_region() end

bolt.onmousebutton(function (event)
  if not plugin_enabled() then return end
  if not event:shift() then return end
  EX.arm_until = (bolt.time() or 0) + 600000
  EX.status = "capture armed (region snapshot, 0.6s)"
end)

-- Is a bbox centred inside the capture region during an armed window?
function EX.in_capture(x0, y0, x1, y1)
  if EX.arm_until == 0 then return false end
  local now = bolt.time()
  if not now or now >= EX.arm_until then return false end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  return cx >= EX.rx and cx <= EX.rx + EX.rw
     and cy >= EX.ry and cy <= EX.ry + EX.rh
end

-- skill -> guaranteed ranges, from data/skill_doors.txt. BOTH directions are
-- guarantees (adjudicated 2026-07-15 by the tier table's author): a level
-- inside exactly one range proves that parity; inside both (strength's
-- 106-110 overlap) or neither (the 101-105 gap) proves nothing. crit_lo == 0
-- is the file's "no crit range" sentinel (prayer/agility/summoning/
-- divination/construction).
local SKILL_DOORS = {}
do
  local raw = SET.read_bundled("skill_doors.txt")
  for line in raw:gmatch("[^\r\n]+") do
    if line:sub(1, 1) ~= "#" then
      local sk, mx, cl, ch, bl, bh = line:match("^(%a+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)")
      if sk then
        SKILL_DOORS[sk] = { max = tonumber(mx),
                            crit_lo = tonumber(cl), crit_hi = tonumber(ch),
                            bonus_lo = tonumber(bl), bonus_hi = tonumber(bh) }
      end
    end
  end
end

-- Mechanical inverse of the glyph naming convention (GLYPH_UP_A, GLYPH_LO_A,
-- GLYPH_D0..9, GLYPH_PERIOD, GLYPH_COMMA).
local function char_of(name)
  local c = name:match("^GLYPH_LO_(%a)$")
  if c then return c:lower() end
  c = name:match("^GLYPH_UP_(%a)$")
  if c then return c:upper() end
  c = name:match("^GLYPH_D(%d)$")
  if c then return c end
  if name == "GLYPH_PERIOD" then return "." end
  if name == "GLYPH_COMMA" then return "," end
  return nil
end

-- Was the current rect found by the four-corner identity scan (trusted for
-- queue admission), as opposed to the structural bootstrap fallback (reader
-- input only -- a heuristic rect must never silently catalog)?
function EX.rect_trusted()
  local r = EX.rect
  return r ~= nil and r.sig == nil
end

-- Is a bbox centred inside the current box rect? The rect stales 1.5s after
-- its last sighting so a vanished box stops admitting/collecting promptly.
function EX.in_rect(x0, y0, x1, y1)
  local r = EX.rect
  if not r then return false end
  local now = bolt.time() or 0
  if now - r.t > 1500000 then return false end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  return cx >= r.x0 and cx <= r.x1 and cy >= r.y0 and cy <= r.y1
end

-- Called by the main capture loop for every cataloged GLYPH_* match inside
-- the rect. Multi-frame stacking is fine: the assembler's shadow-dedup
-- collapses same-char entries within 2px, which covers both the drop-shadow
-- twin and the same glyph re-seen across frames.
function EX.add_glyph(name, x0, y0, x1, y1)
  EX.frame_glyphs[#EX.frame_glyphs + 1] =
    { name = name, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

-- Per-2D-batch scan, called from onrender2d. Cataloged mode: locate the four
-- EXAMINE_CORNER placements (dims-prefiltered, close-button pattern) and set
-- the rect. Bootstrap mode (corner not cataloged): collect small square
-- images; tick() groups them by signature looking for the 4x-one-sig
-- structural fingerprint.
function EX.scan2d(event, vpi, n)
  -- Throttling here is SPLIT. The box chrome itself only draws ~1 frame in
  -- 5 (measured by the corner census), so a 5Hz scan rarely coincides with
  -- a chrome frame and rect acquisition ate ~1-3s of the box's 3s life --
  -- examine deductions arrived visibly late. The cataloged four-corner scan
  -- is dims-prefiltered (only corner-sized images reach a signature check),
  -- cheap enough for EVERY frame. Only the structural bootstrap sweep --
  -- the expensive whole-range collection -- keeps the shared 5Hz gate.
  -- No floor gate: examine boxes render anywhere (any examine, any place)
  -- and cataloging wants them all. Binding is separately safe -- an empty
  -- door census just reports "no unresolved icon".
  local now = bolt.time() or 0
  local tl = sig_names()["EXAMINE_CORNER_TL"]
  local tr = sig_names()["EXAMINE_CORNER_TR"]
  local bl = sig_names()["EXAMINE_CORNER_BL"]
  local br = sig_names()["EXAMINE_CORNER_BR"]
  if tl and tr and bl and br then
    -- Four-corner identity scan. Measured reality (corner census, 2026-07-15,
    -- 169 sightings dead-equal): the box draws FOUR DISTINCT corner images,
    -- one each per draw cycle (~every 5th frame). Each corner must match its
    -- OWN signature AND sit in its geometric role -- four distinct sigs in a
    -- constrained arrangement, unfakeable by UI furniture.
    local meta = sig_meta()["EXAMINE_CORNER_TL"]
    local cw, chh = meta and meta.w or 0, meta and meta.h or 0
    local found = {}
    for i = 0, n - 1 do
      local fv = i * vpi + 1
      local ax, ay, aw, ah = event:vertexatlasdetails(fv)
      if aw == cw and ah == chh then
        local sig = SET.cached_sig(event, ax, ay, aw, ah)
        if sig then
          -- Role by NAME via the many-to-one catalog (sig -> name), not the
          -- single-valued signature_names lookup: this lets a second box
          -- outline (the red-chrome variant) share the corner names and be
          -- recognised as the same roles. Any number of variants can be
          -- cataloged under EXAMINE_CORNER_TL.. and all match here.
          local nm = sig_catalog()[sig]
          local role = (nm == "EXAMINE_CORNER_TL" and "TL") or (nm == "EXAMINE_CORNER_TR" and "TR")
            or (nm == "EXAMINE_CORNER_BL" and "BL") or (nm == "EXAMINE_CORNER_BR" and "BR") or nil
          if role then
            local x0, y0, x1, y1 = SET.vertex_bounds(event, fv, vpi)
            if x0 then
              found[role] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
            end
          end
        end
      end
    end
    local a, b, c, d = found.TL, found.TR, found.BL, found.BR
    if a and b and c and d
       and math.abs(a.y0 - b.y0) <= 3 and math.abs(c.y0 - d.y0) <= 3
       and math.abs(a.x0 - c.x0) <= 3 and math.abs(b.x0 - d.x0) <= 3
       and b.x0 - a.x0 > 20 and c.y0 - a.y0 > 10 then
      -- RISING EDGE (no live rect within the 1.5s staleness window -> a box
      -- just appeared): stamp the latency timeline for examine_diag.
      if not EX.rect or (now - EX.rect.t) > 1500000 then
        EX.t_rect = now
        EX.t_first_parse = nil
        EX.tr("RECT rising %d,%d..%d,%d", a.x0, a.y0, d.x1, d.y1)
        EX.tr_keys = {}   -- new box, fresh state-change story
      end
      EX.rect = { x0 = a.x0, y0 = a.y0, x1 = d.x1, y1 = d.y1, t = now }
    end
  else
    -- Structural bootstrap sweep: expensive (all 6..14 images, whole screen)
    -- and only needed until the corners are cataloged -- shared 5Hz gate.
    if not SET.scan_frame then return end
    for i = 0, n - 1 do
      local fv = i * vpi + 1
      local ax, ay, aw, ah = event:vertexatlasdetails(fv)
      if aw and ah and aw >= 6 and aw <= 14 and ah >= 6 and ah <= 14 then
        local sig = SET.cached_sig(event, ax, ay, aw, ah)
        if sig then
          local x0, y0, x1, y1 = SET.vertex_bounds(event, fv, vpi)
          if x0 then
            -- Dedup by (sig, ~position): a stable box contributes exactly one
            -- entry per corner however many frames it spans.
            local dup = false
            for _, e in ipairs(EX.frame_sq) do
              if e.sig == sig and math.abs(e.x0 - x0) <= 3 and math.abs(e.y0 - y0) <= 3 then
                dup = true; break
              end
            end
            if not dup then
              EX.frame_sq[#EX.frame_sq + 1] =
                { sig = sig, w = aw, h = ah, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
            end
          end
        end
      end
    end
  end
end

-- Assemble this tick's glyphs into reading order and parse the sentence.
-- Returns level, skill_lc on success. Anchor: "level<digits><Skill>tooptimally"
-- (spaces don't render). The continuity guard rejects a reading with a
-- horizontal hole in the digit/skill run -- an uncataloged glyph would
-- otherwise silently corrupt the level ("95" with no 9-glyph reads "5").
local function assemble()
  local g = EX.frame_glyphs
  EX.frame_glyphs = {}
  if #g > 0 and #g < 12 then EX.tr("glyphs=%d (below 12, skip)", #g) end
  if #g < 12 then return end
  table.sort(g, function (a, b)
    local ay, by = a.y0 + a.y1, b.y0 + b.y1
    if ay ~= by then return ay < by end
    return a.x0 < b.x0
  end)
  local rows = {}
  local row, row_yc
  for _, e in ipairs(g) do
    local yc = (e.y0 + e.y1) / 2
    if not row or yc - row_yc > 6 then
      row = {}; rows[#rows + 1] = row; row_yc = yc
    end
    row[#row + 1] = e
  end
  local chars = {}
  for ri, r in ipairs(rows) do
    table.sort(r, function (a, b) return a.x0 < b.x0 end)
    local last
    for _, e in ipairs(r) do
      local ch = char_of(e.name)
      if ch then
        if last and last.ch == ch and e.x0 - last.x0 <= 2 then
          -- drop-shadow twin / same glyph re-seen across frames
        else
          last = { ch = ch, row = ri, x0 = e.x0, x1 = e.x1 }
          chars[#chars + 1] = last
        end
      end
    end
  end
  local buf = {}
  for _, c in ipairs(chars) do buf[#buf + 1] = c.ch end
  local text = table.concat(buf)
  EX.last_text = text
  local s_pos, _, lvl, skill = text:find("level(%d+)(%a-)tooptimally")
  if not s_pos or #lvl == 0 or #skill == 0 then
    EX.trd("parse", ("parse FAIL (no anchor) glyphs=%d text=%s"):format(#g, text:sub(1, 48)))
    return
  end
  if #lvl > 3 then EX.tr("parse FAIL (level %s too long)", lvl); return end
  -- One glyph == one char, so string positions map 1:1 onto `chars`.
  -- Position-aware continuity: INSIDE the digit run and INSIDE the skill
  -- word, any gap over 6px means a missing (unmatched) character -- reject.
  -- At the two WORD-SPACE boundaries ('l'->first digit, last digit->skill
  -- capital) a real space lives there, and subpixel phase stretches it up to
  -- ~8px (seen live: a perfect 'level 21 Mining' rejected at 7px), so those
  -- two pairs get a 9px allowance instead.
  local run_from  = s_pos + 4                        -- the closing 'l' of "level"
  local run_to    = s_pos + 4 + #lvl + #skill
  local digit_1st = s_pos + 5                        -- first digit (after the space)
  local skill_1st = s_pos + 5 + #lvl                 -- first skill char (after the space)
  for i = run_from + 1, math.min(run_to, #chars) do
    local a, b = chars[i - 1], chars[i]
    local limit = (i == digit_1st or i == skill_1st) and 9 or 6
    if a.row == b.row and b.x0 - a.x1 > limit then
      EX.status = ("gap %dpx before char %d ('%s') -- uncataloged glyph? rejected")
        :format(b.x0 - a.x1, i, b.ch)
      EX.tr("parse FAIL %s", EX.status)
      return
    end
  end
  local v = tonumber(lvl)
  if not v or v < 1 or v > 120 then
    EX.tr("parse FAIL (level %s out of range)", lvl)
    return
  end
  EX.trd("parse", ("parse OK %d %s (glyphs=%d)"):format(v, skill:lower(), #g))
  return v, skill:lower()
end

-- Per-swap processing. The CORE pipeline (guards, assembly, double-read,
-- bind) runs every swap: the examine->map budget is 200ms, and the old
-- 15-swap cadence cost 250-500ms in the double-read alone. Per-swap cost is
-- small -- assembly sorts ~100 entries and skips outright on glyphless
-- frames. Only the dev diagnostic write keeps the 15-swap cadence.
local _ctr = 0
function EX.tick()
  _ctr = _ctr + 1
  -- Bootstrap: group structural corner candidates. Exactly four placements
  -- of one signature in true 2x2 corner FORMATION, at examine-box-plausible
  -- size and aspect, = candidate rect. The formation/size/aspect filters are
  -- load-bearing: a persistent UI cluster of four identical squares (seen
  -- live: a 249x179 false rect in the HUD corner) otherwise wins every tick
  -- and starves the real box.
  local have_corners = sig_names()["EXAMINE_CORNER_TL"] and sig_names()["EXAMINE_CORNER_TR"]
    and sig_names()["EXAMINE_CORNER_BL"] and sig_names()["EXAMINE_CORNER_BR"]
  if not have_corners and #EX.frame_sq > 0 then
    local function two_pairs(a, b, c, d)
      local v = { a, b, c, d }
      table.sort(v)
      return (v[2] - v[1]) <= 4 and (v[4] - v[3]) <= 4 and (v[3] - v[2]) > 20
    end
    local by = {}
    for _, e in ipairs(EX.frame_sq) do
      local t = by[e.sig]
      if not t then t = {}; by[e.sig] = t end
      t[#t + 1] = e
    end
    -- Structural diag (dev): what the scan saw and which gate said no. A
    -- histogram of group sizes plus a verdict line per exactly-4 group.
    local hist, notes = {}, {}
    for sig, list in pairs(by) do
      hist[#list] = (hist[#list] or 0) + 1
      if #list == 4 then
        local ok_form = two_pairs(list[1].x0, list[2].x0, list[3].x0, list[4].x0)
          and two_pairs(list[1].y0, list[2].y0, list[3].y0, list[4].y0)
        local rx0, ry0, rx1, ry1 = math.huge, math.huge, -math.huge, -math.huge
        for _, p in ipairs(list) do
          if p.x0 < rx0 then rx0 = p.x0 end
          if p.y0 < ry0 then ry0 = p.y0 end
          if p.x1 > rx1 then rx1 = p.x1 end
          if p.y1 > ry1 then ry1 = p.y1 end
        end
        local w, h = rx1 - rx0, ry1 - ry0
        local ok_size = w >= 80 and w <= 320 and h >= 30 and h <= 130
          and w / h >= 1.6 and w / h <= 5.5
        if #notes < 6 then
          notes[#notes + 1] = string.format(
            "  quad %dx%d at %d,%d..%d,%d (img %dx%d) formation=%s size=%s",
            math.floor(w), math.floor(h), math.floor(rx0), math.floor(ry0),
            math.floor(rx1), math.floor(ry1), list[1].w, list[1].h,
            tostring(ok_form), tostring(ok_size))
        end
        if ok_form and ok_size then
          EX.rect = { x0 = rx0, y0 = ry0, x1 = rx1, y1 = ry1,
                      t = bolt.time() or 0, sig = sig, w = list[1].w, h = list[1].h }
          break
        end
      end
    end
    if #EX.frame_sq > 0 then
      local hh = {}
      for sz, cnt in pairs(hist) do hh[#hh + 1] = sz .. "x" .. cnt end
      table.sort(hh)
      EX.sq_note = string.format("entries=%d  group-size histogram: %s\n%s",
        #EX.frame_sq, table.concat(hh, "  "),
        #notes > 0 and table.concat(notes, "\n") or "  (no exactly-4 groups)")
    end
  end
  EX.frame_sq = {}
  -- Read the box. Two consecutive agreeing parses promote to EX.level.
  -- OPENED-DOOR GUARD: the examine box outlives its door by ~3s. If the door
  -- opens (its DOOR_<skill> icon leaves the map) while its box lingers, a
  -- re-read would migrate onto the next unresolved icon of the same skill.
  -- Track icon disappearances and record {skill, level, time}; the bind step
  -- below refuses readings matching skill+level inside the window. Level
  -- comes from bound_doors when the vanished door was bound (authoritative),
  -- else from the most recent confirmed reading of that skill -- the exact
  -- text the lingering box still shows. No level known -> skill-only block.
  -- Arming is SUPPRESSED for 2s after a base-cell move (below): a base
  -- correction re-keys the whole grid, faking door-vanishes.
  do
    local cur, base_ck = SET.door_cells()
    -- BASE-SHIFT SUPPRESSION: in the first
    -- frames of a floor the base can be drawn at the WRONG cell and then
    -- correct; the correction re-keys the whole grid, so every icon
    -- "vanishes" from its old key -- including a skill door attached to
    -- base. The opened-door guard read that as "door just opened" and
    -- blocked the examine bind, which the 4s re-promotion suppressor then
    -- stretched into the measured 4.02s propagation delays. A base move
    -- means the vanish bookkeeping is re-keying noise, not door state:
    -- drop it and hold guard ARMING off for 2s.
    if base_ck and base_ck ~= EX.base_ck_prev then
      EX.base_ck_prev = base_ck
      EX.base_moved_us = bolt.time() or 0
      EX.opened_guard = {}
      EX.door_prev = nil
      EX.tr("BASE moved to %s -- opened-guard reset, arming held 2s", base_ck)
    end
    local base_quiet = not EX.base_moved_us
      or ((bolt.time() or 0) - EX.base_moved_us) >= 2e6
    if EX.door_prev then
      local now2 = bolt.time() or 0
      for ck, skl in pairs(EX.door_prev) do
        if not cur[ck] and base_quiet then
          local v2 = S.bound_doors[ck] and S.bound_doors[ck].v
          if not v2 then
            local lr = EX.last_reads[skl]
            if lr and now2 - lr.t < 10e6 then v2 = lr.v end
          end
          EX.opened_guard[skl] = { v = v2, t = now2 }
        end
      end
    end
    EX.door_prev = cur
  end
  local v, sk = assemble()
  if v and sk then
    -- Timeline: first successful parse since the rect rose (diag only).
    if not EX.t_first_parse then EX.t_first_parse = bolt.time() end
    if not SKILL_DOORS[sk] then
      EX.status = ("read level %d but unknown skill '%s'"):format(v, sk)
    elseif EX.pending and EX.pending.v == v and EX.pending.sk == sk
       and (bolt.time() - EX.pending.t) < 3e6 then
      -- Suppress re-promotion while the same box is still on screen; a fresh
      -- examine of the same door later re-promotes and the repeat check
      -- handles it.
      if not (EX.level and EX.level.used and EX.level.v == v
              and EX.level.skill == sk and (bolt.time() - EX.level.t) < 4e6) then
        EX.tr("PROMOTE %d %s (pending_age=%.3f)", v, sk,
          (bolt.time() - EX.pending.t) / 1e6)
        EX.tr_keys.suppress = nil   -- next suppression onset is a new story
        EX.level = { v = v, skill = sk, t = bolt.time() }
        EX.last_reads[sk] = { v = v, t = bolt.time() }
        EX.status = ("read level %d %s (confirmed twice)"):format(v, sk)
      else
        -- Steady-state suppression cycle: understood and information-free
        -- (see the 2026-07-16 traces) -- log only its ONSET, not each swap.
        EX.trd("suppress", ("SUPPRESS onset %d %s"):format(v, sk))
      end
      EX.pending = nil
    else
      EX.pending = { v = v, sk = sk, t = bolt.time() }
    end
  end
  -- BIND: assign the requirement reading by MAP ICON CENSUS -- pure grid
  -- logic, no world coordinates, so it works right after a mid-floor reload.
  -- The skill is DECODED from the box text, so the census only has to find
  -- the one unresolved icon of that skill. A level inside exactly one
  -- guaranteed range (skill_doors.txt) proves that parity -- bonus OR crit;
  -- overlap/gap levels prove nothing.
  -- Anchor gate: bound_doors / skill_bonus / skill_crit are sticky and keyed
  -- by cell. While coordinates are relative-fallback, hold the reading
  -- unconsumed -- it binds within ~200ms once the anchor locks.
  -- Floor gate: no binds while between floors (a reading confirmed in the
  -- gap would bind against a frozen graph; the rising-edge wipe clears it).
  if EX.level and not EX.level.used and S.close_anchor_x
     and (S.floor_active or not floor_gate_armed()) then
    EX.level.used = true
    -- Log the attempt once per distinct reading (retries re-enter each swap).
    if EX.tr_bind_t ~= EX.level.t then
      EX.tr_bind_t = EX.level.t
      EX.tr("BIND attempt %d %s (level_age=%.3f)", EX.level.v, EX.level.skill,
        (bolt.time() - EX.level.t) / 1e6)
    end
    -- OPENED-DOOR GUARD check: a door of this skill vanished from the map
    -- moments ago. If this reading matches its level (or its level is
    -- unknown), it is the opened door's lingering box -- refuse, or it
    -- migrates onto the next unresolved icon of the same skill.
    local g = EX.opened_guard[EX.level.skill]
    if g and (bolt.time() - g.t) < 4e6
       and (g.v == nil or g.v == EX.level.v) then
      EX.bind = { verdict = ("no action: a %s door just opened -- lingering-box guard")
                    :format(EX.level.skill),
                  v = EX.level.v, t = bolt.time() }
    else
    -- REPEAT-EXAMINE check first: a reading whose skill+level matches a door
    -- already bound this floor is that door examined again -- NOT a new door.
    -- KNOWN LIMITATION (deliberate, conservative): a genuinely NEW door of
    -- the same skill and same requirement is indistinguishable from a repeat
    -- and is dropped, never misassigned.
    local repeat_ck
    for bck, b in pairs(S.bound_doors) do
      if b.v == EX.level.v and b.skill == EX.level.skill then repeat_ck = bck; break end
    end
    -- PHANTOM PURGE: a matching binding whose cell is no longer in the room
    -- graph was bound against stale transition state (seen live: strength 82
    -- bound to phantom 2,1 carried across a floor wipe, which then
    -- repeat-blocked the real door at 5,2 for the whole floor). Purge it and
    -- its parity residue, and let this reading bind fresh via the census.
    if repeat_ck and not cell_at(repeat_ck) then
      S.bound_doors[repeat_ck] = nil
      S.skill_bonus[repeat_ck] = nil
      S.skill_crit[repeat_ck]  = nil
      repeat_ck = nil
    end
    -- Census of UNRESOLVED door icons only: a door already bound this floor
    -- is spoken for and must not keep inflating its skill's icon count.
    local list = {}
    for ck, skl in pairs((SET.door_cells())) do
      if not S.bound_doors[ck] then
        list[#list + 1] = { ck = ck, skill = skl }
      end
    end
    if repeat_ck then
      EX.bind = { ck = repeat_ck, skill = EX.level.skill, v = EX.level.v,
                  t = bolt.time(),
                  verdict = "no action: repeat examine of already-bound door" }
    else
      local target, how
      local only, dup
      for _, e in ipairs(list) do
        if e.skill == EX.level.skill then
          if only then dup = true; break end
          only = e
        end
      end
      if only and not dup then
        target = only
        how = ("only unresolved %s icon (%d doors in census)"):format(EX.level.skill, #list)
      elseif dup then
        EX.bind = { verdict = "no action: multiple " .. EX.level.skill .. " icons",
                    v = EX.level.v, t = bolt.time() }
      else
        EX.bind = { verdict = "no action: no unresolved " .. EX.level.skill .. " icon on map",
                    v = EX.level.v, t = bolt.time() }
      end
      if target then
        -- The door is now identified whatever the verdict: record it so it
        -- leaves the census pool and its repeats are recognised by skill+level.
        S.bound_doors[target.ck] = { skill = target.skill, v = EX.level.v }
        local sd = SKILL_DOORS[target.skill]
        local in_bonus = sd and EX.level.v >= sd.bonus_lo and EX.level.v <= sd.bonus_hi
        -- CAP-OVERFLOW BONUS: a door on a level-99-max skill whose requirement
        -- lands in 100-105 (above the skill's real cap) is guaranteed BONUS.
        -- Disjoint from the normal 1-N band, so it carries its own reason.
        local over_cap = sd and sd.max == 99 and EX.level.v >= 100 and EX.level.v <= 105
        if over_cap then in_bonus = true end
        local in_crit  = sd and sd.crit_lo > 0
          and EX.level.v >= sd.crit_lo and EX.level.v <= sd.crit_hi
        local verdict
        if in_bonus and in_crit then
          verdict = "ambiguous (level inside BOTH ranges -- overlap)"
        elseif in_bonus then
          -- FIRST PROOF WINS, same rule as parity facts. Never overwrite an
          -- established reason.
          if S.skill_bonus[target.ck] then
            verdict = "BONUS (already marked -- kept first proof)"
          else
            S.skill_bonus[target.ck] = over_cap
              and ("skill door examined: requires level %d %s, in the 100-105 band " ..
                   "above the level-99 cap -- guaranteed bonus"):format(EX.level.v, target.skill)
              or  ("skill door examined: requires level %d %s, inside " ..
                   "the guaranteed-bonus range %d-%d"):format(EX.level.v, target.skill, sd.bonus_lo, sd.bonus_hi)
            verdict = "BONUS"
            SET.parity_kick = true   -- repaint the map THIS swap, not next dump tick
            if SET.sync.emit then
              SET.sync.emit({ t = "skill_door", c = target.ck, s = target.skill,
                              v = EX.level.v, p = "bonus" })
            end
          end
        elseif in_crit then
          if S.skill_crit[target.ck] then
            verdict = "CRIT (already marked -- kept first proof)"
          else
            S.skill_crit[target.ck] = ("skill door examined: requires level %d %s, inside " ..
              "the guaranteed-crit range %d-%d"):format(EX.level.v, target.skill, sd.crit_lo, sd.crit_hi)
            verdict = "CRIT"
            SET.parity_kick = true   -- repaint the map THIS swap, not next dump tick
            if SET.sync.emit then
              SET.sync.emit({ t = "skill_door", c = target.ck, s = target.skill,
                              v = EX.level.v, p = "crit" })
            end
          end
        else
          verdict = "ambiguous (level in neither guaranteed range)"
        end
        EX.bind = { ck = target.ck, skill = target.skill, v = EX.level.v,
                    verdict = verdict, how = how, t = bolt.time() }
      end
    end
    end
    if EX.bind then
      -- trd so a retry loop (no-icon verdict re-attempting each swap)
      -- collapses to one line instead of flooding the ring.
      EX.trd("bind", ("BIND result: %s%s"):format(
        EX.bind.ck and (EX.bind.ck .. " ") or "", EX.bind.verdict))
    end
  end
  -- Lean dev diagnostic: box rect, last assembled text, pending/confirmed
  -- reading, last bind -- enough to verify OCR + binding live. Disk writes
  -- stay on the old 15-swap cadence.
  if _ctr < 15 then return end
  _ctr = 0
  if SET.DEV then
    local bind_line = "(none yet)"
    if EX.bind then
      bind_line = string.format("%s%s level %d -> %s%s  (%.0fs ago)",
        EX.bind.ck and ("room " .. EX.bind.ck .. "  ") or "",
        EX.bind.skill or "?", EX.bind.v, EX.bind.verdict,
        EX.bind.how and ("  [" .. EX.bind.how .. "]") or "",
        (bolt.time() - EX.bind.t) / 1e6)
    end
    local r = EX.rect
    -- Latency timeline: where did the last examine's time go? rect_first is
    -- the rising edge (box appeared), then first full parse, double-read
    -- confirm, bind attempt. Sub-second gaps rect->parse->confirm are
    -- healthy; a large gap points at stale atlas sigs (rect/parse) or the
    -- anchor gate (confirm->bind, see anchor flag).
    local function ago_s(t)
      return t and string.format("%.2fs ago", (bolt.time() - t) / 1e6) or "-"
    end
    local timeline = string.format(
      "rect_first=%s  first_parse=%s  confirmed=%s  bind_attempt=%s  anchor=%s",
      ago_s(EX.t_rect), ago_s(EX.t_first_parse),
      ago_s(EX.level and EX.level.t), ago_s(EX.bind and EX.bind.t),
      S.close_anchor_x and "locked" or "NOT LOCKED")
    SET.dev_save("examine_diag.txt", string.format(
      "status=%s\n" ..
      "box rect=%s%s\n" ..
      "last assembled text: %s\n" ..
      "pending read: %s\n" ..
      "LAST REQUIREMENT LEVEL READ: %s\n" ..
      "LAST DOOR BIND: %s\n" ..
      "timeline: %s\n\n" ..
      "structural scan (last non-empty tick):\n%s\n",
      tostring(EX.status),
      r and string.format("%d,%d..%d,%d", r.x0, r.y0, r.x1, r.y1) or "(none)",
      r and r.sig and "  [structural -- corner not cataloged yet]" or "",
      tostring(EX.last_text),
      EX.pending and (EX.pending.v .. " " .. EX.pending.sk) or "(none)",
      EX.level and string.format("%d %s  (%.0fs ago)", EX.level.v, EX.level.skill,
        (bolt.time() - EX.level.t) / 1e6) or "(none yet)",
      bind_line,
      timeline,
      EX.sq_note or "(nothing collected)"))
    -- Frame-accurate promotion-loop trace (ring buffer; see EX.tr).
    if #EX.trace > 0 then
      SET.dev_save("examine_trace.txt", table.concat(EX.trace, "\n") .. "\n")
    end
  end
end
return EX
end
