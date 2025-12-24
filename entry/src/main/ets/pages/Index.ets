// ArkUI 交互弹窗与系统操作能力
import { promptAction } from '@kit.ArkUI'
// 媒体库访问（图片读取、保存）
import { photoAccessHelper } from '@kit.MediaLibraryKit'
// PixelMap 与图片处理能力
import { image } from '@kit.ImageKit'
// 文件读写能力
import { fileIo } from '@kit.CoreFileKit'
// Ability 上下文相关能力
import { common } from '@kit.AbilityKit'
// 系统标准错误类型
import { BusinessError } from '@kit.BasicServicesKit'
// 资源管理（string、media 等）
import resourceManager from '@ohos.resourceManager'
// 绘制 API（Canvas / Path / Paint）
import drawing from '@ohos.graphics.drawing'
// 工具类（时间、编码等）
import util from '@ohos.util'

// entry/src/main/ets/pages/Index.ets
// 颜色选择组件
import { ColorWheelPicker } from './ColorPicker'
// 协作通信客户端及消息定义
import {
  CollabClient,
  CollabMessage,
  buildClearMessage,
  CollabAssignIdPayload,
  CollabImageSyncPayload,
  OnlineUsersPayload,
  OnlineUserItem
} from '../common/net/CollabClient'

// 统一错误结构，兼容系统与自定义错误
interface ErrorWithCode {
  code?: number | string // 错误码
  message?: string // 错误描述
}

// 在线用户展示信息
interface OnlineUserInfo {
  clientId: string // 协作客户端 ID
  displayColor: string // 用户标识颜色
  isSelf: boolean // 是否为当前设备
}

// 画布状态快照，用于撤销 / 恢复
interface CanvasSnapshot {
  pixelMap?: image.PixelMap // 底图快照
  drawPixelMap?: image.PixelMap // 绘制图层快照
  zoom: number // 当前缩放比例
  offsetX: number // X 方向偏移
  offsetY: number // Y 方向偏移
  brightnessLevel: number // 亮度参数
  contrastLevel: number // 对比度参数
  accumulatedRotate: number // 累计旋转角度
}

// 操作记录，用于协作日志展示
interface OperationLogItem {
  id: number // 本地唯一标识
  userId: string // 操作者 ID
  userColor: string // 操作者颜色
  message: string // 操作描述
  timestamp: string // 操作时间
}

// 顶部菜单类型
enum TopMenu {
  None, // 无菜单
  Image, // 图片操作
  Shape, // 形状工具
  Brush // 画笔工具
}

// 形状绘制工具类型
enum ShapeTool {
  None, // 未选择
  Point, // 点
  Line, // 直线
  Rect, // 矩形
  Circle, // 圆
  Ellipse, // 椭圆
  FreeDraw // 自由绘制
}

// 画笔工具类型
enum BrushTool {
  None, // 未选择
  Pen, // 普通画笔
  Highlighter, // 荧光笔
  Eraser // 橡皮擦
}

// 通道顺序（r/g/b/a 在每个像素 4 字节中的偏移）
interface ChannelOrder {
  r: number
  g: number
  b: number
  a: number
  bytesPerPixel: number
}

// UI 坐标转像素坐标的返回类型
interface PixelPoint {
  x: number
  y: number
}


@Entry
@Component
struct Index {
  // ====================== 画布基础状态 ======================
  @State pixelMap?: image.PixelMap = undefined // 当前底图 PixelMap
  @State zoom: number = 1.0 // 当前缩放比例
  @State offsetX: number = 0 // 画布 X 方向平移
  @State offsetY: number = 0 // 画布 Y 方向平移
  @State pixelVersion: number = 0 // 底图版本号，用于触发重绘
  // ====================== 绘制图层 ======================
  @State drawPixelMap?: image.PixelMap = undefined // 绘制专用图层（线条/形状）
  @State drawPixelVersion: number = 0 // 绘制层版本号
  // 橡皮擦只作用于 drawPixelMap，不影响底图

  // ====================== 旋转与图像调整 ======================
  private isRotating: boolean = false // 防止旋转按钮被连续触发
  private accumulatedRotate: number = 0 // 累计旋转角度（度）
  @State rotateDeg: number = 0 // 当前旋转角度
  @State brightnessLevel: number = 0.0 // 亮度调整值（0 为原图）
  @State contrastLevel: number = 0.0 // 对比度调整值（0 为原图）
  // ====================== UI 与工具状态 ======================
  @State showLeftPanel: boolean = false // 左侧工具栏是否展开
  @State currentTool: string = '' // 当前工具字符串标识
  @State activeMenu: TopMenu = TopMenu.None // 当前激活的顶栏菜单
  @State currentShape: ShapeTool = ShapeTool.None // 当前形状工具
  @State currentBrush: BrushTool = BrushTool.Pen // 当前画笔类型
  @State currentMenu: string = 'image' // 当前一级菜单
  @State currentSubTool: string = '' // 当前二级工具
  // ====================== 手势状态 ======================
  private lastPanX: number = 0 // 上一次拖动 X
  private lastPanY: number = 0 // 上一次拖动 Y
  private lastZoom: number = 1.0 // 上一次缩放比例
  // ====================== 裁剪相关 ======================
  @State cropMode: boolean = false // 是否处于裁剪模式
  @State cropStartX: number = 0 // 裁剪起点 X（UI 坐标）
  @State cropStartY: number = 0 // 裁剪起点 Y
  @State cropEndX: number = 0 // 裁剪终点 X
  @State cropEndY: number = 0 // 裁剪终点 Y
  // ====================== 画布尺寸 ======================
  @State canvasWidth: number = 0 // 画布显示宽度
  @State canvasHeight: number = 0 // 画布显示高度
  // ====================== 撤销 / 重做 ======================
  private history: Array<CanvasSnapshot> = [] // 操作历史栈
  private historyIndex: number = -1 // 当前历史索引
  private readonly historyLimit: number = 10 // 最大历史步数
  private originalPixelMap?: image.PixelMap = undefined // 打开图片时的原始快照
  // ====================== 画笔样式 ======================
  @State strokeWidth: number = 4 // 画笔粗细
  @State strokeR: number = 0 // 画笔颜色 R
  @State strokeG: number = 0 // 画笔颜色 G
  @State strokeB: number = 0 // 画笔颜色 B
  @State strokeOpacity: number = 1.0 // 画笔透明度
  // ====================== 形状 / 自由绘制状态 ======================
  private isShapeDrawing: boolean = false // 是否正在绘制形状
  private shapeStartUiX: number = 0 // 形状起点 X（UI）
  private shapeStartUiY: number = 0 // 形状起点 Y
  private isFreeDrawing: boolean = false // 是否处于自由绘制
  private freeLastUiX: number = 0 // 自由绘制上一个点 X
  private freeLastUiY: number = 0 // 自由绘制上一个点 Y
  // ====================== 自由绘制缓冲 ======================
  private freeDrawBuffer: Uint8Array | null = null // 像素数据缓存
  private freeDrawArrayBuffer: ArrayBuffer | null = null // ArrayBuffer 引用
  private freeDrawByteLength: number = 0 // 缓冲区长度
  private freeBufferReady: boolean = false // 缓冲是否就绪
  // ====================== 图像辅助参数 ======================
  @State imageDiag: number = 0 // 当前底图对角线长度（用于缩放画笔）
  // ====================== 协作相关 ======================
  private collabClient: CollabClient = new CollabClient(
    'ws://101.43.185.73:8080/collab'// 协作服务器地址
  )
  @State localClientId: string = '' // 服务器分配的 clientId
  @State localColor: string = '#000000' // 本机代表色
  @State onlineUsers: Array<OnlineUserInfo> = [] // 当前在线用户列表
  private clientId: string = 'client-' + Date.now().toString() // 本机唯一 clientId
  // ====================== 协作用户配色 ======================
  private userColorPalette: Array<string> = [// 协作用户颜色池
    '#2563EB',
    '#EC4899',
    '#10B981',
    '#F97316',
    '#A855F7',
  ]
  private nextColorIndex: number = 0 // 下一个分配颜色索引
  // ====================== 协作状态与日志 ======================
  @State collabEnabled: boolean = false // 是否启用协作
  @State showOpLog: boolean = false // 是否显示操作日志
  @State opLogList: Array<OperationLogItem> = [] // 操作日志列表
  private opSeq: number = 0 // 操作日志自增序号
  private lastOpDesc: string = '' // 上一次协作操作描述

  // ====== 生命周期：页面出现时初始化 / 关闭 WebSocket ======
  aboutToAppear(): void {
    // 设置 WebSocket 的各类回调
    this.collabClient.setCallbacks(
      // WebSocket 连接成功回调
      () => {
        console.log('[Collab] WebSocket open');

        // 如果当前未开启协作，立即断开连接
        if (!this.collabEnabled) {
          this.collabClient.close();
          return;
        }

        // 连接成功后先清空在线用户列表
        this.onlineUsers = [];
      },
      // WebSocket 关闭回调
      () => {
        console.log('[Collab] WebSocket close');
        this.onlineUsers = []; // 清空在线用户
        this.localClientId = ''; // 重置本机 clientId
      },
      // WebSocket 消息回调
      (msg: CollabMessage) => {
        console.log('[Collab] message = ' + JSON.stringify(msg));

        // 如果是其他客户端发来的消息，确保其在在线用户列表中
        if (msg.clientId && msg.clientId !== this.clientId) {
          this.ensureRemoteUser(msg.clientId);
        }

        // ========== ① 处理服务器分配 clientId ==========
        if (msg.type === 'assignId') {
          const payload = msg.payload as CollabAssignIdPayload | undefined;

          // 保存服务器分配给本机的正式 clientId
          this.localClientId = msg.clientId ?? '';

          // 优先使用服务器指定的用户颜色
          const color: string =
            (payload && payload.displayColor) ||
            this.pickColorForClient(this.localClientId || this.clientId);

          this.localColor = color;

          // 构造本机用户信息
          const selfUser: OnlineUserInfo = {
            clientId: this.localClientId || this.clientId,
            displayColor: color,
            isSelf: true
          };

          // 将自己加入在线用户列表
          this.onlineUsers = [selfUser];

          console.info('[Collab] assigned id = ' + this.localClientId);
          return; // assignId 消息处理完后直接结束
        }

        // ========== ② 更新在线用户列表 ==========
        if (msg.type === 'onlineUsers') {
          const payload = msg.payload as OnlineUsersPayload;

          // 用服务器下发的在线用户列表整体刷新本地状态
          this.onlineUsers = payload.users.map((u: OnlineUserItem): OnlineUserInfo => {
            const info: OnlineUserInfo = {
              clientId: u.clientId,
              displayColor: u.displayColor,
              isSelf: u.clientId === this.localClientId
            };
            return info;
          });
        }

        // ========== ③ 处理远端清空画布 ==========
        if (msg.type === 'clear') {
          console.log('[Collab] remote clear layer, do resetView()');
          this.resetView(); // 清空本地画布视图

          // 仅记录其他用户触发的清空操作
          const selfId: string = this.localClientId || this.clientId;
          if (msg.clientId && msg.clientId !== selfId) {
            this.appendOpLog(msg.clientId, '清空画布');
          }
        }

        // ========== ④ 处理图片同步消息 ==========
        if (msg.type === 'imageSync') {
          const payload = msg.payload as CollabImageSyncPayload;
          console.info('[Collab] receive image-sync from: ' + msg.clientId);

          // 跳过自己发送的同步回显，只记录远端操作
          const selfId: string = this.localClientId || this.clientId;
          if (msg.clientId && msg.clientId !== selfId) {
            const desc: string = payload.opDesc ?? '更新了画布';
            this.appendOpLog(msg.clientId, desc);
          }

          // 应用远端同步过来的图片数据
          this.applyRemoteImage(payload).then(() => {
            console.info('[Collab] remote image applied');
            promptAction.showToast({ message: '已加载协作图片' });
          });
        }

        // 其他协作消息类型在这里继续扩展
      },
      // WebSocket 错误回调
      (err: string) => {
        console.error('[Collab] error = ' + err);
      }
    );

    // 主动发起 WebSocket 连接
    this.collabClient.connect();
  }

  aboutToDisappear(): void {
    // 页面销毁时记得断开连接
    this.collabClient.close();
  }

