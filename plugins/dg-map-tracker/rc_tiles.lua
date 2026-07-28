-- Runecraft Tiles puzzle solver, ported from the archived room-detect plugin
-- (2026-07-28). Exhaustive solver only: the k=1..5 iterative refinement always
-- runs (the old rc_exhaustive toggle is gone -- chase-the-lights survives only
-- as the fast upper bound the refinement prunes against).
--
-- The puzzle: a 5x5 grid of tiles, each yellow or green. FORCE(i) toggles tile
-- i; IMBUE(i) toggles tile i and its 4-neighbours. Goal: all one colour in the
-- fewest moves. Since FORCE alone solves any state in K moves (K = mismatched
-- tiles), the search runs over imbue subsets and lets FORCE clean up the rest.
--
-- Detection: every n=4644 mesh in the player's room is one puzzle tile. Yellow
-- vs green is baked into the bone matrix's Y-axis sign (event:vertexanimation,
-- m6 > 0 yellow, < 0 green) -- view-independent, no pixel readback. Unlike the
-- original (colour cached on first sight, so the plan never updated as tiles
-- were pressed), colours re-read on the 5Hz scan cadence and the solver re-runs
-- on any state change: the markers stay live through the solve.
--
-- Interface (installed on SET.rc):
--   RC.enabled  -- flag, applied from the settings poll (rc_tiles_enabled)
--   RC.scan(event, wx, wz, px, pz) -- from onrender3d, n==4644 only; returns
--                                     true so the caller skips the resource path
--   RC.tick()   -- from onswapbuffers: room-change reset + solver pump
--   RC.markers()-- nil, or { force = {tile...}, imbue = {tile...} } in world
--                  coords for the render pass in main.lua
return function (deps)
  local bolt = require("bolt")   -- module scope has no bolt global; every sibling module self-requires
  local SET = deps.SET
  local RC = {}
  SET.rc = RC

  local TILE = 512          -- world units per game tile (mirrors main.lua)
  local ROOM = 16           -- tiles per room edge

  RC.enabled = SET.get("rc_tiles_enabled", true) == true

  -- ---- state, reset whenever the player changes room --------------------------
  local tiles_by_key = {}   -- "tx,tz" -> { wx, wy, wz }
  local tile_colors  = {}   -- "tx,tz" -> "yellow" | "green"
  local solution     = nil  -- { target, total, moves = { {kind, key}... } }
  local room_key     = nil
  local last_state   = -1
  local solver_co, solver_state, solver_result, solver_b2k

  local function reset()
    tiles_by_key, tile_colors = {}, {}
    solution, last_state = nil, -1
    solver_co, solver_result = nil, nil
    RC._markers = nil
  end

  -- ---- bit ops (no native bit library in bolt's sandbox: pcall, then fall
  -- back to arithmetic -- the coroutine pump absorbs the cost either way) ------
  local ok_bit, bit_lib = pcall(require, "bit")
  local b_and, b_or, b_xor, b_lshift, popcount
  if ok_bit and bit_lib then
    b_and, b_or, b_xor, b_lshift = bit_lib.band, bit_lib.bor, bit_lib.bxor, bit_lib.lshift
    local POP8 = {}
    for i = 0, 255 do
      local n, v = 0, i
      while v > 0 do n = n + (v % 2); v = math.floor(v / 2) end
      POP8[i] = n
    end
    popcount = function (x)
      return POP8[bit_lib.band(x, 0xFF)]
           + POP8[bit_lib.band(bit_lib.rshift(x, 8),  0xFF)]
           + POP8[bit_lib.band(bit_lib.rshift(x, 16), 0xFF)]
           + POP8[bit_lib.band(bit_lib.rshift(x, 24), 0xFF)]
    end
  else
    popcount = function (x)
      local c = 0
      while x > 0 do
        if x % 2 == 1 then c = c + 1 end
        x = math.floor(x / 2)
      end
      return c
    end
    b_and = function (a, b)
      local r, v = 0, 1
      while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + v end
        a = math.floor(a / 2); b = math.floor(b / 2); v = v * 2
      end
      return r
    end
    b_or = function (a, b)
      local r, v = 0, 1
      while a > 0 or b > 0 do
        if a % 2 == 1 or b % 2 == 1 then r = r + v end
        a = math.floor(a / 2); b = math.floor(b / 2); v = v * 2
      end
      return r
    end
    b_xor = function (a, b)
      local r, v = 0, 1
      while a > 0 or b > 0 do
        if (a % 2) ~= (b % 2) then r = r + v end
        a = math.floor(a / 2); b = math.floor(b / 2); v = v * 2
      end
      return r
    end
    b_lshift = function (a, n) return a * (2 ^ n) end
  end

  -- Precompute the 25 imbue masks (a plus sign around each cell) and the 25
  -- single-bit masks.
  local IMBUE_MASKS, IMBUE_BITS = {}, {}
  for r = 0, 4 do
    for c = 0, 4 do
      local i = r * 5 + c
      local mask = b_lshift(1, i)
      if r > 0 then mask = b_or(mask, b_lshift(1, (r - 1) * 5 + c)) end
      if r < 4 then mask = b_or(mask, b_lshift(1, (r + 1) * 5 + c)) end
      if c > 0 then mask = b_or(mask, b_lshift(1, r * 5 + (c - 1))) end
      if c < 4 then mask = b_or(mask, b_lshift(1, r * 5 + (c + 1))) end
      IMBUE_MASKS[i + 1] = mask
    end
  end
  for i = 1, 25 do IMBUE_BITS[i] = b_lshift(1, i - 1) end

  -- Chase-the-lights: fast (~64 candidates) upper bound, not always optimal.
  local function solve_chase(diff)
    local best_total      = popcount(diff)
    local best_imbue_bits = 0
    local best_force_bits = diff
    for top = 0, 31 do
      local grid = { {0,0,0,0,0}, {0,0,0,0,0}, {0,0,0,0,0}, {0,0,0,0,0}, {0,0,0,0,0} }
      for i = 0, 24 do
        grid[math.floor(i / 5) + 1][(i % 5) + 1] =
          (b_and(diff, b_lshift(1, i)) ~= 0) and 1 or 0
      end
      local imbue_bits, imbues = 0, 0
      local function toggle(r, c)
        if r >= 1 and r <= 5 and c >= 1 and c <= 5 then grid[r][c] = 1 - grid[r][c] end
      end
      local function press(r, c)
        toggle(r, c); toggle(r - 1, c); toggle(r + 1, c); toggle(r, c - 1); toggle(r, c + 1)
        imbues = imbues + 1
        imbue_bits = b_or(imbue_bits, b_lshift(1, (r - 1) * 5 + (c - 1)))
      end
      for c = 1, 5 do
        if b_and(top, b_lshift(1, c - 1)) ~= 0 then press(1, c) end
      end
      for r = 2, 5 do
        for c = 1, 5 do
          if grid[r - 1][c] == 1 then press(r, c) end
        end
      end
      local force_bits, forces = 0, 0
      for c = 1, 5 do
        if grid[5][c] == 1 then
          force_bits = b_or(force_bits, b_lshift(1, 4 * 5 + (c - 1)))
          forces = forces + 1
        end
      end
      local total = imbues + forces
      if total < best_total then
        best_total, best_imbue_bits, best_force_bits = total, imbue_bits, force_bits
      end
    end
    return { imbue_bits = best_imbue_bits, force_bits = best_force_bits, total = best_total }
  end

  -- Budgeted yield: the exhaustive k=5 sweep is ~68k inner iterations; slicing
  -- it across frames keeps the client smooth. Resumed once per swap by tick().
  local YIELD_INTERVAL = 800
  local solver_tick_n = 0
  local function tick_yield()
    solver_tick_n = solver_tick_n + 1
    if solver_tick_n >= YIELD_INTERVAL then
      solver_tick_n = 0
      coroutine.yield()
    end
  end

  -- Exhaustive iterative refinement, k = 1..5 ALWAYS (the ported plugin gated
  -- k=4,5 behind rc_exhaustive; that is the only mode here).
  local function solve_iterative(diff, best_total, best_imbue_bits, best_force_bits)
    local IB, IM = IMBUE_BITS, IMBUE_MASKS
    local bx, po, bo = b_xor, popcount, b_or
    if best_total > 1 then
      for i = 1, 25 do
        local a = IM[i]
        local t = 1 + po(bx(diff, a))
        if t < best_total then
          best_total = t; best_imbue_bits = IB[i]; best_force_bits = bx(diff, a)
        end
      end
    end
    if best_total > 2 then
      for i = 1, 24 do
        local ai = IM[i]; local bi = IB[i]
        for j = i + 1, 25 do
          local a = bx(ai, IM[j])
          local t = 2 + po(bx(diff, a))
          if t < best_total then
            best_total = t; best_imbue_bits = bo(bi, IB[j]); best_force_bits = bx(diff, a)
          end
        end
      end
    end
    if best_total > 3 then
      for i = 1, 23 do
        local ai = IM[i]; local bi = IB[i]
        for j = i + 1, 24 do
          local aij = bx(ai, IM[j]); local bij = bo(bi, IB[j])
          for k = j + 1, 25 do
            local a = bx(aij, IM[k])
            local t = 3 + po(bx(diff, a))
            if t < best_total then
              best_total = t; best_imbue_bits = bo(bij, IB[k]); best_force_bits = bx(diff, a)
            end
          end
          tick_yield()
        end
      end
    end
    if best_total > 4 then
      for i = 1, 22 do
        local ai = IM[i]; local bi = IB[i]
        for j = i + 1, 23 do
          local aij = bx(ai, IM[j]); local bij = bo(bi, IB[j])
          for k = j + 1, 24 do
            local aijk = bx(aij, IM[k]); local bijk = bo(bij, IB[k])
            for l = k + 1, 25 do
              local a = bx(aijk, IM[l])
              local t = 4 + po(bx(diff, a))
              if t < best_total then
                best_total = t; best_imbue_bits = bo(bijk, IB[l]); best_force_bits = bx(diff, a)
              end
            end
            tick_yield()
          end
        end
      end
    end
    if best_total > 5 then
      for i = 1, 21 do
        local ai = IM[i]; local bi = IB[i]
        for j = i + 1, 22 do
          local aij = bx(ai, IM[j]); local bij = bo(bi, IB[j])
          for k = j + 1, 23 do
            local aijk = bx(aij, IM[k]); local bijk = bo(bij, IB[k])
            for l = k + 1, 24 do
              local aijkl = bx(aijk, IM[l]); local bijkl = bo(bijk, IB[l])
              for m = l + 1, 25 do
                local a = bx(aijkl, IM[m])
                local t = 5 + po(bx(diff, a))
                if t < best_total then
                  best_total = t; best_imbue_bits = bo(bijkl, IB[m]); best_force_bits = bx(diff, a)
                end
              end
              tick_yield()
            end
          end
        end
      end
    end
    return { imbue_bits = best_imbue_bits, force_bits = best_force_bits, total = best_total }
  end

  local function solve_for_diff(diff)
    local chase = solve_chase(diff)
    return solve_iterative(diff, chase.total, chase.imbue_bits, chase.force_bits)
  end

  -- Both targets (all-yellow, all-green); keep the shorter plan.
  local function solve_grid(state25)
    local ALL_ONES = 0x1FFFFFF
    local plan0 = solve_for_diff(state25)
    coroutine.yield()
    local plan1 = solve_for_diff(b_xor(state25, ALL_ONES))
    local best = (plan0.total <= plan1.total) and plan0 or plan1
    best.target = (plan0.total <= plan1.total) and "yellow" or "green"
    return best
  end

  -- 25-bit state (0=yellow, 1=green) from tile_colors, plus bit -> world-key.
  local function extract_state()
    if next(tile_colors) == nil then return nil end
    local min_tx, min_tz = math.huge, math.huge
    for key in pairs(tile_colors) do
      local sx, sz = key:match("^(-?%d+),(-?%d+)$")
      local tx, tz = tonumber(sx), tonumber(sz)
      if tx < min_tx then min_tx = tx end
      if tz < min_tz then min_tz = tz end
    end
    if min_tx == math.huge then return nil end
    local state, bit_to_key, n_bits = 0, {}, 0
    for r = 0, 4 do
      for c = 0, 4 do
        local tx, tz = min_tx + c, min_tz + 4 - r
        local key = tx .. "," .. tz
        local color = tile_colors[key]
        if color then
          n_bits = n_bits + 1
          if color == "green" then state = b_or(state, b_lshift(1, r * 5 + c)) end
          bit_to_key[r * 5 + c] = key
        end
      end
    end
    if n_bits < 25 then return nil end
    return state, bit_to_key
  end

  local function finalize(best, bit_to_key)
    -- A tile in both lists renders as both markers (dot inside the ring).
    local kinds = {}
    for i = 0, 24 do
      if b_and(best.imbue_bits, b_lshift(1, i)) ~= 0 then
        kinds[bit_to_key[i]] = { imbue = true }
      end
    end
    for i = 0, 24 do
      if b_and(best.force_bits, b_lshift(1, i)) ~= 0 then
        kinds[bit_to_key[i]] = kinds[bit_to_key[i]] or {}
        kinds[bit_to_key[i]].force = true
      end
    end
    local moves = {}
    for key, k in pairs(kinds) do
      if k.imbue then moves[#moves + 1] = { kind = "imbue", key = key } end
      if k.force then moves[#moves + 1] = { kind = "force", key = key } end
    end
    solution = { target = best.target, total = best.total, moves = moves }
    RC._markers = nil   -- rebuild marker lists on next markers() call
    local lines = { string.format("solve: target=%s total=%d", best.target, best.total) }
    for _, mv in ipairs(moves) do
      lines[#lines + 1] = string.format("  %s @ %s", mv.kind, mv.key)
    end
    SET.dev_save("rc_solve.txt", table.concat(lines, "\n") .. "\n")
  end

  local function maybe_solve()
    local state, bit_to_key = extract_state()
    if not state then return end
    if state == last_state and (solution or solver_co) then return end
    last_state, solver_state, solver_b2k = state, state, bit_to_key
    solver_result = nil
    solver_tick_n = 0
    solver_co = coroutine.create(function () solver_result = solve_grid(solver_state) end)
  end

  -- ---- interface --------------------------------------------------------------

  -- Called from onrender3d for n==4644 meshes, before the scan-range cull (the
  -- puzzle spans the room, the cull box does not). Records the tile and
  -- (re)reads its colour; a colour CHANGE invalidates downstream via
  -- maybe_solve's state comparison. Returns true so the caller skips the
  -- resource path -- puzzle tiles must never reach the unknown queue.
  function RC.scan(event, wx, wy, wz, px, pz)
    if not RC.enabled then return true end
    if math.floor(wx / TILE / ROOM) ~= math.floor(px / TILE / ROOM)
       or math.floor(wz / TILE / ROOM) ~= math.floor(pz / TILE / ROOM) then
      return true   -- other room: still a puzzle tile, still not a resource
    end
    local key = string.format("%d,%d", math.floor(wx / TILE), math.floor(wz / TILE))
    local ok_a, tf = pcall(event.vertexanimation, event, 1)
    if ok_a and tf then
      local _, _, _, _, _, m6 = tf:get()
      if m6 and m6 > 0 then tile_colors[key] = "yellow"
      elseif m6 and m6 < 0 then tile_colors[key] = "green" end
    end
    if not tiles_by_key[key] then
      tiles_by_key[key] = { wx = wx, wy = wy, wz = wz }
    end
    return true
  end

  -- Called once per swap: reset on room change, kick/advance the solver.
  function RC.tick()
    if not RC.enabled then return end
    local pos = bolt.playerposition()
    if not pos then return end
    local px, _, pz = pos:get()
    local rk = math.floor(px / TILE / ROOM) .. "," .. math.floor(pz / TILE / ROOM)
    if rk ~= room_key then
      room_key = rk
      reset()
    end
    maybe_solve()
    if solver_co then
      local ok, err = coroutine.resume(solver_co)
      if not ok then
        SET.dev_save("rc_solve_err.txt", tostring(err) .. "\n")
        solver_co = nil
      elseif coroutine.status(solver_co) == "dead" then
        solver_co = nil
        if solver_result then finalize(solver_result, solver_b2k) end
      end
    end
  end

  -- Marker lists for the render pass, world coords. Cached until the solution
  -- changes. force = press this tile (red dot); imbue = imbue this tile
  -- (magenta ring); a combo tile appears in both lists.
  function RC.markers()
    if not RC.enabled or not solution then return nil end
    if not RC._markers then
      local m = { force = {}, imbue = {} }
      for _, mv in ipairs(solution.moves) do
        local tile = tiles_by_key[mv.key]
        if tile and m[mv.kind] then m[mv.kind][#m[mv.kind] + 1] = tile end
      end
      RC._markers = m
    end
    return RC._markers
  end
end
