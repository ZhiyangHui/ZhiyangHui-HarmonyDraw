// =============================
//  WebSocket 协作服务器（云服务器版本）
// =============================
const WebSocket = require('ws');

const PORT = 8080;

let nextId = 1;
const colors = ['#EF4444', '#3B82F6', '#10B981', '#F59E0B', '#8B5CF6'];

const wss = new WebSocket.WebSocketServer({
    host: '0.0.0.0', // ★ 必须监听所有网卡，外网才能访问
    port: PORT,
    path: '/collab'
});

console.log(`🚀 协作服务器已启动: ws://0.0.0.0:${PORT}/collab`);
console.log(`🌐 公网访问地址: ws://101.43.185.73:${PORT}/collab`);


// ===== 客户端连接时处理 =====
wss.on('connection', (ws) => {
    const clientId = 'user-' + nextId.toString();
    const color = colors[(nextId - 1) % colors.length];
    nextId += 1;

    ws.clientId = clientId;
    ws.displayColor = color;

    console.log(`🌐 新客户端已连接: ${clientId}`);

    // 分配 ID 和颜色
    const assignMsg = {
        type: 'assignId',
        clientId: clientId,
        payload: { displayColor: color }
    };
    ws.send(JSON.stringify(assignMsg));

    // 收到消息，广播给其他客户端
    ws.on('message', (msg) => {
        const text = msg.toString();
        console.log(`📩 [${clientId}] -> ${text}`);

        wss.clients.forEach((client) => {
            if (client !== ws && client.readyState === WebSocket.OPEN) {
                client.send(text);
            }
        });
    });

    ws.on('close', () => {
        console.log(`❌ 客户端断开连接: ${clientId}`);
    });
});
