#!/usr/bin/env python3
"""Fake party member for testing dg-map-tracker sync without a second player.

Run:  python tools/sync-testpeer.py [room_code] [ws_url]
Defaults: room_code=dgparty-dev, url=ws://127.0.0.1:8765

Joins the same hashed room the plugin derives (djb2, matching main.lua's
room_key), prints every frame received, and sends a presence heartbeat plus
one test event so the plugin's sync_diag.txt shows inbound traffic.

With --inject: waits for the plugin's presence (to learn its floor id and
cell), then sends ONE key_found event for gold_wedge at the plugin's own
cell -- verifies the whole merge path solo (expect the keys panel to show
gold_wedge found at your cell, and "merged key_found" in sync_diag.txt).
"""

import asyncio
import json
import sys

import websockets


def room_key(code):
    h = 5381
    for ch in code.encode():
        h = (h * 33 + ch) % 4294967296
    return 'r%08x' % h


async def main(code, url, inject):
    async with websockets.connect(url) as ws:
        await ws.send(json.dumps({'t': 'join', 'room': room_key(code)}))
        print('joined room %s (%s)%s' % (room_key(code), code,
                                         '  [inject mode]' if inject else ''))
        injected = False

        async def beat():
            n = 0
            while True:
                await ws.send(json.dumps({'t': 'presence', 'n': 'testpeer'}))
                if n == 1 and not inject:
                    await ws.send(json.dumps(
                        {'t': 'test', 'n': 'testpeer', 'msg': 'hello from testpeer'}))
                    print('>> sent test event')
                n += 1
                await asyncio.sleep(5)

        task = asyncio.ensure_future(beat())
        try:
            async for raw in ws:
                print('<<', raw)
                if inject and not injected:
                    try:
                        ev = json.loads(raw)
                    except Exception:
                        continue
                    if (ev.get('t') == 'presence' and ev.get('n') != 'testpeer'
                            and ev.get('f') and ev.get('c')):
                        injected = True
                        out = {'t': 'key_found', 'k': 'gold_wedge',
                               'c': ev['c'], 'f': ev['f'], 'n': 'testpeer'}
                        await ws.send(json.dumps(out))
                        print('>> injected', json.dumps(out))
        finally:
            task.cancel()


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--inject']
    inj = '--inject' in sys.argv[1:]
    code = args[0] if len(args) > 0 else 'dgparty-dev'
    url = args[1] if len(args) > 1 else 'ws://127.0.0.1:8765'
    asyncio.run(main(code, url, inj))
