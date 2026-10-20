# mod.io listing: DG Utils

Paste each block into the matching field on mod.io as plain text (mod.io renders neither markdown nor HTML). Not shipped in the zip.

## Plugin name

DG Utils

## Summary

A shared library for Dungeoneering plugins. Reads the floor map into a room tree and exposes party member positions, held keys, gatestone positions and the type of each room (base, boss, puzzle). No UI of its own.

## Description

DG Utils does nothing visible by itself. It is a dependency for other Dungeoneering plugins, so they can share one tested reader of the floor instead of each scraping the map interface.

HOW TO USE

1. Install DG Utils from the Plugin Hub. Plugins that need it list it as a dependency.
2. Plugin authors: add DG Utils to the required dependencies in the plugin manifest and call the functions below through the variable named there.

API

InDungeon()
    True while the player is on a Dungeoneering floor.

GetParty()
    { { slot = 1, name = "Name", cell = 16 }, ... }
    cell is the map cell the member's pip is in, or nil outside a dungeon.

GetFloorNumber(), GetTheme(), GetComplexity()
    The party's current floor (1 to 60), its theme ("Frozen", "Abandoned 1", "Furnished", "Abandoned 2", "Occult", "Warped"), and complexity (1 low, 2 high).

GetKeys()
    The key numbers the player holds, e.g. { 12, 15 }. Same numbers as room.blocker.value.
    KeyName[number] gives the display name, e.g. KeyName[41] = "Purple triangle".

GetGatestones()
    { GATE_GREEN = cell, GATE_RED = cell, GATE_GROUP = cell }, nil for a stone that is not placed.

GetRoomTemplateAt(cell)
    { column, row } of the template room the cell was built from.

GetRoomTypeAt(cell)
    "BASE", "BOSS", "NORMAL" or a puzzle name such as "PUZZLE_SLIDEY_TILES". Only trustworthy for cells in GetMap().rooms.

GetMap()
    The floor as a tree of rooms rooted at the base:
    { seed, version, root, boss, rooms = { [cell] = room } }
    room = { cell, col, row, opened, openedAt, exits, blocker = { type, value }, parent, north, east, south, west }

    cell is row * 8 + col, counted from the south-west corner of the map.
    north, east, south, west link to the neighboring rooms (nil means no door).
    blocker.type is "none", "key" or "skill"; value is the key number or the SkillType.
    openedAt is the floor time in seconds when the room was opened.

    The table is shared and live: callers keep a reference and read version, which increments on any change. It must not be modified. Rooms that were already open when the plugin started reading have openedAt and blocker of nil.

NOTES

Everything is read from the game's own map interface and variables. Nothing is sent anywhere.
No permissions required.

CONTACT

Email: Skerf73@gmail.com or @Skerf on Discord