  build() {
    Column() {
      Column() {
        Column() {

          // 顶部工具栏
          Column() {
            // === 一级菜单：图片操作 / 形状 / 画笔 / 撤销 / 分享 ===
            Row({ space: 8 }) {
              // 一级按钮：图片操作
              Button('图片操作', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .backgroundColor(this.currentMenu === 'image' ? '#2563EB' : '#EFF6FF')
                .fontColor(this.currentMenu === 'image' ? '#FFFFFF' : '#1D4ED8')
                .onClick(() => {
                  this.currentMenu = this.currentMenu === 'image' ? '' : 'image'
                })

              // 一级按钮：形状
              Button('形状', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .backgroundColor(this.currentMenu === 'shape' ? '#2563EB' : '#EFF6FF')
                .fontColor(this.currentMenu === 'shape' ? '#FFFFFF' : '#1D4ED8')
                .onClick(() => {
                  this.currentMenu = this.currentMenu === 'shape' ? '' : 'shape'
                })

              // 一级按钮：画笔
              Button('画笔', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .backgroundColor(this.currentMenu === 'brush' ? '#2563EB' : '#EFF6FF')
                .fontColor(this.currentMenu === 'brush' ? '#FFFFFF' : '#1D4ED8')
                .onClick(() => {
                  this.currentMenu = this.currentMenu === 'brush' ? '' : 'brush'
                })

              // 新增：一级按钮：分享
              // Button('分享', { type: ButtonType.Capsule })
              //   .height(32)
              //   .fontSize(12)
              //   .backgroundColor(this.currentMenu === 'share' ? '#2563EB' : '#EFF6FF')
              //   .fontColor(this.currentMenu === 'share' ? '#FFFFFF' : '#1D4ED8')
              //   .onClick(() => {
              //     this.currentMenu = this.currentMenu === 'share' ? '' : 'share'
              //   })

              // 一级按钮：加水印
              Button('加水印', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .backgroundColor('#E0F2FE')
                .fontColor('#0369A1')
                .onClick(async () => {
                  await this.addWatermark()
                })


              // 一级按钮：撤销
              Button('撤销', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .backgroundColor('#fff31818')
                .onClick(async () => {
                  await this.undo()
                })
            }
            .width('100%')
            .padding({
              left: 4,
              right: 4,
              top: 4,
              bottom: 4
            })
            .justifyContent(FlexAlign.Center)

            // === 二级菜单区域：根据 currentMenu 决定显示哪一行 ===
            if (this.currentMenu === 'image') {
              // 图片操作：带横向滚动条
              Scroll() {
                Row({ space: 8 }) {
                  Button('裁剪', { type: ButtonType.Capsule })
                    .height(32)
                    .fontSize(12)
                    .backgroundColor(this.cropMode ? '#EF4444' : '#EFF6FF')
                    .fontColor(this.cropMode ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => {
                      if (!this.pixelMap) {
                        // 不进入裁剪模式，但调用 doCrop，让 doCrop 自己弹出 toast
                        this.doCrop()
                        return
                      }

                      this.cropMode = !this.cropMode
                      if (this.cropMode) {
                        this.cropStartX = 0
                        this.cropStartY = 0
                        this.cropEndX = 0
                        this.cropEndY = 0
                      }
                    })

                  // 二级按钮统一用 Normal + 浅灰背景，与一级区分
                  Button('对比度+', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor('#F3F4F6')
                    .fontColor('#374151')
                    .onClick(() => this.adjustContrast(0.1))

                  Button('对比度-', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor('#F3F4F6')
                    .fontColor('#374151')
                    .onClick(() => this.adjustContrast(-0.1))

                  Button('左旋90°', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor('#F3F4F6')
                    .fontColor('#374151')
                    .onClick(() => this.rotateLeft90())

                  Button('右旋90°', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor('#F3F4F6')
                    .fontColor('#374151')
                    .onClick(() => this.rotateRight90())

                  Button('变亮', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor('#F3F4F6')
                    .fontColor('#374151')
                    .onClick(() => this.adjustBrightness(0.05))

                  Button('变暗', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor('#F3F4F6')
                    .fontColor('#374151')
                    .onClick(() => this.adjustBrightness(-0.05))
                }
                .height(32)
                .padding({ left: 4, right: 4 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .width('100%')
              .padding({ bottom: 8 }) // 二级菜单和画布之间留一点空隙
            } else if (this.currentMenu === 'shape') {
              Scroll() {
                Row({ space: 8 }) {

                  Button('点', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Point ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Point ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.selectShape(ShapeTool.Point))

                  Button('直线', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Line ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Line ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.selectShape(ShapeTool.Line))

                  Button('矩形', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Rect ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Rect ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.selectShape(ShapeTool.Rect))

                  Button('圆', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Circle ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Circle ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.selectShape(ShapeTool.Circle))

                  Button('椭圆', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Ellipse ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Ellipse ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.selectShape(ShapeTool.Ellipse))

                  Button('线条', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.FreeDraw ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.FreeDraw ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.selectShape(ShapeTool.FreeDraw))

                }
                .height(32)
                .padding({ left: 4, right: 4 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .width('100%')
              .padding({ bottom: 8 })

            } else if (this.currentMenu === 'brush') {
              Scroll() {
                Column() {
                  // ===== 粗细调节 Slider =====
                  Row({ space: 8 }) {
                    Text('粗细')
                      .fontSize(11)
                      .fontColor('#4B5563')
                      .width(36)

                    Slider({
                      value: this.strokeWidth,
                      min: 1,
                      max: 40,
                      step: 1
                    })
                      .width('60%')
                      .onChange((value: number) => {
                        this.strokeWidth = value
                      })

                    Text(`${this.strokeWidth.toFixed(0)} px`)
                      .fontSize(10)
                      .fontColor('#6B7280')
                      .width(40)
                  }
                  .height(32)
                  .padding({ left: 4, right: 4, bottom: 4 })
                  .alignItems(VerticalAlign.Center)


                  // ===== 透明度 Slider =====
                  Row({ space: 8 }) {
                    Text('透明度')
                      .fontSize(11)
                      .fontColor('#4B5563')
                      .width(36)

                    Slider({
                      value: this.strokeOpacity,
                      min: 0.1, // 最低 10%，防止完全看不见
                      max: 1.0,
                      step: 0.05
                    })
                      .width('60%')
                      .onChange((value: number) => {
                        this.strokeOpacity = value
                      })

                    Text(`${Math.round(this.strokeOpacity * 100)}%`)
                      .fontSize(10)
                      .fontColor('#6B7280')
                      .width(40)
                  }
                  .height(32)
                  .padding({ left: 4, right: 4, bottom: 4 })
                  .alignItems(VerticalAlign.Center)


                  // ---- 颜色预览 ----
                  Row() {
                    // ===== 橡皮擦 =====
                    Row({ space: 8 }) {
                      Button('橡皮擦', { type: ButtonType.Normal })
                        .height(28)
                        .fontSize(11)
                        .backgroundColor(this.currentBrush === BrushTool.Eraser ? '#FB923C' : '#FEF3C7')
                        .fontColor(this.currentBrush === BrushTool.Eraser ? '#FFFFFF' : '#92400E')
                        .onClick(() => {
                          if (this.currentBrush === BrushTool.Eraser) {
                            // 再点一次：关闭橡皮擦，恢复普通画笔
                            this.currentBrush = BrushTool.Pen
                            // 自由画保持不变，用户可以继续用普通画笔自由画
                          } else {
                            // 第一次点：开启橡皮擦 + 进入自由绘制模式
                            this.currentBrush = BrushTool.Eraser
                            this.currentShape = ShapeTool.FreeDraw
                          }
                        })

                    }
                    .height(32)
                    .padding({ left: 4, right: 4, bottom: 4 })

                    ColorWheelPicker({
                      strokeR: $strokeR,
                      strokeG: $strokeG,
                      strokeB: $strokeB
                    }).margin({ top: 6 })

                    Text('当前颜色预览').fontSize(14)

                    Blank()
                      .width(24)
                      .height(24)
                      .backgroundColor(
                        // strokeR/G/B 是 0~255，需要组装成 0xAARRGGBB
                        (0xFF000000 +
                          (this.strokeR << 16) +
                          (this.strokeG << 8) +
                        this.strokeB)
                      )
                      .border({ width: 1, color: '#111827' })
                      .margin({ left: 8 })
                  }

                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .width('100%')
              .padding({ bottom: 8 })
            }

          }


          // ===== 顶部：在线协作条 =====
          // 顶部：协作 & 在线用户栏
          Row({ space: 8 }) {
            // 左侧：协作按钮
            Button(this.collabEnabled ? '断开协作' : '加入协作', { type: ButtonType.Capsule })
              .height(24)
              .fontSize(10)
              .backgroundColor(this.collabEnabled ? '#FEE2E2' : '#DCFCE7')
              .fontColor(this.collabEnabled ? '#B91C1C' : '#166534')
              .onClick(() => {
                if (this.collabEnabled) {
                  this.collabEnabled = false
                  this.collabClient.close()
                  this.onlineUsers = []
                  promptAction.showToast({ message: '已断开协作' })
                } else {
                  this.collabEnabled = true
                  this.collabClient.connect()
                  promptAction.showToast({ message: '正在加入协作...' })
                }
              })

            // 操作记录按钮
            Button(this.showOpLog ? '收起记录' : '操作记录', { type: ButtonType.Capsule })
              .height(22)
              .fontSize(10)
              .backgroundColor(this.showOpLog ? '#DBEAFE' : '#E5E7EB')
              .fontColor('#111827')
              .onClick(() => {
                this.showOpLog = !this.showOpLog
              })

            // 在线用户区域整体放到一个水平 Scroll 里
            // 这样当用户很多时可以左右滑动
            Scroll() {
              Row({ space: 4 }) {
                // 中间标题：“在线：”
                Text('在线：')
                  .fontSize(10)
                  .fontColor('#6B7280')

                // 在线用户标签
                Row({ space: 4 }) {
                  ForEach(this.onlineUsers, (u: OnlineUserInfo) => {
                    Row() {
                      // 彩色小方块
                      Rect()
                        .width(8)
                        .height(8)
                        .radius(2)
                        .fill(u.displayColor)
                        .margin({ right: 4 })

                      Text(u.isSelf ? '我(' + u.clientId + ')' : u.clientId)
                        .fontSize(10)
                        .fontColor('#111827')
                    }
                    .padding({
                      left: 6,
                      right: 6,
                      top: 2,
                      bottom: 2
                    })
                    .backgroundColor(u.isSelf ? '#DBEAFE' : '#E5E7EB')
                    .borderRadius(999)
                  }, (u: OnlineUserInfo) => u.clientId)
                }
              }
              .height(26)
            }
            .scrollable(ScrollDirection.Horizontal) // 水平滚动
            .layoutWeight(1) // 占据剩余空间，自适应压缩，不撑开左侧按钮
          }
          .justifyContent(FlexAlign.Start) // 整行靠左排
          .alignItems(VerticalAlign.Center) // 垂直居中
          .padding({
            left: 12,
            right: 12,
            top: 4,
            bottom: 4
          })
          .backgroundColor('#F9FAFB')

          // ===== 操作记录区域 =====
          if (this.showOpLog) {
            Column() {
              Scroll() {
                Column({ space: 4 }) {
                  ForEach(this.opLogList, (item: OperationLogItem) => {
                    Row() {
                      // 左侧用户颜色块
                      Rect()
                        .width(10)
                        .height(10)
                        .radius(2)
                        .fill(item.userColor)
                        .margin({ right: 6 })

                      // 中间文本：时间 + 用户 + 操作内容
                      Column({ space: 2 }) {
                        Text(`[${item.timestamp}] ${item.userId}`)
                          .fontSize(11)
                          .fontColor('#4B5563')

                        Text(item.message)
                          .fontSize(11)
                          .fontColor('#111827')
                      }
                    }
                    .padding({
                      left: 8,
                      right: 8,
                      top: 4,
                      bottom: 4
                    })
                    .backgroundColor('#FFFFFF')
                    .borderRadius(6)
                  }, (item: OperationLogItem) => item.id.toString())
                }
              }
              .width('100%')
              .height(120) // 固定高度，内部可滚动

              // 底部一条淡灰线
              Divider().strokeWidth(0.5).color('#E5E7EB')
            }
            .padding({ left: 12, right: 12, bottom: 6 })
            .backgroundColor('#F3F4F6')
          }


          // 画布
          Stack() {
            if (!this.pixelMap) {
              Column() {
                Text('点击“打开图片”开始编辑')
                  .fontSize(14)
                  .fontColor('#9AA1A8')
                  .letterSpacing(0.5)
              }
              .width('100%').height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            } else {
              // =======================
              // 1. 图片显示层（底图）
              // =======================
              Image(this.pixelMap)
                .id(`img-${this.pixelVersion}`)
                .objectFit(ImageFit.Contain)
                .width('100%')
                .height('100%')
                .scale({ x: this.zoom, y: this.zoom })
                .translate({ x: this.offsetX, y: this.offsetY })
                .colorFilter(this.buildToneMatrix())

              // =======================
              // 1.5 绘制图层（叠加）
              // =======================
              if (this.drawPixelMap) {
                Image(this.drawPixelMap)
                  .id(`draw-${this.drawPixelVersion}`)
                  .objectFit(ImageFit.Contain)
                  .width('100%')
                  .height('100%')
                  .scale({ x: this.zoom, y: this.zoom })
                  .translate({ x: this.offsetX, y: this.offsetY })
              }


              // ==========================
              // 2. 拖拽 & 缩放手势层（不是裁剪时生效）
              // ==========================
              if (!this.cropMode) {
                Stack()
                  .width('100%')
                  .height('100%')
                  .backgroundColor(Color.Transparent)
                  .hitTestBehavior(HitTestMode.Transparent)
                  .gesture(
                    GestureGroup(GestureMode.Parallel,

                      // 点击：画点
                      TapGesture()
                        .onAction((ev: GestureEvent) => {
                          if (!ev.fingerList || ev.fingerList.length === 0) {
                            return
                          }
                          const finger = ev.fingerList[0]
                          const x: number = finger.localX
                          const y: number = finger.localY

                          console.info(`>>> tap at x=${x}, y=${y}`)

                          if (this.currentShape === ShapeTool.Point) {
                            this.drawPointAtUi(x, y)
                          }
                        }),

                      // 拖拽：平移 / 直线 / 矩形 / 圆 / 椭圆 / 自由画
                      PanGesture({ direction: PanDirection.All })
                        .onActionStart(e => {
                          if (!e.fingerList || e.fingerList.length === 0) {
                            return
                          }
                          const f = e.fingerList[0]

                          if (this.currentShape === ShapeTool.FreeDraw) {
                            this.isFreeDrawing = true
                            this.freeLastUiX = f.localX
                            this.freeLastUiY = f.localY

                            // 异步准备 buffer（不能 await）
                            this.prepareFreeDrawBuffer()

                            // 存一次快照方便撤销整笔
                            if (this.pixelMap) {
                              this.clonePixelMap(this.pixelMap as image.PixelMap)
                                .then(pmBackup => this.pushHistorySnapshot(true, pmBackup))
                            }
                            return
                          }


                          // 情况 2：直线 / 矩形 / 圆 / 椭圆：拖出一个形状
                          if (this.currentShape === ShapeTool.Line ||
                            this.currentShape === ShapeTool.Rect ||
                            this.currentShape === ShapeTool.Circle ||
                            this.currentShape === ShapeTool.Ellipse) {
                            this.isShapeDrawing = true
                            this.shapeStartUiX = f.localX
                            this.shapeStartUiY = f.localY
                            console.info(`>>> shape start ui=(${this.shapeStartUiX}, ${this.shapeStartUiY})`)
                            return
                          }

                          // 情况 3：其他情况 → 当成平移画布
                          this.lastPanX = this.offsetX
                          this.lastPanY = this.offsetY
                        })
                        .onActionUpdate(e => {
                          if (!e.fingerList || e.fingerList.length === 0) {
                            return
                          }
                          const f = e.fingerList[0]

                          if (this.isFreeDrawing && this.currentShape === ShapeTool.FreeDraw) {
                            this.drawFreeStrokeSegmentSync(
                              this.freeLastUiX,
                              this.freeLastUiY,
                              f.localX,
                              f.localY
                            )

                            this.freeLastUiX = f.localX
                            this.freeLastUiY = f.localY
                            return
                          }

                          // 正在画图形（线 / 矩形 / 圆 / 椭圆）时，不平移
                          if (this.isShapeDrawing &&
                            (this.currentShape === ShapeTool.Line ||
                              this.currentShape === ShapeTool.Rect ||
                              this.currentShape === ShapeTool.Circle ||
                              this.currentShape === ShapeTool.Ellipse)) {
                            return
                          }

                          // 否则：平移画布
                          this.offsetX = this.lastPanX + e.offsetX
                          this.offsetY = this.lastPanY + e.offsetY
                        })
                        .onActionEnd((e: GestureEvent) => {
                          // 自由画结束
                          if (this.isFreeDrawing && this.currentShape === ShapeTool.FreeDraw) {
                            this.handleFreeDrawEnd()
                            return
                          }

                          // 图形结束
                          if (!e.fingerList || e.fingerList.length === 0) {
                            this.isShapeDrawing = false
                            return
                          }

                          const f = e.fingerList[0]

                          const endUiX: number = f.localX
                          const endUiY: number = f.localY


                          // 图形结束：直线 / 矩形 / 圆 / 椭圆
                          if (this.isShapeDrawing &&
                            (this.currentShape === ShapeTool.Line ||
                              this.currentShape === ShapeTool.Rect ||
                              this.currentShape === ShapeTool.Circle ||
                              this.currentShape === ShapeTool.Ellipse)) {

                            this.isShapeDrawing = false

                            if (this.currentShape === ShapeTool.Line) {
                              this.handleLineDrag(this.shapeStartUiX, this.shapeStartUiY, endUiX, endUiY)
                            } else if (this.currentShape === ShapeTool.Rect) {
                              this.handleRectDrag(this.shapeStartUiX, this.shapeStartUiY, endUiX, endUiY)
                            } else if (this.currentShape === ShapeTool.Circle) {
                              this.handleCircleDrag(this.shapeStartUiX, this.shapeStartUiY, endUiX, endUiY)
                            } else if (this.currentShape === ShapeTool.Ellipse) {
                              this.handleEllipseDrag(this.shapeStartUiX, this.shapeStartUiY, endUiX, endUiY)
                            }
                          }
                        }),
                      // 缩放：保持原来的逻辑
                      PinchGesture()
                        .onActionStart(e => {
                          this.lastZoom = this.zoom
                        })
                        .onActionUpdate(e => {
                          let next = this.lastZoom * e.scale
                          this.zoom = Math.min(5, Math.max(0.3, next))
                        })
                    )
                  )
              }


              // === 裁剪模式 ===
              if (this.cropMode) {
                // 手势：拖出裁剪框
                Stack()
                  .width('100%')
                  .height('100%')
                  .backgroundColor(Color.Transparent)
                  .gesture(
                    PanGesture({ direction: PanDirection.All })
                      .onActionStart(ev => {
                        const f = ev.fingerList[0]
                        this.cropStartX = f.localX
                        this.cropStartY = f.localY
                        this.cropEndX = f.localX
                        this.cropEndY = f.localY
                      })
                      .onActionUpdate(ev => {
                        const f = ev.fingerList[0]
                        this.cropEndX = f.localX
                        this.cropEndY = f.localY
                      })
                      .onActionEnd(() => {
                        this.doCrop()
                      })
                  )

                // 画裁剪框（UI）
                Rect()
                  .position({
                    x: Math.min(this.cropStartX, this.cropEndX),
                    y: Math.min(this.cropStartY, this.cropEndY)
                  })
                  .width(Math.abs(this.cropEndX - this.cropStartX))
                  .height(Math.abs(this.cropEndY - this.cropStartY))
                  .stroke(Color.Red)
                  .strokeWidth(2)
                  .fill('rgba(255,0,0,0.18)')
              }

            }
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(2)
          .clip(true)
          .onAreaChange((oldArea, newArea) => {
            this.canvasWidth = Number(newArea.width)
            this.canvasHeight = Number(newArea.height)
          })


          // 底部工具栏
          Row({ space: 10 }) {
            Text('鸿绘')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#6B7280')
              .layoutWeight(1)

            Button('打开图片', { type: ButtonType.Capsule })
              .height(40).padding({ left: 14, right: 14 })
              .onClick(() => this.pickImage())

            SaveButton({
              icon: SaveIconStyle.FULL_FILLED,
              text: SaveDescription.SAVE_IMAGE,
              buttonType: ButtonType.Capsule
            })
              .height(40)
              .padding({ left: 14, right: 14 })
              .onClick(async (event, result: SaveButtonOnClickResult) => {
                if (result === SaveButtonOnClickResult.SUCCESS) {
                  // 用户点了保存按钮，系统临时授予相册写入权限（约 5 秒）
                  await this.saveImage()
                } else {
                  promptAction.showToast({ message: '授权失败，无法保存' })
                }
              })

            Button('重置', { type: ButtonType.Capsule })
              .height(40)
              .padding({ left: 14, right: 14 })
              .backgroundColor('#EEF2FF')
              .fontColor('#3B82F6')
              .onClick(() => {
                this.resetView();

                if (this.collabClient.connected) {
                  const senderId: string = this.localClientId || this.clientId;

                  const msg: CollabMessage = buildClearMessage(
                    senderId,
                    'main-layer'
                  );
                  this.collabClient.send(msg);
                } else {
                  console.error('[Collab] not connected, skip sRend clear');
                }
              })
          }
          .width('100%')
          .padding({
            left: 12,
            right: 12,
            top: 10,
            bottom: 10
          })
          .backgroundColor('#F7F8FA')
          .border({ width: { top: 0.5 }, color: '#E5E7EB' })
          .alignItems(VerticalAlign.Center)

        }
        .width('100%').height('100%')
        .backgroundColor('#FFFFFF')
        .padding(12)
      }
    }
  }

  // 统一拿“通道在像素里的位置”。
  // 不同 PixelFormat 下，一个像素的 4 个字节顺序不一样（RGBA / BGRA / ARGB）。
  // 以后凡是读写 buffer，都先调这个函数拿到 r/g/b/a 的偏移，避免到处写 switch。
  private getChannelOrder(fmt: image.PixelMapFormat): ChannelOrder {
    // 默认按 RGBA：R=0, G=1, B=2, A=3（每像素 4 字节）
    let order: ChannelOrder = {
      r: 0,
      g: 1,
      b: 2,
      a: 3,
      bytesPerPixel: 4
    }

    switch (fmt) {
      case image.PixelMapFormat.BGRA_8888:
        // BGRA：B,G,R,A
        order = {
          r: 2,
          g: 1,
          b: 0,
          a: 3,
          bytesPerPixel: 4
        }
        break
      case image.PixelMapFormat.ARGB_8888:
        // ARGB：A,R,G,B
        order = {
          r: 1,
          g: 2,
          b: 3,
          a: 0,
          bytesPerPixel: 4
        }
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
      // RGBA：R,G,B,A
        order = {
          r: 0,
          g: 1,
          b: 2,
          a: 3,
          bytesPerPixel: 4
        }
        break
    }

    return order
  }

  private applyOverlayByAlpha(
    baseData: Uint8Array,
    overlayData: Uint8Array,
    width: number,
    height: number,
    baseCh: ChannelOrder,
    overCh: ChannelOrder
  ): void {
    const bpp: number = baseCh.bytesPerPixel

    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const idx: number = (y * width + x) * bpp

        const oaIdx: number = idx + overCh.a
        const alphaOver: number = overlayData[oaIdx]
        if (alphaOver === 0) {
          continue
        }

        baseData[idx + baseCh.r] = overlayData[idx + overCh.r]
        baseData[idx + baseCh.g] = overlayData[idx + overCh.g]
        baseData[idx + baseCh.b] = overlayData[idx + overCh.b]
        baseData[idx + baseCh.a] = alphaOver
      }
    }
  }

  // 把logo图片变成pixelMap
  private async loadLogoPixelMap(): Promise<image.PixelMap> {
    // 获取当前 UIAbility 的上下文
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // 从上下文中拿资源管理器
    const resMgr = context.resourceManager;

    // 获取 logo 图片资源的 id
    const logoId: number = $r('app.media.logo').id;

    // 从资源中读取图片的二进制数据
    const fileData: Uint8Array = await resMgr.getMediaContent(logoId);

    // 只截取 Uint8Array 实际有效的数据范围，避免 buffer 中的多余字节
    const buffer: ArrayBuffer = fileData.buffer.slice(
      fileData.byteOffset,
      fileData.byteOffset + fileData.byteLength
    );

    // 使用图片二进制数据创建 ImageSource
    const imgSource: image.ImageSource = image.createImageSource(buffer);
    // 从 ImageSource 生成可编辑的 PixelMap
    const logoPm: image.PixelMap = await imgSource.createPixelMap({
      editable: true
    });
    // 释放 ImageSource，避免资源泄漏
    imgSource.release?.();

    // 返回生成的 PixelMap
    return logoPm;
  }

  // 在绘制层上，把 watermarkPm 按 (offsetX, offsetY) 的位置贴上去
  private async pasteWatermarkIntoLayer(
    layerPm: image.PixelMap,
    watermarkPm: image.PixelMap,
    offsetX: number,
    offsetY: number
  ): Promise<void> {

    // 拿到绘制层和水印各自的图像信息（尺寸、像素格式等）
    const layerInfo: image.ImageInfo = await layerPm.getImageInfo()
    const wmInfo: image.ImageInfo = await watermarkPm.getImageInfo()

    // 绘制层的宽高
    const layerW: number = layerInfo.size.width
    const layerH: number = layerInfo.size.height

    // 水印的宽高
    const wmW: number = wmInfo.size.width
    const wmH: number = wmInfo.size.height

    // 任意一边尺寸异常，说明没法画，直接返回
    if (wmW <= 0 || wmH <= 0 || layerW <= 0 || layerH <= 0) {
      console.info('>>> pasteWatermarkIntoLayer: invalid size, skip')
      return
    }

    // 计算两张图各自需要的像素缓冲区大小
    const layerLen: number = layerPm.getPixelBytesNumber()
    const wmLen: number = watermarkPm.getPixelBytesNumber()

    // 为绘制层和水印各自申请一块内存，用来读像素
    const layerBuf: ArrayBuffer = new ArrayBuffer(layerLen)
    const wmBuf: ArrayBuffer = new ArrayBuffer(wmLen)

    // 把 PixelMap 里的像素读进内存 buffer
    await layerPm.readPixelsToBuffer(layerBuf)
    await watermarkPm.readPixelsToBuffer(wmBuf)

    // 用 Uint8Array 方便按字节读写 RGBA
    const layerData: Uint8Array = new Uint8Array(layerBuf)
    const wmData: Uint8Array = new Uint8Array(wmBuf)

    // 根据各自的 pixelFormat，拿到正确的 RGBA 通道顺序
    const layerCh: ChannelOrder = this.getChannelOrder(layerInfo.pixelFormat)
    const wmCh: ChannelOrder = this.getChannelOrder(wmInfo.pixelFormat)

    // 绘制层中 R/G/B/A 在一个像素里的偏移
    const lrOff: number = layerCh.r
    const lgOff: number = layerCh.g
    const lbOff: number = layerCh.b
    const laOff: number = layerCh.a

    // 水印中 R/G/B/A 在一个像素里的偏移
    const wrOff: number = wmCh.r
    const wgOff: number = wmCh.g
    const wbOff: number = wmCh.b
    const waOff: number = wmCh.a

    // 开始逐像素遍历水印
    for (let wy: number = 0; wy < wmH; wy++) {

      // 计算水印这一行对应到绘制层上的 y 坐标
      const ty: number = offsetY + wy
      if (ty < 0 || ty >= layerH) {
        continue // 超出绘制层范围，跳过
      }

      for (let wx: number = 0; wx < wmW; wx++) {

        // 计算水印这一列对应到绘制层上的 x 坐标
        const tx: number = offsetX + wx
        if (tx < 0 || tx >= layerW) {
          continue // 超出绘制层范围，跳过
        }

        // 当前水印像素在水印 buffer 中的起始索引
        const wmIdx: number = (wy * wmW + wx) * 4

        // 取水印像素的 alpha
        const waIdx: number = wmIdx + waOff
        const alpha: number = wmData[waIdx]

        // 水印这个点是完全透明的，就什么都不做
        if (alpha === 0) {
          continue
        }

        // 当前目标像素在绘制层 buffer 中的起始索引
        const baseIdx: number = (ty * layerW + tx) * 4

        // 绘制层中 RGBA 的实际索引
        const lrIdx: number = baseIdx + lrOff
        const lgIdx: number = baseIdx + lgOff
        const lbIdx: number = baseIdx + lbOff
        const laIdx: number = baseIdx + laOff

        // 水印中 RGB 的实际索引
        const wrIdx: number = wmIdx + wrOff
        const wgIdx: number = wmIdx + wgOff
        const wbIdx: number = wmIdx + wbOff

        // 简单规则：只要水印不透明，就直接覆盖绘制层的颜色
        layerData[lrIdx] = wmData[wrIdx]
        layerData[lgIdx] = wmData[wgIdx]
        layerData[lbIdx] = wmData[wbIdx]
        layerData[laIdx] = alpha
      }
    }

    // 把改完的像素数据写回绘制层 PixelMap
    await layerPm.writeBufferToPixels(layerBuf)
  }

  // 把水印缩放到不超过 targetWidth x targetHeight 的大小（保持原来的宽高比例）
  private async resizeWatermark(
    watermarkPm: image.PixelMap,
    targetWidth: number,
    targetHeight: number
  ): Promise<image.PixelMap> {

    // 读取水印图片的基本信息（主要是宽高、像素格式）
    const wmInfo: image.ImageInfo = await watermarkPm.getImageInfo()
    const srcW: number = wmInfo.size.width
    const srcH: number = wmInfo.size.height

    // 如果水印本身就已经比目标尺寸小，就没必要缩放，直接用原图
    if (srcW <= targetWidth && srcH <= targetHeight) {
      return watermarkPm
    }

    // 计算横向和纵向分别需要缩放多少
    const scaleX: number = targetWidth / srcW
    const scaleY: number = targetHeight / srcH

    // 取较小的那个比例，保证缩放后既不超宽也不超高
    const scale: number = Math.min(scaleX, scaleY)

    // 根据缩放比例算出新的宽高，至少保证是 1 像素
    const newW: number = Math.max(1, Math.floor(srcW * scale))
    const newH: number = Math.max(1, Math.floor(srcH * scale))

    // 读取原始水印的全部像素数据到内存
    const srcLen: number = watermarkPm.getPixelBytesNumber()
    const srcBuf: ArrayBuffer = new ArrayBuffer(srcLen)
    await watermarkPm.readPixelsToBuffer(srcBuf)
    const srcData: Uint8Array = new Uint8Array(srcBuf)

    // 为缩放后的新图像准备一块 RGBA 的像素缓冲区
    const dstBuf: ArrayBuffer = new ArrayBuffer(newW * newH * 4)
    const dstData: Uint8Array = new Uint8Array(dstBuf)

    // 根据水印的像素格式，确定 R/G/B/A 在一个像素里的位置
    // 这样下面读像素时就不会搞错通道顺序
    const srcCh: ChannelOrder = this.getChannelOrder(wmInfo.pixelFormat)
    const srOff: number = srcCh.r
    const sgOff: number = srcCh.g
    const sbOff: number = srcCh.b
    const saOff: number = srcCh.a
    const srcBpp: number = srcCh.bytesPerPixel // 每个像素占多少字节（这里是 4）

    // 使用“最近邻”方式缩放：
    // 新图中的每一个像素，直接去原图里找一个最接近的像素来用
    for (let dy: number = 0; dy < newH; dy++) {

      // 计算新图 y 对应原图的 y
      const srcY: number = Math.min(srcH - 1, Math.floor(dy / scale))

      for (let dx: number = 0; dx < newW; dx++) {

        // 计算新图 x 对应原图的 x
        const srcX: number = Math.min(srcW - 1, Math.floor(dx / scale))

        // 原图中这个像素在 buffer 里的起始位置
        const srcIndex: number = (srcY * srcW + srcX) * srcBpp

        // 读出原图这个像素的 RGBA
        const r: number = srcData[srcIndex + srOff]
        const g: number = srcData[srcIndex + sgOff]
        const b: number = srcData[srcIndex + sbOff]
        const a: number = srcData[srcIndex + saOff]

        // 新图中这个像素在 buffer 里的起始位置（固定 RGBA）
        const dstIndex: number = (dy * newW + dx) * 4

        // 把颜色写进新图
        dstData[dstIndex + 0] = r
        dstData[dstIndex + 1] = g
        dstData[dstIndex + 2] = b
        dstData[dstIndex + 3] = a
      }
    }

    // 用刚刚生成的 RGBA 像素数据，创建一张新的 PixelMap
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: newW, height: newH }
    }

    // 返回缩放后的水印 PixelMap
    const resizedPm: image.PixelMap = await image.createPixelMap(dstBuf, opts)
    return resizedPm
  }

  // 给当前图片添加一个水印（贴在绘制图层上）
  private async addWatermark(): Promise<void> {

    // 如果还没打开图片，就没地方加水印
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    // 在真正修改图片前，先存一份完整快照，方便后面撤销
    await this.pushFullSnapshotBeforeChange()

    // 确保当前存在“绘制图层”（水印只画在这个层上，不改底图）
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      promptAction.showToast({ message: '当前没有可编辑图层' })
      return
    }

    // 读取内置的水印图片（logo）
    const logoPm: image.PixelMap = await this.loadLogoPixelMap()

    // 把水印缩放到一个合适的大小，避免原图太大
    const resizedLogoPm: image.PixelMap =
      await this.resizeWatermark(logoPm, 100, 100)

    // 读取绘制图层的尺寸，用来计算水印放在哪
    const layerInfo: image.ImageInfo = await layerPm.getImageInfo()
    const layerW: number = layerInfo.size.width
    const layerH: number = layerInfo.size.height

    // 读取水印图片的实际尺寸
    const watermarkInfo: image.ImageInfo = await resizedLogoPm.getImageInfo()
    const watermarkWidth: number = watermarkInfo.size.width
    const watermarkHeight: number = watermarkInfo.size.height

    // 默认把水印放在右下角，并预留一点边距
    const margin: number = 10
    let offsetX: number = layerW - watermarkWidth - margin
    let offsetY: number = layerH - watermarkHeight - margin

    // 防止水印尺寸过大导致坐标为负数
    if (offsetX < 0) {
      offsetX = 0
    }
    if (offsetY < 0) {
      offsetY = 0
    }

    // 真正把水印像素贴到绘制图层指定位置
    await this.pasteWatermarkIntoLayer(
      layerPm,
      resizedLogoPm,
      offsetX,
      offsetY
    )

    // clone 一份新的 PixelMap，用来触发 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)

    // 释放旧的绘制图层，避免内存泄漏
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }

    // 替换为新的绘制图层
    this.drawPixelMap = newLayer
    this.drawPixelVersion++

    // 记录操作日志，并把这次修改同步给协作用户
    const desc: string = '在右下角添加了水印'
    await this.logAndSyncAfterImageChange(desc)

    // 给用户一个明确的反馈
    promptAction.showToast({ message: '水印已添加' })
  }

  // 根据底图 pm 创建一张“完全透明”的绘制图层
  // 尺寸和像素格式与底图一致，用来专门画线条/水印
  private async createEmptyDrawLayerLike(
    pm: image.PixelMap
  ): Promise<image.PixelMap> {

    // 先复制一份底图，主要是为了拿到相同的尺寸、像素格式，并且保证可编辑
    const layer: image.PixelMap = await this.clonePixelMap(pm)

    // 计算这张图一共占用多少字节
    const byteLength: number = layer.getPixelBytesNumber()

    // 准备一个缓冲区，把像素数据读出来
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layer.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 每 4 个字节是一个像素（RGBA），把所有像素清成透明
    for (let i = 0; i < data.length; i += 4) {
      data[i] = 0 // R
      data[i + 1] = 0 // G
      data[i + 2] = 0 // B
      data[i + 3] = 0 // A：设为 0，表示完全透明
    }

    // 把清空后的像素数据写回 PixelMap
    await layer.writeBufferToPixels(buffer)

    // 返回这张“空白但可画”的绘制图层
    return layer
  }

  // 确保当前有一张“绘制图层”可用：
  // 如果还没有，就新建一张透明的；如果已经有了，直接用现成的
  private async ensureDrawLayer(): Promise<image.PixelMap | undefined> {

    // 如果连底图都没有，说明还没打开图片，没法创建绘制层
    if (!this.pixelMap) {
      return undefined
    }

    // 如果当前还没有绘制图层
    if (!this.drawPixelMap) {

      // 以底图为模板，创建一张尺寸和格式一致的透明图层
      const basePm = this.pixelMap as image.PixelMap
      this.drawPixelMap = await this.createEmptyDrawLayerLike(basePm)

      // 更新版本号，强制 UI 刷新
      this.drawPixelVersion++
    }

    // 返回当前可用的绘制图层
    return this.drawPixelMap as image.PixelMap
  }

  // 克隆一张 PixelMap：通过“先打包成 PNG，再解码”的方式
  // 这是鸿蒙 6.0 下最稳妥、不容易出现颜色变化的做法
  private async clonePixelMap(
    pm: image.PixelMap
  ): Promise<image.PixelMap> {

    // 创建一个图片打包器，用来把 PixelMap 转成二进制数据
    const packer = image.createImagePacker()

    // 打包参数：使用 PNG，无损格式，尽量保证颜色不变
    const packOpts: image.PackingOption = {
      format: 'image/png',
      quality: 100
    }

    // 把原 PixelMap 打包成一段内存里的 PNG 数据
    const buffer: ArrayBuffer = await packer.packToData(pm, packOpts)

    // 用完就释放，避免资源占用
    packer.release?.()

    // 用这段 PNG 数据重新创建一个 ImageSource
    const imgSource = image.createImageSource(buffer)

    // 从 ImageSource 解码出一张新的 PixelMap，并且设置为可编辑
    const clonePm: image.PixelMap = await imgSource.createPixelMap({
      editable: true
    })

    // 解码完成后释放 ImageSource
    imgSource.release?.()

    // 返回这张全新的 PixelMap（内容一样，但内存是独立的）
    return clonePm
  }

  // 在一次“会改变图像或视图状态”的操作之前调用，用来记录一条撤销快照
  // includePixel = true：把传进来的 pmForSnapshot 当作底图快照保存（不再额外 clone）
  // 这个分支主要是给裁剪这种“已经生成新 PixelMap”的操作用
  private async pushHistorySnapshot(
    includePixel: boolean,
    pmForSnapshot?: image.PixelMap
  ): Promise<void> {

    // 底图快照（可能有，也可能没有）
    let snapshotPixel: image.PixelMap | undefined = undefined

    // 绘制图层的快照（单独保存一份，避免后续被继续修改）
    let snapshotDraw: image.PixelMap | undefined = undefined

    // 如果这次操作需要保存底图，并且外面已经给了现成的 PixelMap
    if (includePixel && pmForSnapshot) {
      snapshotPixel = pmForSnapshot
    }

    // 不管底图要不要存，只要当前存在绘制图层，就 clone 一份作为快照
    if (this.drawPixelMap) {
      snapshotDraw = await this.clonePixelMap(this.drawPixelMap as image.PixelMap)
    }

    // 如果当前不是在历史的最末尾（说明用户刚撤销过）
    // 那么再做新操作时，需要把“未来的历史记录”全部丢掉
    if (this.historyIndex >= 0 && this.historyIndex < this.history.length - 1) {
      for (let i = this.historyIndex + 1; i < this.history.length; i++) {
        // 释放被丢弃的底图快照
        this.history[i].pixelMap?.release?.()
        // 释放被丢弃的绘制图层快照
        this.history[i].drawPixelMap?.release?.()
      }
      // 只保留当前 index 之前的历史
      this.history = this.history.slice(0, this.historyIndex + 1)
    }

    // 把当前状态压入历史栈
    this.history.push({
      pixelMap: snapshotPixel, // 底图快照（可能为空）
      drawPixelMap: snapshotDraw, // 绘制图层快照
      zoom: this.zoom, // 当前缩放比例
      offsetX: this.offsetX, // 当前平移 X
      offsetY: this.offsetY, // 当前平移 Y
      brightnessLevel: this.brightnessLevel, // 当前亮度
      contrastLevel: this.contrastLevel, // 当前对比度
      accumulatedRotate: this.accumulatedRotate // 累计旋转角度
    })

    // 更新当前历史指针，指向最新一条
    this.historyIndex = this.history.length - 1
  }

  // 重置到“刚打开图片时”的状态
  private async resetView(): Promise<void> {
    // ① 如果当前根本没有图片，什么都不用做
    if (!this.pixelMap) {
      return;
    }

    // ② 如果没有保存过“原始图片快照”
    // 说明是老逻辑或异常情况，只重置视图参数即可
    if (!this.originalPixelMap) {
      this.zoom = 1.0; // 缩放恢复 100%
      this.offsetX = 0; // 位移清零
      this.offsetY = 0;
      this.brightnessLevel = 0.0; // 亮度恢复默认
      this.contrastLevel = 0.0; // 对比度恢复默认
      this.accumulatedRotate = 0; // 旋转角度清零
      this.pixelVersion++; // 通知 UI 刷新
      return;
    }

    // ③ reset 也是一种“会改图”的操作
    // 所以在真正重置前，先把当前状态存进历史，方便撤销
    const currentPm: image.PixelMap = this.pixelMap as image.PixelMap;
    const beforeResetPm: image.PixelMap = await this.clonePixelMap(currentPm);
    await this.pushHistorySnapshot(true, beforeResetPm);

    // ④ 用“刚打开图片时”的原图，还原底图
    // 这里重新 clone 一份，保证是可编辑的新对象
    const originalPm: image.PixelMap = this.originalPixelMap as image.PixelMap;
    const newPm: image.PixelMap = await this.clonePixelMap(originalPm);

    // 释放当前正在用的底图，避免内存泄漏
    currentPm.release();

    // 用原始图片替换当前底图
    this.pixelMap = newPm;

    // ⑤ 重建绘制图层
    // reset 的含义是：所有画过的东西全部清空
    if (this.drawPixelMap) {
      const currentDrawPm: image.PixelMap = this.drawPixelMap as image.PixelMap;
      currentDrawPm.release();
    }

    // 新建一张“全透明”的绘制层
    const drawLayer: image.PixelMap = await this.createEmptyDrawLayerLike(newPm);
    this.drawPixelMap = drawLayer;
    this.drawPixelVersion++; // 强制让绘制层 Image 重新渲染

    // ⑥ 所有视图参数恢复到初始状态
    this.zoom = 1.0;
    this.offsetX = 0;
    this.offsetY = 0;
    this.brightnessLevel = 0.0;
    this.contrastLevel = 0.0;
    this.accumulatedRotate = 0;

    // ⑦ 通知底图刷新
    this.pixelVersion++;
  }

  // 打开图片：从系统相册选择一张图片并加载到编辑器
  private async pickImage() {
    try {
      // ===== 1. 调起系统选图器 =====
      const picker = new photoAccessHelper.PhotoViewPicker()
      const options = new photoAccessHelper.PhotoSelectOptions()

      // 只允许选择图片
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
      // 最多选一张
      options.maxSelectNumber = 1

      // 等用户操作完成
      const result = await picker.select(options)
      const uris: Array<string> = result.photoUris

      // 用户什么都没选
      if (!uris || uris.length === 0) {
        promptAction.showToast({ message: '未选择图片' })
        return
      }

      // ===== 2. 拿到图片的 URI =====
      const uri: string = uris[0]
      console.info(`>>> Selected URI = ${uri}`)

      // ===== 3. 打开图片文件，拿到 fd =====
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)

      // 用 fd 创建 ImageSource（负责解码图片）
      const imgSource: image.ImageSource = image.createImageSource(file.fd)
      if (!imgSource) {
        await fileIo.close(file)
        throw new Error('createImageSource 返回空')
      }

      // ===== 4. 从 ImageSource 解码成 PixelMap =====
      const pm: image.PixelMap = await imgSource.createPixelMap({
        editable: true // 必须可编辑，后面要改像素
      })

      // 释放底层资源
      imgSource.release?.()
      await fileIo.close(file)

      // ===== 5. 保存“原始图片快照”，用于 reset =====
      if (this.originalPixelMap) {
        this.originalPixelMap.release?.()
      }
      // clone 一份，保证后续 reset 不被污染
      this.originalPixelMap = await this.clonePixelMap(pm)

      // ===== 6. 替换当前正在编辑的图片 =====
      if (this.pixelMap) {
        this.pixelMap.release?.()
      }
      this.pixelMap = pm

      // ===== 7. 初始化视图状态（等同“刚打开图片”）=====
      this.zoom = 1.0
      this.offsetX = 0
      this.offsetY = 0
      this.brightnessLevel = 0.0
      this.contrastLevel = 0.0
      this.accumulatedRotate = 0
      this.pixelVersion++ // 通知 UI 刷新底图

      // ===== 8. 记录图片对角线长度（后续裁剪等功能用）=====
      const openInfo: image.ImageInfo = await pm.getImageInfo()
      const openW: number = openInfo.size.width
      const openH: number = openInfo.size.height
      this.imageDiag = Math.hypot(openW, openH)

      // ===== 9. 为这张图创建一张“透明绘制图层” =====
      // 如果之前有旧的绘制层，先释放
      if (this.drawPixelMap) {
        this.drawPixelMap.release?.()
      }
      // 新建一张和底图尺寸一致的透明图层
      this.drawPixelMap = await this.createEmptyDrawLayerLike(pm)
      this.drawPixelVersion++

      // ===== 10. 记录操作日志 =====
      const selfId: string = this.localClientId || this.clientId
      this.appendOpLog(selfId, '打开了一张图片', this.localColor)

      // ===== 11. 协作模式下，同步给其他人 =====
      if (this.collabClient.connected && this.pixelMap) {
        await this.broadcastImageToPeers(
          this.pixelMap as image.PixelMap,
          '打开了一张图片'
        )
      }

      promptAction.showToast({ message: '图片已加载' })

    } catch (err) {
      // ===== 12. 异常兜底处理 =====
      let code = 'NA'
      let message = 'unknown'

      if (typeof err === 'object' && err !== null) {
        const e = err as ErrorWithCode
        if (e.code !== undefined) {
          code = String(e.code)
        }
        if (e.message !== undefined) {
          message = String(e.message)
        }
      } else {
        message = String(err)
      }

      const msg = `code=${code} msg=${message}`
      console.error(`[pickImage] failed: ${msg}`)
      promptAction.showToast({ message: `打开失败：${msg}` })
    }
  }

  // 保存图片：把当前编辑结果写入系统相册
  private async saveImage() {
    try {
      // ===== 0. 没有图就不能保存 =====
      if (!this.pixelMap) {
        promptAction.showToast({ message: '请先打开图片' })
        return
      }

      // 拿到 UIAbility 上下文，用于访问系统相册
      const context = getContext(this) as common.UIAbilityContext
      const helper = photoAccessHelper.getPhotoAccessHelper(context)

      // ===== 1. 克隆一份当前底图，用来“专门保存” =====
      // 这样保存过程不会影响正在编辑的那张图
      const basePm: image.PixelMap = this.pixelMap as image.PixelMap
      const pmForSave: image.PixelMap = await this.clonePixelMap(basePm)

      // ===== 2. 如果有绘制层（画笔 / 图形 / 水印），先合成到这张保存用的图上 =====
      if (this.drawPixelMap) {
        await this.mergeDrawLayerIntoBase(
          pmForSave,
          this.drawPixelMap as image.PixelMap
        )
      }

      // ===== 3. 把亮度 / 对比度真正“烘焙”进像素 =====
      // 只影响保存结果，不会改当前编辑状态
      await this.bakeToneForSave(pmForSave)

      // ===== 4. 在系统相册中创建一个新的图片文件 =====
      const uri: string = await helper.createAsset(
        photoAccessHelper.PhotoType.IMAGE,
        'jpg'
      )

      // 打开这个文件，准备写入
      const file = await fileIo.open(
        uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      )

      // ===== 5. 把 PixelMap 编码成 JPEG 并写入文件 =====
      const packer = image.createImagePacker()
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 90 // 压缩质量，90 比较清晰
      }

      // packToFile 是回调形式，这里包一层 Promise 方便 await
      await new Promise<void>((resolve, reject) => {
        packer.packToFile(
          pmForSave,
          file.fd,
          packOpts,
          (err: BusinessError) => err ? reject(err) : resolve()
        )
      })

      // 释放资源
      packer.release?.()
      await fileIo.close(file)

      promptAction.showToast({ message: '已保存到相册' })
    } catch (err) {
      // ===== 6. 保存失败兜底 =====
      const e = err as BusinessError
      console.error(`saveImage failed, code=${e?.code}, msg=${e?.message}`)
      promptAction.showToast({ message: '保存失败' })
    }
  }

  // 根据当前裁剪框裁剪图片，同时同步裁剪绘制图层
  private async doCrop(): Promise<void> {
    // 没有图片时不能裁剪
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo()

    // 画布尺寸异常，直接退出裁剪
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      promptAction.showToast({ message: '画布尚未初始化' })
      this.cropMode = false
      return
    }

    // 图片原始尺寸
    const imgW: number = info.size.width
    const imgH: number = info.size.height

    // contain 模式下图片的基础缩放比例
    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )

    if (scaleBase <= 0) {
      this.cropMode = false
      return
    }

    // 图片在当前视图中的实际显示尺寸
    const realW: number = imgW * scaleBase * this.zoom
    const realH: number = imgH * scaleBase * this.zoom

    // 图片在画布上的显示位置
    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY
    const imageRight: number = imageLeft + realW
    const imageBottom: number = imageTop + realH

    // UI 上的裁剪框（不区分拖动方向）
    let uiX1 = Math.min(this.cropStartX, this.cropEndX)
    let uiY1 = Math.min(this.cropStartY, this.cropEndY)
    let uiX2 = Math.max(this.cropStartX, this.cropEndX)
    let uiY2 = Math.max(this.cropStartY, this.cropEndY)

    // 裁剪框限制在图片显示区域内
    uiX1 = Math.max(uiX1, imageLeft)
    uiY1 = Math.max(uiY1, imageTop)
    uiX2 = Math.min(uiX2, imageRight)
    uiY2 = Math.min(uiY2, imageBottom)

    if (uiX2 <= uiX1 || uiY2 <= uiY1) {
      this.cropMode = false
      return
    }

    // 将 UI 坐标换算为图片像素坐标
    const cropX = Math.floor((uiX1 - imageLeft) * imgW / realW)
    const cropY = Math.floor((uiY1 - imageTop) * imgH / realH)
    const cropW = Math.floor((uiX2 - uiX1) * imgW / realW)
    const cropH = Math.floor((uiY2 - uiY1) * imgH / realH)

    if (cropW <= 0 || cropH <= 0) {
      this.cropMode = false
      return
    }

    // 裁剪前保存一份快照，用于撤销
    const backupPm = await this.clonePixelMap(pm)
    await this.pushHistorySnapshot(true, backupPm)

    // 裁剪底图
    await pm.crop({
      x: cropX,
      y: cropY,
      size: { width: cropW, height: cropH }
    })

    // 同步裁剪绘制图层
    if (this.drawPixelMap) {
      try {
        await this.drawPixelMap.crop({
          x: cropX,
          y: cropY,
          size: { width: cropW, height: cropH }
        })
        this.drawPixelVersion++
      } catch {
        // 绘制层裁剪失败时忽略
      }
    }

    // 根据裁剪前后尺寸，适当缩小画笔粗细
    const oldDiag = this.imageDiag || Math.hypot(imgW, imgH)
    const newDiag = Math.hypot(cropW, cropH)

    if (oldDiag > 0 && newDiag > 0) {
      let ratio = newDiag / oldDiag
      if (ratio > 1) {
        ratio = 1
      }
      if (ratio < 0.8) {
        ratio = 0.8
      }
      this.strokeWidth = Math.max(1, this.strokeWidth * ratio)
      this.imageDiag = newDiag
    }

    // 退出裁剪模式并重置视图参数
    this.cropMode = false
    this.zoom = 1
    this.offsetX = 0
    this.offsetY = 0
    this.pixelVersion++

    this.cropStartX = 0
    this.cropStartY = 0
    this.cropEndX = 0
    this.cropEndY = 0
  }

  // 向右旋转九十度
  private async rotateRight90(): Promise<void> {
    // 没有图片就不能旋转
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    // 防止连续快速点击导致重复旋转
    if (this.isRotating) {
      return
    }

    // 旋转会改变图像，先记录一次历史，支持撤销
    await this.pushHistorySnapshot(false)

    this.isRotating = true
    try {
      // 旋转底图（顺时针 90°）
      await (this.pixelMap as image.PixelMap).rotate(90)

      // 如果存在绘制图层，必须一起旋转，否则会错位
      if (this.drawPixelMap) {
        await (this.drawPixelMap as image.PixelMap).rotate(90)
        this.drawPixelVersion++ // 强制刷新绘制层
      }

      // 记录当前累计旋转角度（用于状态还原）
      this.accumulatedRotate = (this.accumulatedRotate + 90) % 360

      // 刷新底图显示
      this.pixelVersion++

      // 记录操作日志并同步给协作者
      await this.logAndSyncAfterImageChange('右旋转 90°')
    } catch (err) {
      const e = err as Error
      console.error(`rotateRight90 failed: ${e.message}`)
      promptAction.showToast({ message: '右旋失败' })
    } finally {
      // 解除旋转锁
      this.isRotating = false
    }
  }

  // 向左旋转 90 度
  private async rotateLeft90(): Promise<void> {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    // 防止重复触发旋转
    if (this.isRotating) {
      return
    }

    // 记录历史，支持撤销
    await this.pushHistorySnapshot(false)

    this.isRotating = true
    try {
      // PixelMap.rotate 使用角度制，这里 270° 等价于左旋 90°
      await (this.pixelMap as image.PixelMap).rotate(270)

      // 绘制图层同步旋转，保证叠加关系不乱
      if (this.drawPixelMap) {
        await (this.drawPixelMap as image.PixelMap).rotate(270)
        this.drawPixelVersion++
      }

      // 更新累计旋转角度
      this.accumulatedRotate = (this.accumulatedRotate + 270) % 360

      this.pixelVersion++
      await this.logAndSyncAfterImageChange('左旋转 90°')
    } catch (err) {
      const e = err as Error
      console.error(`rotateLeft90 failed: ${e.message}`)
      promptAction.showToast({ message: '左旋失败' })
    } finally {
      this.isRotating = false
    }
  }

  // 调整图片亮度，delta 为正变亮，为负变暗
  private async adjustBrightness(delta: number) {
    // 没有图片就不能调亮度
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    // 亮度只是参数变化，不改像素本身，存一条历史用于撤销
    await this.pushHistorySnapshot(false)

    // 累加亮度变化量
    this.brightnessLevel += delta

    // 限制亮度范围，避免画面完全发白或发黑
    const MAX_LEVEL: number = 0.5
    const MIN_LEVEL: number = -0.5

    if (this.brightnessLevel > MAX_LEVEL) {
      this.brightnessLevel = MAX_LEVEL
    }
    if (this.brightnessLevel < MIN_LEVEL) {
      this.brightnessLevel = MIN_LEVEL
    }

    // 根据变化方向生成一条操作描述
    let desc: string
    if (delta > 0) {
      desc = '提高了亮度'
    } else if (delta < 0) {
      desc = '降低了亮度'
    } else {
      desc = '调整了亮度'
    }

    // 记录操作日志，并同步给协作用户
    await this.logAndSyncAfterImageChange(desc)
  }

  // 构建用于显示的亮度 + 对比度颜色矩阵
  private buildToneMatrix(): Array<number> {
    // 当前亮度偏移量，正数变亮，负数变暗
    const b: number = this.brightnessLevel

    // 对比度系数：contrastLevel [-1, 1] 映射到 [0, 2]
    // 1 表示不变，小于 1 变灰，大于 1 反差更强
    const c: number = 1.0 + this.contrastLevel

    // 为了让画面“围绕中灰 0.5 拉伸”，需要一个额外偏移
    // 不然只调对比度会整体往黑或白偏
    const offset: number = 0.5 * (1.0 - c) + b

    // 4x5 的颜色矩阵：
    // 每一行对应 R / G / B / A
    // 最后一列是偏移量（亮度）
    return [
      c, 0, 0, 0, offset, // R 通道
      0, c, 0, 0, offset, // G 通道
      0, 0, c, 0, offset, // B 通道
      0, 0, 0, 1, 0// A 通道不变
    ]
  }

  // 调整图片对比度（不直接改像素，只改参数）
  private async adjustContrast(delta: number) {
    // 没有图片就不处理
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    // 记录一次历史状态，用于撤销
    // 这里只保存参数，不拷贝像素
    await this.pushHistorySnapshot(false)

    // 按传入的增量修改当前对比度
    this.contrastLevel += delta

    // 对比度的安全范围，防止画面失真
    const MAX_CONTRAST: number = 1.0
    const MIN_CONTRAST: number = -1.0

    // 超过上限就卡住
    if (this.contrastLevel > MAX_CONTRAST) {
      this.contrastLevel = MAX_CONTRAST
    }

    // 低于下限就卡住
    if (this.contrastLevel < MIN_CONTRAST) {
      this.contrastLevel = MIN_CONTRAST
    }

    // 根据用户操作生成一条可读的描述
    let desc: string
    if (delta > 0) {
      desc = '提高了对比度'
    } else if (delta < 0) {
      desc = '降低了对比度'
    } else {
      desc = '调整了对比度'
    }

    // 记录操作日志，并同步给协作用户
    await this.logAndSyncAfterImageChange(desc)
  }

  // 选择当前要绘制的形状
  private selectShape(shape: ShapeTool) {
    // 记录当前选中的形状类型（点 / 线 / 矩形 / 圆等）
    this.currentShape = shape

    // 如果之前在用橡皮擦，切换到形状时自动恢复成普通画笔
    // 避免出现“用橡皮擦画形状”的异常状态
    if (this.currentBrush === BrushTool.Eraser) {
      this.currentBrush = BrushTool.Pen
    }
  }

  //撤销操作
  private async undo() {
    // 调试用：看当前历史长度和指针位置
    console.info(`>>> UNDO CALLED, historyLen=${this.history.length}, historyIndex=${this.historyIndex}`)

    // 没有历史，或者已经退到最前面了
    if (this.historyIndex < 0 || this.history.length === 0) {
      promptAction.showToast({ message: '没有可以撤销的操作' })
      return
    }

    // 取出当前要恢复的快照，然后指针前移
    const snapshot: CanvasSnapshot = this.history[this.historyIndex]
    this.historyIndex--

    // ===== 情况 1：这个快照里有 pixelMap（比如裁剪、重置这种）=====
    if (snapshot.pixelMap) {
      // 克隆一份快照里的 pixelMap，保证是 editable
      const newPm = await this.clonePixelMap(snapshot.pixelMap)

      // 释放当前正在用的 pixelMap
      if (this.pixelMap && this.pixelMap !== snapshot.pixelMap) {
        (this.pixelMap as image.PixelMap).release?.()
      }

      // 切换成快照里的底图
      this.pixelMap = newPm
    }

    // ===== 情况 2：没有 pixelMap，只是参数变化（旋转 / 亮度 / 对比度）=====
    else if (this.pixelMap) {
      // 当前角度和目标角度
      const currentAngle = this.accumulatedRotate
      const targetAngle = snapshot.accumulatedRotate

      // 算出需要“转回去”的角度
      const diff = (360 + targetAngle - currentAngle) % 360
      if (diff === 90 || diff === 180 || diff === 270) {
        try {
          await (this.pixelMap as image.PixelMap).rotate(diff)
        } catch (err) {
          console.error(`undo rotateBack failed: ${JSON.stringify(err)}`)
        }
      }
    }

    // ===== 恢复绘制图层（drawPixelMap）=====
    if (snapshot.drawPixelMap) {
      // 有绘制层快照，克隆一份恢复
      const newDraw = await this.clonePixelMap(snapshot.drawPixelMap)

      // 释放当前绘制层
      if (this.drawPixelMap && this.drawPixelMap !== snapshot.drawPixelMap) {
        this.drawPixelMap.release?.()
      }

      this.drawPixelMap = newDraw
      this.drawPixelVersion++ // 触发绘制层刷新
    } else {
      // 快照里没有绘制层，说明当时是“纯底图”状态
      if (this.drawPixelMap) {
        this.drawPixelMap.release?.()
        this.drawPixelMap = undefined
        this.drawPixelVersion++
      }
    }

    // ===== 恢复视图和参数状态 =====
    this.zoom = snapshot.zoom
    this.offsetX = snapshot.offsetX
    this.offsetY = snapshot.offsetY
    this.brightnessLevel = snapshot.brightnessLevel
    this.contrastLevel = snapshot.contrastLevel
    this.accumulatedRotate = snapshot.accumulatedRotate

    // 记录一次撤销操作（日志 + 协作同步）
    const desc: string = '撤销了一步操作'
    await this.logAndSyncAfterImageChange(desc)

    // 刷新底图显示
    this.pixelVersion++
  }

  // 在当前可编辑图层上画一个“点”
  // 传入的是 UI 坐标（点击位置），内部会换算成图片像素坐标
  private async drawPointAtUi(uiX: number, uiY: number) {
    // 没有底图，直接不画
    if (!this.pixelMap) {
      return
    }

    // 画之前先压一份快照，保证这一步可以撤销
    await this.pushFullSnapshotBeforeChange()

    // 画布尺寸还没算出来时，不处理
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      console.info('>>> drawPointAtUi: canvas size is 0, skip')
      return
    }

    // 优先画在绘制图层（drawPixelMap）上
    // 如果没有绘制图层，就直接改底图
    let targetPm: image.PixelMap | undefined = this.drawPixelMap as image.PixelMap | undefined
    let targetIsDrawLayer: boolean = true

    if (!targetPm) {
      targetPm = this.pixelMap as image.PixelMap
      targetIsDrawLayer = false
    }

    // 理论兜底：两个都不存在
    if (!targetPm) {
      console.warn('>>> drawPointAtUi: both drawPixelMap & pixelMap are null')
      promptAction.showToast({ message: '当前没有可编辑图层，请重新打开图片' })
      return
    }

    console.info(`>>> drawPointAtUi: target layer = ${targetIsDrawLayer ? 'drawPixelMap' : 'pixelMap'}`)

    // 用底图的信息来做 UI -> 像素 的坐标映射
    const basePm = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()

    const imgW: number = baseInfo.size.width
    const imgH: number = baseInfo.size.height

    // 计算 contain 模式下的基础缩放比例
    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )

    if (scaleBase <= 0) {
      console.info('>>> drawPointAtUi: scaleBase <= 0, skip')
      return
    }

    // 图片在当前画布中的实际显示尺寸
    const realW: number = imgW * scaleBase * this.zoom
    const realH: number = imgH * scaleBase * this.zoom

    // 图片左上角在画布中的位置
    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    // 把 UI 坐标换算成图片像素坐标
    const pxFloat: number = (uiX - imageLeft) * (imgW / realW)
    const pyFloat: number = (uiY - imageTop) * (imgH / realH)

    const px: number = Math.floor(pxFloat)
    const py: number = Math.floor(pyFloat)

    console.info(`>>> drawPointAtUi: ui=(${uiX.toFixed(1)}, ${uiY.toFixed(1)}) -> pixel=(${px}, ${py})`)

    // 点在图片外面，直接忽略
    if (px < 0 || py < 0 || px >= imgW || py >= imgH) {
      return
    }

    // 读取目标图层的像素数据
    const info: image.ImageInfo = await targetPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    if (px < 0 || py < 0 || px >= width || py >= height) {
      console.info('>>> drawPointAtUi: pixel out of target layer range')
      return
    }

    const byteLength: number = targetPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await targetPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 统一获取当前像素格式下的 RGBA 通道顺序
    const ch: ChannelOrder = this.getChannelOrder(info.pixelFormat)
    const rOffset: number = ch.r
    const gOffset: number = ch.g
    const bOffset: number = ch.b
    const aOffset: number = ch.a

    // 根据图片尺寸算一个“看起来合适”的画笔半径
    const radius: number = this.computeStrokeRadiusPixel(imgW, imgH)
    const alpha: number = this.getStrokeAlpha()

    // 以 (px, py) 为中心画一个“实心圆点”
    for (let yy: number = py - radius; yy <= py + radius; yy++) {
      if (yy < 0 || yy >= height) {
        continue
      }
      for (let xx: number = px - radius; xx <= px + radius; xx++) {
        if (xx < 0 || xx >= width) {
          continue
        }

        const dx: number = xx - px
        const dy: number = yy - py
        if (dx * dx + dy * dy > radius * radius) {
          continue
        }

        const baseIndex: number = (yy * width + xx) * 4
        const rIndex: number = baseIndex + rOffset
        const gIndex: number = baseIndex + gOffset
        const bIndex: number = baseIndex + bOffset
        const aIndex: number = baseIndex + aOffset

        // 橡皮擦只清 alpha，其它画笔直接写颜色
        if (this.currentBrush === BrushTool.Eraser) {
          data[aIndex] = 0
        } else {
          data[rIndex] = this.strokeR
          data[gIndex] = this.strokeG
          data[bIndex] = this.strokeB
          data[aIndex] = alpha
        }
      }
    }

    // 写回像素，并通过 clone 的方式触发 UI 刷新
    await targetPm.writeBufferToPixels(buffer)

    if (targetIsDrawLayer) {
      const newLayer: image.PixelMap = await this.clonePixelMap(targetPm)
      if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
        this.drawPixelMap.release?.()
      }
      this.drawPixelMap = newLayer
      this.drawPixelVersion++
    } else {
      const newBase: image.PixelMap = await this.clonePixelMap(targetPm)
      if (this.pixelMap && this.pixelMap !== newBase) {
        (this.pixelMap as image.PixelMap).release?.()
      }
      this.pixelMap = newBase
      this.pixelVersion++
    }

    // 记录操作日志并同步给协作者
    const desc: string = `画了一个点 像素=(${px}, ${py})`
    await this.logAndSyncAfterImageChange(desc)

    console.info(
      `>>> drawPointAtUi done: target=${targetIsDrawLayer ? 'draw' : 'base'}, size=${width}x${height}`
    )
  }

  // 将画布上的 UI 坐标统一转换为图片内部的像素坐标，供所有绘制工具共用
  private async uiToPixel(uiX: number, uiY: number): Promise<PixelPoint | undefined> {
    // 没有底图时无法进行坐标映射
    if (!this.pixelMap) {
      return undefined
    }

    // 画布尺寸异常时直接返回，避免除零等问题
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return undefined
    }

    // 读取当前底图的像素尺寸信息
    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo()
    const imgW: number = info.size.width
    const imgH: number = info.size.height

    // 计算基础缩放比例（contain），保证整张图完整显示在画布中
    const scaleBase: number = Math.min(this.canvasWidth / imgW, this.canvasHeight / imgH)
    if (scaleBase <= 0) {
      return undefined
    }

    // 结合当前缩放因子 zoom，得到图片在画布中的实际显示尺寸
    const realW: number = imgW * scaleBase * this.zoom
    const realH: number = imgH * scaleBase * this.zoom

    // 计算图片左上角在画布坐标系中的位置（居中 + 平移）
    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    // 将 UI 坐标反算为图片内部的像素坐标
    const px: number = Math.floor((uiX - imageLeft) * (imgW / realW))
    const py: number = Math.floor((uiY - imageTop) * (imgH / realH))

    // 返回 PixelPoint 类型，避免直接使用未声明类型的对象字面量
    const pt: PixelPoint = { x: px, y: py }
    return pt
  }

  // 在像素缓冲区中以 (cx, cy) 为中心画一个有粗细的实心点，供画点和画线复用
  private drawThickPointIntoBuffer(
    data: Uint8Array, // 整张图的像素数据缓冲区
    width: number, // 图像宽度（像素）
    height: number, // 图像高度（像素）
    cx: number, // 点中心的 x 坐标
    cy: number, // 点中心的 y 坐标
    radius: number, // 点的半径（决定粗细）
    rOffset: number, // R 通道在像素中的偏移
    gOffset: number, // G 通道在像素中的偏移
    bOffset: number, // B 通道在像素中的偏移
    aOffset: number, // A 通道在像素中的偏移
    alpha: number, // 当前画笔的透明度
    bpp: number // 每个像素占用的字节数（通常是 4）
  ): void {
    // 在圆的垂直范围内逐行扫描
    for (let yy: number = cy - radius; yy <= cy + radius; yy++) {
      if (yy < 0 || yy >= height) {
        continue
      }

      // 在圆的水平方向范围内逐列扫描
      for (let xx: number = cx - radius; xx <= cx + radius; xx++) {
        if (xx < 0 || xx >= width) {
          continue
        }

        const dx: number = xx - cx // 当前像素到中心点的 x 距离
        const dy: number = yy - cy // 当前像素到中心点的 y 距离
        if (dx * dx + dy * dy > radius * radius) {
          continue // 在圆外的像素直接跳过
        }

        const baseIndex: number = (yy * width + xx) * bpp // 当前像素在 buffer 中的起始位置
        const rIndex: number = baseIndex + rOffset // R 通道索引
        const gIndex: number = baseIndex + gOffset // G 通道索引
        const bIndex: number = baseIndex + bOffset // B 通道索引
        const aIndex: number = baseIndex + aOffset // A 通道索引

        if (aIndex < 0 || aIndex >= data.length) {
          continue // 防止数组越界
        }

        if (this.currentBrush === BrushTool.Eraser) {
          data[aIndex] = 0 // 橡皮擦只清 alpha
        } else {
          if (rIndex >= 0 && rIndex < data.length) {
            data[rIndex] = this.strokeR // 写入 R
          }
          if (gIndex >= 0 && gIndex < data.length) {
            data[gIndex] = this.strokeG // 写入 G
          }
          if (bIndex >= 0 && bIndex < data.length) {
            data[bIndex] = this.strokeB // 写入 B
          }
          data[aIndex] = alpha // 写入透明度
        }
      }
    }
  }

  // 直线工具：把 UI 拖拽产生的起点/终点坐标，转换成图片像素坐标，并在绘制图层上画一条直线
  private async handleLineDrag(
    startUiX: number,
    startUiY: number,
    endUiX: number,
    endUiY: number
  ): Promise<void> {
    if (!this.pixelMap) {
      return // 没有底图，无法绘制
    }

    // 将起点 UI 坐标转换为图片像素坐标
    const p0: PixelPoint | undefined = await this.uiToPixel(startUiX, startUiY)
    // 将终点 UI 坐标转换为图片像素坐标
    const p1: PixelPoint | undefined = await this.uiToPixel(endUiX, endUiY)
    if (!p0 || !p1) {
      return // 坐标转换失败（如越界），直接退出
    }

    // 确保存在绘制图层（没有则创建）
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return // 无法获得绘制图层
    }

    // 在绘制图层上，根据像素坐标真正画直线
    await this.drawLineBetweenPixels(p0.x, p0.y, p1.x, p1.y)

    // 统一成左上角 / 右下角坐标，方便日志与同步
    const left: number = Math.min(p0.x, p1.x)
    const top: number = Math.min(p0.y, p1.y)
    const right: number = Math.max(p0.x, p1.x)
    const bottom: number = Math.max(p0.y, p1.y)

    // 生成一条人可读的操作描述
    const desc: string = `画了一条直线 (${left}, ${top}) -> (${right}, ${bottom})`
    // 记录操作并同步给协作端
    await this.logAndSyncAfterImageChange(desc)

    // 给用户一个完成提示
    promptAction.showToast({ message: '直线已绘制' })
  }

  // 在绘制图层 drawPixelMap 上画一条“带粗细的直线”
  // 入参 x0,y0,x1,y1 都是图片内部的像素坐标
  private async drawLineBetweenPixels(
    x0: number,
    y0: number,
    x1: number,
    y1: number
  ): Promise<void> {
    // 没有底图就直接退出
    if (!this.pixelMap) {
      return
    }

    // 画线属于一次真正的绘制操作，先压一份完整快照，支持撤销
    await this.pushFullSnapshotBeforeChange()

    // 1. 用底图尺寸做一次边界检查
    // 正常情况下绘制层尺寸和底图是一致的
    const basePm: image.PixelMap = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const baseW: number = baseInfo.size.width
    const baseH: number = baseInfo.size.height

    // 如果起点或终点不在图片范围内，直接放弃
    if (
      x0 < 0 || y0 < 0 || x0 >= baseW || y0 >= baseH ||
        x1 < 0 || y1 < 0 || x1 >= baseW || y1 >= baseH
    ) {
      console.info('>>> drawLineBetweenPixels: endpoints out of base range, skip')
      return
    }

    // 2. 只在绘制图层上画线，不直接改底图
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    // 再用绘制图层尺寸做一次防御检查
    if (
      x0 < 0 || y0 < 0 || x0 >= width || y0 >= height ||
        x1 < 0 || y1 < 0 || x1 >= width || y1 >= height
    ) {
      console.info('>>> drawLineBetweenPixels: endpoints out of layer range, skip')
      return
    }

    // 3. 读取绘制图层的像素数据到内存
    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 根据像素格式，取得 RGBA 在一个像素里的真实偏移
    const ch: ChannelOrder = this.getChannelOrder(info.pixelFormat)
    const rOffset: number = ch.r
    const gOffset: number = ch.g
    const bOffset: number = ch.b
    const aOffset: number = ch.a
    const bpp: number = ch.bytesPerPixel

    // 根据画布大小和当前画笔宽度，计算像素级半径
    const radius: number = this.computeStrokeRadiusPixel(width, height)
    // 当前画笔透明度
    const alpha: number = this.getStrokeAlpha()

    // 在指定像素(cx, cy)位置，画一个“带半径的圆点”
    // 这是实现“粗线条”的基础
    const drawThickPoint = (x: number, y: number): void => {
      this.drawThickPointIntoBuffer(
        data,
        width,
        height,
        x,
        y,
        radius,
        rOffset,
        gOffset,
        bOffset,
        aOffset,
        alpha,
        bpp
      )
    }


    // 5. 使用 Bresenham 算法逐像素走一条直线
    // 每走到一个像素点，就画一个“粗点”
    // Bresenham 直线算法
    // 从起点开始走
    let curX: number = x0
    let curY: number = y0

    // x 方向需要走的总步数
    const dx: number = Math.abs(x1 - x0)
    // x 方向每一步是往右(+1)还是往左(-1)
    const sx: number = x0 < x1 ? 1 : -1

    // y 方向需要走的总步数（这里取负数是算法写法）
    const dy: number = -Math.abs(y1 - y0)
    // y 方向每一步是往下(+1)还是往上(-1)
    const sy: number = y0 < y1 ? 1 : -1

    // 误差值：用来判断下一步该不该在 y 方向走
    let err: number = dx + dy

    // 一直走，直到走到终点
    while (true) {
      // 在当前像素位置画一个“粗点”
      drawThickPoint(curX, curY)

      // 到达终点就结束
      if (curX === x1 && curY === y1) {
        break
      }

      // 把误差放大一倍，方便判断方向
      const e2: number = 2 * err

      // 如果误差还允许，先在 x 方向走一步
      if (e2 >= dy) {
        err += dy
        curX += sx
      }

      // 如果误差还允许，在 y 方向走一步
      if (e2 <= dx) {
        err += dx
        curY += sy
      }
    }


    // 6. 把修改后的像素数据写回绘制图层
    await layerPm.writeBufferToPixels(buffer)

    // 为了触发 UI 刷新，clone 一份新的 PixelMap，替换引用
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)

    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer

    // 修改版本号，驱动叠加层 Image 重新渲染
    this.drawPixelVersion++

    console.info(
      `>>> drawLineBetweenPixels: line drawn, drawPixelVersion=${this.drawPixelVersion}`
    )
  }

  // 矩形工具：把 UI 拖拽的起点/终点转换成图片像素坐标，并在绘制图层上画一个矩形
  private async handleRectDrag(
    startUiX: number,
    startUiY: number,
    endUiX: number,
    endUiY: number
  ): Promise<void> {
    if (!this.pixelMap) {
      return // 没有底图，无法绘制
    }

    // 将起点 UI 坐标转换为图片像素坐标
    const p0: PixelPoint | undefined = await this.uiToPixel(startUiX, startUiY)
    // 将终点 UI 坐标转换为图片像素坐标
    const p1: PixelPoint | undefined = await this.uiToPixel(endUiX, endUiY)
    if (!p0 || !p1) {
      return // 坐标转换失败（如越界），直接退出
    }

    // 修改前先压一份完整快照，支持撤销
    await this.pushFullSnapshotBeforeChange()

    // 在绘制图层上按像素坐标画矩形
    await this.drawRectBetweenPixels(p0.x, p0.y, p1.x, p1.y)

    // 统一成左上角 / 右下角坐标，方便记录和同步
    const left: number = Math.min(p0.x, p1.x)
    const top: number = Math.min(p0.y, p1.y)
    const right: number = Math.max(p0.x, p1.x)
    const bottom: number = Math.max(p0.y, p1.y)

    // 生成一条可读的操作描述
    const desc: string = `画了一个矩形 左上像素=(${left}, ${top}), 右下像素=(${right}, ${bottom})`
    // 记录操作并同步给协作端
    await this.logAndSyncAfterImageChange(desc)

    // 提示用户绘制完成
    promptAction.showToast({ message: '矩形已绘制' })
  }

  // 在像素坐标里画一个矩形边框（使用当前 stroke 宽度和颜色）
  // 在绘制图层 drawPixelMap 上画一个矩形边框（使用当前 stroke 宽度和颜色）
  private async drawRectBetweenPixels(x0: number, y0: number, x1: number, y1: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    // 1）先用底图做一次尺寸边界检查
    const basePm: image.PixelMap = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const baseW: number = baseInfo.size.width
    const baseH: number = baseInfo.size.height

    // 归一化成左上 / 右下
    let left: number = Math.min(x0, x1)
    let right: number = Math.max(x0, x1)
    let top: number = Math.min(y0, y1)
    let bottom: number = Math.max(y0, y1)

    // 裁剪在图片范围之内（用底图尺寸）
    left = Math.max(0, left)
    right = Math.min(baseW - 1, right)
    top = Math.max(0, top)
    bottom = Math.min(baseH - 1, bottom)

    if (left >= right || top >= bottom) {
      console.info('>>> drawRectBetweenPixels: rect too small, skip')
      return
    }

    // 2）只在绘制图层上画矩形
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    // 3）读绘制层的像素
    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    const ch: ChannelOrder = this.getChannelOrder(info.pixelFormat)
    const rOffset: number = ch.r
    const gOffset: number = ch.g
    const bOffset: number = ch.b
    const aOffset: number = ch.a
    const bpp: number = ch.bytesPerPixel

    const radius: number = this.computeStrokeRadiusPixel(width, height)
    const alpha: number = this.getStrokeAlpha()

    const drawThickPoint = (x: number, y: number): void => {
      this.drawThickPointIntoBuffer(
        data,
        width,
        height,
        x,
        y,
        radius,
        rOffset,
        gOffset,
        bOffset,
        aOffset,
        alpha,
        bpp
      )
    }


    // 5）画四条边：上、下、左、右
    for (let x: number = left; x <= right; x++) {
      drawThickPoint(x, top) // 上边
      drawThickPoint(x, bottom) // 下边
    }
    for (let y: number = top; y <= bottom; y++) {
      drawThickPoint(left, y) // 左边
      drawThickPoint(right, y) // 右边
    }

    // 6）写回绘制层像素
    await layerPm.writeBufferToPixels(buffer)

    // 7）clone 一份新的绘制层，换引用，强制 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer
    this.drawPixelVersion++ // 触发 Image(drawPixelMap) 重建

    console.info(`>>> drawRectBetweenPixels: rect drawn, drawPixelVersion=${this.drawPixelVersion}`)
  }

  // 在像素坐标系中画一个圆形边框：参数是圆的外接正方形左上 / 右下，实际绘制在绘制图层上
  private async drawCircleBetweenPixels(left: number, top: number, right: number, bottom: number): Promise<void> {
    if (!this.pixelMap) {
      return // 没有底图直接退出
    }

    // 用底图尺寸做一次边界裁剪，避免越界
    const basePm: image.PixelMap = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const baseW: number = baseInfo.size.width
    const baseH: number = baseInfo.size.height

    left = Math.max(0, left)
    right = Math.min(baseW - 1, right)
    top = Math.max(0, top)
    bottom = Math.min(baseH - 1, bottom)

    const w: number = right - left // 外接矩形宽
    const h: number = bottom - top // 外接矩形高
    const side: number = Math.min(w, h) // 取短边作为圆的直径

    if (side <= 0) {
      return // 框太小，不画
    }

    // 强制用正方形框住圆
    right = left + side
    bottom = top + side

    const cx: number = Math.round((left + right) / 2) // 圆心 x
    const cy: number = Math.round((top + bottom) / 2) // 圆心 y
    const radius: number = side / 2 // 圆半径

    // 确保存在绘制图层，只在绘制层上改像素
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    // 把绘制层像素一次性读到内存 buffer
    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 根据像素格式拿到通道偏移和 bpp
    const ch: ChannelOrder = this.getChannelOrder(info.pixelFormat)
    const rOffset: number = ch.r
    const gOffset: number = ch.g
    const bOffset: number = ch.b
    const aOffset: number = ch.a
    const bpp: number = ch.bytesPerPixel

    const strokeRadius: number = this.computeStrokeRadiusPixel(width, height) // 线宽对应的像素半径
    const alpha: number = this.getStrokeAlpha() // 当前画笔透明度

    // 在指定像素位置画一个“粗点”，作为画圆边的基础
    const drawThickPoint = (px: number, py: number): void => {
      this.drawThickPointIntoBuffer(
        data,
        width,
        height,
        px,
        py,
        strokeRadius,
        rOffset,
        gOffset,
        bOffset,
        aOffset,
        alpha,
        bpp
      )
    }

    // 用参数方程沿圆周走一圈，逐点画粗点
    const TWO_PI: number = Math.PI * 2
    const steps: number = Math.max(36, Math.floor(TWO_PI * radius / 2)) // 半径越大，步数越多

    for (let i: number = 0; i < steps; i++) {
      const t: number = (TWO_PI * i) / steps
      const px: number = Math.round(cx + radius * Math.cos(t))
      const py: number = Math.round(cy + radius * Math.sin(t))

      if (px < 0 || px >= width || py < 0 || py >= height) {
        continue // 越界像素直接跳过
      }
      drawThickPoint(px, py)
    }

    // 把修改后的像素写回绘制层
    await layerPm.writeBufferToPixels(buffer)

    // clone 新 PixelMap，替换引用以触发 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer
    this.drawPixelVersion++ // 驱动叠加层重新渲染
  }

  // 圆形工具：把 UI 拖拽的起点/终点转换成像素坐标，用正方形框出一个圆并画到绘制图层
  private async handleCircleDrag(
    startUiX: number,
    startUiY: number,
    endUiX: number,
    endUiY: number
  ): Promise<void> {
    if (!this.pixelMap) {
      return // 没有底图，无法绘制
    }

    const p0: PixelPoint | undefined = await this.uiToPixel(startUiX, startUiY) // 起点 UI → 像素
    const p1: PixelPoint | undefined = await this.uiToPixel(endUiX, endUiY) // 终点 UI → 像素
    if (!p0 || !p1) {
      return // 坐标转换失败直接退出
    }

    const x0: number = p0.x // 起点像素 x
    const y0: number = p0.y // 起点像素 y
    const x1: number = p1.x // 终点像素 x
    const y1: number = p1.y // 终点像素 y

    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo() // 仅用于调试日志

    console.info(
      `>>> handleCircleDrag uiStart=(${startUiX.toFixed(1)},${startUiY.toFixed(1)}), ` +
        `uiEnd=(${endUiX.toFixed(1)},${endUiY.toFixed(1)}) -> ` +
        `pixelStart=(${x0},${y0}), pixelEnd=(${x1},${y1}), imgSize=(${info.size.width},${info.size.height})`
    )

    let left: number = Math.min(x0, x1) // 拖拽框左边
    let right: number = Math.max(x0, x1) // 拖拽框右边
    let top: number = Math.min(y0, y1) // 拖拽框上边
    let bottom: number = Math.max(y0, y1) // 拖拽框下边

    const boxW: number = right - left // 拖拽框宽度
    const boxH: number = bottom - top // 拖拽框高度
    const side: number = Math.min(Math.abs(boxW), Math.abs(boxH)) // 取短边作为圆的直径

    if (side <= 0) {
      return // 框太小，不画
    }

    right = left + side // 用左上角 + side 构成正方形
    bottom = top + side // 保证画出来的是正圆

    await this.pushFullSnapshotBeforeChange() // 绘制前压快照，支持撤销
    await this.drawCircleBetweenPixels(left, top, right, bottom) // 在绘制图层上画圆

    const desc: string = `画了一个圆 左上像素=(${left}, ${top}), 右下像素=(${right}, ${bottom})` // 操作描述
    await this.logAndSyncAfterImageChange(desc) // 记录日志并同步协作端

    promptAction.showToast({ message: '圆形已绘制' }) // 提示用户完成
  }

  // 椭圆工具：把 UI 拖拽的起点/终点转换成像素坐标，用矩形框出一个椭圆并画到绘制图层
  private async handleEllipseDrag(
    startUiX: number,
    startUiY: number,
    endUiX: number,
    endUiY: number
  ): Promise<void> {
    if (!this.pixelMap) {
      return // 没有底图就不处理
    }

    const p0: PixelPoint | undefined = await this.uiToPixel(startUiX, startUiY) // 起点 UI → 像素
    const p1: PixelPoint | undefined = await this.uiToPixel(endUiX, endUiY) // 终点 UI → 像素
    if (!p0 || !p1) {
      return // 坐标转换失败直接退出
    }

    const x0: number = p0.x // 起点像素 x
    const y0: number = p0.y // 起点像素 y
    const x1: number = p1.x // 终点像素 x
    const y1: number = p1.y // 终点像素 y

    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo() // 仅用于调试日志

    console.info(
      `>>> handleEllipseDrag uiStart=(${startUiX.toFixed(1)},${startUiY.toFixed(1)}), ` +
        `uiEnd=(${endUiX.toFixed(1)},${endUiY.toFixed(1)}) -> ` +
        `pixelStart=(${x0},${y0}), pixelEnd=(${x1},${y1}), imgSize=(${info.size.width},${info.size.height})`
    )

    const left: number = Math.min(x0, x1) // 椭圆外接矩形左边
    const right: number = Math.max(x0, x1) // 椭圆外接矩形右边
    const top: number = Math.min(y0, y1) // 椭圆外接矩形上边
    const bottom: number = Math.max(y0, y1) // 椭圆外接矩形下边

    if (right - left <= 0 || bottom - top <= 0) {
      return // 框太小，不画
    }

    await this.pushFullSnapshotBeforeChange() // 绘制前压快照，支持撤销
    await this.drawEllipseBetweenPixels(left, top, right, bottom) // 在绘制图层上画椭圆

    const desc: string = `画了一个椭圆 左上像素=(${left}, ${top}), 右下像素=(${right}, ${bottom})` // 操作描述
    await this.logAndSyncAfterImageChange(desc) // 记录操作并同步协作端

    promptAction.showToast({ message: '椭圆已绘制' }) // 提示用户完成
  }

  // 在像素坐标系中画一个椭圆边框，参数是椭圆外接矩形的左上 / 右下，实际绘制在绘制图层上
  private async drawEllipseBetweenPixels(left: number, top: number, right: number, bottom: number): Promise<void> {
    if (!this.pixelMap) {
      return // 没有底图就不处理
    }

    // 用底图尺寸对传入的矩形做一次裁剪，防止越界
    const basePm: image.PixelMap = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const baseW: number = baseInfo.size.width
    const baseH: number = baseInfo.size.height

    left = Math.max(0, left)
    right = Math.min(baseW - 1, right)
    top = Math.max(0, top)
    bottom = Math.min(baseH - 1, bottom)

    const w: number = right - left // 外接矩形宽
    const h: number = bottom - top // 外接矩形高
    if (w <= 0 || h <= 0) {
      return // 矩形无效，直接退出
    }

    const cx: number = Math.round((left + right) / 2) // 椭圆中心 x
    const cy: number = Math.round((top + bottom) / 2) // 椭圆中心 y
    const rx: number = w / 2 // 椭圆 x 方向半径
    const ry: number = h / 2 // 椭圆 y 方向半径

    // 确保存在绘制图层，只在绘制层上画
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    // 把绘制层像素整体读到内存里，后面直接改 buffer
    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 根据像素格式获取通道偏移和每像素字节数
    const ch: ChannelOrder = this.getChannelOrder(info.pixelFormat)
    const rOffset: number = ch.r
    const gOffset: number = ch.g
    const bOffset: number = ch.b
    const aOffset: number = ch.a
    const bpp: number = ch.bytesPerPixel // 一个像素占多少字节

    const thickRadius: number = this.computeStrokeRadiusPixel(width, height) // 线宽对应的像素半径
    const alpha: number = this.getStrokeAlpha() // 当前画笔透明度

    // 在指定像素点画一个“粗点”，椭圆边是由这些点拼出来的
    const drawThickPoint = (px: number, py: number): void => {
      this.drawThickPointIntoBuffer(
        data,
        width,
        height,
        px,
        py,
        thickRadius,
        rOffset,
        gOffset,
        bOffset,
        aOffset,
        alpha,
        bpp
      )
    }

    // 用参数方程沿椭圆边走一圈
    const TWO_PI: number = Math.PI * 2
    const maxR: number = Math.max(rx, ry)
    const steps: number = Math.max(36, Math.floor(TWO_PI * maxR / 2)) // 椭圆越大，步数越多

    for (let i: number = 0; i < steps; i++) {
      const t: number = (TWO_PI * i) / steps
      const px: number = Math.round(cx + rx * Math.cos(t)) // 当前点 x
      const py: number = Math.round(cy + ry * Math.sin(t)) // 当前点 y

      if (px < 0 || px >= width || py < 0 || py >= height) {
        continue // 越界像素跳过
      }
      drawThickPoint(px, py)
    }

    // 把修改后的像素数据写回绘制图层
    await layerPm.writeBufferToPixels(buffer)

    // clone 一份新的 PixelMap，替换引用以触发 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer
    this.drawPixelVersion++ // 驱动叠加层重新渲染
  }

  // 在自由绘制时，把一小段手势移动同步画进内存里的像素 buffer（不涉及 PixelMap 写回）
  private drawFreeStrokeSegmentSync(
    prevUiX: number,
    prevUiY: number,
    curUiX: number,
    curUiY: number
  ): void {
    // 自由绘制开始时必须已经准备好内存 buffer，否则直接跳过
    if (!this.freeDrawBuffer || !this.freeDrawArrayBuffer) {
      return
    }

    // 没有底图也没有绘制层，说明当前没有可画的目标
    if (!this.pixelMap && !this.drawPixelMap) {
      return
    }

    // 优先用绘制层作为参考尺寸，其次才用底图
    const basePm: image.PixelMap = (this.drawPixelMap ?? this.pixelMap) as image.PixelMap
    const info: image.ImageInfo = basePm.getImageInfoSync() // 同步拿尺寸和像素格式

    const imgW: number = info.size.width // 图片像素宽
    const imgH: number = info.size.height // 图片像素高

    // 根据画布尺寸和图片尺寸，计算 contain 模式下的基础缩放比例
    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )

    const realW: number = imgW * scaleBase * this.zoom // 当前图片在画布上的显示宽
    const realH: number = imgH * scaleBase * this.zoom // 当前图片在画布上的显示高

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX // 图片左上角 x
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY // 图片左上角 y

    // 把上一帧和当前帧的 UI 坐标转换成图片像素坐标
    const x0: number = Math.floor((prevUiX - imageLeft) * (imgW / realW))
    const y0: number = Math.floor((prevUiY - imageTop) * (imgH / realH))
    const x1: number = Math.floor((curUiX - imageLeft) * (imgW / realW))
    const y1: number = Math.floor((curUiY - imageTop) * (imgH / realH))

    // 任一端点越界就直接丢弃这一小段，避免写坏 buffer
    if (
      x0 < 0 || x0 >= imgW || y0 < 0 || y0 >= imgH ||
        x1 < 0 || x1 >= imgW || y1 < 0 || y1 >= imgH
    ) {
      return
    }

    // 在内存 buffer 里同步画一小段线，用于自由绘制的实时反馈
    this.drawLineIntoBuffer(
      x0,
      y0,
      x1,
      y1,
      this.freeDrawBuffer as Uint8Array, // 当前自由绘制用的像素缓冲区
      imgW,
      imgH,
      info.pixelFormat // 像素格式决定通道顺序和 bpp
    )
  }

  // 在给定的像素缓冲区里画一条“带粗细的线段”（用于自由绘制，直接改内存，不走 PixelMap）
  private drawLineIntoBuffer(
    x0: number,
    y0: number,
    x1: number,
    y1: number,
    buffer: Uint8Array,
    imgW: number,
    imgH: number,
    pixelFormat: image.PixelMapFormat
  ): void {
    const width: number = imgW // 图片像素宽
    const height: number = imgH // 图片像素高

    const ch: ChannelOrder = this.getChannelOrder(pixelFormat) // 根据像素格式确定通道顺序
    const rOffset: number = ch.r // R 通道在一个像素里的偏移
    const gOffset: number = ch.g // G 通道偏移
    const bOffset: number = ch.b // B 通道偏移
    const aOffset: number = ch.a // A 通道偏移
    const bpp: number = ch.bytesPerPixel // 每个像素占用的字节数

    const radius: number = this.computeStrokeRadiusPixel(imgW, imgH) // 当前画笔在像素级的半径
    const alpha: number = this.getStrokeAlpha() // 当前画笔透明度

    // 在指定像素位置画一个“粗点”，用于拼出粗线
    const drawThickPoint = (px: number, py: number): void => {
      this.drawThickPointIntoBuffer(
        buffer, // 直接操作传入的像素缓冲区
        width,
        height,
        px,
        py,
        radius, // 使用当前画笔半径
        rOffset,
        gOffset,
        bOffset,
        aOffset,
        alpha,
        bpp
      )
    }

    let curX: number = x0 // 当前走到的像素 x
    let curY: number = y0 // 当前走到的像素 y
    const dx: number = Math.abs(x1 - x0) // x 方向总步数
    const sx: number = x0 < x1 ? 1 : -1 // x 方向每步走向
    const dy: number = -Math.abs(y1 - y0) // y 方向总步数（算法要求为负）
    const sy: number = y0 < y1 ? 1 : -1 // y 方向每步走向
    let err: number = dx + dy // Bresenham 误差项

    while (true) {
      drawThickPoint(curX, curY) // 在当前像素位置画一个粗点

      if (curX === x1 && curY === y1) {
        break // 到达终点就结束
      }

      const e2: number = 2 * err // 放大误差，用来判断走向
      if (e2 >= dy) {
        err += dy
        curX += sx // 在 x 方向前进一步
      }
      if (e2 <= dx) {
        err += dx
        curY += sy // 在 y 方向前进一步
      }
    }
  }

  // 为自由绘制准备一份可直接修改的像素缓冲区（从绘制图层拷贝）
  private async prepareFreeDrawBuffer() {
    if (!this.pixelMap) {
      return // 没有底图，直接返回
    }

    // 自由绘制只作用在绘制图层上，没有就先创建一张全透明的绘制层
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return // 创建或获取绘制层失败
    }

    this.freeBufferReady = false // 标记缓冲区尚未准备好

    this.freeDrawByteLength = layerPm.getPixelBytesNumber() // 计算绘制层所需的字节大小
    this.freeDrawArrayBuffer = new ArrayBuffer(this.freeDrawByteLength) // 分配一块连续内存

    // 异步把绘制层像素读到内存里，避免在手势回调中 await
    layerPm.readPixelsToBuffer(this.freeDrawArrayBuffer).then(() => {
      this.freeDrawBuffer = new Uint8Array(this.freeDrawArrayBuffer as ArrayBuffer) // 用 Uint8Array 方便直接改像素
      this.freeBufferReady = true // 标记缓冲区已可用于自由绘制
    })
  }

  // 自由绘制结束时调用：把内存里的绘制结果真正提交到绘制图层
  private async handleFreeDrawEnd(): Promise<void> {
    // 只在自由绘制模式下才处理，且必须已经有图片
    if (this.currentShape !== ShapeTool.FreeDraw || !this.pixelMap) {
      return
    }

    this.isFreeDrawing = false // 标记自由绘制状态结束

    // 自由绘制只作用在绘制图层上，没有绘制层就直接清理并退出
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      this.freeDrawBuffer = null
      this.freeDrawArrayBuffer = null
      return
    }

    // 1) 把内存里的最终像素数据写回到绘制图层 PixelMap
    if (this.freeDrawArrayBuffer) {
      await layerPm.writeBufferToPixels(this.freeDrawArrayBuffer)
    }

    // 2) clone 一份新的绘制图层，替换引用，强制触发 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer
    this.drawPixelVersion++ // 驱动叠加层 Image 重新渲染

    // 3) 清空自由绘制过程中使用的临时缓冲区
    this.freeDrawBuffer = null
    this.freeDrawArrayBuffer = null

    // 4) 记录一次“自由绘制完成”的操作，并同步给协作端
    const desc: string = '自由画笔：完成了一笔自由绘制'
    await this.logAndSyncAfterImageChange(desc)
  }

  // 根据当前画笔透明度 strokeOpacity（0.0 ~ 1.0），计算实际写入像素用的 alpha 值（0 ~ 255）
  private getStrokeAlpha(): number {
    // 把 0.0 ~ 1.0 的透明度映射到 0 ~ 255 的整型 alpha
    let a: number = Math.round(this.strokeOpacity * 255)

    // 防御：防止计算结果越界
    if (a < 0) {
      a = 0
    } else if (a > 255) {
      a = 255
    }

    return a // 返回最终可用于写像素的 alpha 值
  }

  // 把绘制图层 overlayPm 合成到 basePm 上，只修改 basePm 本身
  // 规则很简单：只要 overlay 的某个像素 alpha > 0，就用 overlay 的 RGBA 直接覆盖 base
  private async mergeDrawLayerIntoBase(
    basePm: image.PixelMap,
    overlayPm: image.PixelMap
  ): Promise<void> {
    // 读取底图和绘制层的基本信息
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const overInfo: image.ImageInfo = await overlayPm.getImageInfo()

    const width: number = baseInfo.size.width
    const height: number = baseInfo.size.height

    // 尺寸不一致时直接放弃，避免数组越界
    if (overInfo.size.width !== width || overInfo.size.height !== height) {
      console.warn(
        `mergeDrawLayerIntoBase: size mismatch base=${width}x${height} over=${overInfo.size.width}x${overInfo.size.height}`
      )
      return
    }

    // 为底图和绘制层各准备一个像素缓冲区
    const baseLen: number = basePm.getPixelBytesNumber()
    const overLen: number = overlayPm.getPixelBytesNumber()

    const baseBuf: ArrayBuffer = new ArrayBuffer(baseLen)
    const overBuf: ArrayBuffer = new ArrayBuffer(overLen)

    // 把 PixelMap 的像素读到内存里
    await basePm.readPixelsToBuffer(baseBuf)
    await overlayPm.readPixelsToBuffer(overBuf)

    const baseData: Uint8Array = new Uint8Array(baseBuf)
    const overData: Uint8Array = new Uint8Array(overBuf)

    // 根据像素格式，拿到 RGBA 在一个像素里的偏移
    const bch: ChannelOrder = this.getChannelOrder(baseInfo.pixelFormat)
    const och: ChannelOrder = this.getChannelOrder(overInfo.pixelFormat)

    // 每像素字节数必须一致，否则直接退出
    if (bch.bytesPerPixel !== och.bytesPerPixel) {
      console.warn(
        `mergeDrawLayerIntoBase: bytesPerPixel mismatch base=${bch.bytesPerPixel} over=${och.bytesPerPixel}`
      )
      return
    }
    const bpp: number = bch.bytesPerPixel

    // 逐像素扫描整张图
    for (let y: number = 0; y < height; y++) {
      for (let x: number = 0; x < width; x++) {
        const idx: number = (y * width + x) * bpp // 当前像素起始位置

        const oaIdx: number = idx + och.a // overlay 的 alpha 索引
        if (oaIdx < 0 || oaIdx >= overData.length) {
          continue
        }

        const alphaOver: number = overData[oaIdx]
        if (alphaOver === 0) {
          // overlay 这里是透明的，说明没画内容，直接跳过
          continue
        }

        // overlay 的 RGB 索引
        const orIdx: number = idx + och.r
        const ogIdx: number = idx + och.g
        const obIdx: number = idx + och.b

        // base 的 RGBA 索引
        const brIdx: number = idx + bch.r
        const bgIdx: number = idx + bch.g
        const bbIdx: number = idx + bch.b
        const baIdx: number = idx + bch.a

        // 再做一次越界保护
        if (
          orIdx < 0 || orIdx >= overData.length ||
            ogIdx < 0 || ogIdx >= overData.length ||
            obIdx < 0 || obIdx >= overData.length
        ) {
          continue
        }
        if (
          brIdx < 0 || brIdx >= baseData.length ||
            bgIdx < 0 || bgIdx >= baseData.length ||
            bbIdx < 0 || bbIdx >= baseData.length ||
            baIdx < 0 || baIdx >= baseData.length
        ) {
          continue
        }

        // overlay 不透明 → 直接覆盖 base
        baseData[brIdx] = overData[orIdx]
        baseData[bgIdx] = overData[ogIdx]
        baseData[bbIdx] = overData[obIdx]
        baseData[baIdx] = alphaOver // 保留 overlay 的 alpha
      }
    }

    // 把合成后的像素写回底图
    await basePm.writeBufferToPixels(baseBuf)
  }

  // 仅用于“保存图片”：
  // 把当前 brightnessLevel / contrastLevel 的效果直接“烘焙”进像素数据里
  private async bakeToneForSave(pm: image.PixelMap): Promise<void> {
    // 如果亮度和对比度都为默认值，说明没有任何调整，直接返回
    if (this.brightnessLevel === 0 && this.contrastLevel === 0) {
      return
    }

    // 读取像素格式和尺寸信息
    const info: image.ImageInfo = await pm.getImageInfo()

    // 申请一块 ArrayBuffer，用来承载整张图的像素数据
    const byteLength: number = pm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)

    // 把 PixelMap 的像素数据读到 buffer 中
    await pm.readPixelsToBuffer(buffer)

    // 用 Uint8Array 视图来逐字节操作 RGBA 数据
    const data: Uint8Array = new Uint8Array(buffer)

    // 根据像素格式，统一获取各通道的偏移位置
    const ch: ChannelOrder = this.getChannelOrder(info.pixelFormat)
    const rOffset: number = ch.r
    const gOffset: number = ch.g
    const bOffset: number = ch.b
    const aOffset: number = ch.a

    // === 亮度 / 对比度计算===
    // 对比度系数：contrastLevel = 0 时，c = 1
    const c: number = 1.0 + this.contrastLevel

    // 亮度偏移：brightnessLevel 是 [-1, 1]，映射到 [-255, 255]
    const shiftBrightness: number = this.brightnessLevel * 255.0

    // 综合偏移量：保证对比度变化是围绕 128 中心展开
    const shiftTotal: number = 128.0 * (1.0 - c) + shiftBrightness

    // 限制数值到 [0, 255]，防止溢出
    const clamp = (v: number): number => {
      if (v < 0) {
        return 0
      }
      if (v > 255) {
        return 255
      }
      return v
    }

    // 遍历整张图的像素数据
    // 每 4 个字节是一组像素（RGBA / BGRA / ARGB）
    for (let i: number = 0; i < data.length; i += 4) {
      const rIndex: number = i + rOffset
      const gIndex: number = i + gOffset
      const bIndex: number = i + bOffset
      const aIndex: number = i + aOffset

      // 读取原始 RGB 值
      const r: number = data[rIndex]
      const g: number = data[gIndex]
      const b: number = data[bIndex]

      // 对 RGB 应用亮度 + 对比度公式
      data[rIndex] = clamp(c * r + shiftTotal)
      data[gIndex] = clamp(c * g + shiftTotal)
      data[bIndex] = clamp(c * b + shiftTotal)

      // alpha 通道保持不变（透明度不受影响）
      data[aIndex] = data[aIndex]
    }

    // 把处理后的像素数据写回 PixelMap
    await pm.writeBufferToPixels(buffer)
  }

