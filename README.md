# Screen Stream

## Cấu trúc

```
screenshare/
├── server.js       — Node.js server (WebSocket + HTTP)
├── index.html      — Web client (thuần JS, không cần build)
├── stream.lua      — Roblox executor script (viewer)
└── package.json    — Dependencies
```

## Cài đặt & Chạy Server

```bash
npm install
npm start
```

Server mặc định chạy ở port `3000`. Trên Render.com nó sẽ tự dùng biến `PORT`.

## Sử dụng

1. **Deploy server** lên `lonelyhubstreaming.onrender.com`
2. **Mở `index.html`** trong trình duyệt → nhấn **"Bắt đầu Stream"** → chọn màn hình
3. **Chạy `stream.lua`** trong Roblox executor → GUI hiện ở giữa màn hình, tự động nhận stream

## Yêu cầu

- Executor hỗ trợ: `request()`, `writefile()`, `getcustomasset()`
- Tương thích: Synapse X, KRNL, Fluxus, Solara và các executor hiện đại

## Khi web ngắt

Khi trình duyệt đóng/dừng stream → Lua tự động phát hiện qua `/api/status` và dừng hiển thị.
