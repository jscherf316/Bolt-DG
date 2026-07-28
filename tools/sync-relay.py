#!/usr/bin/env python3
"""Dev relay for dg-map-tracker party sync. Dumb stateless room fanout.

Run:  python tools/sync-relay.py [port]     (default 8765)

Protocol (JSON text frames):
  client -> relay, first frame:   {"t":"join","room":"<room key>"}
  relay  -> joiner:               {"t":"joined","peers":<count of others>}
  relay  -> others in room:       {"t":"peer_join"} / {"t":"peer_leave"}
  anything after join is fanned out VERBATIM to every other room member.

No storage, no replay: late-join state transfer is peer-to-peer by design
(existing members snapshot their evidence to newcomers). See SYNC_PLAN.md.
"""

import asyncio
import json
import sys

import websockets

ROOMS = {}   # room key -> set of websockets


async def tell(ws, obj):
    try:
        await ws.send(json.dumps(obj))
    except Exception:
        pass


async def handler(ws):
    room = None
    try:
        async for raw in ws:
            if room is None:
                try:
                    msg = json.loads(raw)
                except Exception:
                    continue
                if msg.get('t') == 'join' and isinstance(msg.get('room'), str) and msg['room']:
                    room = msg['room']
                    ROOMS.setdefault(room, set()).add(ws)
                    await tell(ws, {'t': 'joined', 'peers': len(ROOMS[room]) - 1})
                    for peer in list(ROOMS[room]):
                        if peer is not ws:
                            await tell(peer, {'t': 'peer_join'})
                continue
            for peer in list(ROOMS.get(room, ())):
                if peer is not ws:
                    try:
                        await peer.send(raw)
                    except Exception:
                        pass
    except websockets.ConnectionClosed:
        pass
    finally:
        if room and ws in ROOMS.get(room, set()):
            ROOMS[room].discard(ws)
            for peer in list(ROOMS[room]):
                await tell(peer, {'t': 'peer_leave'})
            if not ROOMS[room]:
                del ROOMS[room]


async def main(port):
    async with websockets.serve(handler, '0.0.0.0', port):
        print('sync relay listening on :%d' % port)
        await asyncio.Future()


if __name__ == '__main__':
    asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 8765))
