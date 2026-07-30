const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const path = require("path");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws" });

let latestFrame = null;
let streamerConnected = false;
let streamerSocket = null;
const mjpegClients = new Set();
const wsViewers = new Set();

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.sendStatus(200);
  next();
});

app.use(express.static(path.join(__dirname, "public")));

app.get("/", (req, res) => res.sendFile(path.join(__dirname, "index.html")));
app.get("/viewer", (req, res) => res.sendFile(path.join(__dirname, "viewer.html")));

app.get("/api/status", (req, res) => {
  res.json({ connected: streamerConnected, viewers: mjpegClients.size + wsViewers.size });
});

app.get("/api/frame/latest.jpg", (req, res) => {
  if (!latestFrame || !streamerConnected) return res.status(204).end();
  res.setHeader("Content-Type", "image/jpeg");
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate");
  res.setHeader("Pragma", "no-cache");
  res.send(latestFrame);
});

// MJPEG stream — browser displays frames natively with zero JS overhead per frame
app.get("/api/stream", (req, res) => {
  res.setHeader("Content-Type", "multipart/x-mixed-replace; boundary=mjpegframe");
  res.setHeader("Cache-Control", "no-cache, no-store");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("Pragma", "no-cache");
  res.flushHeaders();

  mjpegClients.add(res);

  if (latestFrame && streamerConnected) {
    writeMjpegFrame(res, latestFrame);
  }

  req.on("close", () => mjpegClients.delete(res));
  req.on("error", () => mjpegClients.delete(res));
});

function writeMjpegFrame(res, frameData) {
  try {
    res.write(`--mjpegframe\r\nContent-Type: image/jpeg\r\nContent-Length: ${frameData.length}\r\n\r\n`);
    res.write(frameData);
    res.write("\r\n");
  } catch (_) {
    mjpegClients.delete(res);
  }
}

function broadcastFrame(frameData) {
  for (const client of mjpegClients) writeMjpegFrame(client, frameData);
  for (const viewer of wsViewers) {
    if (viewer.readyState === 1) {
      try { viewer.send(frameData); } catch (_) { wsViewers.delete(viewer); }
    }
  }
}

wss.on("connection", (ws, req) => {
  const urlObj = new URL(req.url || "/", "http://x");
  const role = urlObj.searchParams.get("role");

  if (role === "viewer") {
    wsViewers.add(ws);
    ws.send(JSON.stringify({ type: "status", connected: streamerConnected }));
    if (latestFrame && streamerConnected) ws.send(latestFrame);
    ws.on("close", () => wsViewers.delete(ws));
    ws.on("error", () => wsViewers.delete(ws));
    return;
  }

  // Streamer connection
  if (streamerSocket) streamerSocket.close();
  streamerSocket = ws;
  streamerConnected = true;
  latestFrame = null;

  for (const v of wsViewers) {
    if (v.readyState === 1) v.send(JSON.stringify({ type: "status", connected: true }));
  }

  ws.on("message", (data, isBinary) => {
    if (isBinary) {
      latestFrame = Buffer.from(data);
    } else {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === "frame" && msg.data) {
          const b64 = msg.data.replace(/^data:image\/\w+;base64,/, "");
          latestFrame = Buffer.from(b64, "base64");
        }
      } catch (_) {}
    }
    if (latestFrame) broadcastFrame(latestFrame);
  });

  const onClose = () => {
    if (streamerSocket !== ws) return;
    streamerConnected = false;
    streamerSocket = null;
    latestFrame = null;
    for (const v of wsViewers) {
      if (v.readyState === 1) v.send(JSON.stringify({ type: "status", connected: false }));
    }
  };
  ws.on("close", onClose);
  ws.on("error", onClose);
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Server on port ${PORT}`));
