// entry/src/main/ets/common/collab/CollabClient.ets
// WebSocket 协作客户端：负责连接服务器、收发协作消息
import { webSocket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'

// ========== 协作消息 payload 定义 ==========

// 图片同步消息的 payload，表示一整张画面
export interface CollabImageSyncPayload {
  format: 'image/png'
  baseBase64: string              // 底图
  drawBase64?: string             // 绘制层（可选：没有绘制层就不发）
  opDesc?: string
}

// 服务器给客户端分配身份时使用的 payload
export interface CollabAssignIdPayload {
  displayColor: string // 服务器分配的显示颜色
  opDesc?: string // 可选说明
}

// 单个在线用户的信息
export interface OnlineUserItem {
  clientId: string // 客户端唯一标识
  displayColor: string // 该用户在 UI 中显示的颜色
}

// 在线用户列表的 payload
export interface OnlineUsersPayload {
  users: Array<OnlineUserItem> // 当前在线的所有用户
}

// 所有协作消息类型
export type CollabMessageType =
  | 'assignId' // 服务器分配 clientId
    | 'clear' // 清空图层
    | 'imageSync' // 同步整张图像
    | 'onlineUsers' // 在线用户列表更新

// 协作消息的统一结构
export interface CollabMessage {
  type: CollabMessageType // 消息类型
  clientId: string // 发送方 clientId
  payload:
    | CollabAssignIdPayload
    | CollabClearPayload
    | CollabImageSyncPayload
    | OnlineUsersPayload
}

// 单个笔迹点的数据结构
export interface StrokePoint {
  x: number // 像素 x
  y: number // 像素 y
  pressure: number // 压力值 0~1
  color: string // 颜色 '#RRGGBB'
  width: number // 画笔宽度（屏幕像素）
}

// 笔迹同步消息的 payload
export interface CollabStrokePayload {
  layerId: string // 图层 id
  points: Array<StrokePoint> // 笔迹点列表
  color: string // 笔迹颜色
  width: number // 笔迹宽度
}

// 清空图层消息的 payload
export interface CollabClearPayload {
  layerId: string // 被清空的图层 id
  opDesc?: string // 可选操作说明
}

// 所有 payload 的联合类型
export type CollabPayload =
  | CollabStrokePayload
    | CollabClearPayload
    | CollabImageSyncPayload
    | CollabAssignIdPayload
    | OnlineUsersPayload

// 构造一条“清空图层”的协作消息
export function buildClearMessage(
  clientId: string,
  layerId: string,
  opDesc?: string
): CollabMessage {
  const payload: CollabClearPayload = {
    layerId: layerId,
    opDesc: opDesc
  }

  const msg = {} as CollabMessage // ArkTS 要求显式声明类型
  msg.type = 'clear'
  msg.clientId = clientId
  msg.payload = payload

  return msg
}

// ========== 回调类型定义 ==========

// 收到协作消息时的回调
export type CollabMsgCallback = (msg: CollabMessage) => void

// 出错时的回调
export type CollabErrorCallback = (msg: string) => void

// 连接状态变化回调
export type CollabStateCallback = () => void

// ========== WebSocket 协作客户端封装 ==========

// WebSocket 协作客户端封装类
export class CollabClient {
  private url: string // WebSocket 服务地址
  private ws: webSocket.WebSocket | null = null // 当前 WebSocket 实例
  private isConnected: boolean = false // 当前连接状态
  private onOpen?: CollabStateCallback // 连接成功回调
  private onClose?: CollabStateCallback // 连接关闭回调
  private onMsg?: CollabMsgCallback // 收到消息回调
  private onErr?: CollabErrorCallback // 错误回调

  constructor(url: string) {
    this.url = url // 例如 ws://192.168.0.10:8080/collab
  }

  // 设置连接 / 消息 / 错误回调
  setCallbacks(
    onOpen?: CollabStateCallback,
    onClose?: CollabStateCallback,
    onMsg?: CollabMsgCallback,
    onErr?: CollabErrorCallback
  ): void {
    this.onOpen = onOpen
    this.onClose = onClose
    this.onMsg = onMsg
    this.onErr = onErr
  }

  // 建立 WebSocket 连接
  connect(): void {
    if (this.ws !== null) {
      this.safeCloseInner() // 已存在连接先关闭
      this.ws = null
    }

    const socket: webSocket.WebSocket = webSocket.createWebSocket()
    this.ws = socket

    // WebSocket 打开事件
    socket.on('open', (err: BusinessError, _value: Object) => {
      if (err) {
        this.reportError('WebSocket open error: ' + JSON.stringify(err))
        return
      }
      this.isConnected = true
      this.onOpen && this.onOpen()
    })

    // WebSocket 消息事件
    socket.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err) {
        this.reportError('WebSocket message error: ' + JSON.stringify(err))
        return
      }

      if (typeof data === 'string') {
        this.handleTextMessage(data) // 只处理文本 JSON
      } else {
        this.reportError('Unsupported binary message from server')
      }
    })

    // WebSocket 关闭事件
    socket.on('close', (err: BusinessError) => {
      this.isConnected = false
      if (err) {
        this.reportError('WebSocket close error: ' + JSON.stringify(err))
      }
      this.onClose && this.onClose()
    })

    // WebSocket 错误事件
    socket.on('error', (err: BusinessError) => {
      this.isConnected = false
      this.reportError('WebSocket error: ' + JSON.stringify(err))
    })

    // 发起连接
    socket.connect(this.url, (err: BusinessError, value: boolean) => {
      if (err) {
        this.reportError('WebSocket connect error: ' + JSON.stringify(err))
        return
      }
      if (!value) {
        this.reportError('WebSocket connect failed, value=false')
      }
    })
  }

  // 发送一条协作消息
  send(msg: CollabMessage): void {
    if (!this.ws || !this.isConnected) {
      this.reportError('WebSocket not connected, cannot send')
      return
    }

    const text: string = JSON.stringify(msg)
    this.ws.send(text).catch((err: string) => {
      this.reportError('WebSocket send error: ' + err)
    })
  }

  // 主动关闭连接
  close(): void {
    this.safeCloseInner()
    this.ws = null
    this.isConnected = false
  }

  // 内部安全关闭 WebSocket
  private safeCloseInner(): void {
    if (!this.ws) {
      return
    }
    this.ws.close().catch((err: string) => {
      this.reportError('WebSocket close error: ' + err)
    })
  }

  // 处理收到的文本消息
  private handleTextMessage(text: string): void {
    let parsed: CollabMessage
    try {
      parsed = JSON.parse(text) as CollabMessage
    } catch {
      this.reportError('JSON parse error: ' + text)
      return
    }

    if (!parsed.type || !parsed.clientId) {
      this.reportError('Invalid collab message: ' + text)
      return
    }

    this.onMsg && this.onMsg(parsed)
  }

  // 统一错误上报
  private reportError(msg: string): void {
    console.error('[CollabClient] ' + msg)
    this.onErr && this.onErr(msg)
  }

  // 对外暴露当前连接状态
  get connected(): boolean {
    return this.isConnected
  }
}
