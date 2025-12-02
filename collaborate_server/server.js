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
