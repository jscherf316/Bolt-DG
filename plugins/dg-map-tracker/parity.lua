-- ============================================================================
-- parity.lua -- the parity engine, as a module.
-- ============================================================================
-- Extracted verbatim from main.lua (history lives there). Loaded with
--   local solve_parity = require("parity")({ ... deps ... })
--
-- DEPENDENCIES ARE INJECTED, NEVER READ FROM GLOBALS. The engine is a pure
-- function of (rooms, ev) plus these four pieces of floor geometry; keeping
-- them explicit is what lets test/spec.py load THIS SHIPPED FILE with stubs
-- instead of slicing engine text out of main.lua by string markers -- which is
-- how the previous harness broke.
--
-- The engine body below is kept at column 0 on purpose: it is a verbatim move,
-- and an unindented diff against main.lua's history stays readable.
return function (deps)
local cell_doors = deps.cell_doors
local key_lower  = deps.key_lower
local NEI_DELTA  = deps.NEI_DELTA
local NEI_OPP    = deps.NEI_OPP

-- ============================================================================
-- Parity engine
-- ============================================================================
-- Pure function of (room snapshot, observations) -> parity per cell. Pure so it
-- can be exercised against synthetic dungeons without bolt.
--
-- MODEL. Every room IS crit or bonus, fixed at floor generation; "unknown" is
-- our bucket, not a room state. Crit rooms form a connected subgraph from base
-- to boss (the crit tree); bonus rooms hang off it as side branches. A crit
-- room is exactly one of: base/boss, backbone-interior, side-branch-interior,
-- or side-branch-terminus (holds a crit key; all its children are bonus -- the
-- only category legally lacking a crit continuation).
--
-- WHY A TREE. The floor graph is GUARANTEED ACYCLIC, so a BFS from base yields
-- THE tree: every room has exactly one path from base, hence exactly one
-- parent, so "ancestor"/"descendant" are well defined and the arbitrary pairs()
-- visit order cannot pick a wrong parent. If loops were ever possible this
-- would need dominators instead and none of the propagators below would hold.
--
-- FIXED POINT. Propagators feed each other (a bonus mark unlocks an
-- elimination, which forces a crit, which unlocks another bonus flood), so they
-- run until nothing changes. Everything is derived fresh each call and NO
-- derived inference is persisted -- a corrected observation self-heals instead
-- of sticking. (The old code had to persist forced-crit because its "exactly
-- one openable candidate in the whole graph" precondition was transient. The
-- per-parent elimination below has a monotone precondition -- bonus never
-- un-marks -- so it simply re-derives.)
--
-- CONTRADICTIONS are recorded, never swallowed. Crit meeting bonus, or base or
-- boss flipping bonus, means an upstream observation is wrong (a misclassified
-- resource tier is the usual culprit). The old code hid these by silently
-- halting the walk.
-- Minimum rooms in the crit tree on a LARGE floor, base and boss included.
-- Whole tree, side branches and all -- NOT the length of the base->boss walk.
-- Medium/small bounds are unknown, hence the floor_is_large gate on its use.
local CRIT_MIN = 18

