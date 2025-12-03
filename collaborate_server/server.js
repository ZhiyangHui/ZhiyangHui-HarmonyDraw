// =============================
//  WebSocket 协作服务器（最终版本）
// =============================
const WebSocket = require('ws');
const os = require('os');

const PORT = 8080;

// 创建 WebSocketServer（注意 ws 模块这里叫 WebSocketServer）
const wss = new WebSocket.WebSocketServer({
    port: PORT,
    path: '/collab'
});

// ===== 获取本机 IPv4 地址（用于打印给你看） =====
function getLocalIPv4() {
    const nets = os.networkInterfaces();
    for (const name of Object.keys(nets)) {
        for (const net of nets[name] || []) {
            if (net.family === 'IPv4' && !net.internal) {
                return net.address; // 比如 192.168.1.11
            }
        }
    }
    return '127.0.0.1';
}

// ====== 打印服务器启动信息 ======
const ip = getLocalIPv4();
console.log(`🚀 协作服务器已启动: ws://${ip}:${PORT}/collab`);


// ====== WebSocket 事件 ======
wss.on('connection', ws => {
    console.log('🌐 新客户端已连接');

    ws.on('message', msg => {
        console.log('📩 收到消息:', msg.toString());

        // 广播给所有客户端（除了自己）
        wss.clients.forEach(client => {
            if (client !== ws && client.readyState === WebSocket.OPEN) {
                client.send(msg.toString());
            }
        });
    });

    ws.on('close', () => {
        console.log('❌ 客户端断开连接');
    });
});


let nextId = 1;
const colors = ['#EF4444', '#3B82F6', '#10B981', '#F59E0B', '#8B5CF6'];

wss.on('connection', (ws) => {
    const clientId = 'user-' + nextId.toString();
    const color = colors[(nextId - 1) % colors.length];
    nextId += 1;

    // 挂到 ws 对象上，后面转发消息用
    ws.clientId = clientId;
    ws.displayColor = color;

    console.log(`🌐 新客户端已连接: ${clientId}`);

    // 主动告诉这个客户端：你的 id 和 颜色
    const assignMsg = {
        type: 'assignId',
        clientId: clientId,
        payload: {
            displayColor: color
        }
    };
    ws.send(JSON.stringify(assignMsg));

    ws.on('message', (msg) => {
        console.log(`📩 收到消息: ${msg.toString()}`);

        // 把消息转给其他所有客户端
        wss.clients.forEach((client) => {
            if (client !== ws && client.readyState === WebSocket.OPEN) {
                client.send(msg.toString());
            }
        });
    });
});

