// entry/src/main/ets/common/collab/CollabClient.ets
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

// ========== 协作消息类型定义 ==========
export interface CollabImageSyncPayload {
  format: string; // 'image/png'
  dataBase64: string; // 整张图片的 PNG 的 base64
  opDesc?: string;
}


// ==== 新增：服务器给客户端分配身份的 payload ====
export interface CollabAssignIdPayload {
  displayColor: string; // 例如 '#EF4444'
  opDesc?: string;
}

export interface OnlineUserItem {
  clientId: string;
  displayColor: string;
}

export interface OnlineUsersPayload {
  users: Array<OnlineUserItem>;
}


// 所有消息类型（加上 'assignId'）
export type CollabMessageType =
  | 'assignId'
    | 'clear'
    | 'imageSync'
    | 'onlineUsers'; // ← 新增


export interface CollabMessage {
  type: CollabMessageType;
  clientId: string;
  payload:
    | CollabAssignIdPayload
    | CollabClearPayload
    | CollabImageSyncPayload
    | OnlineUsersPayload; // ✅ 一定要加这一行
}


// 单个笔迹点
export interface StrokePoint {
  x: number;
  y: number;
  pressure: number; // 0~1
  color: string; // '#RRGGBB'
  width: number; // 画笔宽度（屏幕像素）
}

// 笔迹消息的 payload
export interface CollabStrokePayload {
  layerId: string;
  points: Array<StrokePoint>;
  color: string;
  width: number;
}

// 清空图层消息的 payload
export interface CollabClearPayload {
  layerId: string;
  opDesc?: string; // 🔵 新增，可选说明文字
}


// 所有 payload 的联合类型
export type CollabPayload =
  CollabStrokePayload
    | CollabClearPayload
    | CollabImageSyncPayload
    | CollabAssignIdPayload
    | OnlineUsersPayload; // ← 新加入这个


// ==== 工具函数：构造 “清空图层” 消息 ====

// 注意：这里用显式的 interface 类型，ArkTS 认可，不会报 untyped object literal
export function buildClearMessage(
  clientId: string,
  layerId: string,
  opDesc?: string
): CollabMessage {
  const payload: CollabClearPayload = {
    layerId: layerId,
    opDesc: opDesc
  };

  // 🚨 不能写成字面量，要用“创建空对象 + 赋值”的方式
  const msg = {} as CollabMessage;
  msg.type = 'clear';
  msg.clientId = clientId;
  msg.payload = payload;

  return msg;
}


// ========== 回调类型定义 ==========

export type CollabMsgCallback = (msg: CollabMessage) => void;

export type CollabErrorCallback = (msg: string) => void;

export type CollabStateCallback = () => void;

// ========== WebSocket 客户端封装 ==========

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

    // --- open 事件 ---
    socket.on('open', (err: BusinessError, _value: Object) => {
      if (err) {
        this.reportError('WebSocket open error: ' + JSON.stringify(err));
        return;
      }
      this.isConnected = true;
      if (this.onOpen) {
        this.onOpen();
      }
    });

    // --- message 事件 ---
    socket.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err) {
        this.reportError('WebSocket message error: ' + JSON.stringify(err));
        return;
      }

      if (typeof data === 'string') {
        this.handleTextMessage(data);
      } else {
        // 后面你要支持二进制再扩展
        this.reportError('Unsupported binary message from server');
      }
    });

    // --- close 事件 ---
    socket.on('close', (err: BusinessError, _result: webSocket.CloseResult) => {
      this.isConnected = false;
      if (err) {
        this.reportError('WebSocket close error: ' + JSON.stringify(err));
      }
      if (this.onClose) {
        this.onClose();
      }
    });

    // --- error 事件 ---
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
      // 真正 ready 还是看 on('open')
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

    const text: string = JSON.stringify(msg);
    const promise: Promise<boolean> = this.ws.send(text);
    promise.then((ok: boolean) => {
      if (!ok) {
        this.reportError('WebSocket send returned false');
      }
    }).catch((err: string) => {
      this.reportError('WebSocket send error: ' + err);
    });
  }

  /**
   * 主动关闭连接
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
    const socket: webSocket.WebSocket = this.ws;
    const promise: Promise<boolean> = socket.close();
    promise.then((_value: boolean) => {
      // ignore
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
      parsed = JSON.parse(text) as CollabMessage;
    } catch (_e) {
      this.reportError('JSON parse error: ' + text);
      return;
    }

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
   * 对外提供连接状态
   */
  get connected(): boolean {
    return this.isConnected;
  }
}
