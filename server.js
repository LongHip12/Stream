const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const path = require("path");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws" });

// ── State ─────────────────────────────────────────────────────────
let streamerSocket   = null;
let streamerConnected = false;

// JPEG state (for Lua HTTP polling + MJPEG)
let latestJpeg = null;
const mjpegClients = new Set();

// WebM state (for smooth web viewer via MSE)
let webmCodec        = null;   // e.g. 'video/webm;codecs=vp8'
let webmInitChunks   = [];     // first N chunks (contain EBML + tracks header)
let webmRecentChunks = [];     // rolling buffer of recent clusters
const INIT_CHUNK_COUNT = 6;    // first 6 chunks = init segment
const MAX_RECENT       = 30;   // ~6s at 200ms timeslice

// WebSocket viewers
const wsViewers = new Set();

// ── CORS ─────────────────────────────────────────────────────────
app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.sendStatus(200);
  next();
});

app.use(express.static(path.join(__dirname, "public")));
app.get("/",        (_, res) => res.sendFile(path.join(__dirname, "index.html")));
app.get("/viewer",  (_, res) => res.sendFile(path.join(__dirname, "viewer.html")));

app.get("/api/status", (_, res) =>
  res.json({ connected: streamerConnected, viewers: mjpegClients.size + wsViewers.size })
);

// JPEG frame — for Lua
app.get("/api/frame/latest.jpg", (_, res) => {
  if (!latestJpeg || !streamerConnected) return res.status(204).end();
  res.setHeader("Content-Type", "image/jpeg");
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate");
  res.send(latestJpeg);
});

// MJPEG — smooth web fallback (still useful for non-MSE browsers)
app.get("/api/stream", (req, res) => {
  res.setHeader("Content-Type", "multipart/x-mixed-replace; boundary=mjf");
  res.setHeader("Cache-Control", "no-cache, no-store");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();
  mjpegClients.add(res);
  if (latestJpeg && streamerConnected) pushMjpeg(res, latestJpeg);
  req.on("close",  () => mjpegClients.delete(res));
  req.on("error",  () => mjpegClients.delete(res));
});

function pushMjpeg(res, frame) {
  try {
    res.write(`--mjf\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.length}\r\n\r\n`);
    res.write(frame);
    res.write("\r\n");
  } catch (_) { mjpegClients.delete(res); }
}

// ── Broadcast helpers ─────────────────────────────────────────────
function broadcastJpeg(frame) {
  for (const c of mjpegClients) pushMjpeg(c, frame);
}

function broadcastWebm(chunk) {
  for (const v of wsViewers) {
    if (v.readyState === 1) {
      try { v.send(chunk); } catch (_) { wsViewers.delete(v); }
    }
  }
}

// ── WebSocket ─────────────────────────────────────────────────────
wss.on("connection", (ws, req) => {
  const url  = new URL(req.url || "/", "http://x");
  const role = url.searchParams.get("role");

  // ── Viewer ──────────────────────────────────────────────────────
  if (role === "viewer") {
    wsViewers.add(ws);

    // Tell viewer current state
    ws.send(JSON.stringify({ type: "status", connected: streamerConnected }));

    // If WebM stream is active: send init + recent chunks for immediate playback
    if (webmCodec && streamerConnected) {
      ws.send(JSON.stringify({ type: "codec", value: webmCodec }));
      const catchup = [...webmInitChunks, ...webmRecentChunks];
      for (const chunk of catchup) {
        try { ws.send(chunk); } catch (_) {}
      }
    }

    ws.on("close",  () => wsViewers.delete(ws));
    ws.on("error",  () => wsViewers.delete(ws));
    return;
  }

  // ── Streamer ─────────────────────────────────────────────────────
  if (streamerSocket) streamerSocket.close();
  streamerSocket    = ws;
  streamerConnected = true;

  // Reset WebM buffers for new stream session
  webmInitChunks   = [];
  webmRecentChunks = [];
  webmCodec        = null;
  latestJpeg       = null;

  // Notify viewers streamer is live
  for (const v of wsViewers) {
    if (v.readyState === 1)
      v.send(JSON.stringify({ type: "status", connected: true }));
  }

  ws.on("message", (data, isBinary) => {
    if (!isBinary) {
      // JSON control message from streamer
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === "codec") {
          webmCodec        = msg.value;
          webmInitChunks   = [];
          webmRecentChunks = [];
          // Tell all current viewers which codec is coming
          for (const v of wsViewers) {
            if (v.readyState === 1)
              v.send(JSON.stringify({ type: "codec", value: webmCodec }));
          }
        }
      } catch (_) {}
      return;
    }

    const buf = Buffer.from(data);

    // Detect frame type by magic bytes
    // JPEG: FF D8 — always sent for Lua compatibility
    if (buf[0] === 0xFF && buf[1] === 0xD8) {
      latestJpeg = buf;
      broadcastJpeg(buf);
      return;
    }

    // WebM chunk (init header or cluster)
    const totalChunks = webmInitChunks.length + webmRecentChunks.length;

    if (webmInitChunks.length < INIT_CHUNK_COUNT) {
      // Accumulate init segment (contains EBML header + Segment Info + Tracks)
      webmInitChunks.push(buf);
    } else {
      // Rolling recent buffer
      webmRecentChunks.push(buf);
      if (webmRecentChunks.length > MAX_RECENT) webmRecentChunks.shift();
    }

    broadcastWebm(buf);
  });

  const onClose = () => {
    if (streamerSocket !== ws) return;
    streamerConnected = false;
    streamerSocket    = null;
    latestJpeg        = null;
    for (const v of wsViewers) {
      if (v.readyState === 1)
        v.send(JSON.stringify({ type: "status", connected: false }));
    }
  };
  ws.on("close", onClose);
  ws.on("error", onClose);
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Server on port ${PORT}`));
