# Party-sync dev relay: a dumb, stateless WebSocket room-fanout. It stores
# nothing and never inspects event contents -- it just forwards each message
# to the other members of the sender's room. Matches the wire protocol the
# sidecar (sync.html) speaks:
#
#   client -> relay (first frame):  {"t":"join","room":"<room_key>"}
#   relay  -> joiner:               {"t":"joined","peers":<existing count>}
#   relay  -> existing members:     {"t":"peer_join"}       (on a new join)
#   relay  -> remaining members:    {"t":"peer_leave"}      (on a disconnect)
#   client -> relay (later frames): <event json>  -> forwarded verbatim to room
#
# For the same-machine two-account test both clients point sync_url at
# ws://127.0.0.1:8765 (the default) and share a room via sync_room. Run:
#
#   python tools/sync-relay.py            # localhost:8765
#   python tools/sync-relay.py 9000       # custom port
#
# Requires the `websockets` package (pip install websockets).
import asyncio
import json
import sys

import websockets

rooms = {}   # room_key -> set of connections


async def _send(ws, obj):
    try:
        await ws.send(json.dumps(obj))
    except Exception:
        pass


async def handler(ws):
    room = None
    try:
        async for raw in ws:
            msg = None
            try:
                msg = json.loads(raw)
            except Exception:
                pass
            # First frame is the join; everything after is fan-out traffic.
            if room is None and isinstance(msg, dict) and msg.get("t") == "join":
                room = str(msg.get("room", ""))
                members = rooms.setdefault(room, set())
                await _send(ws, {"t": "joined", "peers": len(members)})
                for m in list(members):
                    await _send(m, {"t": "peer_join"})
                members.add(ws)
                print("[join]  room=%s  size=%d" % (room, len(members)))
                continue
            if room is None:
                continue   # ignore anything before a valid join
            # Fan the raw frame out to everyone else in the room, untouched.
            peers = [m for m in rooms.get(room, ()) if m is not ws]
            for m in peers:
                try:
                    await m.send(raw)
                except Exception:
                    pass
            if isinstance(msg, dict):
                print("[msg]   room=%s  t=%-10s from=%-12s -> %d peer(s)"
                      % (room, msg.get("t", "?"), msg.get("n", "?"), len(peers)))
    finally:
        if room is not None:
            members = rooms.get(room, set())
            members.discard(ws)
            for m in list(members):
                await _send(m, {"t": "peer_leave"})
            if not members:
                rooms.pop(room, None)
            print("[leave] room=%s  size=%d" % (room, len(members)))


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    async with websockets.serve(handler, "127.0.0.1", port):
        print("sync relay listening on ws://127.0.0.1:%d  (Ctrl-C to stop)" % port)
        await asyncio.Future()   # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nrelay stopped")
