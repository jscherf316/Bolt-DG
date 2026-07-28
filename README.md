# Bolt-DG

Bolt-launcher plugin for RuneScape 3 Dungeoneering.

One plugin: **[dg-map-tracker](plugins/dg-map-tracker/)** -- a live DG floor
map (room graph with crit/bonus parity), key tracking, resource highlighting,
line draw, and a built-in settings panel (the CTRL button).

## Setup

- Import `plugins/dg-map-tracker/` via Bolt's plugin manager.
- On first run the three capture zones appear as labeled coloured boxes:
  MAP (red), KEYBAG (blue), WORLD MAP (green).
- Drag each box over the matching game element.
- Hide the boxes from the settings panel ("Show capture zones") when done.

## Development

- Canonical / seed data lives in `data/` -- read via
  `bolt.loadfile("data/<key>")` or seeded into user config on first run.
- All runtime settings consolidate into a single `settings.json` in the
  plugin's config dir.
- The settings panel is self-contained (`settings_panel.lua` + its two HTML
  pages); rows are declared in the registry table at the top of that module.
- Diagnostics are always on; the plugin writes its state files into its
  config dir.

Plugin source lives at `plugins/dg-map-tracker/`. Bolt loads from
`%APPDATA%\bolt-launcher\data\plugins\` (see `config\plugins.json` for the
authoritative path) -- deploy by copying the plugin folder there, or use a
directory junction:
`mklink /J "%APPDATA%\bolt-launcher\data\plugins\dg-map-tracker" "<repo>\plugins\dg-map-tracker"`

Note: bolt records a plugin's install path at import time. If you switch from
a real directory to a junction, re-import from the bolt UI so it picks up the
new path.
