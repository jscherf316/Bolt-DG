# Bolt-DG

[Bolt-launcher](https://codeberg.org/Adamcake/Bolt) plugin for RuneScape 3 Dungeoneering.

## Features

- Automatic Guide Mode
- Key and door tracking
- Resource and ground key highlights
- Party Sync (unstable)
- Built in settings panel

## Setup

- In Bolt's plugin manager, install from URL:

  `https://raw.githubusercontent.com/jscherf316/Bolt-DG/main/meta.json`

- Drag the three capture zones for MAP, KEYBAG, and WORLD MAP over the
  in-game DG map, keybag, and world map icon respectively.
- Toggle capture zone display off from settings panel when done.
- Start a new dungeon and everything should be working.
- Render resolutions other than 100% are not supported.
- Interactable and loot drop highlights must be disabled.

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