local function solve_parity(rooms, ev)
  local P, parent, kids, diag, why = {}, {}, {}, {}, {}
  local base_key, boss_key
  for k, c in pairs(rooms) do
    for _, n in ipairs(c.images) do
      if n == "ICON_BASE" then base_key = k end
      if n == "ICON_BOSS" then boss_key = k end
    end
  end
  -- No base => not on a floor (the client does not render the DG map outside a
  -- dungeon, so there is nothing to read). Bail with an EMPTY-BUT-COMPLETE
  -- result: callers destructure all five values, so returning fewer leaves meta
  -- nil and the dump crashes on meta.base. A blank map is correct here; a crash
  -- is not.
  if not base_key then
    local n = 0
    for _ in pairs(rooms) do n = n + 1 end
    return P, parent, diag, why,
      { rounds = 0, unmatched_locks = 0, ncrit = 0, base = nil, boss = nil,
        kids = kids, key_in = {}, found_of = {}, nrooms = n }
  end

  -- BFS spanning tree from base. Requires a reciprocal door so a passage isn't
  -- linked to a merely-adjacent room. Acyclic floor => this IS the real tree.
  local queue, head, seen = { base_key }, 1, { [base_key] = true }
  while head <= #queue do
    local ck = queue[head]; head = head + 1
    kids[ck] = kids[ck] or {}
    local c = rooms[ck]
    for dir in pairs(cell_doors(c)) do
      local d = NEI_DELTA[dir]
      local nk = (c.gx + d[1]) .. "," .. (c.gz + d[2])
      local nc = rooms[nk]
      if nc and not seen[nk] and cell_doors(nc)[NEI_OPP[dir]] then
        seen[nk] = true
        parent[nk] = ck
        kids[ck][#kids[ck] + 1] = nk
        queue[#queue + 1] = nk
      end
    end
  end

  local dirty = false
  local fatal = nil
  local function note(m) diag[#diag + 1] = m end
  -- Single write path: every invariant is enforced in one place, and every
  -- assignment records WHY. The audit trail is not optional -- a wrong parity is
  -- untraceable without it, because by the time you look at the map the
  -- evidence that caused it has already cascaded through other propagators.
  -- A contradiction reports BOTH reasons, which is what actually identifies the
  -- lying observation.
  --
  -- A CONTRADICTION IS FATAL. Parity is a fact of the floor, fixed at
  -- generation, so two propagators reaching opposite conclusions about one room
  -- is not a close call to be arbitrated -- it is proof that something upstream
  -- is lying. Every inference after it would be reasoning from that lie, so the
  -- floor is dead and we stop. Recording the fault and carrying on would only
  -- manufacture a plausible map, which is strictly worse than no map: the whole
  -- point of the plugin is that you can trust what it says.
  --
  -- Both sides are captured, not just the loser. Knowing "5,5 is bonus" is
  -- useless; knowing "5,5 was crit because of X and bonus because of Y" names
  -- the two claims and one of them is the bug.
  local function set(ck, val, reason)
    if P[ck] == val then return end
    if P[ck] then
      local m = ("contradiction %s: already %s (%s), inferred %s (%s)")
        :format(ck, P[ck], why[ck] or "?", val, reason)
      note(m)
      fatal = fatal or { cell = ck, had = P[ck], had_why = why[ck] or "?",
                         got = val, got_why = reason, text = m }
      return
    end
    if val == "bonus" and (ck == base_key or ck == boss_key) then
      local m = ("invariant %s: refused to mark %s bonus -- %s")
        :format(ck, ck == base_key and "base" or "boss", reason)
      note(m)
      fatal = fatal or { cell = ck, had = "crit (by definition)",
                         had_why = ck == base_key and "base" or "boss",
                         got = val, got_why = reason, text = m }
      return
    end
    P[ck] = val
    why[ck] = reason
    dirty = true
  end

  local keys = ev.keys or {}
  -- cell -> the key that spawned there. A room holds at most one key, so two
  -- keys claiming one cell means the pickup detector is lying. Distrust BOTH
  -- bindings rather than arbitrarily keeping whichever pairs() yielded last: a
  -- wrong pickup cell feeds the key propagators below and would cascade bad
  -- bonus marks across the whole floor. Better to lose an inference than to
  -- invent one. found_of[] is the trusted view; use it, never info.found.
  local key_in, poisoned = {}, {}
  for kn, info in pairs(keys) do
    if info.found then
      if key_in[info.found] then
        note(("invariant %s: two keys bound to one room (%s, %s) -- both distrusted")
          :format(info.found, key_in[info.found], kn))
        poisoned[info.found] = true
      end
      key_in[info.found] = kn
    end
  end
  local found_of = {}
  for ck in pairs(poisoned) do key_in[ck] = nil end
  for kn, info in pairs(keys) do
    if info.found and not poisoned[info.found] then found_of[kn] = info.found end
  end
  local function key_parity(kn)
    local i = keys[kn]
    if not i then return nil end
    if i.lock and P[i.lock] then return P[i.lock] end
    local f = found_of[kn]
    if f and P[f] == "bonus" then return "bonus" end               -- bonus room => bonus key
    -- Boss on the map => the whole crit tree is already open => every crit door
    -- has been opened. SOLO, we watched every one of them while it was still
    -- locked, because nobody else can open a door -- so a key whose lock was
    -- NEVER observed has its door in unexplored space, which is off the crit
    -- tree by exactly the argument the unopened-room rule uses. Bonus key.
    --
    -- Group floors are excluded, and the flag is sticky in the GROUP direction:
    -- a teammate can open a key door before we ever see it locked, so there
    -- lock=nil means "we missed it", not "there is none". This is NEGATIVE
    -- evidence, same class as no_key_trusted -- fire it wrongly and it marks a
    -- crit room bonus, and the cascade kills the floor.
    --
    -- The live case it exists for (2026-07-25): yellow_triangle sat at 2,3 with
    -- its lock never seen, and since a key alone halts bonus-UP, the whole
    -- 2,3 -> 2,4 -> 2,5 column stayed unknown long after the boss was found.
    if ev.solo and boss_key and not i.lock then return "bonus" end
    return nil
  end
  local function unopened(ck)
    for _, n in ipairs(rooms[ck].images) do
      if n:sub(1, 9) == "UNOPENED_" then return true end
    end
    return false
  end
  -- "This room offers no crit continuation." True when every child is bonus --
  -- and ALSO when there are no children at all, i.e. an opened dead end, which
  -- is the strongest form of the same fact. That second case is easy to miss:
  -- phrasing it as "all children are bonus" makes a childless room fail
  -- vacuously, so dead ends never flood bonus and a whole dead branch stays
  -- unknown forever (seen live: DE_SOUTH at 0,0 stalling the 0,0-0,3 chain).
  --
  -- Only meaningful for an OPENED room: opening reveals full adjacency on the
  -- minimap, so an opened room's children are all known. An unopened room has
  -- no children YET and could still be anything, including boss.
  local function no_crit_continuation(ck)
    if unopened(ck) then return false end
    for _, kid in ipairs(kids[ck] or {}) do
      if P[kid] ~= "bonus" then return false end
    end
    return true
  end
  -- "This crit room needs >=1 crit child" holds only once it is ruled out as a
  -- side-branch terminus: it gave no key, or the key it gave is proven bonus.
  -- A key alone gives no leverage (the key could be crit, making it a terminus).
  -- Can we actually go through this unopened room right now? ONLY a key door can
  -- block us. A skill door gates on level, which the party is assumed to meet
  -- for the floor's tier, and a guardian ("?") door is simply fought -- both are
  -- always openable and count as frontier exactly like a plain unopened room.
  --
  -- A key door counts as openable when its key is IN THE BAG or has a trusted
  -- FOUND record. The found case is load-bearing for soundness: found + door
  -- still locked + key not in bag can only mean the key is lying in explored
  -- space, fetchable at will -- so the door does not actually block progress.
  -- Excluding it shrank the frontier below reality and produced a FALSE crit on
  -- a live floor (2026-07-14): gold_crescent sat unfetched at 3,5 with its lock
  -- at 7,3; 7,3 was excluded as "locked", the frontier collapsed to the one
  -- other openable door, and the rule proved that door crit -- though walking
  -- back for the key reached boss-ward progress without ever touching it. The
  -- old exclusion argument ("no crit key could ever be fetched") silently
  -- assumed unfetched keys live BEYOND the frontier; a found key in explored
  -- space is the counterexample.
  -- "This room holds no key" is NEGATIVE evidence -- an absence claim -- and it
  -- is only meaningful once detection has had a chance to run. A room reads as
  -- OPENED from the minimap the instant its door opens, but a ground key inside
  -- it is detected by PROXIMITY -- so there is a built-in race: door opens, "no
  -- key here" is evaluated the same tick, the key is scanned a few frames later.
  -- Persistence froze exactly that race on a live floor (deathdump_1784094322):
  -- 0,2 went bonus as "opened dead end, holds no key" while the BOSS KEY lay
  -- undetected inside it, and the cascade off that false bonus killed the floor
  -- three different ways.
  --
  -- Gate: trust absence only once the room has been opened for >= 1 second
  -- (ev.opened_at[ck] + ev.now, bolt.time() microseconds). 0.1s covers
  -- detection latency: the opener stands adjacent to the door, so nearly the
  -- whole room is already inside the scan box when it opens. Known residual: a
  -- key in the ~1-tile strip beyond scan range, in a room opened but never
  -- approached, can outlive the deadline -- if it is later found, the persisted
  -- fact collides and fails loudly. Positive evidence (key seen, key proven
  -- bonus) needs no gate. ev.opened_at == nil means "trust absence"
  -- (pure-engine fixtures); main.lua always passes the real stamps.
  local function no_key_trusted(ck)
    if not ev.opened_at then return true end
    local t = ev.opened_at[ck]
    return t ~= nil and (ev.now or 0) - t >= 100000
  end
  local function openable(ck)
    local need
    for _, n in ipairs(rooms[ck].images) do
      local kn = key_lower(n)
      if kn then need = kn; break end
    end
    if not need then return true end
    return (ev.keybag or {})[need] == true or found_of[need] ~= nil
  end
  local function not_terminus(ck)
    if ck == boss_key then return false end
    -- Base is the ROOT, never a side-branch terminus. A terminus is the end of
    -- a branch that exists only to hold a crit key; base is where the crit path
    -- STARTS, so it always has >=1 crit child (category 0) no matter what it
    -- holds. Without this, a key bound to base -- which the ground-key detector
    -- readily does, since it mis-binds to the player's own cell and the player
    -- spawns on base -- withholds the "needs a crit child" premise and blocks
    -- elimination across the entire floor from the very first room.
    if ck == base_key then return true end
    local kn = key_in[ck]
    if not kn then return no_key_trusted(ck) end
    return key_parity(kn) == "bonus"
  end

  set(base_key, "crit", "seed: base is crit by definition")
  if boss_key then set(boss_key, "crit", "seed: boss is crit by definition") end
  -- PERSISTED FACTS from earlier ticks, seeded before anything is re-derived.
  -- Parity is a permanent property of the floor: once a room is proven crit or
  -- bonus it stays that way until the floor ends, so a proof is not something to
  -- re-earn every tick. Re-deriving from scratch USED to throw these away, which
  -- silently lost every conclusion whose premise was transient -- the frontier
  -- rule's most of all, since the frontier itself moves as you explore, so rooms
  -- would go crit and then fall back to unknown.
  --
  -- Seeding them here also puts them through set(), which is the point: if a
  -- fresh inference disagrees with a fact we already proved, that is a
  -- contradiction and the floor dies. Re-derivation used to hide exactly this
  -- class of bug by quietly rearranging the map instead of reporting it.
  for ck, f in pairs(ev.facts or {}) do
    -- Tagged so the dump does not replay a stale premise in the present tense.
    -- The frontier rule especially: its reason names the frontier as it stood
    -- when the proof was made, and that frontier has usually moved on since.
    -- The fact remains true; the sentence describing it is history.
    if seen[ck] then set(ck, f.val, "proved earlier -- " .. f.reason) end
  end
  for ck, res in pairs(ev.resource_bonus or {}) do
    if seen[ck] then
      set(ck, "bonus", ("resource: sub-top-tier %s sighted here"):format(
        type(res) == "string" and res or "resource"))
    end
  end
  -- Skill-door examines: a requirement inside a skill's guaranteed range
  -- proves the locked room's parity (the reason string is built at bind time
  -- and names the door, skill and level). Both directions are guarantees per
  -- skill_doors.txt -- adjudicated 2026-07-15 by the tier table's author: a
  -- crit-range level cannot appear on a bonus door. A level inside BOTH
  -- ranges (strength's 106-110 overlap) or NEITHER (the 101-105 gap) is
  -- ambiguous and never reaches these maps. Crit propagates UP to base via
  -- the normal propagator; bonus floods DOWN.
  for ck, why in pairs(ev.skill_bonus or {}) do
    if seen[ck] then set(ck, "bonus", why) end
  end
  for ck, why in pairs(ev.skill_crit or {}) do
    if seen[ck] then set(ck, "crit", why) end
  end

  local rounds = 0
  repeat
    dirty = false
    rounds = rounds + 1
    if fatal then break end

    -- Bonus DOWN: unconditional. Nothing past a bonus room can be on the
    -- backbone, because the crit path cannot detour through a bonus room.
    for ck in pairs(rooms) do
      if P[ck] == "bonus" then
        for _, kid in ipairs(kids[ck] or {}) do
          set(kid, "bonus", ("bonus DOWN from parent %s"):format(ck))
        end
      end
    end

    -- Crit UP: unconditional. Crit is connected from base, so a crit room's
    -- path back to base traverses only crit rooms.
    for ck in pairs(rooms) do
      if P[ck] == "crit" then
        local cur = parent[ck]
        while cur do
          set(cur, "crit", ("crit UP: ancestor of crit room %s"):format(ck))
          cur = parent[cur]
        end
      end
    end

    -- Bonus UP: conditional flood-fill. A room whose every child is bonus has
    -- no crit continuation, so it is bonus too -- UNLESS it holds a key that
    -- is not proven bonus, in which case it may be a side-branch terminus
    -- holding a crit key, which would make it crit. Halt there.
    for ck in pairs(rooms) do
      if not P[ck] and no_crit_continuation(ck) then
        local kn = key_in[ck]
        if (not kn and no_key_trusted(ck)) or (kn and key_parity(kn) == "bonus") then
          set(ck, "bonus", ("bonus UP: no crit continuation -- %s%s"):format(
            #(kids[ck] or {}) == 0 and "opened dead end, no children"
              or ("all " .. #kids[ck] .. " children bonus (" .. table.concat(kids[ck], " ") .. ")"),
            kn and (", key " .. kn .. " proven bonus") or ", holds no key"))
        end
      end
    end

    -- Key: bonus pickup => bonus lock. Bonus rooms never hold crit keys, so a
    -- key found in a bonus room must open a bonus door, wherever that door is.
    for kn, i in pairs(keys) do
      local f = found_of[kn]
      if f and i.lock and P[f] == "bonus" then
        set(i.lock, "bonus", ("key %s: picked up in bonus room %s, so it opens a bonus door"):format(kn, f))
      end
    end

    -- Key: crit lock => crit pickup (the CONTRAPOSITIVE of the rule above). If
    -- the cell behind a key door is crit, that door must be opened to progress,
    -- so the key is a crit key by definition -- and bonus rooms never hold crit
    -- keys, so the room the key was picked up in is crit. Crit then flows UP
    -- the pickup room's whole ancestor chain via the crit-UP propagator.
    -- Note the direction: PICKUP crit says nothing about the lock (crit rooms
    -- drop bonus keys too); only LOCK crit forces the pickup.
    for kn, i in pairs(keys) do
      local f = found_of[kn]
      if f and i.lock and P[i.lock] == "crit" and seen[f] then
        set(f, "crit", ("key %s: its lock %s is crit, so the key is crit, and bonus rooms never hold crit keys -- pickup room is crit"):format(kn, i.lock))
      end
    end

    -- Key: a crit room with a key and no crit continuation IS a terminus, so
    -- its key is crit => the lock is crit => crit flows up from the lock.
    for ck in pairs(rooms) do
      local kn = key_in[ck]
      if kn and P[ck] == "crit" and no_crit_continuation(ck) then
        local i = keys[kn]
        if i.lock then
          set(i.lock, "crit", ("key %s: crit room %s has no crit continuation, so it is a terminus and its key is crit"):format(kn, ck))
        end
      end
    end

    -- Elimination, per crit room (not global). Once a crit room is ruled out as
    -- a terminus it must have >=1 crit child; if every child but one is bonus,
    -- that one is crit.
    for ck in pairs(rooms) do
      if P[ck] == "crit" and not unopened(ck) and not_terminus(ck) then
        local ks = kids[ck] or {}
        if #ks > 0 then
          local left, has_crit = {}, false
          for _, kid in ipairs(ks) do
            if P[kid] == "crit" then has_crit = true
            elseif P[kid] ~= "bonus" then left[#left + 1] = kid end
          end
          if not has_crit then
            if #left == 1 then
              set(left[1], "crit", ("elimination: only unresolved child of crit non-terminus %s"):format(ck))
            elseif #left == 0 then
              note(("contradiction %s: crit non-terminus with every child bonus"):format(ck))
            end
          end
        end
      end
    end

    -- BOSS UNDISCOVERED: boss exists on every floor, and an opened room's
    -- adjacency is fully known, so boss cannot be hiding among opened rooms --
    -- it lies beyond the unexplored frontier. The base->boss path therefore
    -- crosses exactly ONE frontier room, so any room that is an ancestor of
    -- EVERY frontier room is on that path whichever one it proves to be, and is
    -- crit. With a single frontier room this collapses to "that room is crit".
    -- Frontier excludes already-bonus rooms: nothing beyond a bonus room can be
    -- crit, so boss cannot be back there.
    -- QUIET GATE (user's delay pattern, generalized). The frontier argument
    -- consumes ABSENCE evidence -- "nothing else is openable" -- and both dead
    -- floors died of it firing inside the gap between a room appearing on the
    -- minimap and the key inside it being proximity-scanned (deathdumps
    -- 1784094322, 1784095964: 6,3 opened, locked 6,2 visible, orange_pentagon
    -- on 6,3's floor not yet seen; frontier collapsed to 5,7 and painted a
    -- bonus corridor crit). Sized to SCAN LATENCY (frames), deliberately not to
    -- human traversal: a key grabbed fast, or never approached, beats ANY timer
    -- (proven by green_corner, picked up inside the old 1s window and never
    -- detected at all) -- so a long timer only slows the map without closing the
    -- residual; collisions from that class fail loudly via the contradiction
    -- path instead. So it may only run once the world has been STILL
    -- for 0.1s: no new room, no door opened, no key found, no bag change.
    -- ev.last_change == nil (fixtures) means quiet.
    local quiet = ev.last_change == nil
               or (ev.now or 0) - ev.last_change >= 100000
    if not boss_key and quiet then
      local any_unopened = false
      for ck in pairs(rooms) do
        if seen[ck] and unopened(ck) and P[ck] ~= "bonus" then any_unopened = true; break end
      end
      if not any_unopened then
        note("contradiction: boss is undiscovered but no unexplored frontier remains")
      end
      -- Frontier is the OPENABLE unopened rooms, not merely the unopened ones.
      -- A locked key door is not somewhere we can go, so it cannot be where our
      -- next progress happens -- and excluding it makes the frontier smaller,
      -- which makes the shared-ancestor set LARGER and the rule stronger.
      --
      -- Soundness: the floor is completable, so at least one openable frontier
      -- room must be crit -- if every one were bonus, everything beyond them is
      -- bonus, no crit key could ever be fetched, the locked crit doors would
      -- never open and boss would be unreachable. Whichever one is the real crit
      -- room, a shared ancestor of ALL of them is an ancestor of that one, so it
      -- is crit regardless of which. Note this yields crit, not necessarily
      -- BACKBONE: the room may instead head a crit side-branch holding the key
      -- that unlocks the backbone. Crit either way.
      local frontier = {}
      for ck in pairs(rooms) do
        if seen[ck] and unopened(ck) and P[ck] ~= "bonus" and openable(ck) then
          frontier[#frontier + 1] = ck
        end
      end
      if #frontier > 0 then
        local common = {}
        local cur = frontier[1]
        while cur do common[cur] = true; cur = parent[cur] end
        for i = 2, #frontier do
          local chain = {}
          cur = frontier[i]
          while cur do chain[cur] = true; cur = parent[cur] end
          for k in pairs(common) do
            if not chain[k] then common[k] = nil end
          end
        end
        -- Name the frontier in the reason: "only N rooms" is unauditable
        -- after the fact -- the purple_corner death hinged on WHICH room the
        -- frontier had collapsed to, and the count alone could not say.
        local flist = table.concat(frontier, " ")
        for ck in pairs(common) do
          set(ck, "crit", ("frontier: boss is undiscovered and only %d room(s) can be opened (%s), so progress must run through one of them; this room is an ancestor of every one"):format(#frontier, flist))
        end
      end
    end

    -- BOSS DISCOVERED: a room only reveals ICON_BOSS once ENTERED, and you can
    -- only have walked to it from base along the backbone -- which means every
    -- crit door en route was already unlocked and every crit-key side branch
    -- already fetched. So the moment boss is on the map the crit tree is opened
    -- in its entirety, boss included. Anything still unopened is off it.
    if boss_key then
      for ck in pairs(rooms) do
        if seen[ck] and unopened(ck) then
          set(ck, "bonus", "boss is on the map, so the whole crit tree is already opened; a still-unopened room is off it")
        end
      end
      -- And by the same argument no locked crit door remains, so a key still
      -- sitting in the keybag cannot be a crit key -- its lock is bonus.
      for kn in pairs(ev.keybag or {}) do
        local i = keys[kn]
        if i and i.lock then
          set(i.lock, "bonus", ("key %s: still held with boss already on the map, so every crit key has been spent; this one is bonus"):format(kn))
        end
      end
    end

    -- BRANCH-CAPACITY FORCING. The crit tree must hold at least CRIT_MIN rooms
    -- (whole tree, side branches included). So if every branch EXCEPT C, maxed
    -- out, still cannot reach CRIT_MIN, the shortfall has to live in C --
    -- therefore C is crit. This is the only rule that yields CRIT from counting
    -- alone, with no bonus, key or boss evidence anywhere in the branch.
    --
    --   capacity(X) = 0                                  if X is bonus
    --   capacity(X) = 1 + sum(capacity(children))
    --                   + undiscovered reachable from X   if X is UNOPENED
    --
    -- OVER-counting is safe: too large a capacity only makes the rule fire less
    -- often, so an undiscovered region touching several unopened rooms is simply
    -- counted for each rather than partitioned.
    --
    -- Gated on a proven-large floor: 18-23 is a LARGE-floor bound and the
    -- medium/small bounds are unknown, so firing this early would invent crit.
    if ev.floor_is_large and CRIT_MIN then
      -- Undiscovered = in-bounds cell with no known room. An OPENED room's
      -- doors always lead to already-discovered rooms (opening reveals full
      -- adjacency), so undiscovered space is only ever reachable via an
      -- UNOPENED room -- which is what makes the bound computable at all.
      local undisc = {}
      for gx = 0, 7 do
        for gz = 0, 7 do
          local ck = gx .. "," .. gz
          if not rooms[ck] then undisc[ck] = true end
        end
      end
      -- Flood undiscovered cells into connected regions.
      local region_of, region_size, nreg = {}, {}, 0
      for ck in pairs(undisc) do
        if not region_of[ck] then
          nreg = nreg + 1
          local stack, n = { ck }, 0
          region_of[ck] = nreg
          while #stack > 0 do
            local cur = table.remove(stack)
            n = n + 1
            local sx, sy = cur:match("^(%-?%d+),(%-?%d+)$")
            sx, sy = tonumber(sx), tonumber(sy)
            for _, d in pairs(NEI_DELTA) do
              local nk = (sx + d[1]) .. "," .. (sy + d[2])
              if undisc[nk] and not region_of[nk] then
                region_of[nk] = nreg
                stack[#stack + 1] = nk
              end
            end
          end
          region_size[nreg] = n
        end
      end
      -- Credit each region to every unopened room touching it. A region touching
      -- NO unopened room is unreachable from base, so it holds no rooms at all.
      local undisc_cap = {}
      for ck in pairs(rooms) do
        if seen[ck] and unopened(ck) then
          local hit = {}
          for _, d in pairs(NEI_DELTA) do
            local id = region_of[(rooms[ck].gx + d[1]) .. "," .. (rooms[ck].gz + d[2])]
            if id then hit[id] = true end
          end
          local n = 0
          for id in pairs(hit) do n = n + region_size[id] end
          undisc_cap[ck] = n
        end
      end
      local cap = {}
      local function capacity(ck)
        if cap[ck] then return cap[ck] end
        cap[ck] = 0                      -- cycle guard; the graph is a tree, but
        if P[ck] == "bonus" then return 0 end
        local n = 1
        for _, kid in ipairs(kids[ck] or {}) do n = n + capacity(kid) end
        if unopened(ck) then n = n + (undisc_cap[ck] or 0) end
        cap[ck] = n
        return n
      end
      local total = capacity(base_key)
      for ck in pairs(rooms) do
        if seen[ck] and ck ~= base_key and not P[ck] then
          local without = total - capacity(ck)
          if without < CRIT_MIN then
            set(ck, "crit", ("capacity: the crit tree needs >=%d rooms but everything outside this branch caps at %d, so the shortfall must be in here"):format(CRIT_MIN, without))
          end
        end
      end
    end
  until not dirty or rounds > 64

  -- FATAL: an opened dead end holding no key cannot be crit. A crit branch
  -- exists to reach the boss or to fetch a key; a childless, keyless, opened
  -- room serves neither, so a crit mark on one proves an upstream proof false
  -- (seen live 2026-07-17: a frontier mint chained 5,1->5,0->4,0 crit into an
  -- empty dead end, and the only tell was the crit count creeping past the
  -- structural bound -- bonus-UP could not object because it only touches
  -- unmarked cells). Adjudicated fatal: same epistemic status as crit meeting
  -- bonus. Uses bonus-UP's absence-evidence gate: "holds no key" is only
  -- trustworthy once the ground scan has had its window in an opened room.
  if not fatal then
    for ck in pairs(rooms) do
      if P[ck] == "crit" and ck ~= base_key and ck ~= boss_key
         and not unopened(ck) and #(kids[ck] or {}) == 0
         and not key_in[ck] and no_key_trusted(ck) then
        local m = ("contradiction %s: crit terminus holds no key -- opened dead end, no children, nothing to fetch (crit because: %s)")
          :format(ck, why[ck] or "?")
        note(m)
        fatal = { cell = ck, had = "crit", had_why = why[ck] or "?",
                  got = "bonus", got_why = "opened dead end, no children, holds no key -- a crit branch must end at the boss or a key",
                  text = m }
        break
      end
    end
  end

  -- Structural validators. These never change parity -- they surface upstream
  -- detection errors so a bad observation is visible instead of silently
  -- corrupting the graph.
  if boss_key and key_in[boss_key] then note("invariant: boss room holds a key") end
  local nkeys, nlocks = 0, 0
  for _, i in pairs(keys) do
    if i.found then nkeys = nkeys + 1 end
    if i.lock then nlocks = nlocks + 1 end
  end
  -- Counting constraint: keys and locks pair 1:1, so the seen counts bound what
  -- is left -- K found keys and L seen locks => K-L matching locks (or L-K keys)
  -- still exist in unexplored space. NEITHER SIGN IS A VIOLATION mid-floor:
  -- seeing a key door before finding its key is the normal state of exploration
  -- (live example: 6 locks / 3 found keys on a healthy floor, which the old
  -- check here reported as "1:1 pairing violated" every tick). The count only
  -- binds once the floor is fully explored, and the real per-key violations --
  -- two locks claiming one key, two keys in one room -- are detected above.
  -- meta.unmatched_locks carries the (signed) count for display.
  local ncrit = 0
  for _, v in pairs(P) do if v == "crit" then ncrit = ncrit + 1 end end
  local nrooms = 0
  for _ in pairs(rooms) do nrooms = nrooms + 1 end
  -- Large-floor bounds: 50-64 rooms, crit path 18-23 INCLUDING base+boss.
  -- The room count is advisory (only meaningful once fully explored). The
  -- CRIT count is FATAL (adjudicated 2026-07-17): crit marks only ever
  -- accumulate toward the true count, so exceeding the 23-room ceiling at
  -- ANY moment proves at least one crit proof false -- and 23 is the
  -- largest tree any floor size allows, so the bound holds floor-wide.
  if nrooms > 64 then
    note(("bounds: %d rooms exceeds the 64-room large-floor maximum"):format(nrooms))
  end
  if ncrit > 23 then
    local m = ("contradiction: %d crit rooms exceeds the 23-room crit-path ceiling -- at least one crit proof is false"):format(ncrit)
    note(m)
    fatal = fatal or { cell = "(floor)", had = "<= 23 crit rooms",
                       had_why = "structural bound: the largest crit tree any floor allows is 23 rooms including base+boss",
                       got = ncrit .. " crit rooms", got_why = "accumulated crit proofs", text = m }
  end
  return P, parent, diag, why,
    { rounds = rounds, unmatched_locks = nkeys - nlocks, ncrit = ncrit,
      base = base_key, boss = boss_key, kids = kids, key_in = key_in,
      found_of = found_of, nrooms = nrooms, fatal = fatal }
end

return solve_parity
end
