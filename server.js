const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const path = require("path");
const jpeg = require("jpeg-js");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws" });

let streamerSocket = null;
let streamerConnected = false;

const wsViewers = new Set();

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.sendStatus(200);
  next();
});

app.use(express.static(path.join(__dirname, "public")));
app.get("/", (_, res) => res.sendFile(path.join(__dirname, "index.html")));
app.get("/viewer", (_, res) => res.sendFile(path.join(__dirname, "viewer.html")));

app.get("/api/status", (_, res) =>
  res.json({ connected: streamerConnected, viewers: wsViewers.size })
);

function sendJson(ws, obj) {
  try { ws.send(JSON.stringify(obj)); } catch (_) {}
}

wss.on("connection", (ws, req) => {
  const url = new URL(req.url || "/", "http://x");
  const role = url.searchParams.get("role");

  if (role === "raw-viewer" || role === "jpeg-viewer" || role === "viewer") {
    wsViewers.add(ws);
    sendJson(ws, { type: "status", connected: streamerConnected });
    ws.on("close", () => wsViewers.delete(ws));
    ws.on("error", () => wsViewers.delete(ws));
    return;
  }

  if (streamerSocket) streamerSocket.close();
  streamerSocket = ws;
  streamerConnected = true;

  for (const v of wsViewers) if (v.readyState === 1) sendJson(v, { type: "status", connected: true });

  ws.on("message", (data, isBinary) => {
    if (!isBinary) return;

    const buf = Buffer.from(data);

    if (buf[0] === 0xFF && buf[1] === 0xD8) {
      try {
        const rawPixels = jpeg.decode(buf, { useTolerantUnknown: true, formatAsRGBA: true });
        
        const header = Buffer.alloc(4);
        header.writeUInt16LE(rawPixels.width, 0);
        header.writeUInt16LE(rawPixels.height, 2);

        const payload = Buffer.concat([header, rawPixels.data]);

        for (const v of wsViewers) {
          if (v.readyState === 1) {
            try { v.send(payload); } catch (_) { wsViewers.delete(v); }
          }
        }
      } catch (_) {}
    }
  });

  const onClose = () => {
    if (streamerSocket !== ws) return;
    streamerConnected = false;
    streamerSocket = null;
    for (const v of wsViewers) if (v.readyState === 1) sendJson(v, { type: "status", connected: false });
  };
  ws.on("close", onClose);
  ws.on("error", onClose);
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Server running on port ${PORT}`));
      
