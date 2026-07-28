# DG Map Tracker

Bolt plugin for RuneScape 3 Dungeoneering. Watches the game's minimap
icons, tile geometry, and world position each frame and builds a live
room-graph of the current floor. Shows a compact map panel with room
parity (critical / bonus / unknown), key ownership, connecting
corridors, and skill-door tiers. A keys panel tracks every key spawn
seen on the floor and where its matching door is. In-world overlays
highlight resources, ground keys, door-adjacent tiles, and puzzle
ghosts, and a line-draw feature points at tracked keys.

Settings live in a built-in panel: the draggable CTRL button opens it.

## Capture zones

The plugin reads three screen regions, shown as draggable labeled
boxes when "Show capture zones" is on (default on for new installs):

- **MAP** (red) -- the DG map interface.
- **KEYBAG** (blue) -- the key inventory.
- **WORLD MAP** (green) -- the floor icon area.

Align each once; positions persist in config.

## What ships in `data/`

Canonical / seed data bundled with the plugin. On first run the plugin
seeds the user's config dir from these files; subsequent user
modifications live in config and are never overwritten by plugin
updates.

| File                  | Purpose                                              |
|-----------------------|------------------------------------------------------|
| `icons_data.txt`      | Mesh rasterization catalog for classified 3D icons   |
| `img_signatures.txt`  | 2D image signatures for room-body / door / passage icons |
| `mm_signatures.txt`   | Minimap signature name list (for classifier UX)      |
| `shape_rot.txt`       | Default per-shape camera calibration for icon render |
| `skill_doors.txt`     | Skill-door tier lookup (crit / bonus / unresolvable) |
| `resource_types.txt`  | Max resource tier per skill                          |
| `resources.txt`       | 3D resource fingerprint catalog (v1 + v2 prints)     |
| `guardian_doors.txt`, `ghosts.txt`, `dino_colors.txt` | Guardian-door / puzzle-ghost / dino-tier catalogs |
| `icons.txt`, `img_ignored.txt`, `resource_ignored.txt`, etc. | Starter curated lists |

## Configuration

Every runtime setting lives in one flat JSON file -- `settings.json` --
inside this plugin's config dir
(`%APPDATA%\bolt-launcher\config\plugins\<uuid>\`). Use the settings
panel rather than editing it by hand; it covers party sync, map size,
scan range, the capture-zone toggle, and per-panel visibility. Panel
positions and the capture-zone rectangles save themselves when dragged.

Runtime catalog data stays in its own files (`icons.txt`,
`img_signatures.txt`, `resources.txt`, `img_ignored.txt`, etc.) --
those are large / append-heavy and don't fit the flat-JSON shape.

## Diagnostics

Always on. The plugin writes state files into its config dir
(`draw_dbg.txt`, `floor_diag.txt`, `obs_diag.txt`, `parity_dump.txt`,
`rooms.txt`, queue snapshots, and per-floor death reports). These are
the first place to look when something silently stops tracking --
`draw_dbg.txt`'s `floor_gate:` / `gates:` / `anchor=` lines in
particular.

## Panels

- **Rooms panel** -- the floor grid. Tile colour = parity (tan crit,
  near-black bonus / unknown, yellow = crit with key held, red = floor
  dead); corridors drawn between connected rooms; door icons show the
  key or skill required.
- **Keys panel** -- every colour x shape key. Cell parity border,
  found / lock coordinates if seen, dim if unseen.
- **Line Draw panel** -- toggles the in-world line to tracked ground
  keys, colour / opacity / thickness, grid-aligned routing.
- **Image Tracker / Resources / Icons panels** -- cataloguing tools,
  hidden behind Show Dev Tools in the settings panel.
