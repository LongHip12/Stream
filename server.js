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

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.sendStatus(200);
  next();
});

app.use(express.static(path.join(__dirname, "public")));

app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "index.html"));
});

app.get("/api/status", (req, res) => {
  res.json({ connected: streamerConnected });
});

app.get("/api/frame/latest.jpg", (req, res) => {
  if (!latestFrame || !streamerConnected) {
    return res.status(204).end();
  }
  res.setHeader("Content-Type", "image/jpeg");
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate");
  res.setHeader("Pragma", "no-cache");
  res.send(latestFrame);
});

wss.on("connection", (ws, req) => {
  if (streamerSocket) {
    streamerSocket.close();
  }

  streamerSocket = ws;
  streamerConnected = true;
  latestFrame = null;

  ws.on("message", (data, isBinary) => {
    if (isBinary) {
      latestFrame = data;
    } else {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === "frame" && msg.data) {
          const b64 = msg.data.replace(/^data:image\/\w+;base64,/, "");
          latestFrame = Buffer.from(b64, "base64");
        }
      } catch (_) {}
    }
  });

  ws.on("close", () => {
    if (streamerSocket === ws) {
      streamerConnected = false;
      streamerSocket = null;
      latestFrame = null;
    }
  });

  ws.on("error", () => {
    if (streamerSocket === ws) {
      streamerConnected = false;
      streamerSocket = null;
      latestFrame = null;
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
