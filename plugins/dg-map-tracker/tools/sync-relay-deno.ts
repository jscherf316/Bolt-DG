// Party-sync relay for dg-map-tracker -- single file, for Deno Deploy.
//
// Deploy (no repo, no build):
//   1. https://dash.deno.com  ->  New Playground
//   2. Paste this whole file, click Save & Deploy
//   3. Copy the URL it gives you (https://<name>.deno.dev) and use the
//      wss:// form as the plugin's sync_url:  wss://<name>.deno.dev
//
// Run locally instead:  deno run --allow-net sync-relay-deno.ts   (ws://localhost:8000)
//
// Protocol -- identical to tools/sync-relay.py (JSON text frames):
//   client -> relay, first frame:   {"t":"join","room":"<room key>"}
//   relay  -> joiner:               {"t":"joined","peers":<count of others>}
//   relay  -> others in room:       {"t":"peer_join"} / {"t":"peer_leave"}
//   any frame after join is fanned out VERBATIM to every other room member.
//
// No storage, no replay: late-join state transfer is peer-to-peer by design
// (existing members snapshot their evidence to newcomers).
//
// Deno Deploy runs multiple isolates and a room can straddle them, so a
// BroadcastChannel bridges the message + join/leave fanout across isolates.
// Peer COUNTS are per-isolate (best-effort): if two peers land on different
// isolates, each may report 0 others even though fanout still reaches them.
// Fine for testing. For exact global counts / strict single-room coordination,
// move to a Cloudflare Durable Object (one object == one room == one authority).

const rooms = new Map<string, Set<WebSocket>>();
const bridge = new BroadcastChannel("dg-sync");

function roomSet(room: string): Set<WebSocket> {
  let s = rooms.get(room);
  if (!s) { s = new Set(); rooms.set(room, s); }
  return s;
}

// Send to every local member of `room`, optionally skipping the sender.
function fanoutLocal(room: string, data: string, except?: WebSocket) {
  for (const ws of rooms.get(room) ?? []) {
    if (ws !== except && ws.readyState === WebSocket.OPEN) {
      try { ws.send(data); } catch { /* peer went away mid-send */ }
    }
  }
}

// Frames from other isolates: fan out to our local members only (the sender
// lives on the origin isolate, which already excluded it there).
bridge.onmessage = (e: MessageEvent) => {
  const { room, data } = e.data as { room: string; data: string };
  fanoutLocal(room, data);
};

// Deliver `data` to all other members of `room` -- this isolate + every other.
function relayToOthers(room: string, data: string, sender: WebSocket) {
  fanoutLocal(room, data, sender);
  bridge.postMessage({ room, data });
}

Deno.serve((req: Request) => {
  if (req.headers.get("upgrade") !== "websocket") {
    // Plain HTTP (health checks, a browser poking the URL): 200 OK so uptime
    // pingers stay happy and it's obvious the relay is alive.
    return new Response("dg-sync relay ok\n", { status: 200 });
  }

  const { socket, response } = Deno.upgradeWebSocket(req);
  let room: string | null = null;

  socket.onmessage = (ev: MessageEvent) => {
    if (typeof ev.data !== "string") return;

    if (room === null) {
      // Pre-join: only a valid join frame is honored; everything else ignored.
      let msg: { t?: string; room?: string };
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg?.t === "join" && typeof msg.room === "string" && msg.room) {
        room = msg.room;
        const peers = roomSet(room);
        // "joined" carries the count of OTHERS -- report before adding self.
        socket.send(JSON.stringify({ t: "joined", peers: peers.size }));
        peers.add(socket);
        relayToOthers(room, JSON.stringify({ t: "peer_join" }), socket);
      }
      return;
    }

    // Post-join: rebroadcast the frame verbatim to the rest of the room.
    relayToOthers(room, ev.data, socket);
  };

  const leave = () => {
    if (room === null) return;
    const peers = rooms.get(room);
    if (peers) {
      peers.delete(socket);
      relayToOthers(room, JSON.stringify({ t: "peer_leave" }), socket);
      if (peers.size === 0) rooms.delete(room);
    }
    room = null;
  };
  socket.onclose = leave;
  socket.onerror = leave;

  return response;
});
