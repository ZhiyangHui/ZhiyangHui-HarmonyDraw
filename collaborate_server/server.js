// =============================
// WebSocket 协作服务器
// =============================

const WebSocket = require('ws'); // 引入 ws 库，用来创建 WebSocket 服务

const PORT = 8080; // 服务器监听端口

let nextId = 1; // 用于给新连接的客户端分配递增 ID
const colors = ['#EF4444', '#3B82F6', '#10B981', '#F59E0B', '#8B5CF6']; // 可选的用户标识颜色池

// 创建 WebSocket 服务，监听所有网卡的 /collab 路径
const wss = new WebSocket.WebSocketServer({
    host: '0.0.0.0', // 监听所有网卡，保证公网可以访问
    port: PORT, // 使用指定端口
    path: '/collab'  // 协作通信路径
});

// 启动日志，分别打印内网和公网访问地址
console.log(`协作服务器已启动: ws://0.0.0.0:${PORT}/collab`);
console.log(`公网访问地址: ws://101.43.185.73:${PORT}/collab`);

// ===== 客户端连接时的处理逻辑 =====
wss.on('connection', (ws) => {
    // 为新客户端生成唯一 clientId
    const clientId = 'user-' + nextId.toString();
    // 按顺序从颜色池中分配一个颜色
    const color = colors[(nextId - 1) % colors.length];
    nextId += 1;

    // 把 clientId 和颜色挂到 ws 对象上，方便后续使用
    ws.clientId = clientId;
    ws.displayColor = color;

    console.log(`新客户端已连接: ${clientId}`);

    // 构造“分配身份”的消息，告诉客户端它的 clientId 和颜色
    const assignMsg = {
        type: 'assignId',
        clientId: clientId,
        payload: { displayColor: color }
    };

    // 连接建立后，立刻把身份信息发给客户端
    ws.send(JSON.stringify(assignMsg));

    // 监听当前客户端发来的消息
    ws.on('message', (msg) => {
        const text = msg.toString(); // 把消息转成字符串
        console.log(` [${clientId}] -> ${text}`);

        // 把这条消息转发给所有其他已连接的客户端
        wss.clients.forEach((client) => {
            if (client !== ws && client.readyState === WebSocket.OPEN) {
                client.send(text);
            }
        });
    });

    // 客户端断开连接时打印日志
    ws.on('close', () => {
        console.log(`客户端断开连接: ${clientId}`);
    });
});
