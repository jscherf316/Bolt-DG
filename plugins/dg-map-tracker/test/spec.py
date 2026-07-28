#!/usr/bin/env python3
"""Tests for dg-map-tracker's parity engine and world/map coordinate mapping.

Run:  python test/spec.py          (from plugins/dg-map-tracker/)

WHY THIS FILE IS IN THE REPO. A previous version of this harness lived in a
session temp directory, was never committed, and was deleted -- taking 71 tests
with it. It is not optional infrastructure; the bugs below were all found by it
or would have been.

HOW IT WORKS. The parity engine is require()d from the shipped parity.lua with
stub dependencies -- the same injection main.lua uses -- so these tests exercise
SHIPPED CODE, not a copy that can drift. The few main.lua-resident functions
under test (base_if_player_in_it, world_room_to_grid, unix_now) are still
extracted from main.lua by text markers; keep those functions' first lines
stable or update the markers here in the same commit.

LESSONS PAID FOR IN REAL BUGS -- do not undo these:
  1. Assert the REASON, not just the value. Several propagators can produce the
     same value, so a value assertion passes while the rule under test is dead.
  2. A passing test can encode the bug. A test once asserted that a key on BASE
     suppresses elimination -- which was the live bug, green the whole time.
  3. Fixtures must describe POSSIBLE floors. A floor with no boss AND no frontier
     cannot exist; such a fixture will report diagnostics, and that is correct.
     Only assert #diag == 0 on a well-formed floor.
  4. "Contradiction reported" is a FAILURE signal, not noise.
"""

import io
import os
import re
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, os.pardir, 'main.lua')

# Globals the engine closes over. Kept minimal and faithful; NEI_DELTA in
# particular must match main.lua -- north is gz-1 -- or the axis tests are void.
PRELUDE = '''
NEI_DELTA = { n = {0,-1}, e = {1,0}, s = {0,1}, w = {-1,0} }
NEI_OPP   = { n = "s", e = "w", s = "n", w = "e" }
ROOM_DOORS = {
  ["4WAY"]        = {n=true,e=true,s=true,w=true},
  ["2WAY_NS"]     = {n=true,s=true},
  ["2WAY_EW"]     = {e=true,w=true},
  ["2WAY_NE"]     = {n=true,e=true},
  ["2WAY_ES"]     = {e=true,s=true},
  ["2WAY_SW"]     = {s=true,w=true},
  ["2WAY_NW"]     = {n=true,w=true},
  ["3WAY_NEW"]    = {n=true,e=true,w=true},
  ["ICON_BASE"]   = {}, ["ICON_BOSS"] = {},
  ["DE_NORTH"]    = {n=true}, ["DE_SOUTH"] = {s=true},
  ["DE_EAST"]     = {e=true}, ["DE_WEST"]  = {w=true},
  ["UNOPENED_NORTH_TEMPLATE"] = {n=true},
  ["UNOPENED_SOUTH_TEMPLATE"] = {s=true},
  ["UNOPENED_EAST_TEMPLATE"]  = {e=true},
  ["UNOPENED_WEST_TEMPLATE"]  = {w=true},
}
function cell_doors(cell)
  local out = {}
  for _, name in ipairs(cell.images) do
    local d = ROOM_DOORS[name]
    if d then for k in pairs(d) do out[k] = true end end
  end
  return out
end
-- Must replicate the REAL key_lower's validation: it returns nil for anything
-- that is not <color>_<shape>. A bare string.lower stub makes EVERY image name
-- read as a key, which silently disables openable() in every fixture -- the
-- frontier then sees no openable rooms at all and never fires.
local COLORS = { blue=true, purple=true, green=true, silver=true,
                 orange=true, crimson=true, gold=true, yellow=true }
local SHAPES = { triangle=true, rectangle=true, wedge=true, corner=true,
                 pentagon=true, diamond=true, shield=true, crescent=true }
function key_lower(name)
  if not name then return nil end
  local ln = string.lower(name)
  local color, shape = ln:match("^([^_]+)_(.+)$")
  if color and shape and COLORS[color] and SHAPES[shape] then return ln end
  return nil
end
rooms_by_cell = {}
'''

FAILS = []


def check(label, cond, detail=''):
    print('  %-4s %s%s' % ('ok' if cond else 'FAIL', label,
                           ('  -- ' + detail) if detail and not cond else ''))
    if not cond:
        FAILS.append(label)


def extract(src, start, end_after='\nend', repl_local=True):
    i = src.index(start)
    j = src.index(end_after, i) + len(end_after)
    body = src[i:j]
    return body.replace('local function', 'function', 1) if repl_local else body


def build():
    src = io.open(MAIN, encoding='utf-8').read()
    lua = lupa.LuaRuntime()
    lua.compile(src)                                   # parse check main.lua
    plugin_dir = os.path.dirname(MAIN).replace('\\', '/')
    lua.compile(io.open(os.path.join(plugin_dir, 'parity.lua'),
                        encoding='utf-8').read())      # parse check parity.lua
    lua.execute(PRELUDE)
    # Load the engine exactly the way main.lua does: require + injected deps.
    lua.execute('package.path = "%s/?.lua;" .. package.path' % plugin_dir)
    lua.execute('solve_x = require("parity")({cell_doors = cell_doors,'
                ' key_lower = key_lower, NEI_DELTA = NEI_DELTA,'
                ' NEI_OPP = NEI_OPP})')
    lua.execute(extract(src, 'function base_if_player_in_it'))
    lua.execute('S = {}\n' + extract(src, 'local function world_room_to_grid'))
    lua.execute(extract(src, 'local function unix_now'))
    return lua, src


def cells(lua, spec):
    """spec: {(gx,gz): [images]} -> lua table keyed 'gx,gz'."""
    t = {}
    for (gx, gz), imgs in spec.items():
        t['%d,%d' % (gx, gz)] = lua.table_from(
            {'gx': gx, 'gz': gz, 'images': lua.table_from(list(imgs))})
    return lua.table_from(t)