  // 把屏幕上的画笔粗细 strokeWidth 换算成图片里的像素半径，保证缩放前后看起来一样粗
  private computeStrokeRadiusPixel(imgW: number, imgH: number): number {
    const MIN_RADIUS: number = 1 // 半径最小值，避免算出 0 画不出来

    // 画布尺寸异常时兜底，直接用 strokeWidth 当像素半径
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return Math.max(MIN_RADIUS, Math.floor(this.strokeWidth))
    }

    // 按 contain 规则计算图片在画布中的基础缩放比例
    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )

    // 实际缩放倍数 = 基础缩放 × 当前 zoom
    const realScale: number = scaleBase * this.zoom

    // 缩放异常时兜底，直接用 strokeWidth
    if (realScale <= 0) {
      return Math.max(MIN_RADIUS, Math.floor(this.strokeWidth))
    }

    // 屏幕上的画笔半径除以缩放倍数，得到真实写入像素的半径
    let r: number = this.strokeWidth / realScale

    // 半径太小时强制给个最小值，避免看不见
    if (r < MIN_RADIUS) {
      r = MIN_RADIUS
    }

    // 像素半径取整即可
    return Math.floor(r)
  }

  // 确保指定 clientId 的远端用户存在于在线用户列表中，不存在则创建并加入
  private ensureRemoteUser(clientId: string): void {
    // 如果这个 clientId 已经在在线用户列表里了，就不用再加一次
    const existed: OnlineUserInfo | undefined = this.onlineUsers
      .find((u: OnlineUserInfo) => u.clientId === clientId);
    if (existed) {
      return;
    }

    // 根据 clientId 生成一个固定的显示颜色，同一个用户颜色始终一致
    const color: string = this.pickColorForClient(clientId);

    // 构造远端用户信息，这里明确标记不是自己
    const remoteUser: OnlineUserInfo = {
      clientId: clientId,
      displayColor: color,
      isSelf: false
    };

    // 把新用户追加到在线用户列表，用新数组触发状态更新
    this.onlineUsers = [...this.onlineUsers, remoteUser];
  }

  // 根据 clientId 计算一个稳定的颜色，用于给远端用户分配固定显示颜色
  private pickColorForClient(clientId: string): string {
    // 使用一个简单的字符串 hash 算法，把 clientId 映射成一个 32 位无符号整数
    let hash: number = 0;
    for (let i = 0; i < clientId.length; i++) {
      // hash * 31 是常见做法，charCodeAt 提供字符的数值表示
      hash = (hash * 31 + clientId.charCodeAt(i)) >>> 0; // 强制转成无符号 32bit
    }

    // 颜色调色板的大小
    const paletteSize: number = this.userColorPalette.length;
    if (paletteSize === 0) {
      // 调色板为空时的兜底颜色，避免数组越界
      return '#000000';
    }

    // 用 hash 对调色板长度取模，保证索引一定落在有效范围内
    const idx: number = hash % paletteSize;

    // 返回对应的颜色；同一个 clientId 永远得到同一个颜色
    return this.userColorPalette[idx];
  }

  // 把当前画面广播给其他协作端，用于实时同步画布内容（不影响本地撤销栈）
  private async syncCanvasToOthers(): Promise<void> {
    // 没有开启协作功能时，不做任何同步
    if (!this.collabEnabled) {
      return;
    }

    // 协作客户端不存在或未连接，说明当前无法发送数据，直接跳过
    if (!this.collabClient || !this.collabClient.connected) {
      console.info('[Collab] not connected, skip syncCanvasToOthers');
      return;
    }

    // 当前没有有效的像素数据，没必要同步
    if (!this.pixelMap) {
      console.info('[Collab] no pixelMap, skip syncCanvasToOthers');
      return;
    }

    // 使用最近一次操作的描述，作为本次同步的说明信息，便于对端理解变更
    const desc: string = this.lastOpDesc || '';

    // 把当前画面和操作描述一起广播给所有已连接的协作端
    await this.broadcastImageToPeers(this.pixelMap as image.PixelMap, desc);
  }

  // 操作记录：向操作日志列表中追加一条记录，用于本地展示和协作提示
  private appendOpLog(userId: string, message: string, colorOpt?: string): void {
    // 优先使用外部传入的颜色（例如本机操作时传入的本地用户颜色）
    let color: string | undefined = colorOpt;

    // 如果没有显式传颜色，则从在线用户列表中查找该用户对应的显示颜色
    if (!color) {
      const u: OnlineUserInfo | undefined = this.onlineUsers
        .find((item: OnlineUserInfo) => item.clientId === userId);
      if (u) {
        color = u.displayColor;
      }
    }

    // 如果仍然没有颜色，则根据 userId 计算一个稳定颜色作为兜底
    if (!color) {
      color = this.pickColorForClient(userId);
    }

    // 生成当前时间戳，用于日志显示
    const now: Date = new Date();
    const ts: string = this.formatTime(now);

    // 生成递增的日志 id，保证列表中每条记录都有唯一标识
    const id: number = ++this.opSeq;

    // 构造一条完整的操作日志对象
    const item: OperationLogItem = {
      id: id,
      userId: userId,
      userColor: color,
      message: message,
      timestamp: ts
    };

    // 将新日志追加到列表末尾
    // 为了避免日志无限增长，只保留最近的 maxLen 条
    const maxLen: number = 50;
    const list: Array<OperationLogItem> = [...this.opLogList, item];
    if (list.length > maxLen) {
      list.shift(); // 超出上限时，移除最早的一条日志
    }

    // 更新操作日志列表，触发 UI 刷新
    this.opLogList = list;
  }

  // 时间格式化 HH:MM:SS
  private formatTime(d: Date): string {
    const h: string = d.getHours().toString().padStart(2, '0');
    const m: string = d.getMinutes().toString().padStart(2, '0');
    const s: string = d.getSeconds().toString().padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  // 把当前画面（底图 + 绘制层 + 亮度/对比度）打包成 PNG + base64，并通过 WebSocket 同步给所有协作端
  private async broadcastImageToPeers(pm: image.PixelMap, opDesc: string): Promise<void> {
    // 克隆一份临时 PixelMap 用于发送，避免直接修改当前正在使用的 pixelMap
    const sendPm: image.PixelMap = await this.clonePixelMap(pm)

    try {
      // 如果存在绘制层，则先把绘制层内容合并到发送用的 PixelMap 上
      if (this.drawPixelMap) {
        await this.mergeDrawLayerIntoBase(sendPm, this.drawPixelMap as image.PixelMap)
      }

      // 把当前亮度和对比度调整结果烘焙进 sendPm，只影响发送内容
      await this.bakeToneForSave(sendPm)

      // 创建 ImagePacker，把 PixelMap 打包成 PNG 格式
      const packer = image.createImagePacker()
      const packOpts: image.PackingOption = {
        format: 'image/png',
        quality: 100
      }

      // 将 PixelMap 转成 PNG 的 ArrayBuffer
      const pngBuffer: ArrayBuffer = await packer.packToData(sendPm, packOpts)
      packer.release?.() // 打包完成后释放 packer 资源

      // 把 PNG 的 ArrayBuffer 转成 base64，方便通过 WebSocket 传输
      const pngBase64: string = this.arrayBufferToBase64(pngBuffer)

      // 确定发送方 clientId，优先使用本地 clientId
      const senderId: string = this.localClientId || this.clientId

      // 构造协作同步消息，包含图片数据和本次操作描述
      const msg: CollabMessage = {
        type: 'imageSync',
        clientId: senderId,
        payload: {
          format: 'image/png',
          dataBase64: pngBase64,
          opDesc: opDesc
        } as CollabImageSyncPayload
      }

      // 通过协作客户端把消息发送给所有已连接的协作端
      this.collabClient.send(msg)
      console.info('[Collab] broadcast image-sync, size(base64)=', pngBase64.length)
    } finally {
      // 无论成功还是失败，都要释放临时 PixelMap，避免内存泄漏
      sendPm.release?.()
    }
  }

  // 统一封装：每次图像内容发生变化后，记录一条操作日志，并在需要时同步给其他协作端
  private async logAndSyncAfterImageChange(opDesc: string): Promise<void> {
    // 确定本机的用户 id，优先使用 localClientId
    const selfId: string = this.localClientId || this.clientId

    // 先在本地追加一条操作日志，颜色使用本机的显示颜色
    this.appendOpLog(selfId, opDesc, this.localColor)

    // 保存这次操作描述，供后续协作同步时使用
    this.lastOpDesc = opDesc

    // 如果未开启协作、未连接成功或当前没有图像，则只记录日志，不做同步
    if (
      !this.collabEnabled ||
        !this.collabClient ||
        !this.collabClient.connected ||
        !this.pixelMap
    ) {
      return
    }

    // 默认直接使用当前的 pixelMap 作为发送对象
    let pmForSend: image.PixelMap = this.pixelMap as image.PixelMap

    // 如果当前存在亮度或对比度调整，需要先克隆并把调整结果烘焙进临时图像
    if (this.brightnessLevel !== 0 || this.contrastLevel !== 0) {
      const cloned: image.PixelMap = await this.clonePixelMap(pmForSend) // 克隆一份临时图
      await this.bakeToneForSave(cloned) // 把亮度和对比度效果写入临时图
      pmForSend = cloned
    }

    // 通过 WebSocket 把当前画面和操作描述广播给所有协作端
    await this.broadcastImageToPeers(pmForSend, opDesc)

    // 如果发送用的是临时克隆的 PixelMap，用完后及时释放
    if (pmForSend !== this.pixelMap) {
      pmForSend.release?.()
    }
  }

  // 把一个 ArrayBuffer 转成 base64 字符串，方便通过网络传输
  private arrayBufferToBase64(buf: ArrayBuffer): string {
    const uint8: Uint8Array = new Uint8Array(buf) // 把二进制缓冲区包装成字节数组
    const base64Helper: util.Base64Helper = new util.Base64Helper() // 创建 base64 编解码工具
    const base64Str: string = base64Helper.encodeToStringSync(uint8) // 同步编码成 base64 字符串
    return base64Str // 返回结果
  }

  // 把 base64 字符串还原成 ArrayBuffer，用于恢复二进制数据
  private base64ToArrayBuffer(b64: string): ArrayBuffer {
    const base64Helper: util.Base64Helper = new util.Base64Helper() // 创建 base64 编解码工具
    const uint8: Uint8Array = base64Helper.decodeSync(b64) // 把 base64 解码成字节数组
    const buf: ArrayBuffer = uint8.buffer as ArrayBuffer // 直接取底层的 ArrayBuffer
    return buf // 返回二进制缓冲区
  }

  // 把远端同步过来的 base64 PNG 解码成 PixelMap，并整体替换本地画面
  private async applyRemoteImage(payload: CollabImageSyncPayload): Promise<void> {
    // 把 base64 的 PNG 数据解码成 ArrayBuffer
    const buf: ArrayBuffer = this.base64ToArrayBuffer(payload.dataBase64)
    // 用二进制数据创建 ImageSource
    const imgSource: image.ImageSource = image.createImageSource(buf)
    // 从 ImageSource 生成可编辑的 PixelMap
    const remotePm: image.PixelMap = await imgSource.createPixelMap({ editable: true })
    imgSource.release?.() // 释放 ImageSource，避免资源泄漏

    // 在替换为远端画面前，把当前画面压入历史栈，支持撤销
    if (this.pixelMap) {
      const currentPm: image.PixelMap = this.pixelMap as image.PixelMap
      const backupPm: image.PixelMap = await this.clonePixelMap(currentPm)
      await this.pushHistorySnapshot(true, backupPm)
    }

    // 释放当前底图 PixelMap
    if (this.pixelMap) {
      (this.pixelMap as image.PixelMap).release?.()
    }

    // 用远端传来的 PixelMap 直接作为新的底图
    this.pixelMap = remotePm

    // 更新 originalPixelMap，后续 resetView 以协作后的状态为基准
    if (this.originalPixelMap) {
      this.originalPixelMap.release?.()
    }
    this.originalPixelMap = await this.clonePixelMap(remotePm)

    // 清空绘制层，协作图像已经是“拍平”的最终结果
    if (this.drawPixelMap) {
      this.drawPixelMap.release?.()
      this.drawPixelMap = undefined
    }
    this.drawPixelVersion++ // 通知叠加层发生变化

    console.info('[Collab] applyRemoteImage: replace pixelMap from remote and clear draw layer')

    // 重置视图相关参数，避免远端状态影响本地显示
    this.zoom = 1.0
    this.offsetX = 0
    this.offsetY = 0
    this.brightnessLevel = 0.0
    this.contrastLevel = 0.0
    this.accumulatedRotate = 0

    // 更新像素版本号，驱动 UI 刷新
    this.pixelVersion++
  }

  // 在任何会修改画面的操作之前，先保存一份“完整画面”的快照，用于撤销
  private async pushFullSnapshotBeforeChange(): Promise<void> {
    if (!this.pixelMap) {
      return // 当前没有底图，没必要记录快照
    }

    const currentPm: image.PixelMap = this.pixelMap as image.PixelMap // 当前正在显示的底图

    // 必须 clone 一份新的 PixelMap，不能直接引用原来的 pixelMap
    const backupPm: image.PixelMap = await this.clonePixelMap(currentPm)

    // 把这份克隆后的完整图像压入历史栈，标记为包含像素数据
    await this.pushHistorySnapshot(true, backupPm)
  }
}
