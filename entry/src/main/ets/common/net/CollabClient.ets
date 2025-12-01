// entry/src/main/ets/common/collab/CollabClient.ets
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

// ==== 协作消息类型定义（你可以按需扩展） ====

export type CollabMessageType = 'join' | 'leave' | 'stroke' | 'clear';

export interface StrokePoint {
  x: number;
  y: number;
  pressure: number; // 0~1
  color: string; // '#RRGGBB'
  width: number; // 画笔宽度
}

// 根据你自己的协议来定，这里举例 stroke / clear 类消息
export interface CollabStrokePayload {
  points: StrokePoint[];
  layerId: string;
}

export interface CollabClearPayload {
  layerId: string;
}

export interface CollabMessage {
  type: CollabMessageType;
  clientId: string;

  // 这里用联合类型，避免 any / unknown
  payload?: CollabStrokePayload | CollabClearPayload;
}

// ==== 回调类型 ====

export type CollabMsgCallback = (msg: CollabMessage) => void;

export type CollabErrorCallback = (msg: string) => void;

export type CollabStateCallback = () => void;

// ==== WebSocket 客户端封装 ====

export class CollabClient {
  private url: string;
  private ws: webSocket.WebSocket | null = null;
  private isConnected: boolean = false;
  private onOpen?: CollabStateCallback;
  private onClose?: CollabStateCallback;
  private onMsg?: CollabMsgCallback;
  private onErr?: CollabErrorCallback;

  constructor(url: string) {
    this.url = url; // 例如 "ws://192.168.0.10:8080/collab"
  }

  /**
   * 设置回调
   */
  setCallbacks(
    onOpen?: CollabStateCallback,
    onClose?: CollabStateCallback,
    onMsg?: CollabMsgCallback,
    onErr?: CollabErrorCallback
  ): void {
    this.onOpen = onOpen;
    this.onClose = onClose;
    this.onMsg = onMsg;
    this.onErr = onErr;
  }

  /**
   * 建立连接
   */
  connect(): void {
    // 已有连接先关闭
    if (this.ws !== null) {
      this.safeCloseInner();
      this.ws = null;
    }

    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.ws = socket;

    // --- 订阅 open 事件 ---
    socket.on('open', (err: BusinessError, value: Object) => {
      if (err) {
        this.reportError('WebSocket open error: ' + JSON.stringify(err));
        return;
      }
      this.isConnected = true;
      if (this.onOpen) {
        this.onOpen();
      }
    });

    // --- 订阅 message 事件（重点：签名必须是 (err, value)） ---
    socket.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err) {
        this.reportError('WebSocket message error: ' + JSON.stringify(err));
        return;
      }

      // 服务器现在用文本 JSON，所以先确保是 string
      if (typeof data === 'string') {
        this.handleTextMessage(data);
      } else {
        // 如果以后你想支持二进制，这里可以再扩展
        this.reportError('Unsupported binary message from server');
      }
    });

    // --- 订阅 close 事件 ---
    socket.on('close', (err: BusinessError, result: webSocket.CloseResult) => {
      this.isConnected = false;
      if (err) {
        this.reportError('WebSocket close error: ' + JSON.stringify(err));
      }
      if (this.onClose) {
        this.onClose();
      }
    });

    // --- 订阅 error 事件 ---
    socket.on('error', (err: BusinessError) => {
      this.isConnected = false;
      this.reportError('WebSocket error: ' + JSON.stringify(err));
    });

    // --- 发起连接 ---
    socket.connect(this.url, (err: BusinessError, value: boolean) => {
      if (err) {
        this.reportError('WebSocket connect error: ' + JSON.stringify(err));
        return;
      }
      if (!value) {
        this.reportError('WebSocket connect failed, value=false');
      }
      // 这里真正的“连上”还要等 on('open') 回调
    });
  }

  /**
   * 发送协作消息
   */
  send(msg: CollabMessage): void {
    if (this.ws === null || !this.isConnected) {
      this.reportError('WebSocket not connected, cannot send');
      return;
    }

    let text: string = JSON.stringify(msg);
    let promise: Promise<boolean> = this.ws.send(text);
    promise.then((ok: boolean) => {
      if (!ok) {
        this.reportError('WebSocket send returned false');
      }
    }).catch((err: string) => {
      this.reportError('WebSocket send error: ' + err);
    });
  }

  /**
   * 主动关闭连接（给页面用）
   */
  close(): void {
    this.safeCloseInner();
    this.ws = null;
    this.isConnected = false;
  }

  /**
   * 内部安全关闭
   */
  private safeCloseInner(): void {
    if (this.ws === null) {
      return;
    }
    let socket: webSocket.WebSocket = this.ws;
    // 使用 Promise 版 close，避免 callback 里再套一层
    let promise: Promise<boolean> = socket.close();
    promise.then((_value: boolean) => {
      // 成功关闭，不需要额外处理
    }).catch((err: string) => {
      this.reportError('WebSocket close error: ' + err);
    });
  }

  /**
   * 处理文本消息：JSON -> CollabMessage
   */
  private handleTextMessage(text: string): void {
    let parsed: CollabMessage;
    try {
      // ArkTS 这边 JSON.parse 默认返回 Object，这里直接断言成 CollabMessage
      parsed = JSON.parse(text) as CollabMessage;
    } catch (_e) {
      this.reportError('JSON parse error: ' + text);
      return;
    }

    // 简单校验 type / clientId，避免完全乱的数据
    if (!parsed || !parsed.type || !parsed.clientId) {
      this.reportError('Invalid collab message: ' + text);
      return;
    }

    if (this.onMsg) {
      this.onMsg(parsed);
    }
  }

  /**
   * 统一错误上报
   */
  private reportError(msg: string): void {
    console.error('[CollabClient] ' + msg);
    if (this.onErr) {
      this.onErr(msg);
    }
  }

  /**
   * 提供一个状态查询
   */
  get connected(): boolean {
    return this.isConnected;
  }
}