def main():
    lua, src = build()
    g = lua.globals()
    print('main.lua parses; engine extracted from shipped source\n')

    # ---- world_room_to_grid -------------------------------------------------
    # THE AXIS TEST. The map is drawn NORTH-UP so dungeon rows run SOUTH, while
    # world z runs NORTH -- the z mapping is a REFLECTION (gz = origin.wrz - wrz),
    # not a shift. The old code added a delta on both axes; it was exactly right
    # for the player's own room by construction and mirrored every cross-room
    # sighting to the far side of the player. Months to find. Keep this test.
    print('world_room_to_grid  (origin = NW corner, world room of cell 0,0)')
    g.S.map_origin = lua.table_from({'wrx': 824, 'wrz': 35})
    for name, wrx, wrz, ex, ez in [
            ('NW corner -> 0,0', 824, 35, 0, 0),
            ('SW corner -> 0,7', 824, 28, 0, 7),
            ('NE corner -> 7,0', 831, 35, 7, 0),
            ('SE corner -> 7,7', 831, 28, 7, 7),
            ('live dump 831,32', 831, 32, 7, 3)]:
        gx, gz = g.world_room_to_grid(wrx, wrz)
        check(name, (gx, gz) == (ex, ez), 'got %d,%d want %d,%d' % (gx, gz, ex, ez))

    # The origin is a FLOOR CONSTANT: calibrating from any room must agree.
    # The old model yielded 8 different values across an 8x8 floor -- it was a
    # function of where the player stood, which is what made it a bug.
    SWX, SWZ = 16080 // 16, 1216 // 16          # a real floor's SW corner
    new = {(gx - (SWX + gx), (7 - gz) + SWZ + (7 - gz)) for gx in range(8) for gz in range(8)}
    news = {((SWX + gx) - gx, (SWZ + (7 - gz)) + gz) for gx in range(8) for gz in range(8)}
    olds = {((SWX + gx) - gx, gz - (SWZ + (7 - gz))) for gx in range(8) for gz in range(8)}
    check('origin constant over all 64 rooms (mirror model)', len(news) == 1,
          '%d distinct' % len(news))
    check('shift model is NOT constant (regression guard)', len(olds) > 1,
          'shift model looks constant -- test is void')

    # ---- base_if_player_in_it ----------------------------------------------
    # Exact, not heuristic: to stand anywhere but base you must traverse an
    # adjacent room, which opens it. Monotone within a floor, so false->true
    # means a new floor.
    print('\nbase_if_player_in_it')
    B = ['2WAY_EW', 'ICON_BASE']
    g.rooms_by_cell = cells(lua, {(4, 6): B, (3, 6): ['UNOPENED_EAST_TEMPLATE'],
                                  (5, 6): ['UNOPENED_WEST_TEMPLATE']})
    r = g.base_if_player_in_it()
    check('spawn: all neighbours unopened -> in base', bool(r) and (r.gx, r.gz) == (4, 6))

    g.rooms_by_cell = cells(lua, {(4, 6): B, (3, 6): ['UNOPENED_EAST_TEMPLATE'],
                                  (5, 6): ['3WAY_NEW']})
    check('one neighbour opened -> not in base', g.base_if_player_in_it() is None)

    # A gap is not evidence. Declining costs a frame; guessing costs the floor.
    g.rooms_by_cell = cells(lua, {(4, 6): B, (3, 6): ['UNOPENED_EAST_TEMPLATE']})
    check('neighbour missing -> decline, do not guess', g.base_if_player_in_it() is None)

    g.rooms_by_cell = cells(lua, {(1, 1): ['4WAY']})
    check('no base on map -> nil, no crash', g.base_if_player_in_it() is None)

    # A key door is still an unopened room; a locked base door must not block it.
    g.rooms_by_cell = cells(lua, {(4, 6): B,
                                  (3, 6): ['UNOPENED_EAST_TEMPLATE', 'crimson_pentagon'],
                                  (5, 6): ['UNOPENED_WEST_TEMPLATE']})
    check('locked neighbour still counts as unopened', bool(g.base_if_player_in_it()))

    # ---- solve_parity: write path ------------------------------------------
    print('\nsolve_parity: facts, contradiction, halt')
    rm = cells(lua, {(0, 0): ['2WAY_NS', 'ICON_BASE'], (0, 1): ['2WAY_NS'],
                     (0, 2): ['DE_NORTH']})

    def solve(facts=None):
        return g.solve_x(rm, lua.table_from({'facts': lua.table_from(facts or {})}))

    P, _, diag, why, meta = solve()
    check('no facts -> no fatal', meta.fatal is None)

    # Parity is a fact of the floor: two propagators disagreeing about one room
    # means something upstream lies. Stop rather than manufacture a map.
    P, _, diag, why, meta = solve(
        {'0,0': lua.table_from({'val': 'bonus', 'reason': 'bogus'})})
    check('persisted fact vs seed -> FATAL', meta.fatal is not None)
    if meta.fatal:
        check('fatal names the cell', meta.fatal.cell == '0,0')
        check('fatal captures BOTH claims',
              bool(meta.fatal.had) and bool(meta.fatal.had_why)
              and bool(meta.fatal.got) and bool(meta.fatal.got_why))
        check('halts immediately (does not keep propagating)', meta.rounds <= 1,
              'rounds=%s' % meta.rounds)

    P, _, diag, why, meta = solve(
        {'0,0': lua.table_from({'val': 'crit', 'reason': 'agrees'})})
    check('agreeing fact -> no false fatal', meta.fatal is None)

    # Reason, not value (lesson 1): a persisted fact must be tagged so the dump
    # does not replay an expired premise in the present tense.
    P, _, diag, why, meta = solve(
        {'0,1': lua.table_from({'val': 'crit', 'reason': 'frontier: ...'})})
    check('persisted fact is re-seeded', P['0,1'] == 'crit')
    check('persisted reason is TAGGED as historical',
          why['0,1'].startswith('proved earlier -- '), repr(why['0,1']))
    check('tag applied exactly once (no unbounded growth)',
          why['0,1'].count('proved earlier -- ') == 1)

    # ---- crit lock => crit pickup (contrapositive of bonus pickup => bonus lock)
    # A key whose door opens into a crit cell must itself be crit, and bonus
    # rooms never hold crit keys, so the pickup room is crit. Fixture: base and
    # boss are crit by seed; the key was picked up in a side room (1,1) whose
    # parity NO other rule can derive (it holds a key, so the dead-end rule is
    # withheld; boss is discovered, so the frontier rule is off; its crit
    # sibling already satisfies elimination). Only the contrapositive reaches it.
    print('\nsolve_parity: crit lock => crit pickup room')
    rm2 = cells(lua, {(0, 0): ['2WAY_EW', 'ICON_BASE'], (1, 0): ['4WAY'],
                      (2, 0): ['DE_WEST', 'ICON_BOSS'], (1, 1): ['2WAY_NS']})

    def solve2(keys):
        return g.solve_x(rm2, lua.table_from(
            {'facts': lua.table_from({}),
             'keys': lua.table_from({k: lua.table_from(v) for k, v in keys.items()})}))

    P, _, diag, why, meta = solve2({'gold_wedge': {'found': '1,1', 'lock': '2,0'}})
    check('well-formed fixture (no diagnostics)', len(list(diag.values())) == 0,
          str(list(diag.values())))
    check('pickup room forced crit', P['1,1'] == 'crit', repr(P['1,1']))
    check('reason NAMES the contrapositive rule (not some other propagator)',
          why['1,1'] is not None and 'its lock' in why['1,1'], repr(why['1,1']))

    # Control: same floor, lock undiscovered -> nothing else may derive 1,1.
    # If this fails, the assertion above stopped proving the rule exists.
    P, _, diag, why, meta = solve2({'gold_wedge': {'found': '1,1'}})
    check('control: without the lock, pickup room stays unknown', P['1,1'] is None,
          repr(P['1,1']))

    # Locks legitimately outnumber found keys mid-floor (you see key doors
    # before finding their keys). This exact state -- lock seen, key not found --
    # used to fire "1:1 pairing violated" every tick on healthy floors.
    P, _, diag, why, meta = solve2({'blue_shield': {'lock': '1,1'}})
    check('lock-without-found-key is NOT a diagnostic',
          len(list(diag.values())) == 0, str(list(diag.values())))

    # ---- frontier: a locked door whose key is FOUND (unfetched, in explored
    # space) must count as openable. Live false-crit, 2026-07-14: gold_crescent
    # lay unfetched at 3,5 with lock 7,3; excluding 7,3 as "locked" collapsed
    # the frontier to one other door, which the rule then proved crit -- though
    # fetching the key reached progress without touching that door. Layout:
    # base(0,0) - (1,0) - locked door (2,0), key found at (1,1), plain unopened
    # door at (1,2). Frontier must be BOTH doors; only shared ancestors get crit.
    print('\nsolve_parity: found-but-unfetched key makes its door frontier')
    rm3 = cells(lua, {(0, 0): ['2WAY_EW', 'ICON_BASE'], (1, 0): ['4WAY'],
                      (2, 0): ['UNOPENED_WEST_TEMPLATE', 'gold_wedge'],
                      (1, 1): ['2WAY_NS'],
                      (1, 2): ['UNOPENED_NORTH_TEMPLATE']})
    P, _, diag, why, meta = g.solve_x(rm3, lua.table_from(
        {'facts': lua.table_from({}),
         'keys': lua.table_from({'gold_wedge': lua.table_from(
             {'found': '1,1', 'lock': '2,0'})})}))
    check('well-formed fixture (no diagnostics)', len(list(diag.values())) == 0,
          str(list(diag.values())))
    # 1,0 is crit either way (elimination reaches it first as base's only
    # child); the frontier fix is proven by the NEGATIVE assertions below --
    # old code proved 1,2 crit with "only 1 room(s) can be opened".
    check('shared ancestor is crit', P['1,0'] == 'crit', repr(why['1,0']))
    check('the plain door is NOT falsely proven crit (old bug)',
          P['1,2'] is None, repr((P['1,2'], why['1,2'])))
    check('the locked-but-key-found door stays unknown too',
          P['2,0'] is None, repr(P['2,0']))

    # ---- skill-door examine => bonus (ev.skill_bonus, PR #1) -----------------
    # A requirement inside the skill's guaranteed-bonus range proves the locked
    # room bonus. The reason string is prebuilt at bind time and must survive
    # verbatim; bonus floods down; an unknown cell is ignored; colliding with
    # the base seed is a contradiction, not a repaint. Fixture: base(1,1) with
    # boss north (crit tree complete), dead ends east/west, and a south branch
    # (1,2)-(1,3) where (1,3) holds a found key -- which withholds the dead-end
    # and no-crit-continuation rules, so NO other propagator can reach the
    # branch (control asserts that). Only ev.skill_bonus derives it.
    print('\nsolve_parity: skill-door examine bonus (ev.skill_bonus)')
    rm4 = cells(lua, {(1, 1): ['4WAY', 'ICON_BASE'],
                      (1, 0): ['DE_SOUTH', 'ICON_BOSS'],
                      (0, 1): ['DE_EAST'], (2, 1): ['DE_WEST'],
                      (1, 2): ['2WAY_NS'], (1, 3): ['DE_NORTH']})

    def solve_sb(sb):
        return g.solve_x(rm4, lua.table_from(
            {'facts': lua.table_from({}),
             'keys': lua.table_from({'gold_wedge': lua.table_from({'found': '1,3'})}),
             'skill_bonus': lua.table_from(sb)}))

    reason = ('skill door examined: requires level 37 mining, inside the '
              'guaranteed-bonus range 1-100')
    P, _, diag, why, meta = solve_sb({})
    check('control: without skill_bonus the branch stays unknown',
          P['1,2'] is None, repr((P['1,2'], why['1,2'])))
    P, _, diag, why, meta = solve_sb({'1,2': reason})
    check('examined door room proven bonus', P['1,2'] == 'bonus', repr(P['1,2']))
    check('reason is the bind-time string, verbatim', why['1,2'] == reason,
          repr(why['1,2']))
    check('bonus floods down through the examined door', P['1,3'] == 'bonus',
          repr((P['1,3'], why['1,3'])))
    P, _, diag, why, meta = solve_sb({'9,9': reason})
    check('cell absent from the graph -> ignored, no crash', meta.fatal is None)
    P, _, diag, why, meta = solve_sb({'1,1': reason})
    check('skill-bonus colliding with the base seed -> FATAL',
          meta.fatal is not None)

    # ---- skill-door examine => crit (ev.skill_crit) --------------------------
    # Both directions are guarantees per skill_doors.txt (adjudicated by the
    # tier table's author): a crit-range requirement proves the locked room
    # CRIT, and crit must propagate UP through undecided ancestors to base.
    # Same fixture: skill_crit on the deep cell (1,3) forces (1,2) crit via
    # the UP propagator -- (1,2) is otherwise underivable (control above).
    print('\nsolve_parity: skill-door examine crit (ev.skill_crit)')

    def solve_sc(sc, sb=None):
        return g.solve_x(rm4, lua.table_from(
            {'facts': lua.table_from({}),
             'keys': lua.table_from({'gold_wedge': lua.table_from({'found': '1,3'})}),
             'skill_bonus': lua.table_from(sb or {}),
             'skill_crit': lua.table_from(sc)}))

    creason = ('skill door examined: requires level 108 magic, inside the '
               'guaranteed-crit range 106-120')
    P, _, diag, why, meta = solve_sc({'1,3': creason})
    check('examined door room proven crit', P['1,3'] == 'crit', repr(P['1,3']))
    check('crit reason is the bind-time string, verbatim', why['1,3'] == creason,
          repr(why['1,3']))
    check('crit propagates UP through the undecided parent', P['1,2'] == 'crit',
          repr((P['1,2'], why['1,2'])))
    P, _, diag, why, meta = solve_sc({'1,3': creason}, {'1,2': reason})
    check('skill-crit below a skill-bonus ancestor -> FATAL (cross-collision)',
          meta.fatal is not None)

    # ---- "holds no key" is absence evidence, gated on the room having been
    # OPEN for >= 0.1s. Rooms open on the minimap instantly; ground keys are
    # proximity-scanned frames later. Evaluating absence in that gap is how the
    # boss key at 0,2 got a floor killed (deathdump_1784094322). rm fixture:
    # 0,2 is an opened dead end with no key in evidence.
    print('\nsolve_parity: absence of a key needs the room open >= 1s')
    # 0,1 must be just-opened too: with its keylessness trusted, ELIMINATION
    # (crit non-terminus 0,1 needs a crit child, 0,2 is the only one) forces
    # 0,2 crit soundly and the dead-end gate never gets tested. Gating 0,1
    # exercises the not_terminus site as well.
    def solve_t(opened_us_ago):
        return g.solve_x(rm, lua.table_from(
            {'facts': lua.table_from({}), 'now': 5000000,
             'opened_at': lua.table_from({'0,0': 0,
                                          '0,1': 5000000 - opened_us_ago,
                                          '0,2': 5000000 - opened_us_ago})}))
    P, _, diag, why, meta = solve_t(50000)           # open 0.05s
    check('just-opened dead end stays UNKNOWN (key may be undetected)',
          P['0,2'] is None, repr((P['0,2'], why['0,2'])))
    P, _, diag, why, meta = solve_t(150000)          # open 0.15s
    check('dead end open >=0.1s goes bonus (absence now trusted)',
          P['0,2'] == 'bonus', repr(P['0,2']))
    check('reason still names the dead-end rule',
          why['0,2'] is not None and 'holds no key' in why['0,2'], repr(why['0,2']))

    # ---- frontier quiet gate. Both dead floors died of frontier proofs fired
    # inside the minimap-vs-proximity gap (room + locked door appear instantly,
    # the key inside only when approached). The rule may only run after 1s of
    # 0.1s stillness: no new room/door/key/bag change (ev.now - ev.last_change).
    print('\nsolve_parity: frontier waits for a quiet second')
    # Base needs TWO unresolved children or elimination (base is keyless and
    # trusted) forces the single child crit before the frontier rule is ever
    # consulted -- the same fixture trap as the opened_at test above. The
    # locked door (key never seen) is excluded from the frontier, so the plain
    # unopened room is the sole member.
    rmq = cells(lua, {(1, 1): ['4WAY', 'ICON_BASE'],
                      (1, 0): ['UNOPENED_SOUTH_TEMPLATE'],
                      (2, 1): ['UNOPENED_WEST_TEMPLATE', 'blue_shield']})
    def solve_q(quiet_us):
        return g.solve_x(rmq, lua.table_from(
            {'facts': lua.table_from({}), 'now': 5000000,
             'last_change': 5000000 - quiet_us}))
    P, _, diag, why, meta = solve_q(50000)           # world moved 0.05s ago
    check('disturbed world: frontier does NOT fire', P['1,0'] is None,
          repr((P['1,0'], why['1,0'])))
    P, _, diag, why, meta = solve_q(150000)          # still for 0.15s
    check('quiet world: sole openable room proven crit',
          P['1,0'] == 'crit' and why['1,0'] is not None and 'frontier' in why['1,0'],
          repr(why['1,0']))

    # ---- FATAL: crit terminus holding no key. A crit branch exists to reach
    # the boss or to fetch a key; an opened, childless, keyless room marked
    # crit proves an upstream proof false (live 2026-07-17: a frontier mint
    # chained 5,1->5,0->4,0 crit into an empty dead end -- bonus-UP could not
    # object because it only touches unmarked cells, and the only tell was the
    # crit count creeping past the structural bound). Same absence-evidence
    # gate as bonus-UP: a just-opened room may simply not be scanned yet.
    print('\nsolve_parity: crit terminus holding no key is fatal')
    rmd = cells(lua, {(1, 1): ['4WAY', 'ICON_BASE'],
                      (1, 0): ['DE_SOUTH'],
                      (2, 1): ['UNOPENED_WEST_TEMPLATE'],
                      (0, 1): ['UNOPENED_EAST_TEMPLATE']})
    def solve_d(opened_us_ago, with_key):
        ev = {'facts': lua.table_from(
                {'1,0': lua.table_from({'val': 'crit',
                                        'reason': 'seeded: false frontier mint (test)'})}),
              'now': 5000000,
              'opened_at': lua.table_from({'1,1': 0,
                                           '1,0': 5000000 - opened_us_ago})}
        if with_key:
            ev['keys'] = lua.table_from(
                {'blue_shield': lua.table_from({'found': '1,0'})})
        return g.solve_x(rmd, lua.table_from(ev))
    P, _, diag, why, meta = solve_d(150000, False)
    check('opened keyless crit dead end -> FATAL',
          meta['fatal'] is not None and meta['fatal']['cell'] == '1,0',
          repr(meta['fatal'] and meta['fatal']['text']))
    P, _, diag, why, meta = solve_d(150000, False)
    check('fatal text names the rule',
          meta['fatal'] is not None and 'crit terminus holds no key' in meta['fatal']['text'],
          repr(meta['fatal'] and meta['fatal']['text']))
    P, _, diag, why, meta = solve_d(50000, False)
    check('just-opened: keylessness not yet trusted -> no fatal',
          meta['fatal'] is None, repr(meta['fatal'] and meta['fatal']['text']))
    P, _, diag, why, meta = solve_d(150000, True)
    check('key found in the room: legit terminus -> no fatal',
          meta['fatal'] is None, repr(meta['fatal'] and meta['fatal']['text']))

    # ---- Boss found + SOLO: a key whose lock was never observed is a bonus
    # key. Boss on the map means the whole crit tree is already open, so every
    # crit door has been opened -- and solo, we watched each of them while it
    # was still locked, because nobody else can open a door. A key with no lock
    # ever seen therefore opens a door in unexplored space, which is off the
    # crit tree. Without this, one unlocated key halts bonus-UP and strands its
    # whole branch (live 2026-07-25: yellow_triangle at 2,3 froze the
    # 2,3->2,4->2,5 column long after the boss was found). Group floors must NOT
    # get the rule: a teammate can open a key door before we ever see it locked,
    # so there lock=nil means "we missed it", not "there is none".
    print('\nsolve_parity: unobserved lock is a bonus key (solo + boss only)')
    # 2,0 is an unopened frontier room so the crit path always has somewhere
    # else to continue. Without it the no-boss control is unfair: elimination
    # correctly forces 0,1 -> 0,2 crit as the only branch left, which is the
    # engine being right rather than the rule being withheld.
    def solve_k(solo, boss=True):
        rm = cells(lua, {(0, 0): ['2WAY_ES', 'ICON_BASE'],
                         (1, 0): ['2WAY_EW'] + (['ICON_BOSS'] if boss else []),
                         (2, 0): ['UNOPENED_WEST_TEMPLATE'],
                         (0, 1): ['2WAY_NS'],
                         (0, 2): ['DE_NORTH']})
        return g.solve_x(rm, lua.table_from(
            {'facts': lua.table_from({}), 'now': 5000000, 'solo': solo,
             'opened_at': lua.table_from({'0,0': 0, '1,0': 0,
                                          '0,1': 0, '0,2': 0}),
             'keys': lua.table_from(
                 {'yellow_triangle': lua.table_from({'found': '0,2'})})}))
    P, _, diag, why, meta = solve_k(True)
    check('solo + boss: unlocated key no longer halts bonus-UP',
          P['0,2'] == 'bonus', repr((P['0,2'], why['0,2'])))
    check('and the branch above it cascades bonus',
          P['0,1'] == 'bonus', repr((P['0,1'], why['0,1'])))
    P, _, diag, why, meta = solve_k(False)
    check('group floor: rule withheld, branch stays unknown',
          P['0,2'] is None and P['0,1'] is None,
          repr((P['0,2'], P['0,1'], why['0,2'])))
    P, _, diag, why, meta = solve_k(True, boss=False)
    check('boss not yet found: rule withheld',
          P['0,2'] is None, repr((P['0,2'], why['0,2'])))

    # The gate is only as good as the marker catalog behind it. PLAYER_* comes
    # from the minimap IMAGE catalog, not the 3D icon catalog, so a party slot
    # with no signature makes a group floor look empty -- ev.solo goes true and
    # the rule above fires on a floor where it is unsound. All five slots must
    # be in the SHIPPED seed, not just in whatever a given config accumulated.
    sigs = set()
    for L in io.open(os.path.join(HERE, os.pardir, 'data', 'img_signatures.txt'),
                     encoding='utf-8'):
        nm = L.split('|')[0]
        if nm.startswith('PLAYER_'):
            sigs.add(nm)
    want = {'PLAYER_RED', 'PLAYER_TWO', 'PLAYER_THREE', 'PLAYER_FOUR',
            'PLAYER_FIVE'}
    check('all 5 party-slot markers in the shipped signature seed',
          want <= sigs, 'missing: ' + ', '.join(sorted(want - sigs)))
    # Absence of other markers only means "solo" if classification demonstrably
    # works, which seeing our own marker proves.
    check('ev.solo requires our own marker to have been classified',
          'ev.solo = S.player_seen and not S.group_seen' in src)

    # ---- FATAL: accumulated crit marks above the 23-room ceiling. Crit facts
    # only accumulate toward the true count, so crossing the ceiling at ANY
    # moment proves at least one crit proof false; 23 is the largest tree any
    # floor size allows, so the bound holds floor-wide. Fixture is a legal
    # TREE (snake path -- floors are acyclic) with an unopened continuation so
    # the last crit room is not a terminus and only the count rule can fire.
    print('\nsolve_parity: crit count above the 23-room ceiling is fatal')
    def solve_n(n):
        # Snake path with EXACT corner templates: sloppy 4WAY turns make two
        # turn cells in adjacent rows accidentally adjacent, which forms a
        # CYCLE -- an impossible floor (BFS then re-parents a row and orphans
        # a cell, which trips the dead-end fatal instead of the count fatal).
        path = []
        for gz in range(4):
            row = [(gx, gz) for gx in range(8)]
            if gz % 2 == 1:
                row.reverse()
            path.extend(row)
        path = path[:n]
        lx, lz = path[-1]
        tail = (lx + 1, lz) if lz % 2 == 0 else (lx - 1, lz)
        seq = path + [tail]
        DOOR = {frozenset('ew'): '2WAY_EW', frozenset('ns'): '2WAY_NS',
                frozenset('ne'): '2WAY_NE', frozenset('es'): '2WAY_ES',
                frozenset('sw'): '2WAY_SW', frozenset('nw'): '2WAY_NW',
                frozenset('e'): 'DE_EAST', frozenset('w'): 'DE_WEST'}
        def d(a, b):
            return {(1, 0): 'e', (-1, 0): 'w', (0, 1): 's', (0, -1): 'n'}[
                (b[0] - a[0], b[1] - a[1])]
        spec = {}
        for i, c in enumerate(path):
            doors = set()
            if i > 0:
                doors.add(d(c, seq[i - 1]))
            doors.add(d(c, seq[i + 1]))
            spec[c] = [DOOR[frozenset(doors)]]
        spec[path[0]] = spec[path[0]] + ['ICON_BASE']
        spec[tail] = ['UNOPENED_%s_TEMPLATE'
                      % {'e': 'WEST', 'w': 'EAST'}[d(path[-1], tail)]]
        facts = {('%d,%d' % c): lua.table_from({'val': 'crit',
                                                'reason': 'seeded (test)'})
                 for c in path}
        # opened_at empty (keylessness untrusted -> dead-end rule inert) and a
        # fresh last_change (frontier gated) isolate the COUNT rule; without
        # the gate the frontier marks the unopened tail crit and inflates n+1.
        return g.solve_x(cells(lua, spec),
                         lua.table_from({'facts': lua.table_from(facts),
                                         'now': 5000000,
                                         'opened_at': lua.table_from({}),
                                         'last_change': 5000000 - 50000}))
    P, _, diag, why, meta = solve_n(26)
    check('26 crit rooms -> FATAL (floor-wide)',
          meta['fatal'] is not None and meta['fatal']['cell'] == '(floor)',
          repr(meta['fatal'] and meta['fatal']['text']))
    P, _, diag, why, meta = solve_n(23)
    check('23 crit rooms exactly -> no fatal (at the bound)',
          meta['fatal'] is None, repr(meta['fatal'] and meta['fatal']['text']))

    # ---- resources.lua v2 identity matcher (overhaul phase 3) --------------
    # Exact prints with wide margins, NO cross-variant generalisation: the
    # 2026-07-19 distance matrix showed same-name variants (41-346) fully
    # overlap cross-tier neighbours (78-220), while live re-sights of a
    # cataloged mesh land at d=0-2. Fixture lines are REAL prints from that
    # session's catalog.
    print('\nresources.lua v2: identity matcher (exact prints, wide margins)')
    lua.execute('package.preload["bolt"] = function() return {'
                ' saveconfig = function() end,'
                ' loadconfig = function() return nil end } end')
    lua.execute('res_mod = require("resources")({'
                ' SET = { load_or_seed = function() return "" end,'
                '         get = function() return nil end,'
                '         dev_save = function() end, DEV = false,'
                '         sync = {}, clamp = function(a, b) return a, b end },'
                ' S = { resource_sightings = {} },'
                ' world_room_to_grid = function() return nil end,'
                ' is_room_body = function() return false end,'
                ' cell_at = function() return nil end,'
                ' unix_now = function() return 0 end })')
    v2 = g.res_mod.v2
    TREE = 'V2|T3_TREE|3|2559|160,1024,512|56,59,57|22,0,2,0,0,0,0,0|6,5,9,4|120'
    TREE10 = 'V2|T10_TREE_2|10|2709|152,944,428|63,45,52|24,0,0,0,0,0,0,0|8,5,1,10|126'
    ORE = 'V2|T10_ORE_2|10|2043|476,344,432|93,65,61|17,0,0,0,4,0,0,3|15,4,0,5|190'
    f = v2.parse(TREE)
    check('parse -> serialize -> parse is lossless (dist 0)',
          f is not None and v2.dist(f, v2.parse(v2.serialize('T3_TREE', 3, f))) == 0)
    for line in (TREE, TREE10, ORE):
        lua.globals().tmp_e = v2.parse(line)
        lua.execute('table.insert(res_mod.v2.entries(), tmp_e)')
    hit, d = v2.accept(f)
    check('self re-sight accepts its own print, unambiguous, d=0',
          hit is not None and hit.name == 'T3_TREE' and not hit.ambig and d == 0,
          repr((hit and hit.name, hit and hit.ambig, d)))
    # A nearby SAME-BASE variant print must not create ambiguity: T3_TREE_2
    # is the same resource for every consumer (verdicts work on the base).
    twin = v2.parse(TREE)
    twin['name'] = 'T3_TREE_2'
    twin['mrgb'][1] = twin['mrgb'][1] + 2   # d = 3 from the original
    lua.globals().tmp_e = twin
    lua.execute('table.insert(res_mod.v2.entries(), tmp_e)')
    hit, d = v2.accept(f)
    check('same-base twin inside the rival floor -> still unambiguous',
          hit is not None and not hit.ambig, repr((hit and hit.name, hit and hit.ambig, d)))
    # A DIFFERENT-base print inside the rival floor demotes to ambiguous
    # (display-only, never binds).
    fake = v2.parse(TREE)
    fake['name'] = 'FAKE_ORE'
    fake['mrgb'][1] = fake['mrgb'][1] + 4   # d = 6: accept-band, rival-floor
    lua.globals().tmp_e = fake
    lua.execute('table.insert(res_mod.v2.entries(), tmp_e)')
    hit, d = v2.accept(f)
    check('other-base print inside the rival floor -> ambig (no bind)',
          hit is not None and bool(hit.ambig), repr((hit and hit.name, hit and hit.ambig, d)))
    # Far features accept nothing: no nearest-neighbour guessing.
    far = v2.parse(TREE)
    far['n'] = 5000
    hit, d = v2.accept(far)
    check('far mesh -> rejected outright (no nearest-neighbour guess)',
          hit is None, repr((hit and hit.name, d)))

    # ---- unix_now -----------------------------------------------------------
    # bolt.time() is MONOTONIC microseconds (uptime) and cannot name a dump.
    # bolt.datetime() is the only wall clock and is already UTC, so days-from-
    # civil converts exactly. Verified against Python's calendar.timegm.
    print('\nunix_now (from bolt.datetime, UTC)')
    import calendar
    import datetime
    for y, mo, d, h, mi, s in [(1970, 1, 1, 0, 0, 0), (2000, 3, 1, 12, 0, 0),
                               (2024, 2, 29, 23, 59, 59), (2026, 7, 14, 15, 38, 0),
                               (2038, 1, 19, 3, 14, 7)]:
        lua.execute('bolt = { datetime = function() return %d,%d,%d,%d,%d,%d end }'
                    % (y, mo, d, h, mi, s))
        ref = calendar.timegm(datetime.datetime(y, mo, d, h, mi, s).timetuple())
        got = g.unix_now()
        check('%04d-%02d-%02d %02d:%02d:%02d' % (y, mo, d, h, mi, s), got == ref,
              'got %s want %s' % (got, ref))

    # ---- static checks ------------------------------------------------------
    # A call to a main-chunk local declared LOWER in the file silently compiles
    # to a global read -> nil at runtime. Valid syntax, so parsing never catches
    # it. This shipped once (persist_icon_data), swallowed by a pcall.
    print('\nstatic checks')
    lines = src.split('\n')
    decl = {}
    for i, ln in enumerate(lines):
        m = (re.match(r'^local\s+function\s+([A-Za-z_]\w*)', ln)
             or re.match(r'^local\s+([A-Za-z_]\w*)\s*$', ln)
             or re.match(r'^local\s+([A-Za-z_]\w*)\s*=', ln))
        if m and m.group(1) not in decl:
            decl[m.group(1)] = i
    bad = [(n, i + 1, d + 1) for n, d in decl.items()
           for i, ln in enumerate(lines[:d])
           if re.search(r'(?<![\w.:])%s\s*\(' % re.escape(n), ln)
           and not ln.strip().startswith('--')]
    check('no use-before-declaration of main-chunk locals', not bad, str(bad))

    # Locals declared inside ';(function () ... end)()' module blocks are
    # FUNCTION-scoped, not main-chunk, even though the module style keeps them
    # at column 0 -- strip those spans before counting, or the check overcounts
    # (222 raw vs 169 real when the HUD/line-draw/examine modules landed).
    outside, depth = [], 0
    for _line in src.split('\n'):
        if depth == 0 and re.match(r'^;\(function \(\)', _line):
            depth = 1
        elif depth == 1 and re.match(r'^end\)\(\)', _line):
            depth = 0
        elif depth == 0:
            outside.append(_line)
    n_locals = len(re.findall(r'(?m)^local\s+(?:function\s+)?([A-Za-z_]\w*)',
                              '\n'.join(outside)))
    check('main-chunk locals under Lua 5.1 cap of 200', n_locals < 200, '%d' % n_locals)

    html = io.open(os.path.join(HERE, os.pardir, 'rooms.html'), encoding='utf-8').read()
    check('no stray gy in main.lua (renamed to gz)', not re.search(r'\bgy\b', src))
    check('no stray gy in rooms.html', not re.search(r'\bgy\b', html))
    check('json keys agree across the lua/html boundary',
          set(re.findall(r'"(g[xz])":', src)) == set(re.findall(r'r\.(g[xz])\b', html)))
    # saveconfig cannot create directories and bolt exposes no mkdir, so a
    # subdir write silently fails on any install that lacks the folder.
    check('death dumps are flat files, not a subdir',
          not re.search(r'saveconfig\(\s*\(?"[^"]*/', src))

    # ---- ground-key matcher: colour must discriminate same-shape keys --------
    # The old metric scored colour as the MIN per-vertex distance. Same-shape
    # keys (all 8 corners, etc.) share identical positions AND neutral outline
    # verts, so the min always found a matching vert -> colour term ~0 for every
    # colour, the entries tied on position, and the winner was decided by loop
    # order. green_corner and others systematically lost and never bound
    # (found=nil across many floors, including boss keys). Summing colour over
    # the verts makes the coloured shape-verts discriminate. This replicates the
    # shipped metric against the bundled catalog; constants read from main.lua so
    # the test tracks the code.
    print('\nground-key matcher (colour discriminates same-shape keys)')
    check('key matchers sum colour, not min (regression guard)',
          'pos_sum + 2 * col_sum' in src and '2 * 5 * col_min' not in src)
    m_cut = re.search(r'local IK_CUTOFF\s*=\s*(\d+)', src)
    m_mar = re.search(r'local IK_MARGIN\s*=\s*(\d+)', src)
    check('IK_CUTOFF and IK_MARGIN present', bool(m_cut and m_mar))
    if m_cut and m_mar:
        CUT, MAR = int(m_cut.group(1)), int(m_mar.group(1))
        keys, byn = {}, {}
        cat = os.path.join(HERE, os.pardir, 'data', 'icons.txt')
        for line in io.open(cat, encoding='utf-8'):
            p = line.strip().split('|')
            if len(p) >= 5 and p[1] == 'icon' and p[0].islower() and '_' in p[0]:
                try:
                    vs = sorted((tuple(int(x) for x in c.split(',')) for c in p[4:]),
                                key=lambda v: v[2])   # by y, like verts_sorted
                except ValueError:
                    continue
                if len(vs) == 5:
                    keys[p[0]] = (p[3], vs)
                    byn.setdefault(p[3], []).append(p[0])

        def kscore(a, b):   # main.lua: pos L1 + 2 * (sum of per-vertex colour L1)
            pos = sum(abs(a[i][1]-b[i][1]) + abs(a[i][2]-b[i][2]) + abs(a[i][3]-b[i][3])
                      for i in range(5))
            col = sum(abs(a[i][4]-b[i][4]) + abs(a[i][5]-b[i][5]) + abs(a[i][6]-b[i][6])
                      for i in range(5))
            return pos + 2 * col

        def resolve(name):
            n, vs = keys[name]
            ranked = sorted((kscore(vs, keys[o][1]), o) for o in byn[n])
            best_s, best_n = ranked[0]
            rival_s = next(s for s, o in ranked if o != best_n)
            return best_n, best_s, rival_s

        bad, tightest = [], (1e9, '')
        for name in keys:
            best_n, best_s, rival_s = resolve(name)
            if best_n != name or best_s > CUT or (rival_s - best_s) < MAR:
                bad.append(name)
            if rival_s - best_s < tightest[0]:
                tightest = (rival_s - best_s, name)
        check('%d keys each win their bucket (margin>=%d, within cutoff %d)'
              % (len(keys), MAR, CUT), not bad, 'failing: ' + ', '.join(bad[:8]))
        check('tightest margin still clears the requirement',
              tightest[0] >= MAR, '%s margin %.0f < %d' % (tightest[1], tightest[0], MAR))
        # green_corner: the recurring found=nil boss key that motivated the fix.
        if 'green_corner' in keys:
            bn, bs, rs = resolve('green_corner')
            check('green_corner resolves to itself (was the found=nil boss key)',
                  bn == 'green_corner' and (rs - bs) >= MAR,
                  'best=%s margin=%.0f' % (bn, rs - bs))

    # ---- resource classifier: the tolerant v1 fallback tier ------------------
    # v2 recognises only what has a V2 print, so v1-only catalog names need a
    # tolerant tier or they go dark (exact-key or nothing). The matcher that
    # used to fill that role was retired for binding foreign meshes -- it ran an
    # n+-5 window with cutoff 3000, while the closest pair of DIFFERENT base
    # names in the catalog scores ~1492. This runs the SHIPPED v1_fallback over
    # the bundled catalog and asserts the cutoff still sits well under that
    # collision floor, so nobody can quietly loosen it back into the failure.
    print('\nresource matcher (tolerant v1 fallback below v2)')
    rsrc = io.open(os.path.join(os.path.dirname(MAIN), 'resources.lua'),
                   encoding='utf-8').read()
    lua.compile(rsrc)                                  # parse check resources.lua
    m_min = re.search(r'local MIN_N\s*=\s*(\d+)', rsrc)
    m_bind = re.search(r'local BIND\s*=\s*(\d+)', rsrc)
    m_show = re.search(r'local SHOW\s*=\s*(\d+)', rsrc)
    check('v1 fallback constants present', bool(m_min and m_bind and m_show))
    if m_min and m_bind and m_show:
        MIN_N, BIND, SHOW = (int(m.group(1)) for m in (m_min, m_bind, m_show))
        lua.execute(extract(rsrc, 'local function parse_catalog_verts'))
        lua.execute(extract(rsrc, 'local function v1_fallback'))
        g.RES_TXT = io.open(os.path.join(HERE, os.pardir, 'data', 'resources.txt'),
                            encoding='utf-8').read()
        lua.execute('''
resources_by_n = {}
CAT = {}
for line in RES_TXT:gmatch("[^\\r\\n]+") do
  if not line:match("^%s*#") and not line:match("^%s*$")
     and not line:match("^V2|") then
    local name, tier, rest = line:match("^%s*([%w_]+)|(%d+)|(.+)$")
    if name and rest then
      local n, verts = parse_catalog_verts(rest)
      if n and verts and #verts == 5 then
        local vs = { verts[1], verts[2], verts[3], verts[4], verts[5] }
        table.sort(vs, function (a, b) return a.y < b.y end)
        resources_by_n[n] = resources_by_n[n] or {}
        table.insert(resources_by_n[n],
          { name = name, tier = tonumber(tier), n = n,
            verts = verts, verts_sorted = vs })
        table.insert(CAT, { name = name, n = n, key = rest })
      end
    end
  end
end
function fb(key, n)            -- name only: lupa turns multi-returns into tuples
  local e = v1_fallback(key, n)
  return e and e.name or nil
end
''')
        cat = [(g.CAT[i].name, g.CAT[i].n, g.CAT[i].key)
               for i in range(1, len(g.CAT) + 1)]
        check('%d catalog prints loaded into the shipped scorer' % len(cat),
              len(cat) > 100)

        def base(nm):
            i = nm.rfind('_')
            return nm[:i] if i > 0 and nm[i+1:].isdigit() else nm

        # Every print, fed back as a live fingerprint, must resolve to its own
        # base name -- variant-vs-base confusion is harmless and expected.
        wrong = []
        for name, n, key in cat:
            if n < MIN_N:
                continue
            got = g.fb(key, n)
            if got is None or base(got) != base(name):
                wrong.append('%s->%s' % (name, got))
        check('every print resolves to its own base name', not wrong,
              'failing: ' + ', '.join(wrong[:6]))

        # THE guard: nearest cross-base pair at the same vertex count. The
        # retired matcher's cutoff (3000) sat above this; the current one must
        # sit well below it.
        def kscore(a, b):
            pos = sum(abs(a[i][1]-b[i][1]) + abs(a[i][2]-b[i][2]) + abs(a[i][3]-b[i][3])
                      for i in range(5))
            col = sum(abs(a[i][4]-b[i][4]) + abs(a[i][5]-b[i][5]) + abs(a[i][6]-b[i][6])
                      for i in range(5))
            return pos + 2 * col

        def verts(key):
            return sorted((tuple(int(x) for x in c.split(','))
                           for c in key.split('|')[1:]), key=lambda v: v[2])

        floor_all, floor_nodino, pair = 1e9, 1e9, ''
        for i, (na, nna, ka) in enumerate(cat):
            if nna < MIN_N:
                continue
            for nb, nnb, kb in cat[i+1:]:
                if nnb != nna or base(nb) == base(na):
                    continue
                s = kscore(verts(ka), verts(kb))
                if s < floor_all:
                    floor_all, pair = s, '%s vs %s (n=%d)' % (na, nb, nna)
                if '_DINO' not in na and '_DINO' not in nb:
                    floor_nodino = min(floor_nodino, s)
        check('cross-base collision floor %d > SHOW cutoff %d' % (floor_all, SHOW),
              floor_all > SHOW, 'closest: ' + pair)
        check('non-dino floor %d clears SHOW by >=4x (retired matcher used 3000)'
              % floor_nodino, floor_nodino >= 4 * SHOW)
        check('BIND (%d) <= SHOW (%d): binding band is the tighter one'
              % (BIND, SHOW), BIND <= SHOW)

        # Sub-MIN_N entries must not match tolerantly. FISHING_SPOT is 9 verts
        # of flat grey; 9-vert quads are everywhere and carry no signal.
        tiny = [(nm, n, k) for nm, n, k in cat if n < MIN_N]
        check('%d sub-%d-vert entries excluded from tolerant matching'
              % (len(tiny), MIN_N),
              all(g.fb(k, n) is None for nm, n, k in tiny),
              'matched: ' + ', '.join(nm for nm, n, k in tiny))

    print('\n%s  (%d failed)' % ('ALL GREEN' if not FAILS else 'FAILURES: ' + ', '.join(FAILS),
                                 len(FAILS)))
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
