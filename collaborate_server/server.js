// collaborate_server/server.js
// 最小多人协作 WebSocket 服务端（适配 ArkTS 客户端）
// 启动后访问 ws://<ip>:8080/collab?roomId=xxx&userId=xxx

const WebSocket = require('ws');
const { URL } = require('url');

// 房间 -> 客户端集合
const rooms = new Map();

// 创建 WebSocket Server
const wss = new WebSocket.Server({ port: 8080 });

console.log("🚀 协作服务器已启动: ws://0.0.0.0:8080/collab");

// 加入房间
function joinRoom(roomId, ws) {
    if (!rooms.has(roomId)) {
        rooms.set(roomId, new Set());
    }
    rooms.get(roomId).add(ws);
}

// 离开房间
function leaveRoom(roomId, ws) {
    if (!rooms.has(roomId)) {
        return;
    }
    rooms.get(roomId).delete(ws);
    if (rooms.get(roomId).size === 0) {
        rooms.delete(roomId);
    }
}

// 广播消息（除了自己）
function broadcast(roomId, senderId, msgObject) {
    const json = JSON.stringify(msgObject);
    const clients = rooms.get(roomId);
    if (!clients) {
        return;
    }

    for (const client of clients) {
        if (client.readyState === WebSocket.OPEN && client.userId !== senderId) {
            client.send(json);
        }
    }
}

// 有客户端连接
wss.on("connection", (ws, req) => {
    const fullUrl = new URL(req.url, `http://${req.headers.host}`);
    const roomId = fullUrl.searchParams.get("roomId") || "default";
    const userId = fullUrl.searchParams.get("userId") || ("U" + Math.random().toString(16).slice(2));

    ws.roomId = roomId;
    ws.userId = userId;

    console.log(`🟢 客户端连接: roomId=${roomId}, userId=${userId}`);

    joinRoom(roomId, ws);

    // 告诉客户端连接成功
    ws.send(JSON.stringify({
        type: "system",
        event: "connected",
        roomId,
        userId
    }));

    // 收到客户端消息
    ws.on("message", (data) => {
        const text = data.toString();
        console.log(`📩 来自 ${userId} 的消息: ${text}`);

        let msg = null;
        try {
            msg = JSON.parse(text);
        } catch (e) {
            ws.send(JSON.stringify({ type: "error", message: "Invalid JSON" }));
            return;
        }

        // 加上标识，传给别人
        const wrapped = {
            ...msg,
            roomId,
            fromUserId: userId
        };

        // 广播给房间的人
        broadcast(roomId, userId, wrapped);
    });

    // 断开
    ws.on("close", () => {
        console.log(`🔴 客户端断开: ${userId}`);
        leaveRoom(roomId, ws);
    });

    // 错误
    ws.on("error", (err) => {
        console.error(`⚠ WS 错误 (userId=${userId}):`, err.message);
    });
});
