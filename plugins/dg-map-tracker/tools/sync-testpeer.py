# Party-sync test peer: a fake party member for solo verification against a
# single running game client (through tools/sync-relay.py). Two uses:
#
#   LISTEN (default) -- print everything the real client emits to the room.
#     Verifies the plugin's EMIT side: walk past a resource / examine a door
#     and watch the event arrive here.
#       python tools/sync-testpeer.py --room dgparty-dev
#
#   INJECT -- send fake evidence into the room so the real client merges it.
#     Verifies the MERGE side: inject a resource and watch the client's map
#     mark that room. Events must carry the client's current floor id; this
#     tool auto-adopts it from the first presence frame it hears (or pass
#     --floor wrx:wrz, read from the client's sync_diag_<name>.txt).
#       python tools/sync-testpeer.py --emit resource:3,4:T4_TREE
#       python tools/sync-testpeer.py --emit key:silver_diamond:2,5
#       python tools/sync-testpeer.py --emit skill:2,2:113:herblore:crit
#
# The room code is hashed the same way the plugin does (djb2), so --room
# takes the plaintext sync_room, not the digest.
import argparse
import asyncio
import json

import websockets


def room_key(code):
    h = 5381
    for ch in code.encode():
        h = (h * 33 + ch) % 4294967296
    return "r%08x" % h


def build_event(spec, floor):
    parts = spec.split(":")
    kind = parts[0]
    if kind == "resource":
        return {"t": "resource", "c": parts[1], "r": parts[2], "f": floor, "n": "testpeer"}
    if kind == "key":
        return {"t": "key_found", "k": parts[1], "c": parts[2], "f": floor, "n": "testpeer"}
    if kind == "skill":
        return {"t": "skill_door", "c": parts[1], "v": int(parts[2]),
                "s": parts[3], "p": parts[4], "f": floor, "n": "testpeer"}
    raise SystemExit("unknown --emit kind: %s" % kind)


async def run(args):
    room = room_key(args.room)
    async with websockets.connect(args.url) as ws:
        await ws.send(json.dumps({"t": "join", "room": room}))
        floor = args.floor
        emitted = False
        print("joined room %s (%s) as testpeer" % (args.room, room))
        while True:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=None if not args.emit else 8)
            except asyncio.TimeoutError:
                print("no floor id heard in 8s -- pass --floor wrx:wrz (from sync_diag)")
                return
            try:
                ev = json.loads(raw)
            except Exception:
                continue
            t = ev.get("t")
            if t in ("joined", "peer_join", "peer_leave"):
                print("[%s] peers-ish=%s" % (t, ev.get("peers", "")))
                continue
            print("<- %s" % json.dumps(ev))
            # Adopt the client's floor id from any floor-tagged frame.
            if not floor and ev.get("f"):
                floor = ev["f"]
                print("   (adopted floor id %s)" % floor)
            if args.emit and floor and not emitted:
                event = build_event(args.emit, floor)
                await ws.send(json.dumps(event))
                emitted = True
                print("-> injected %s" % json.dumps(event))
                if args.once:
                    await asyncio.sleep(0.5)
                    return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:8765")
    ap.add_argument("--room", default="dgparty-dev")
    ap.add_argument("--emit", help="resource:CELL:NAME | key:KEY:CELL | skill:CELL:LVL:SKILL:bonus|crit")
    ap.add_argument("--floor", help="floor id wrx:wrz (else auto-adopted from a heard frame)")
    ap.add_argument("--once", action="store_true", help="exit after injecting once")
    args = ap.parse_args()
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
