const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const path = require("path");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws" });

let streamerSocket    = null;
let streamerConnected = false;

let latestJpeg = null;
const mjpegClients  = new Set();
const wsViewers     = new Set();
const jpegViewers   = new Set();

let webmCodec        = null;
let webmInitChunks   = [];
let webmRecentChunks = [];
const INIT_CHUNK_COUNT = 6;
const MAX_RECENT       = 30;

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
  res.json({ connected: streamerConnected, viewers: mjpegClients.size + wsViewers.size + jpegViewers.size })
);

app.get("/api/frame/latest.jpg", (_, res) => {
  if (!latestJpeg || !streamerConnected) return res.status(204).end();
  res.setHeader("Content-Type", "image/jpeg");
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate");
  res.send(latestJpeg);
});

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

function broadcastJpeg(frame) {
  for (const c of mjpegClients) pushMjpeg(c, frame);
  for (const v of jpegViewers) {
    if (v.readyState === 1) {
      try { v.send(frame); } catch (_) { jpegViewers.delete(v); }
    }
  }
}

function broadcastWebm(chunk) {
  for (const v of wsViewers) {
    if (v.readyState === 1) {
      try { v.send(chunk); } catch (_) { wsViewers.delete(v); }
    }
  }
}

function sendJson(ws, obj) {
  try { ws.send(JSON.stringify(obj)); } catch (_) {}
}

wss.on("connection", (ws, req) => {
  const url  = new URL(req.url || "/", "http://x");
  const role = url.searchParams.get("role");

  if (role === "viewer") {
    wsViewers.add(ws);
    sendJson(ws, { type: "status", connected: streamerConnected });
    if (webmCodec && streamerConnected) {
      sendJson(ws, { type: "codec", value: webmCodec });
      const catchup = [...webmInitChunks, ...webmRecentChunks];
      for (const chunk of catchup) {
        try { ws.send(chunk); } catch (_) {}
      }
    }
    ws.on("close",  () => wsViewers.delete(ws));
    ws.on("error",  () => wsViewers.delete(ws));
    return;
  }

  if (role === "jpeg-viewer") {
    jpegViewers.add(ws);
    sendJson(ws, { type: "status", connected: streamerConnected });
    if (latestJpeg && streamerConnected) {
      try { ws.send(latestJpeg); } catch (_) {}
    }
    ws.on("close",  () => jpegViewers.delete(ws));
    ws.on("error",  () => jpegViewers.delete(ws));
    return;
  }

  if (streamerSocket) streamerSocket.close();
  streamerSocket    = ws;
  streamerConnected = true;

  webmInitChunks   = [];
  webmRecentChunks = [];
  webmCodec        = null;
  latestJpeg       = null;

  for (const v of wsViewers)   if (v.readyState === 1) sendJson(v, { type: "status", connected: true });
  for (const v of jpegViewers) if (v.readyState === 1) sendJson(v, { type: "status", connected: true });

  ws.on("message", (data, isBinary) => {
    if (!isBinary) {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === "codec") {
          webmCodec        = msg.value;
          webmInitChunks   = [];
          webmRecentChunks = [];
          for (const v of wsViewers) {
            if (v.readyState === 1) sendJson(v, { type: "codec", value: webmCodec });
          }
        }
      } catch (_) {}
      return;
    }

    const buf = Buffer.from(data);

    if (buf[0] === 0xFF && buf[1] === 0xD8) {
      latestJpeg = buf;
      broadcastJpeg(buf);
      return;
    }

    if (webmInitChunks.length < INIT_CHUNK_COUNT) {
      webmInitChunks.push(buf);
    } else {
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
    for (const v of wsViewers)   if (v.readyState === 1) sendJson(v, { type: "status", connected: false });
    for (const v of jpegViewers) if (v.readyState === 1) sendJson(v, { type: "status", connected: false });
  };
  ws.on("close", onClose);
  ws.on("error", onClose);
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Server on port ${PORT}`));
