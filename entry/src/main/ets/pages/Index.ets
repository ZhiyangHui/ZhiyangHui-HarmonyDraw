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


@Entry
@Component
struct Index {
  // 画布状态
  @State pixelMap?: image.PixelMap = undefined
  @State zoom: number = 1.0
  @State offsetX: number = 0
  @State offsetY: number = 0
  @State pixelVersion: number = 0
  // ================= 新增：绘制图层 =================
  // 专门用来画线条/形状，橡皮擦只擦这个层
  @State drawPixelMap?: image.PixelMap = undefined
  @State drawPixelVersion: number = 0
  // ==================================================
  // 旋转中标志，防止连点导致两次右旋
  private isRotating: boolean = false
  private accumulatedRotate: number = 0 // 之前旋转的总度数
  // 旋转 / 亮度 / 对比度
  @State rotateDeg: number = 0 // 旋转角度
  @State brightnessLevel: number = 0.0 // -0.5 ~ 0.5 左右，0 是原图
  @State contrastLevel: number = 0.0 // -1.0 ~ 1.0（0 是原图对比度）
  @State showLeftPanel: boolean = false // 左侧工具栏是否展开
  @State currentTool: string = '' // 当前选择的工具类型（point/line/rect...）
  @State activeMenu: TopMenu = TopMenu.None // 当前展开的顶栏菜单
  @State currentShape: ShapeTool = ShapeTool.None
  @State currentBrush: BrushTool = BrushTool.Pen // 默认就是普通画笔
  // 顶部菜单当前选中的一级菜单：image / shape / brush / ''(不显示二级)
  @State currentMenu: string = 'image'
  // 当前二级菜单（形状 / 画笔才会使用）
  @State currentSubTool: string = ''
  // 手势内部状态
  private lastPanX: number = 0
  private lastPanY: number = 0
  private lastZoom: number = 1.0
  // 裁剪模式 开/关
  @State cropMode: boolean = false
  // 手势选择框（UI 坐标）
  @State cropStartX: number = 0
  @State cropStartY: number = 0
  @State cropEndX: number = 0
  @State cropEndY: number = 0
  // 画布大小（为了把 UI 坐标比例映射成像素坐标）
  @State canvasWidth: number = 0
  @State canvasHeight: number = 0
  // 撤销用的历史栈（不需要响应式）
  private history: Array<CanvasSnapshot> = []
  private historyIndex: number = -1
  private readonly historyLimit: number = 10
  // 新增：记录“打开图片时的原图快照”
  private originalPixelMap?: image.PixelMap = undefined
  //全局画笔样式（形状 + 画笔共享）
  @State strokeWidth: number = 4 // 像素半径，细笔/粗笔一起改这个
  @State strokeR: number = 0 // 默认黑色
  @State strokeG: number = 0
  @State strokeB: number = 0
  @State strokeOpacity: number = 1.0 // 0.0 ~ 1.0 画笔透明度（暂时只作为 UI）
  // 当前是否正在绘制一个形状（线、矩形、圆等）
  private isShapeDrawing: boolean = false
  // 通用形状绘制的起点（UI 坐标）
  private shapeStartUiX: number = 0
  private shapeStartUiY: number = 0
  // 自由绘制状态（形状 = ShapeTool.FreeDraw 时使用）
  private isFreeDrawing: boolean = false
  private freeLastUiX: number = 0
  private freeLastUiY: number = 0
  // 自由画开始时缓存原图像素
  private freeDrawBuffer: Uint8Array | null = null
  private freeDrawArrayBuffer: ArrayBuffer | null = null
  private freeDrawByteLength: number = 0
  private freeBufferReady: boolean = false
  // 当前底图的对角线长度（像素），用于裁剪时温和缩放画笔
  @State imageDiag: number = 0
  // ==== 新增：协作 WebSocket 客户端 ====
  // 把下面的 192.168.1.100 换成你运行 Node.js 服务器那台电脑的局域网 IP
  // 不能用 0.0.0.0，要用具体 IP，比如 192.168.0.5
  private collabClient: CollabClient = new CollabClient(
    'ws://101.43.185.73:8080/collab'
  );
  // 给当前设备一个固定 id（不要每次点击都变）
  @State localClientId: string = ''; // 服务器分配给自己的 id
  @State localColor: string = '#000000'; // 自己的代表色
  // 在线用户列表（包含自己和别人）
  @State onlineUsers: Array<OnlineUserInfo> = [];
  // 本机 clientId（给 CollabClient 用的那个 id，要保持一致）
  private clientId: string = 'client-' + Date.now().toString();
  // 简单的颜色池，按顺序给不同用户分颜色
  private userColorPalette: Array<string> = [
    '#2563EB', // 蓝
    '#EC4899', // 粉
    '#10B981', // 绿
    '#F97316', // 橙
    '#A855F7',// 紫
  ];
  private nextColorIndex: number = 0;
  // 是否参与协作（控制是否连 WebSocket）
  @State collabEnabled: boolean = true;
  @State showOpLog: boolean = false; // 是否展开操作记录面板
  @State opLogList: Array<OperationLogItem> = []; // 操作记录队列
  private opSeq: number = 0; // 本地自增 id
  private lastOpDesc: string = ''; //上一个协作操作

  // ====== 新增：生命周期里初始化 / 关闭 WebSocket ======
  // ====== 生命周期：页面出现时初始化 WebSocket ======
  aboutToAppear(): void {
    this.collabClient.setCallbacks(
      () => {
        // onOpen
        console.log('[Collab] WebSocket open');

        if (!this.collabEnabled) {
          this.collabClient.close();
          return;
        }

        this.onlineUsers = [];
      },
      () => {
        console.log('[Collab] WebSocket close');
        this.onlineUsers = [];
        this.localClientId = ''; // 断开后清空
      },
      (msg: CollabMessage) => {
        console.log('[Collab] message = ' + JSON.stringify(msg));

        // 🔴 远端用户：把不等于我的 clientId 的用户加入 remote 列表
        if (msg.clientId && msg.clientId !== this.clientId) {
          this.ensureRemoteUser(msg.clientId);
        }

        // ========== ① 处理 assignId ==========
        if (msg.type === 'assignId') {
          const payload = msg.payload as CollabAssignIdPayload | undefined;

          // 服务器分配给我的真正 clientId
          this.localClientId = msg.clientId ?? '';

          // 使用服务器给的颜色
          const color: string =
            (payload && payload.displayColor) ||
            this.pickColorForClient(this.localClientId || this.clientId);

          this.localColor = color;

          const selfUser: OnlineUserInfo = {
            clientId: this.localClientId || this.clientId,
            displayColor: color,
            isSelf: true
          };

          // 在线列表里加入自己
          this.onlineUsers = [selfUser];

          console.info('[Collab] assigned id = ' + this.localClientId);
          return;
        }

        // ========== ② ⚡ 处理 onlineUsers 新消息（放在 assignId 后、其他消息前） ==========
        if (msg.type === 'onlineUsers') {
          const payload = msg.payload as OnlineUsersPayload;
          this.onlineUsers = payload.users.map((u: OnlineUserItem): OnlineUserInfo => {
            const info: OnlineUserInfo = {
              clientId: u.clientId,
              displayColor: u.displayColor,
              isSelf: u.clientId === this.localClientId
            };
            return info;
          });
        }


        // ========== ③ clear 消息 ==========
        if (msg.type === 'clear') {
          console.log('[Collab] remote clear layer, do resetView()');
          this.resetView();

          // 只记录别的用户的清空操作
          const selfId: string = this.localClientId || this.clientId;
          if (msg.clientId && msg.clientId !== selfId) {
            // 不再自己算颜色，appendOpLog 会自己从 onlineUsers 里找
            this.appendOpLog(msg.clientId, '清空画布');
          }
        }


        // ========== ④ imageSync 图片同步 ==========
        if (msg.type === 'imageSync') {
          const payload = msg.payload as CollabImageSyncPayload;
          console.info('[Collab] receive image-sync from: ' + msg.clientId);

          // 记录远端更新画布（同样跳过自己发的 echo）
          const selfId: string = this.localClientId || this.clientId;
          if (msg.clientId && msg.clientId !== selfId) {
            const desc: string = payload.opDesc ?? '更新了画布';
            // 不传 color，让 appendOpLog 自己从 onlineUsers 取颜色
            this.appendOpLog(msg.clientId, desc);
          }

          this.applyRemoteImage(payload).then(() => {
            console.info('[Collab] remote image applied');
            promptAction.showToast({ message: '已加载协作图片' });
          });
        }


        // 更多消息类型在这里扩展...
      },
      (err: string) => {
        console.error('[Collab] error = ' + err);
      }
    );

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

              // ✅ 新增：一级按钮：分享
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


                  // ===== 第 2 行：粗细调节 Slider =====
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


                  // ===== 第 3 行：透明度 Slider =====
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


                  // ---- 第五行：颜色预览（可选） ----
                  Row() {
                    // ===== 第 1 行：橡皮擦 =====
                    Row({ space: 8 }) {
                      Button('橡皮擦', { type: ButtonType.Normal })
                        .height(28)
                        .fontSize(11)
                        .backgroundColor(this.currentBrush === BrushTool.Eraser ? '#FB923C' : '#FEF3C7')
                        .fontColor(this.currentBrush === BrushTool.Eraser ? '#FFFFFF' : '#92400E')
                        .onClick(() => {
                          if (this.currentBrush === BrushTool.Eraser) {
                            // 👉 再点一次：关闭橡皮擦，恢复普通画笔
                            this.currentBrush = BrushTool.Pen
                            // 自由画保持不变，用户可以继续用普通画笔自由画
                          } else {
                            // 👉 第一次点：开启橡皮擦 + 进入自由绘制模式
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
          Row({ space: 8 }) { // 用较小 space 控制组件之间的固定间距
            // 左侧：协作按钮（稍微缩小）
            Button(this.collabEnabled ? '断开协作' : '加入协作', { type: ButtonType.Capsule })
              .height(24)             // 原来 28，稍微缩小
              .fontSize(10)           // 原来 11
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

            // 操作记录按钮（也缩小一点）
            Button(this.showOpLog ? '收起记录' : '操作记录', { type: ButtonType.Capsule })
              .height(22)             // 原来 24
              .fontSize(10)           // 原来 11
              .backgroundColor(this.showOpLog ? '#DBEAFE' : '#E5E7EB')
              .fontColor('#111827')
              .onClick(() => {
                this.showOpLog = !this.showOpLog
              })

            // 在线用户区域整体放到一个水平 Scroll 里
            // 这样当用户很多时可以左右滑动
            Scroll() {
              Row({ space: 4 }) { // 内部再稍微紧凑一些
                // 中间标题：“在线：” 更短更窄
                Text('在线：')
                  .fontSize(10)
                  .fontColor('#6B7280')

                // 在线用户标签（紧挨着“在线：”）
                Row({ space: 4 }) {
                  ForEach(this.onlineUsers, (u: OnlineUserInfo) => {
                    Row() {
                      // 彩色小方块
                      Rect()
                        .width(8)    // 原来 10
                        .height(8)
                        .radius(2)
                        .fill(u.displayColor)
                        .margin({ right: 4 })

                      Text(u.isSelf ? '我(' + u.clientId + ')' : u.clientId)
                        .fontSize(10)          // 更小一点
                        .fontColor('#111827')
                    }
                    .padding({
                      left: 6, // 原来 8
                      right: 6,
                      top: 2, // 原来 3
                      bottom: 2
                    })
                    .backgroundColor(u.isSelf ? '#DBEAFE' : '#E5E7EB')
                    .borderRadius(999)
                  }, (u: OnlineUserInfo) => u.clientId)
                }
              }
              .height(26) // 控制整个在线用户区的高度更紧凑
            }
            .scrollable(ScrollDirection.Horizontal) // ✅ 水平滚动
            .layoutWeight(1) // 占据剩余空间，自适应压缩，不撑开左侧按钮
          }
          .justifyContent(FlexAlign.Start) // 整行靠左排
          .alignItems(VerticalAlign.Center) // 垂直居中
          .padding({
            left: 12,
            right: 12,
            top: 4, // 原来 6，稍微减一点
            bottom: 4
          })
          .backgroundColor('#F9FAFB')

          // ===== 操作记录区域，保持你原来的逻辑不变 =====
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


                          // ✅ 情况 2：直线 / 矩形 / 圆 / 椭圆：拖出一个形状
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

                          // ✅ 情况 3：其他情况 → 当成平移画布
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

                          // 👉 正在画图形（线 / 矩形 / 圆 / 椭圆）时，不平移
                          if (this.isShapeDrawing &&
                            (this.currentShape === ShapeTool.Line ||
                              this.currentShape === ShapeTool.Rect ||
                              this.currentShape === ShapeTool.Circle ||
                              this.currentShape === ShapeTool.Ellipse)) {
                            return
                          }

                          // 👉 否则：平移画布
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

                          const f = e.fingerList[0] // ← 已去掉 GestureFinger

                          const endUiX: number = f.localX
                          const endUiY: number = f.localY


                          // ③ 图形结束：直线 / 矩形 / 圆 / 椭圆
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

  private async shareToWeChat(): Promise<void> {
  }

  private async shareToWeibo(): Promise<void> {
  }

  private async shareByEmail(): Promise<void> {
  }

  private async loadLogoPixelMap(): Promise<image.PixelMap> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const resMgr = context.resourceManager;

    const logoId: number = $r('app.media.logo').id;

    // 读出二进制数据（Uint8Array）
    const fileData: Uint8Array = await resMgr.getMediaContent(logoId);

    // ⭐ 关键：只取这一段的有效数据，避免使用整个 buffer 带来的脏数据
    const buffer: ArrayBuffer = fileData.buffer.slice(
      fileData.byteOffset,
      fileData.byteOffset + fileData.byteLength
    );

    const imgSource: image.ImageSource = image.createImageSource(buffer);
    const logoPm: image.PixelMap = await imgSource.createPixelMap({
      editable: true
    });
    imgSource.release?.();

    return logoPm;
  }

  // 在绘制层 layerPm 上，把 watermarkPm 按 (offsetX, offsetY) 贴上去
  private async pasteWatermarkIntoLayer(
    layerPm: image.PixelMap,
    watermarkPm: image.PixelMap,
    offsetX: number,
    offsetY: number
  ): Promise<void> {
    const layerInfo: image.ImageInfo = await layerPm.getImageInfo();
    const wmInfo: image.ImageInfo = await watermarkPm.getImageInfo();

    const layerW: number = layerInfo.size.width;
    const layerH: number = layerInfo.size.height;
    const wmW: number = wmInfo.size.width;
    const wmH: number = wmInfo.size.height;

    // 尺寸兜底：完全在外面就不用画
    if (wmW <= 0 || wmH <= 0 || layerW <= 0 || layerH <= 0) {
      console.info('>>> pasteWatermarkIntoLayer: invalid size, skip');
      return;
    }

    // 读取像素数据
    const layerLen: number = layerPm.getPixelBytesNumber();
    const wmLen: number = watermarkPm.getPixelBytesNumber();

    const layerBuf: ArrayBuffer = new ArrayBuffer(layerLen);
    const wmBuf: ArrayBuffer = new ArrayBuffer(wmLen);

    await layerPm.readPixelsToBuffer(layerBuf);
    await watermarkPm.readPixelsToBuffer(wmBuf);

    const layerData: Uint8Array = new Uint8Array(layerBuf);
    const wmData: Uint8Array = new Uint8Array(wmBuf);

    // ------- layer 通道偏移 -------
    let lrOff: number = 0;
    let lgOff: number = 1;
    let lbOff: number = 2;
    let laOff: number = 3;

    switch (layerInfo.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        lbOff = 0;
        lgOff = 1;
        lrOff = 2;
        laOff = 3;
        break;
      case image.PixelMapFormat.ARGB_8888:
        laOff = 0;
        lrOff = 1;
        lgOff = 2;
        lbOff = 3;
        break;
      case image.PixelMapFormat.RGBA_8888:
      default:
        lrOff = 0;
        lgOff = 1;
        lbOff = 2;
        laOff = 3;
        break;
    }

    // ------- watermark 通道偏移 -------
    let wrOff: number = 0;
    let wgOff: number = 1;
    let wbOff: number = 2;
    let waOff: number = 3;

    switch (wmInfo.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        wbOff = 0;
        wgOff = 1;
        wrOff = 2;
        waOff = 3;
        break;
      case image.PixelMapFormat.ARGB_8888:
        waOff = 0;
        wrOff = 1;
        wgOff = 2;
        wbOff = 3;
        break;
      case image.PixelMapFormat.RGBA_8888:
      default:
        wrOff = 0;
        wgOff = 1;
        wbOff = 2;
        waOff = 3;
        break;
    }

    // 简单策略：只要 watermark 像素 alpha > 0，就直接覆盖绘制层对应像素
    for (let wy: number = 0; wy < wmH; wy++) {
      const ty: number = offsetY + wy;
      if (ty < 0 || ty >= layerH) {
        continue;
      }

      for (let wx: number = 0; wx < wmW; wx++) {
        const tx: number = offsetX + wx;
        if (tx < 0 || tx >= layerW) {
          continue;
        }

        const wmIdx: number = (wy * wmW + wx) * 4;
        const waIdx: number = wmIdx + waOff;
        const alpha: number = wmData[waIdx];

        if (alpha === 0) {
          // 水印这点完全透明，不用管
          continue;
        }

        const lrIdx: number = (ty * layerW + tx) * 4 + lrOff;
        const lgIdx: number = (ty * layerW + tx) * 4 + lgOff;
        const lbIdx: number = (ty * layerW + tx) * 4 + lbOff;
        const laIdx: number = (ty * layerW + tx) * 4 + laOff;

        const wrIdx: number = wmIdx + wrOff;
        const wgIdx: number = wmIdx + wgOff;
        const wbIdx: number = wmIdx + wbOff;

        layerData[lrIdx] = wmData[wrIdx];
        layerData[lgIdx] = wmData[wgIdx];
        layerData[lbIdx] = wmData[wbIdx];
        layerData[laIdx] = alpha;
      }
    }

    await layerPm.writeBufferToPixels(layerBuf);
  }

  // 调整水印大小
  // 调整水印大小为目标尺寸
  // 把水印缩放到不超过 targetWidth x targetHeight（保持长宽比）
  // 如果本来就比目标小，就不缩放
  private async resizeWatermark(
    watermarkPm: image.PixelMap,
    targetWidth: number,
    targetHeight: number
  ): Promise<image.PixelMap> {
    const wmInfo: image.ImageInfo = await watermarkPm.getImageInfo();
    const srcW: number = wmInfo.size.width;
    const srcH: number = wmInfo.size.height;

    // 水印本来就比目标小，直接用原图
    if (srcW <= targetWidth && srcH <= targetHeight) {
      return watermarkPm;
    }

    // 计算缩放比例（保持长宽比，最长边 = target）
    const scaleX: number = targetWidth / srcW;
    const scaleY: number = targetHeight / srcH;
    const scale: number = Math.min(scaleX, scaleY);

    // 得到新的宽高（至少 1 像素）
    const newW: number = Math.max(1, Math.floor(srcW * scale));
    const newH: number = Math.max(1, Math.floor(srcH * scale));

    // 读取原始水印像素
    const srcLen: number = watermarkPm.getPixelBytesNumber();
    const srcBuf: ArrayBuffer = new ArrayBuffer(srcLen);
    await watermarkPm.readPixelsToBuffer(srcBuf);
    const srcData: Uint8Array = new Uint8Array(srcBuf);

    // 准备目标像素缓冲区（我们用 RGBA_8888）
    const dstBuf: ArrayBuffer = new ArrayBuffer(newW * newH * 4);
    const dstData: Uint8Array = new Uint8Array(dstBuf);

    // 源像素通道偏移
    let srOff: number = 0;
    let sgOff: number = 1;
    let sbOff: number = 2;
    let saOff: number = 3;

    switch (wmInfo.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        sbOff = 0;
        sgOff = 1;
        srOff = 2;
        saOff = 3;
        break;
      case image.PixelMapFormat.ARGB_8888:
        saOff = 0;
        srOff = 1;
        sgOff = 2;
        sbOff = 3;
        break;
      case image.PixelMapFormat.RGBA_8888:
      default:
        srOff = 0;
        sgOff = 1;
        sbOff = 2;
        saOff = 3;
        break;
    }

    // 最近邻缩放：对目标 (dx,dy)，在原图中找一个最近的 (sx,sy)
    for (let dy: number = 0; dy < newH; dy++) {
      const srcY: number = Math.min(srcH - 1, Math.floor(dy / scale));
      for (let dx: number = 0; dx < newW; dx++) {
        const srcX: number = Math.min(srcW - 1, Math.floor(dx / scale));

        const srcIndex: number = (srcY * srcW + srcX) * 4;
        const r: number = srcData[srcIndex + srOff];
        const g: number = srcData[srcIndex + sgOff];
        const b: number = srcData[srcIndex + sbOff];
        const a: number = srcData[srcIndex + saOff];

        const dstIndex: number = (dy * newW + dx) * 4;
        // 目标我们直接按 RGBA 写
        dstData[dstIndex + 0] = r;
        dstData[dstIndex + 1] = g;
        dstData[dstIndex + 2] = b;
        dstData[dstIndex + 3] = a;
      }
    }

    // 用我们自己生成的像素数据创建一张新的 PixelMap（RGBA_8888）
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: {
        width: newW,
        height: newH
      }
    };

    const resizedPm: image.PixelMap = await image.createPixelMap(dstBuf, opts);
    return resizedPm;
  }

  // 添加水印到当前绘制图层
  private async addWatermark(): Promise<void> {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' });
      return;
    }

    // 先压一份快照，支持撤销
    await this.pushFullSnapshotBeforeChange();

    // 确保有绘制图层
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer();
    if (!layerPm) {
      promptAction.showToast({ message: '当前没有可编辑图层' });
      return;
    }

    // 加载并调整水印大小（调整为 30x30px）
    const logoPm: image.PixelMap = await this.loadLogoPixelMap();
    const resizedLogoPm: image.PixelMap = await this.resizeWatermark(logoPm, 100, 100); // 调整为 30x30px

    // 获取图层信息
    const layerInfo: image.ImageInfo = await layerPm.getImageInfo();
    const layerW: number = layerInfo.size.width;
    const layerH: number = layerInfo.size.height;

    // 获取水印图片的尺寸
    const watermarkInfo: image.ImageInfo = await resizedLogoPm.getImageInfo();
    const watermarkWidth: number = watermarkInfo.size.width;
    const watermarkHeight: number = watermarkInfo.size.height;

    // 右下角，预留 10px 边距
    const margin: number = 10;
    let offsetX: number = layerW - watermarkWidth - margin;
    let offsetY: number = layerH - watermarkHeight - margin;

    // 防止水印比图还大 / 出界
    if (offsetX < 0) {
      offsetX = 0;
    }
    if (offsetY < 0) {
      offsetY = 0;
    }

    // 把调整好的水印贴到绘制图层
    await this.pasteWatermarkIntoLayer(layerPm, resizedLogoPm, offsetX, offsetY);

    // clone 一份新图层，强制 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm);
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.();
    }
    this.drawPixelMap = newLayer;
    this.drawPixelVersion++;

    // 写操作日志 + 协作同步
    const desc: string = '在右下角添加了水印';
    await this.logAndSyncAfterImageChange(desc);

    promptAction.showToast({ message: '水印已添加' });
  }

  // 根据底图 pm 创建一张“完全透明”的绘制图层（尺寸 & 像素格式一致）
  private async createEmptyDrawLayerLike(pm: image.PixelMap): Promise<image.PixelMap> {
    // 1. 先 clone 一份，保证 editable
    const layer: image.PixelMap = await this.clonePixelMap(pm)

    // 2. 把所有像素清成透明
    const byteLength: number = layer.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layer.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    for (let i = 0; i < data.length; i += 4) {
      data[i] = 0 // R
      data[i + 1] = 0 // G
      data[i + 2] = 0 // B
      data[i + 3] = 0 // A = 0 完全透明
    }

    await layer.writeBufferToPixels(buffer)
    return layer
  }

  // 确保存在绘制图层：没有就创建，有就直接返回
  private async ensureDrawLayer(): Promise<image.PixelMap | undefined> {
    if (!this.pixelMap) {
      return undefined
    }

    if (!this.drawPixelMap) {
      const basePm = this.pixelMap as image.PixelMap
      this.drawPixelMap = await this.createEmptyDrawLayerLike(basePm)
      this.drawPixelVersion++
    }

    return this.drawPixelMap as image.PixelMap
  }

  // 鸿蒙 6.0 官方可用、不变色的克隆：pack → decode
  private async clonePixelMap(pm: image.PixelMap): Promise<image.PixelMap> {
    // 1. pack 成 PNG 内存流（注意：packToData 只有两个参数）
    const packer = image.createImagePacker()
    const packOpts: image.PackingOption = {
      format: 'image/png', // PNG 无损，颜色最安全
      quality: 100
    }

    // HarmonyOS 6.0：packToData 返回 Promise<ArrayBuffer>
    const buffer: ArrayBuffer = await packer.packToData(pm, packOpts)
    packer.release?.()

    // 2. 再 decode 成新的 PixelMap（保持 editable）
    const imgSource = image.createImageSource(buffer)
    const clonePm: image.PixelMap = await imgSource.createPixelMap({
      editable: true
    })
    imgSource.release?.()

    return clonePm
  }

  // 在一次“会改变图像/状态”的操作之前调用，记录快照
  // includePixel = true：把 pmForSnapshot 这张图作为快照保存（不拷贝像素）——专门给裁剪用
  private async pushHistorySnapshot(includePixel: boolean, pmForSnapshot?: image.PixelMap): Promise<void> {
    let snapshotPixel: image.PixelMap | undefined = undefined
    let snapshotDraw: image.PixelMap | undefined = undefined // ⭐ 新增

    // 是否包含像素快照（底图）
    if (includePixel && pmForSnapshot) {
      snapshotPixel = pmForSnapshot
    }

    // ⭐ 不管底图要不要保存，绘制图层如果存在，都 clone 一份保存快照
    if (this.drawPixelMap) {
      snapshotDraw = await this.clonePixelMap(this.drawPixelMap as image.PixelMap)
    }

    // 如果已经撤销到中间，再做新操作，则砍掉“未来”分支
    if (this.historyIndex >= 0 && this.historyIndex < this.history.length - 1) {
      for (let i = this.historyIndex + 1; i < this.history.length; i++) {
        this.history[i].pixelMap?.release?.()
        this.history[i].drawPixelMap?.release?.() // ⭐ 记得释放绘制层快照
      }
      this.history = this.history.slice(0, this.historyIndex + 1)
    }

    this.history.push({
      pixelMap: snapshotPixel,
      drawPixelMap: snapshotDraw, // ⭐ 存进去
      zoom: this.zoom,
      offsetX: this.offsetX,
      offsetY: this.offsetY,
      brightnessLevel: this.brightnessLevel,
      contrastLevel: this.contrastLevel,
      accumulatedRotate: this.accumulatedRotate
    })

    this.historyIndex = this.history.length - 1
  }

  // 重置到“刚打开图片时”的状态
  private async resetView(): Promise<void> {
    // ① 没有图，直接返回
    if (!this.pixelMap) {
      return;
    }

    // ② 没有原图快照：只重置视图参数（兼容老数据）
    if (!this.originalPixelMap) {
      this.zoom = 1.0;
      this.offsetX = 0;
      this.offsetY = 0;
      this.brightnessLevel = 0.0;
      this.contrastLevel = 0.0;
      this.accumulatedRotate = 0;
      this.pixelVersion++;
      return;
    }

    // ③ 在重置之前，先把当前状态放进历史栈，reset 也能“撤销”
    const currentPm: image.PixelMap = this.pixelMap as image.PixelMap;
    const beforeResetPm: image.PixelMap = await this.clonePixelMap(currentPm);
    await this.pushHistorySnapshot(true, beforeResetPm);

    // ④ 用 originalPixelMap 还原底图（重新 clone 一份可编辑版本）
    const originalPm: image.PixelMap = this.originalPixelMap as image.PixelMap;
    const newPm: image.PixelMap = await this.clonePixelMap(originalPm);

    // 释放当前底图
    currentPm.release();

    // 替换为“刚打开图片时”的底图
    this.pixelMap = newPm;

    // ⑤ 重建绘制图层：相当于新建一张全透明的 overlay
    if (this.drawPixelMap) {
      const currentDrawPm: image.PixelMap = this.drawPixelMap as image.PixelMap;
      currentDrawPm.release();
    }
    const drawLayer: image.PixelMap = await this.createEmptyDrawLayerLike(newPm);
    this.drawPixelMap = drawLayer;
    this.drawPixelVersion++; // 触发叠加层 Image 刷新

    // ⑥ 还原视图参数
    this.zoom = 1.0;
    this.offsetX = 0;
    this.offsetY = 0;
    this.brightnessLevel = 0.0;
    this.contrastLevel = 0.0;
    this.accumulatedRotate = 0;

    // ⑦ 通知底图刷新
    this.pixelVersion++;
  }

  // 打开图片（
  private async pickImage() {
    try {
      // 选图
      const picker = new photoAccessHelper.PhotoViewPicker()
      const options = new photoAccessHelper.PhotoSelectOptions()
      // 只选择图片
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
      // 一次最多选一张
      options.maxSelectNumber = 1

      // 等待用户选择图片并拿去结果
      const result = await picker.select(options)
      const uris: Array<string> = result.photoUris

      // 用户未选择图片提示
      if (!uris || uris.length === 0) {
        promptAction.showToast({ message: '未选择图片' })
        return
      }

      // 得到图片地址
      const uri: string = uris[0]
      console.info(`>>> Selected URI = ${uri}`)

      // 用 fileIo 打开 uri，拿 fd
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)

      // 把 fd 交给 ImageKit 解码 → 得到 ImageSource
      const imgSource: image.ImageSource = image.createImageSource(file.fd)
      if (!imgSource) {
        await fileIo.close(file)
        throw new Error('createImageSource 返回空')
      }

      // 从 ImageSource 创建 PixelMap
      const pm: image.PixelMap = await imgSource.createPixelMap({
        editable: true
      })

      // 释放底层资源
      imgSource.release?.()
      await fileIo.close(file)

      // 更新 UI 状态
      // 先释放旧的原图快照
      if (this.originalPixelMap) {
        this.originalPixelMap.release?.()
      }
      // 保存一份“打开时的原图”（以后 resetView 就用它来还原）
      this.originalPixelMap = await this.clonePixelMap(pm)

      // 释放旧的当前图
      if (this.pixelMap) {
        this.pixelMap.release?.()
      }
      // 当前正在编辑的 PixelMap
      this.pixelMap = pm

      // 初始化视图到“刚打开”的状态
      this.zoom = 1.0
      this.offsetX = 0
      this.offsetY = 0
      this.brightnessLevel = 0.0
      this.contrastLevel = 0.0
      this.accumulatedRotate = 0
      this.pixelVersion++

      // 👉 新增：记录当前图片对角线，用于后续裁剪时计算比例
      const openInfo: image.ImageInfo = await pm.getImageInfo()
      const openW: number = openInfo.size.width
      const openH: number = openInfo.size.height
      this.imageDiag = Math.hypot(openW, openH)

      // ========== 新增：为这张图片创建一层透明的绘制层 ==========
      if (this.drawPixelMap) {
        this.drawPixelMap.release?.()
      }
      this.drawPixelMap = await this.createEmptyDrawLayerLike(pm)
      this.drawPixelVersion++
      // =========================================================
      const selfId: string = this.localClientId || this.clientId
      this.appendOpLog(selfId, '打开了一张图片', this.localColor)

      if (this.collabClient.connected && this.pixelMap) {
        await this.broadcastImageToPeers(this.pixelMap as image.PixelMap, '打开了一张图片')
      }

      promptAction.showToast({ message: '图片已加载 ' })
    } catch (err) {
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

  // 保存图片：把当前 PixelMap 写入系统相册
  private async saveImage() {
    try {
      if (!this.pixelMap) {
        promptAction.showToast({ message: '请先打开图片' })
        return
      }

      const context = getContext(this) as common.UIAbilityContext
      const helper = photoAccessHelper.getPhotoAccessHelper(context)

      // 1) 克隆一份底图，用于保存
      const basePm: image.PixelMap = this.pixelMap as image.PixelMap
      const pmForSave: image.PixelMap = await this.clonePixelMap(basePm)

      // 2) 有绘制层的话，先合成上去
      if (this.drawPixelMap) {
        await this.mergeDrawLayerIntoBase(pmForSave, this.drawPixelMap as image.PixelMap)
      }

      // 3) 把亮度/对比度烘焙进 pmForSave（只影响保存，不改真实状态）
      await this.bakeToneForSave(pmForSave)

      // 4) 正常 packToFile 保存 pmForSave ...
      const uri: string = await helper.createAsset(
        photoAccessHelper.PhotoType.IMAGE,
        'jpg'
      )

      const file = await fileIo.open(
        uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      )

      const packer = image.createImagePacker()
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 90
      }

      await new Promise<void>((resolve, reject) => {
        packer.packToFile(
          pmForSave,
          file.fd,
          packOpts,
          (err: BusinessError) => err ? reject(err) : resolve()
        )
      })

      packer.release?.()
      await fileIo.close(file)

      promptAction.showToast({ message: '已保存到相册 ' })
    } catch (err) {
      const e = err as BusinessError
      console.error(`saveImage failed, code=${e?.code}, msg=${e?.message}`)
      promptAction.showToast({ message: '保存失败' })
    }
  }

  // 裁剪：根据当前裁剪框，把底图和绘制层一起裁剪，并“温和”调整画笔粗细
  private async doCrop(): Promise<void> {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo()

    // 画布尺寸、防御
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      promptAction.showToast({ message: '画布尚未初始化' })
      this.cropMode = false
      return
    }

    // === 1. 计算图片在画布上的实际显示区域（考虑 contain + zoom + 平移）===
    const imgW: number = info.size.width
    const imgH: number = info.size.height

    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )

    if (scaleBase <= 0) {
      promptAction.showToast({ message: '缩放参数异常' })
      this.cropMode = false
      return
    }

    const realW: number = imgW * scaleBase * this.zoom
    const realH: number = imgH * scaleBase * this.zoom

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY
    const imageRight: number = imageLeft + realW
    const imageBottom: number = imageTop + realH

    // === 2. 读取 UI 裁剪框，并与图片显示区域求交集 ===
    let uiX1: number = Math.min(this.cropStartX, this.cropEndX)
    let uiY1: number = Math.min(this.cropStartY, this.cropEndY)
    let uiX2: number = Math.max(this.cropStartX, this.cropEndX)
    let uiY2: number = Math.max(this.cropStartY, this.cropEndY)

    // 和图片可见区域求交
    uiX1 = Math.max(uiX1, imageLeft)
    uiY1 = Math.max(uiY1, imageTop)
    uiX2 = Math.min(uiX2, imageRight)
    uiY2 = Math.min(uiY2, imageBottom)

    if (uiX2 <= uiX1 || uiY2 <= uiY1) {
      promptAction.showToast({ message: '裁剪区域超出图片范围' })
      this.cropMode = false
      return
    }

    // === 3. UI 坐标映射到像素坐标 ===
    const px1Float: number = (uiX1 - imageLeft) * (imgW / realW)
    const py1Float: number = (uiY1 - imageTop) * (imgH / realH)
    const px2Float: number = (uiX2 - imageLeft) * (imgW / realW)
    const py2Float: number = (uiY2 - imageTop) * (imgH / realH)

    const cropX: number = Math.max(0, Math.floor(px1Float))
    const cropY: number = Math.max(0, Math.floor(py1Float))
    const cropW: number = Math.floor(px2Float - px1Float)
    const cropH: number = Math.floor(py2Float - py1Float)

    if (cropW <= 0 || cropH <= 0) {
      promptAction.showToast({ message: '裁剪区域太小' })
      this.cropMode = false
      return
    }

    // ========= 4. 真正裁剪（底图 + 绘制层），并记录撤销 =========

    // 4.1 裁剪前备份一份完整底图（用于撤销）
    const backupPm: image.PixelMap = await this.clonePixelMap(pm)
    await this.pushHistorySnapshot(true, backupPm)

    // 4.2 在当前 pixelMap 上原地裁剪（引用不变）
    await pm.crop({
      x: cropX,
      y: cropY,
      size: { width: cropW, height: cropH }
    })

    // 4.3 若存在绘制图层，同步裁剪同一区域，保证尺寸对齐
    if (this.drawPixelMap) {
      const overlayPm: image.PixelMap = this.drawPixelMap as image.PixelMap
      try {
        await overlayPm.crop({
          x: cropX,
          y: cropY,
          size: { width: cropW, height: cropH }
        })
        this.drawPixelVersion++
      } catch (e) {
        const err: Error = e as Error
        console.warn(`crop drawPixelMap failed: ${err.message}`)
      }
    }

    // ========= 5. 温和调整画笔粗细（避免一次裁剪变化过猛） =========

    // 旧对角线：优先用 imageDiag（如果你在打开图片或 reset 时有设置）
    const oldDiag: number = this.imageDiag > 0
      ? this.imageDiag
      : Math.sqrt(imgW * imgW + imgH * imgH)

    const newDiag: number = Math.sqrt(cropW * cropW + cropH * cropH)

    if (oldDiag > 0 && newDiag > 0) {
      const rawRatio: number = newDiag / oldDiag // <1 表示图变小

      // 这里是“温和缩放”：
      // - 不放大画笔：ratio 最大 1.0
      // - 每次最多缩小到 80%：ratio 最小 0.8
      let ratio: number = rawRatio
      if (ratio > 1.0) {
        ratio = 1.0
      }
      if (ratio < 0.8) {
        ratio = 0.8
      }

      // 应用缩放，最低不小于 1 像素
      this.strokeWidth = Math.max(1, this.strokeWidth * ratio)

      // 更新当前图片对角线，作为下一次裁剪的基准
      this.imageDiag = newDiag
    } else {
      // 兜底：无法计算时，只记录新对角线，不调整画笔
      this.imageDiag = newDiag
    }

    // ========= 6. 收尾：复位视图 / 清理状态 =========
    this.cropMode = false
    this.zoom = 1.0
    this.offsetX = 0
    this.offsetY = 0
    this.pixelVersion++

    this.cropStartX = 0
    this.cropStartY = 0
    this.cropEndX = 0
    this.cropEndY = 0

    promptAction.showToast({ message: '裁剪完成' })
  }

  private async rotateRight90(): Promise<void> {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }
    if (this.isRotating) {
      return
    }

    await this.pushHistorySnapshot(false)

    this.isRotating = true
    try {
      // ① 旋转底图
      await (this.pixelMap as image.PixelMap).rotate(90)

      // ② 若有绘制层，也一起旋转（关键）
      if (this.drawPixelMap) {
        await (this.drawPixelMap as image.PixelMap).rotate(90)
        this.drawPixelVersion++
      }

      // ③ 更新累计角度
      this.accumulatedRotate = (this.accumulatedRotate + 90) % 360

      this.pixelVersion++
      await this.logAndSyncAfterImageChange('左旋转 90°')
    } catch (err) {
      const e = err as Error
      console.error(`rotateRight90 failed: ${e.message}`)
      promptAction.showToast({ message: '右旋失败' })
    } finally {
      this.isRotating = false
    }
  }

  // 向左旋转 90 度（逆时针）
  private async rotateLeft90(): Promise<void> {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }
    if (this.isRotating) {
      return
    }

    await this.pushHistorySnapshot(false)

    this.isRotating = true
    try {
      // ① 底图旋转
      await (this.pixelMap as image.PixelMap).rotate(270)

      // ② 绘制图层同步旋转
      if (this.drawPixelMap) {
        await (this.drawPixelMap as image.PixelMap).rotate(270)
        this.drawPixelVersion++
      }

      // ③ 更新累计角度
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

  // 亮度调整
  // 亮度调整
  private async adjustBrightness(delta: number) {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    // 记录当前亮度/对比度参数（不拷贝像素）
    await this.pushHistorySnapshot(false)

    // brightnessLevel 取一个相对温和的区间，防止崩坏
    this.brightnessLevel += delta

    const MAX_LEVEL: number = 0.5 // 大约 +128
    const MIN_LEVEL: number = -0.5 // 大约 -128

    if (this.brightnessLevel > MAX_LEVEL) {
      this.brightnessLevel = MAX_LEVEL
    }
    if (this.brightnessLevel < MIN_LEVEL) {
      this.brightnessLevel = MIN_LEVEL
    }

    // === 新增：构造描述 + 记录操作 + 协作同步 ===
    let desc: string
    if (delta > 0) {
      desc = '提高了亮度'
    } else if (delta < 0) {
      desc = '降低了亮度'
    } else {
      desc = '调整了亮度'
    }

    await this.logAndSyncAfterImageChange(desc)
  }

  // 构建亮度 + 对比度矩阵
  private buildToneMatrix(): Array<number> {
    // 亮度（建议范围 [-0.5, 0.5]）
    const b: number = this.brightnessLevel

    // 对比度系数 c：contrastLevel ∈ [-1,1] 对应 c ∈ [0,2]
    const c: number = 1.0 + this.contrastLevel

    // 为了让“保持中心点不变”，需要额外的偏移项
    // 在归一化[0,1]空间里，中点是 0.5：
    // new = (old - 0.5) * c + 0.5 + b
    //     = c * old + (0.5 * (1 - c) + b)
    const offset: number = 0.5 * (1.0 - c) + b

    return [
      c, 0, 0, 0, offset,
      0, c, 0, 0, offset,
      0, 0, c, 0, offset,
      0, 0, 0, 1, 0
    ]
  }

  // 把当前 brightnessLevel & contrastLevel 一起烘焙到 pixelMap 里
  // 注意：调用后会把 brightnessLevel / contrastLevel 归零，并触发一次刷新
  private async bakeToneToPixelMap(pm: image.PixelMap): Promise<void> {
    // 没有调整亮度和对比度就不用动像素，直接返回
    if (this.brightnessLevel === 0 && this.contrastLevel === 0) {
      return
    }

    // 读出像素数据
    const info: image.ImageInfo = await pm.getImageInfo()
    const byteLength: number = pm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await pm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 判断通道顺序，防止颜色错乱
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (info.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        // B G R A
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        // A R G B
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
      // R G B A
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    // 对比度系数 c（0~2），亮度偏移 *255
    const c: number = 1.0 + this.contrastLevel
    const shiftBrightness: number = this.brightnessLevel * 255.0
    // 把公式 new = (old - 128)*c + 128 + shiftBrightness 展开：
    const shiftTotal: number = 128.0 * (1.0 - c) + shiftBrightness

    const clamp = (v: number): number => {
      if (v < 0) {
        return 0
      }
      if (v > 255) {
        return 255
      }
      return v
    }

    // 遍历一次像素，真正改掉 R/G/B 通道
    for (let i: number = 0; i < data.length; i += 4) {
      const rIndex: number = i + rOffset
      const gIndex: number = i + gOffset
      const bIndex: number = i + bOffset
      const aIndex: number = i + aOffset

      const r = data[rIndex]
      const g = data[gIndex]
      const b = data[bIndex]

      data[rIndex] = clamp(c * r + shiftTotal)
      data[gIndex] = clamp(c * g + shiftTotal)
      data[bIndex] = clamp(c * b + shiftTotal)
      // alpha 原样保持
      data[aIndex] = data[aIndex]
    }

    // 把修改后的像素写回 pixelMap
    await pm.writeBufferToPixels(buffer)

    // 把状态归零：此时底层像素已经是“新亮度 + 新对比度”
    // 再把 colorFilter 的参数设回 0，视觉效果保持不变（不会叠加两次）
    this.brightnessLevel = 0.0
    this.contrastLevel = 0.0
    this.pixelVersion++ // 触发 Image 重新渲染一次
  }

  // 对比度调整
  private async adjustContrast(delta: number) {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    // 记录当前亮度/对比度参数（不拷贝像素）
    await this.pushHistorySnapshot(false)

    this.contrastLevel += delta

    const MAX_CONTRAST: number = 1.0 // 对比度增强上限
    const MIN_CONTRAST: number = -1.0 // 对比度降低下限

    if (this.contrastLevel > MAX_CONTRAST) {
      this.contrastLevel = MAX_CONTRAST
    }
    if (this.contrastLevel < MIN_CONTRAST) {
      this.contrastLevel = MIN_CONTRAST
    }

    let desc: string
    if (delta > 0) {
      desc = '提高了对比度'
    } else if (delta < 0) {
      desc = '降低了对比度'
    } else {
      desc = '调整了对比度'
    }

    await this.logAndSyncAfterImageChange(desc)
  }

  private onClickTopMenu(menu: TopMenu) {
    // 再次点击同一个按钮时收起菜单
    if (this.activeMenu === menu) {
      this.activeMenu = TopMenu.None
    } else {
      this.activeMenu = menu
    }
  }

  private selectShape(shape: ShapeTool) {
    this.currentShape = shape

    // 如果之前是橡皮擦，切换形状时自动恢复为普通画笔
    if (this.currentBrush === BrushTool.Eraser) {
      this.currentBrush = BrushTool.Pen
    }
  }

  private selectBrush(brush: BrushTool) {
    // 先只记录当前画笔
    this.currentBrush = brush
  }

  private async undo() {
    console.info(`>>> UNDO CALLED, historyLen=${this.history.length}, historyIndex=${this.historyIndex}`)

    if (this.historyIndex < 0 || this.history.length === 0) {
      promptAction.showToast({ message: '没有可以撤销的操作' })
      return
    }

    const snapshot: CanvasSnapshot = this.history[this.historyIndex]
    this.historyIndex--

    // === 情况 1：有 pixelMap 快照（如裁剪） ===
    if (snapshot.pixelMap) {
      // 把 snapshot.pixelMap 克隆成可编辑版本
      const newPm = await this.clonePixelMap(snapshot.pixelMap)

      // 释放当前 pixelMap（不等于 snapshot.pixelMap）
      if (this.pixelMap && this.pixelMap !== snapshot.pixelMap) {
        (this.pixelMap as image.PixelMap).release?.()
      }

      // 切换到新的 editable PixelMap
      this.pixelMap = newPm
    }

    // === 情况 2：旋转 / 亮度 / 对比度（无 pixelMap）===
    else if (this.pixelMap) {
      const currentAngle = this.accumulatedRotate
      const targetAngle = snapshot.accumulatedRotate

      const diff = (360 + targetAngle - currentAngle) % 360
      if (diff === 90 || diff === 180 || diff === 270) {
        try {
          await (this.pixelMap as image.PixelMap).rotate(diff)
        } catch (err) {
          console.error(`undo rotateBack failed: ${JSON.stringify(err)}`)
        }
      }
    }

    // ⭐ 新增：恢复绘制图层（drawPixelMap）
    if (snapshot.drawPixelMap) {
      const newDraw = await this.clonePixelMap(snapshot.drawPixelMap)

      if (this.drawPixelMap && this.drawPixelMap !== snapshot.drawPixelMap) {
        this.drawPixelMap.release?.()
      }
      this.drawPixelMap = newDraw
      this.drawPixelVersion++ // 让 Image(drawPixelMap) 也刷新
    } else {
      // 这一步表示当时没有绘制层快照 → 撤销到一个“没有绘制层”的状态
      if (this.drawPixelMap) {
        this.drawPixelMap.release?.()
        this.drawPixelMap = undefined
        this.drawPixelVersion++
      }
    }

    // === 恢复其他状态（缩放/平移/亮度/对比度等） ===
    this.zoom = snapshot.zoom
    this.offsetX = snapshot.offsetX
    this.offsetY = snapshot.offsetY
    this.brightnessLevel = snapshot.brightnessLevel
    this.contrastLevel = snapshot.contrastLevel
    this.accumulatedRotate = snapshot.accumulatedRotate

    const desc: string = '撤销了一步操作'
    await this.logAndSyncAfterImageChange(desc)

    this.pixelVersion++
  }

  // 在「绘制图层」上画一个点（uiX/uiY 是画布上的点击坐标）
  private async drawPointAtUi(uiX: number, uiY: number) {
    if (!this.pixelMap) {
      return
    }

    // ✅ 画之前压一份整图快照（这里按你现有逻辑来）
    await this.pushFullSnapshotBeforeChange();

    // 1. 画布尺寸防御
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      console.info('>>> drawPointAtUi: canvas size is 0, skip')
      return
    }

    // ===== ⭐⭐ 选目标图层：优先 drawPixelMap，没有就用 pixelMap =====
    let targetPm: image.PixelMap | undefined = this.drawPixelMap as image.PixelMap | undefined
    let targetIsDrawLayer: boolean = true

    if (!targetPm) {
      targetPm = this.pixelMap as image.PixelMap
      targetIsDrawLayer = false
    }

    if (!targetPm) {
      console.warn('>>> drawPointAtUi: both drawPixelMap & pixelMap are null')
      promptAction.showToast({ message: '当前没有可编辑图层，请重新打开图片' })
      return
    }

    console.info(`>>> drawPointAtUi: target layer = ${targetIsDrawLayer ? 'drawPixelMap' : 'pixelMap'}`)

    // ===== 下面这部分，原来用 basePm / layerPm 的地方，统一换成 targetPm =====

    const basePm = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()

    const imgW: number = baseInfo.size.width
    const imgH: number = baseInfo.size.height

    // ===== 1) UI -> 像素 坐标映射 =====
    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )

    if (scaleBase <= 0) {
      console.info('>>> drawPointAtUi: scaleBase <= 0, skip')
      return
    }

    const realW: number = imgW * scaleBase * this.zoom
    const realH: number = imgH * scaleBase * this.zoom

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    const pxFloat: number = (uiX - imageLeft) * (imgW / realW)
    const pyFloat: number = (uiY - imageTop) * (imgH / realH)

    const px: number = Math.floor(pxFloat)
    const py: number = Math.floor(pyFloat)

    console.info(`>>> drawPointAtUi: ui=(${uiX.toFixed(1)}, ${uiY.toFixed(1)}) -> pixel=(${px}, ${py})`)

    if (px < 0 || py < 0 || px >= imgW || py >= imgH) {
      // 点击在图片外面，直接丢弃
      return
    }

    // ===== 2) 在「目标图层」上改像素 =====
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

    // 通道顺序
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (info.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    const radius: number = this.computeStrokeRadiusPixel(imgW, imgH)
    const alpha: number = this.getStrokeAlpha()

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

        if (this.currentBrush === BrushTool.Eraser) {
          // ⭐ 橡皮擦：只擦掉目标图层的 alpha
          data[aIndex] = 0
        } else {
          data[rIndex] = this.strokeR
          data[gIndex] = this.strokeG
          data[bIndex] = this.strokeB
          data[aIndex] = alpha
        }
      }
    }

    // ===== 3) 写回 + 换一个新的 PixelMap 引用，强制 UI 刷新 =====
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

    const desc: string = `画了一个点 像素=(${Math.floor(uiX)}, ${Math.floor(uiY)})`
    await this.logAndSyncAfterImageChange(desc)

    console.info(
      `>>> drawPointAtUi done: target=${targetIsDrawLayer ? 'draw' : 'base'}, size=${width}x${height}`
    )
  }

  // 直线工具：拖拽产生的起点/终点（UI 坐标），在这里转换成像素并画线
  // 直线工具：拖拽产生的起点/终点（UI 坐标），在这里转换成像素并在绘制图层上画线
  private async handleLineDrag(startUiX: number, startUiY: number, endUiX: number, endUiY: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo()

    // —— UI → 像素（和画点完全一致的映射逻辑）——
    const scaleBase: number = Math.min(
      this.canvasWidth / info.size.width,
      this.canvasHeight / info.size.height
    )

    const realW: number = info.size.width * scaleBase * this.zoom
    const realH: number = info.size.height * scaleBase * this.zoom

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    const startPxFloat: number = (startUiX - imageLeft) * (info.size.width / realW)
    const startPyFloat: number = (startUiY - imageTop) * (info.size.height / realH)
    const endPxFloat: number = (endUiX - imageLeft) * (info.size.width / realW)
    const endPyFloat: number = (endUiY - imageTop) * (info.size.height / realH)

    const x0: number = Math.floor(startPxFloat)
    const y0: number = Math.floor(startPyFloat)
    const x1: number = Math.floor(endPxFloat)
    const y1: number = Math.floor(endPyFloat)

    console.info(
      `>>> handleLineDrag uiStart=(${startUiX.toFixed(1)},${startUiY.toFixed(1)}), ` +
        `uiEnd=(${endUiX.toFixed(1)},${endUiY.toFixed(1)}) -> ` +
        `pixelStart=(${x0},${y0}), pixelEnd=(${x1},${y1}), imgSize=(${info.size.width},${info.size.height})`
    )

    // 尝试确保有绘制图层（这里不直接用返回值，只做存在性检查）
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    // 交给专门函数在“绘制图层”上画线
    await this.drawLineBetweenPixels(x0, y0, x1, y1)

    // ⭐⭐ 同步协作
    // ⭐ 操作记录：只记录 左上角 -> 右下角（像素坐标）
    const left: number = Math.min(x0, x1)
    const top: number = Math.min(y0, y1)
    const right: number = Math.max(x0, x1)
    const bottom: number = Math.max(y0, y1)

    const desc: string = `画了一条直线 (${left}, ${top}) -> (${right}, ${bottom})`

    await this.logAndSyncAfterImageChange(desc)

    promptAction.showToast({ message: '直线已绘制' })
  }

  // 在绘制图层 drawPixelMap 上画一条“带粗细的直线”
  private async drawLineBetweenPixels(x0: number, y0: number, x1: number, y1: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    // ⭐ 和画点一样，先记录一次历史快照（只记录状态 + 绘制层）
    await this.pushFullSnapshotBeforeChange();

    // 1. 用底图做一次尺寸边界检查（正常和绘制层一致）
    const basePm: image.PixelMap = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const baseW: number = baseInfo.size.width
    const baseH: number = baseInfo.size.height

    if (
      x0 < 0 || y0 < 0 || x0 >= baseW || y0 >= baseH ||
        x1 < 0 || y1 < 0 || x1 >= baseW || y1 >= baseH
    ) {
      console.info('>>> drawLineBetweenPixels: endpoints out of base range, skip')
      return
    }

    // 2. 只在绘制图层上画线
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    if (
      x0 < 0 || y0 < 0 || x0 >= width || y0 >= height ||
        x1 < 0 || y1 < 0 || x1 >= width || y1 >= height
    ) {
      console.info('>>> drawLineBetweenPixels: endpoints out of layer range, skip')
      return
    }

    // 3. 读取绘制层像素
    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 4. 通道顺序
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (info.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    const radius: number = this.computeStrokeRadiusPixel(width, height)
    const alpha: number = this.getStrokeAlpha()

    const drawThickPoint = (cx: number, cy: number): void => {
      for (let yy: number = cy - radius; yy <= cy + radius; yy++) {
        if (yy < 0 || yy >= height) {
          continue
        }
        for (let xx: number = cx - radius; xx <= cx + radius; xx++) {
          if (xx < 0 || xx >= width) {
            continue
          }

          const dx: number = xx - cx
          const dy: number = yy - cy
          if (dx * dx + dy * dy > radius * radius) {
            continue
          }

          const baseIndex: number = (yy * width + xx) * 4
          const rIndex: number = baseIndex + rOffset
          const gIndex: number = baseIndex + gOffset
          const bIndex: number = baseIndex + bOffset
          const aIndex: number = baseIndex + aOffset

          if (this.currentBrush === BrushTool.Eraser) {
            // 橡皮擦：只擦绘制层，变成透明
            data[aIndex] = 0
          } else {
            data[rIndex] = this.strokeR
            data[gIndex] = this.strokeG
            data[bIndex] = this.strokeB
            data[aIndex] = alpha
          }
        }
      }
    }

    // 5. Bresenham 画线
    let curX: number = x0
    let curY: number = y0
    const dx: number = Math.abs(x1 - x0)
    const sx: number = x0 < x1 ? 1 : -1
    const dy: number = -Math.abs(y1 - y0)
    const sy: number = y0 < y1 ? 1 : -1
    let err: number = dx + dy

    // eslint-disable-next-line no-constant-condition
    while (true) {
      drawThickPoint(curX, curY)

      if (curX === x1 && curY === y1) {
        break
      }

      const e2: number = 2 * err
      if (e2 >= dy) {
        err += dy
        curX += sx
      }
      if (e2 <= dx) {
        err += dx
        curY += sy
      }
    }

    // 6. 写回绘制层像素
    await layerPm.writeBufferToPixels(buffer)

    // ⭐ 关键：和画点一样，clone 一张新的图层，换引用，强制 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)

    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer

    this.drawPixelVersion++ // id("draw-xxx") 变化，叠加层 Image 会重建

    console.info(`>>> drawLineBetweenPixels: line drawn, drawPixelVersion=${this.drawPixelVersion}`)
  }

  // 矩形工具：拖拽产生的起点/终点（UI 坐标），在这里转成像素并画矩形
  private async handleRectDrag(startUiX: number, startUiY: number, endUiX: number, endUiY: number) {
    if (!this.pixelMap) {
      return
    }

    const pm = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo()

    // —— UI → 像素（和画点 / 画直线保持完全一致的映射逻辑）——
    const scaleBase: number = Math.min(
      this.canvasWidth / info.size.width,
      this.canvasHeight / info.size.height
    )

    const realW: number = info.size.width * scaleBase * this.zoom
    const realH: number = info.size.height * scaleBase * this.zoom

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    const startPxFloat: number = (startUiX - imageLeft) * (info.size.width / realW)
    const startPyFloat: number = (startUiY - imageTop) * (info.size.height / realH)
    const endPxFloat: number = (endUiX - imageLeft) * (info.size.width / realW)
    const endPyFloat: number = (endUiY - imageTop) * (info.size.height / realH)

    const x0: number = Math.floor(startPxFloat)
    const y0: number = Math.floor(startPyFloat)
    const x1: number = Math.floor(endPxFloat)
    const y1: number = Math.floor(endPyFloat)

    console.info(
      `>>> handleRectDrag uiStart=(${startUiX.toFixed(1)},${startUiY.toFixed(1)}), ` +
        `uiEnd=(${endUiX.toFixed(1)},${endUiY.toFixed(1)}) -> ` +
        `pixelStart=(${x0},${y0}), pixelEnd=(${x1},${y1}), imgSize=(${info.size.width},${info.size.height})`
    )

    // 这里不强制要求完全在图内，真正的边界裁剪交给 drawRectBetweenPixels 去做

    // 1）修改前先把当前整图压入撤销栈（可撤回）
    // 1）修改前：只记录状态 + 绘制层快照（底图不动）
    await this.pushFullSnapshotBeforeChange();

    // 2）在绘制层上画矩形
    await this.drawRectBetweenPixels(x0, y0, x1, y1)

    // 3）写操作记录（带像素坐标）
    // 归一化成左上 / 右下
    const left: number = Math.min(x0, x1)
    const right: number = Math.max(x0, x1)
    const top: number = Math.min(y0, y1)
    const bottom: number = Math.max(y0, y1)

    const desc: string =
      `画了一个矩形 左上像素=(${left}, ${top}), 右下像素=(${right}, ${bottom})`

    await this.logAndSyncAfterImageChange(desc)


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

    // 4）确定通道顺序
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (info.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    const radius: number = this.computeStrokeRadiusPixel(width, height)
    const alpha: number = this.getStrokeAlpha()

    const drawThickPoint = (cx: number, cy: number): void => {
      for (let yy: number = cy - radius; yy <= cy + radius; yy++) {
        if (yy < 0 || yy >= height) {
          continue
        }
        for (let xx: number = cx - radius; xx <= cx + radius; xx++) {
          if (xx < 0 || xx >= width) {
            continue
          }

          const dx: number = xx - cx
          const dy: number = yy - cy
          if (dx * dx + dy * dy > radius * radius) {
            continue
          }

          const baseIndex: number = (yy * width + xx) * 4
          const rIndex: number = baseIndex + rOffset
          const gIndex: number = baseIndex + gOffset
          const bIndex: number = baseIndex + bOffset
          const aIndex: number = baseIndex + aOffset

          if (this.currentBrush === BrushTool.Eraser) {
            // 橡皮擦：只擦绘制层的 alpha
            data[aIndex] = 0
          } else {
            data[rIndex] = this.strokeR
            data[gIndex] = this.strokeG
            data[bIndex] = this.strokeB
            data[aIndex] = alpha
          }
        }
      }
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

  // 在像素坐标里画一个圆形边框（使用当前 stroke 宽度和颜色）
  // 这里传入的是圆的外接正方形的左上 / 右下
  // 这里传入的是圆的外接正方形的左上 / 右下，在“绘制图层”上画圆
  private async drawCircleBetweenPixels(left: number, top: number, right: number, bottom: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    // 用底图做一次边界裁剪（尺寸与绘制层一致）
    const basePm: image.PixelMap = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const baseW: number = baseInfo.size.width
    const baseH: number = baseInfo.size.height

    left = Math.max(0, left)
    right = Math.min(baseW - 1, right)
    top = Math.max(0, top)
    bottom = Math.min(baseH - 1, bottom)

    const w: number = right - left
    const h: number = bottom - top
    const side: number = Math.min(w, h)

    if (side <= 0) {
      console.info('>>> drawCircleBetweenPixels: side too small, skip')
      return
    }

    // 用正方形包住圆
    right = left + side
    bottom = top + side

    const cx: number = Math.round((left + right) / 2)
    const cy: number = Math.round((top + bottom) / 2)
    const radius: number = side / 2

    // ② 在绘制图层上画圆
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    // 1）读绘制层像素
    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 2）通道顺序
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (info.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    const strokeRadius: number = this.computeStrokeRadiusPixel(width, height)

    const alpha: number = this.getStrokeAlpha()

    const drawThickPoint = (px: number, py: number): void => {
      for (let yy: number = py - strokeRadius; yy <= py + strokeRadius; yy++) {
        if (yy < 0 || yy >= height) {
          continue
        }
        for (let xx: number = px - strokeRadius; xx <= px + strokeRadius; xx++) {
          if (xx < 0 || xx >= width) {
            continue
          }
          const dx: number = xx - px
          const dy: number = yy - py
          if (dx * dx + dy * dy > strokeRadius * strokeRadius) {
            continue
          }

          const baseIndex: number = (yy * width + xx) * 4
          const rIndex: number = baseIndex + rOffset
          const gIndex: number = baseIndex + gOffset
          const bIndex: number = baseIndex + bOffset
          const aIndex: number = baseIndex + aOffset

          if (this.currentBrush === BrushTool.Eraser) {
            // 橡皮擦：只擦掉绘制层 alpha
            data[aIndex] = 0
          } else {
            data[rIndex] = this.strokeR
            data[gIndex] = this.strokeG
            data[bIndex] = this.strokeB
            data[aIndex] = alpha
          }
        }
      }
    }

    // 3）用参数方程画一圈：x = cx + r cos t, y = cy + r sin t
    const TWO_PI: number = Math.PI * 2
    // 步数与半径成比例，保证越大越平滑
    const steps: number = Math.max(36, Math.floor(TWO_PI * radius / 2))

    for (let i: number = 0; i < steps; i++) {
      const t: number = (TWO_PI * i) / steps
      const px: number = Math.round(cx + radius * Math.cos(t))
      const py: number = Math.round(cy + radius * Math.sin(t))

      if (px < 0 || px >= width || py < 0 || py >= height) {
        continue
      }
      drawThickPoint(px, py)
    }

    // 4）写回绘制层像素
    await layerPm.writeBufferToPixels(buffer)

    // 5）clone 一份新的绘制层，触发 UI 刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer
    this.drawPixelVersion++ // 叠加层 Image 重新渲染

    console.info(`>>> drawCircleBetweenPixels: circle drawn, drawPixelVersion=${this.drawPixelVersion}`)
  }

  // 圆形工具：拖拽产生的起点/终点（UI 坐标），转成像素并画圆
  // 圆形工具：拖拽产生的起点/终点（UI 坐标），转成像素并画圆（绘制在 overlay）
  private async handleCircleDrag(startUiX: number, startUiY: number, endUiX: number, endUiY: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo()

    // —— UI → 像素（和点 / 直线 / 矩形保持一致）——
    const scaleBase: number = Math.min(
      this.canvasWidth / info.size.width,
      this.canvasHeight / info.size.height
    )

    const realW: number = info.size.width * scaleBase * this.zoom
    const realH: number = info.size.height * scaleBase * this.zoom

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    const startPxFloat: number = (startUiX - imageLeft) * (info.size.width / realW)
    const startPyFloat: number = (startUiY - imageTop) * (info.size.height / realH)
    const endPxFloat: number = (endUiX - imageLeft) * (info.size.width / realW)
    const endPyFloat: number = (endUiY - imageTop) * (info.size.height / realH)

    const x0: number = Math.floor(startPxFloat)
    const y0: number = Math.floor(startPyFloat)
    const x1: number = Math.floor(endPxFloat)
    const y1: number = Math.floor(endPyFloat)

    console.info(
      `>>> handleCircleDrag uiStart=(${startUiX.toFixed(1)},${startUiY.toFixed(1)}), ` +
        `uiEnd=(${endUiX.toFixed(1)},${endUiY.toFixed(1)}) -> ` +
        `pixelStart=(${x0},${y0}), pixelEnd=(${x1},${y1}), imgSize=(${info.size.width},${info.size.height})`
    )

    // 1）先求出拖出矩形的左/右/上/下
    let left: number = Math.min(x0, x1)
    let right: number = Math.max(x0, x1)
    let top: number = Math.min(y0, y1)
    let bottom: number = Math.max(y0, y1)

    const boxW: number = right - left
    const boxH: number = bottom - top
    const side: number = Math.min(Math.abs(boxW), Math.abs(boxH))

    if (side <= 0) {
      console.info('>>> handleCircleDrag: side too small, skip')
      return
    }

    // 用左上角 + side 构造一个正方形区域
    right = left + side
    bottom = top + side

    // 2）修改前压入撤销栈：只记录状态 + 绘制层快照（底图不动）
    await this.pushFullSnapshotBeforeChange();

    // 3）真正画圆（在绘制图层上）
    await this.drawCircleBetweenPixels(left, top, right, bottom)


    // 4）写操作记录
    const desc: string =
      `画了一个圆 左上像素=(${left}, ${top}), 右下像素=(${right}, ${bottom})`

    await this.logAndSyncAfterImageChange(desc)

    promptAction.showToast({ message: '圆形已绘制' })
  }

  // 椭圆工具：拖拽产生的起点/终点（UI 坐标），转成像素并画椭圆
  // 椭圆工具：拖拽产生的起点/终点（UI 坐标），转成像素并在绘制图层上画椭圆
  private async handleEllipseDrag(startUiX: number, startUiY: number, endUiX: number, endUiY: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    const pm: image.PixelMap = this.pixelMap as image.PixelMap
    const info: image.ImageInfo = await pm.getImageInfo()

    const scaleBase: number = Math.min(
      this.canvasWidth / info.size.width,
      this.canvasHeight / info.size.height
    )

    const realW: number = info.size.width * scaleBase * this.zoom
    const realH: number = info.size.height * scaleBase * this.zoom

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    const startPxFloat: number = (startUiX - imageLeft) * (info.size.width / realW)
    const startPyFloat: number = (startUiY - imageTop) * (info.size.height / realH)
    const endPxFloat: number = (endUiX - imageLeft) * (info.size.width / realW)
    const endPyFloat: number = (endUiY - imageTop) * (info.size.height / realH)

    const x0: number = Math.floor(startPxFloat)
    const y0: number = Math.floor(startPyFloat)
    const x1: number = Math.floor(endPxFloat)
    const y1: number = Math.floor(endPyFloat)

    console.info(
      `>>> handleEllipseDrag uiStart=(${startUiX.toFixed(1)},${startUiY.toFixed(1)}), ` +
        `uiEnd=(${endUiX.toFixed(1)},${endUiY.toFixed(1)}) -> ` +
        `pixelStart=(${x0},${y0}), pixelEnd=(${x1},${y1}), imgSize=(${info.size.width},${info.size.height})`
    )

    let left: number = Math.min(x0, x1)
    let right: number = Math.max(x0, x1)
    let top: number = Math.min(y0, y1)
    let bottom: number = Math.max(y0, y1)

    if (right - left <= 0 || bottom - top <= 0) {
      console.info('>>> handleEllipseDrag: rect too small, skip')
      return
    }

    // 1）修改前压入撤销栈：只记录状态 + 绘制层快照（底图不动）
    await this.pushFullSnapshotBeforeChange();

    // 2）真正在绘制图层里画椭圆
    await this.drawEllipseBetweenPixels(left, top, right, bottom)

    // 3）写操作记录
    const desc: string =
      `画了一个椭圆 左上像素=(${left}, ${top}), 右下像素=(${right}, ${bottom})`

    await this.logAndSyncAfterImageChange(desc)

    promptAction.showToast({ message: '椭圆已绘制' })
  }

  // 在像素坐标里画一个椭圆边框（使用当前 stroke 宽度和颜色）
  // 传入的是椭圆外接矩形左上 / 右下
  // 在像素坐标里画一个椭圆边框（使用当前 stroke 宽度和颜色）
  // 传入的是椭圆外接矩形左上 / 右下，实际绘制在 drawPixelMap 上
  private async drawEllipseBetweenPixels(left: number, top: number, right: number, bottom: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    // 先用底图做一次边界裁剪（尺寸与绘制层一致）
    const basePm: image.PixelMap = this.pixelMap as image.PixelMap
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const baseW: number = baseInfo.size.width
    const baseH: number = baseInfo.size.height

    left = Math.max(0, left)
    right = Math.min(baseW - 1, right)
    top = Math.max(0, top)
    bottom = Math.min(baseH - 1, bottom)

    const w: number = right - left
    const h: number = bottom - top

    if (w <= 0 || h <= 0) {
      console.info('>>> drawEllipseBetweenPixels: rect too small, skip')
      return
    }

    const cx: number = Math.round((left + right) / 2)
    const cy: number = Math.round((top + bottom) / 2)
    const rx: number = w / 2
    const ry: number = h / 2

    // ② 在绘制图层上画椭圆
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    // 1）读绘制层像素
    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 2）通道顺序
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (info.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    const thickRadius: number = this.computeStrokeRadiusPixel(width, height)
    const alpha: number = this.getStrokeAlpha()

    const drawThickPoint = (px: number, py: number): void => {
      for (let yy: number = py - thickRadius; yy <= py + thickRadius; yy++) {
        if (yy < 0 || yy >= height) {
          continue
        }
        for (let xx: number = px - thickRadius; xx <= px + thickRadius; xx++) {
          if (xx < 0 || xx >= width) {
            continue
          }
          const dx: number = xx - px
          const dy: number = yy - py
          if (dx * dx + dy * dy > thickRadius * thickRadius) {
            continue
          }

          const baseIndex: number = (yy * width + xx) * 4
          const rIndex: number = baseIndex + rOffset
          const gIndex: number = baseIndex + gOffset
          const bIndex: number = baseIndex + bOffset
          const aIndex: number = baseIndex + aOffset

          if (this.currentBrush === BrushTool.Eraser) {
            // 橡皮擦：只擦绘制层，让它透明
            data[aIndex] = 0
          } else {
            data[rIndex] = this.strokeR
            data[gIndex] = this.strokeG
            data[bIndex] = this.strokeB
            data[aIndex] = alpha
          }
        }
      }
    }

    // 3）参数方程椭圆：x = cx + rx cos t, y = cy + ry sin t
    const TWO_PI: number = Math.PI * 2
    const maxR: number = Math.max(rx, ry)
    const steps: number = Math.max(36, Math.floor(TWO_PI * maxR / 2))

    for (let i: number = 0; i < steps; i++) {
      const t: number = (TWO_PI * i) / steps
      const px: number = Math.round(cx + rx * Math.cos(t))
      const py: number = Math.round(cy + ry * Math.sin(t))

      if (px < 0 || px >= width || py < 0 || py >= height) {
        continue
      }
      drawThickPoint(px, py)
    }

    // 4）写回绘制层像素
    await layerPm.writeBufferToPixels(buffer)

    // 5）clone 一张新的绘制层触发刷新
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer
    this.drawPixelVersion++

    console.info(`>>> drawEllipseBetweenPixels: ellipse drawn, drawPixelVersion=${this.drawPixelVersion}`)
  }

  // 在自由绘制时，每一小段手势移动，实时画到内存 buffer 里（同步）
  private drawFreeStrokeSegmentSync(
    prevUiX: number,
    prevUiY: number,
    curUiX: number,
    curUiY: number
  ): void {
    // 这里要求：已经在手势开始的时候初始化好 freeDrawArrayBuffer / freeDrawBuffer，
    // 且它是基于 “绘制层 drawPixelMap（如果有）或者底图 pixelMap” 的像素数据。
    if (!this.freeDrawBuffer || !this.freeDrawArrayBuffer) {
      return
    }
    if (!this.pixelMap && !this.drawPixelMap) {
      return
    }

    // ✅ 优先使用绘制层的尺寸 / 像素格式
    const basePm: image.PixelMap = (this.drawPixelMap ?? this.pixelMap) as image.PixelMap
    const info: image.ImageInfo = basePm.getImageInfoSync()

    const imgW: number = info.size.width
    const imgH: number = info.size.height

    // —— UI → 像素映射，逻辑跟你之前完全一样 ——
    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )
    const realW: number = imgW * scaleBase * this.zoom
    const realH: number = imgH * scaleBase * this.zoom

    const imageLeft: number = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop: number = (this.canvasHeight - realH) / 2 + this.offsetY

    const x0: number = Math.floor((prevUiX - imageLeft) * (imgW / realW))
    const y0: number = Math.floor((prevUiY - imageTop) * (imgH / realH))
    const x1: number = Math.floor((curUiX - imageLeft) * (imgW / realW))
    const y1: number = Math.floor((curUiY - imageTop) * (imgH / realH))

    // 越界直接丢弃这段
    if (
      x0 < 0 || x0 >= imgW || y0 < 0 || y0 >= imgH ||
        x1 < 0 || x1 >= imgW || y1 < 0 || y1 >= imgH
    ) {
      return
    }

    // ⭐ 真正画到 freeDrawBuffer（同步、不 await）
    this.drawLineIntoBuffer(
      x0,
      y0,
      x1,
      y1,
      this.freeDrawBuffer as Uint8Array,
      imgW,
      imgH,
      info.pixelFormat
    )
  }

  // 在给定的像素缓冲区里画一条“带粗细的线段”（自由画专用，完全同步）
  // x0,y0,x1,y1 是像素坐标；buffer 是整张图的 BGRA/ARGB/RGBA 像素数据
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
    const width: number = imgW
    const height: number = imgH

    // 通道偏移
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        // B G R A
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        // A R G B
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
      // R G B A
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    const radius: number = this.computeStrokeRadiusPixel(imgW, imgH)
    const alpha: number = this.getStrokeAlpha()

    const drawThickPoint = (cx: number, cy: number): void => {
      for (let yy: number = cy - radius; yy <= cy + radius; yy++) {
        if (yy < 0 || yy >= height) {
          continue
        }
        for (let xx: number = cx - radius; xx <= cx + radius; xx++) {
          if (xx < 0 || xx >= width) {
            continue
          }

          const dx: number = xx - cx
          const dy: number = yy - cy
          if (dx * dx + dy * dy > radius * radius) {
            continue
          }

          const baseIndex: number = (yy * width + xx) * 4
          const rIndex: number = baseIndex + rOffset
          const gIndex: number = baseIndex + gOffset
          const bIndex: number = baseIndex + bOffset
          const aIndex: number = baseIndex + aOffset

          if (aIndex >= buffer.length) {
            // 理论上不会越界，保险起见
            continue
          }

          if (this.currentBrush === BrushTool.Eraser) {
            // 🧽 橡皮擦：只把绘制层擦透明
            buffer[aIndex] = 0
          } else {
            // 普通画笔 / 荧光笔：用当前笔刷颜色 + 透明度
            buffer[rIndex] = this.strokeR
            buffer[gIndex] = this.strokeG
            buffer[bIndex] = this.strokeB
            buffer[aIndex] = alpha
          }
        }
      }
    }

    // —— 下面 Bresenham 画线保持不变 ——
    let curX: number = x0
    let curY: number = y0
    const dx: number = Math.abs(x1 - x0)
    const sx: number = x0 < x1 ? 1 : -1
    const dy: number = -Math.abs(y1 - y0)
    const sy: number = y0 < y1 ? 1 : -1
    let err: number = dx + dy

    while (true) {
      drawThickPoint(curX, curY)

      if (curX === x1 && curY === y1) {
        break
      }

      const e2: number = 2 * err
      if (e2 >= dy) {
        err += dy
        curX += sx
      }
      if (e2 <= dx) {
        err += dx
        curY += sy
      }
    }
  }

  private async prepareFreeDrawBuffer() {
    if (!this.pixelMap) {
      return
    }

    // ✅ 自由绘制只针对绘制层，如果还没有绘制层，先创建一张全透明的
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      return
    }

    this.freeBufferReady = false

    this.freeDrawByteLength = layerPm.getPixelBytesNumber()
    this.freeDrawArrayBuffer = new ArrayBuffer(this.freeDrawByteLength)

    // 异步读取绘制层像素（不能在手势里 await）
    layerPm.readPixelsToBuffer(this.freeDrawArrayBuffer).then(() => {
      this.freeDrawBuffer = new Uint8Array(this.freeDrawArrayBuffer as ArrayBuffer)
      this.freeBufferReady = true
    })
  }

  private async handleFreeDrawEnd(): Promise<void> {
    // 只在 FreeDraw 模式下结束自由绘制
    if (this.currentShape !== ShapeTool.FreeDraw || !this.pixelMap) {
      return
    }

    this.isFreeDrawing = false

    // ✅ 自由绘制作用于绘制层，如果没有则直接返回
    const layerPm: image.PixelMap | undefined = await this.ensureDrawLayer()
    if (!layerPm) {
      this.freeDrawBuffer = null
      this.freeDrawArrayBuffer = null
      return
    }

    // 1) 把最终的内存 buffer 写回绘制层 pixelMap
    if (this.freeDrawArrayBuffer) {
      await layerPm.writeBufferToPixels(this.freeDrawArrayBuffer)
    }

    // 2) clone 一份新的绘制层 —— 触发 UI 刷新（与其它图形绘制逻辑保持一致）
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)

    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer
    this.drawPixelVersion++ // Image(drawPixelMap) 会刷新

    // 3) 清空缓存
    this.freeDrawBuffer = null
    this.freeDrawArrayBuffer = null

    // ⭐ 新增 ②：写一条操作记录 + 做协作同步
    const desc: string = '自由画笔：完成了一笔自由绘制'
    await this.logAndSyncAfterImageChange(desc)
  }

  // 根据当前画笔透明度 strokeOpacity（0.0~1.0）计算对应的 alpha（0~255）
  // 当前画笔的 alpha（0~255）
  private getStrokeAlpha(): number {
    // 以后如果要做橡皮擦 = 抹透明，可以在这里 special case
    if (this.currentBrush === BrushTool.Eraser) {
      // 暂时先留着 255，不做“抹透明”逻辑，后面我们单独处理橡皮擦
      // return 0
    }

    let a: number = Math.round(this.strokeOpacity * 255)

    if (a < 0) {
      a = 0
    } else if (a > 255) {
      a = 255
    }
    return a
  }

  // 把 overlayPm（drawPixelMap）按 alpha 合成到 basePm 上（只修改 basePm）
  // 把绘制图层 overlayPm “盖”到 basePm 上：
  // 只要 overlay 像素 alpha > 0，就直接用 overlay 的 RGBA 覆盖 base 对应像素
  private async mergeDrawLayerIntoBase(
    basePm: image.PixelMap,
    overlayPm: image.PixelMap
  ): Promise<void> {
    const baseInfo: image.ImageInfo = await basePm.getImageInfo()
    const overInfo: image.ImageInfo = await overlayPm.getImageInfo()

    const width: number = baseInfo.size.width
    const height: number = baseInfo.size.height

    // 尺寸对不上，先尽量不崩，直接返回（下面第 2 步会保证裁剪时同步裁剪绘制层）
    if (overInfo.size.width !== width || overInfo.size.height !== height) {
      console.warn(
        `mergeDrawLayerIntoBase: size mismatch base=${width}x${height} over=${overInfo.size.width}x${overInfo.size.height}`
      )
      return
    }

    const baseLen: number = basePm.getPixelBytesNumber()
    const overLen: number = overlayPm.getPixelBytesNumber()

    const baseBuf: ArrayBuffer = new ArrayBuffer(baseLen)
    const overBuf: ArrayBuffer = new ArrayBuffer(overLen)

    await basePm.readPixelsToBuffer(baseBuf)
    await overlayPm.readPixelsToBuffer(overBuf)

    const baseData: Uint8Array = new Uint8Array(baseBuf)
    const overData: Uint8Array = new Uint8Array(overBuf)

    // ------- base 通道偏移 -------
    let brOff: number = 0
    let bgOff: number = 1
    let bbOff: number = 2
    let baOff: number = 3

    switch (baseInfo.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        bbOff = 0
        bgOff = 1
        brOff = 2
        baOff = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        baOff = 0
        brOff = 1
        bgOff = 2
        bbOff = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        brOff = 0
        bgOff = 1
        bbOff = 2
        baOff = 3
        break
    }

    // ------- overlay 通道偏移 -------
    let orOff: number = 0
    let ogOff: number = 1
    let obOff: number = 2
    let oaOff: number = 3

    switch (overInfo.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        obOff = 0
        ogOff = 1
        orOff = 2
        oaOff = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        oaOff = 0
        orOff = 1
        ogOff = 2
        obOff = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        orOff = 0
        ogOff = 1
        obOff = 2
        oaOff = 3
        break
    }

    // ------- 简单粗暴：只要 overlay alpha > 0，就覆盖 base -------
    for (let y: number = 0; y < height; y++) {
      for (let x: number = 0; x < width; x++) {
        const idx: number = (y * width + x) * 4

        const oaIdx: number = idx + oaOff
        const alphaOver: number = overData[oaIdx]

        if (alphaOver === 0) {
          // 没画东西/被橡皮擦擦掉的区域 → 直接跳过
          continue
        }

        const orIdx: number = idx + orOff
        const ogIdx: number = idx + ogOff
        const obIdx: number = idx + obOff

        const brIdx: number = idx + brOff
        const bgIdx: number = idx + bgOff
        const bbIdx: number = idx + bbOff
        const baIdx: number = idx + baOff

        baseData[brIdx] = overData[orIdx]
        baseData[bgIdx] = overData[ogIdx]
        baseData[bbIdx] = overData[obIdx]
        baseData[baIdx] = alphaOver // 或者 255，看你需求，这里保留 overlay 原始 alpha
      }
    }

    await basePm.writeBufferToPixels(baseBuf)
  }

  // 仅用于“保存图片”：把当前 brightnessLevel / contrastLevel 烘焙到给定 pm，但不修改 this.brightnessLevel / this.contrastLevel
  private async bakeToneForSave(pm: image.PixelMap): Promise<void> {
    // 当前没有调整就直接不处理
    if (this.brightnessLevel === 0 && this.contrastLevel === 0) {
      return
    }

    const info: image.ImageInfo = await pm.getImageInfo()
    const byteLength: number = pm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await pm.readPixelsToBuffer(buffer)
    const data: Uint8Array = new Uint8Array(buffer)

    // 通道顺序
    let rOffset: number = 0
    let gOffset: number = 1
    let bOffset: number = 2
    let aOffset: number = 3

    switch (info.pixelFormat) {
      case image.PixelMapFormat.BGRA_8888:
        bOffset = 0
        gOffset = 1
        rOffset = 2
        aOffset = 3
        break
      case image.PixelMapFormat.ARGB_8888:
        aOffset = 0
        rOffset = 1
        gOffset = 2
        bOffset = 3
        break
      case image.PixelMapFormat.RGBA_8888:
      default:
        rOffset = 0
        gOffset = 1
        bOffset = 2
        aOffset = 3
        break
    }

    // 和你原来一致的亮度/对比度计算
    const c: number = 1.0 + this.contrastLevel
    const shiftBrightness: number = this.brightnessLevel * 255.0
    const shiftTotal: number = 128.0 * (1.0 - c) + shiftBrightness

    const clamp = (v: number): number => {
      if (v < 0) {
        return 0
      }
      if (v > 255) {
        return 255
      }
      return v
    }

    for (let i: number = 0; i < data.length; i += 4) {
      const rIndex: number = i + rOffset
      const gIndex: number = i + gOffset
      const bIndex: number = i + bOffset
      const aIndex: number = i + aOffset

      const r = data[rIndex]
      const g = data[gIndex]
      const b = data[bIndex]

      data[rIndex] = clamp(c * r + shiftTotal)
      data[gIndex] = clamp(c * g + shiftTotal)
      data[bIndex] = clamp(c * b + shiftTotal)
      data[aIndex] = data[aIndex] // alpha 不变
    }

    await pm.writeBufferToPixels(buffer)
  }

  // 把「屏幕粗细」strokeWidth 换算成「图像像素半径」
  // imgW / imgH 是当前图片（或绘制层）的像素尺寸
  // 把“屏幕上粗细” strokeWidth 换算成“图像里的像素半径”
  // imgW / imgH 是当前图像（或绘制层）的像素尺寸
  private computeStrokeRadiusPixel(imgW: number, imgH: number): number {
    const MIN_RADIUS: number = 1

    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      // 兜底：画布尺寸异常时，直接用 strokeWidth 当像素半径
      return Math.max(MIN_RADIUS, Math.floor(this.strokeWidth))
    }

    // 和 UI→像素映射保持同一套缩放：contain 缩放 * 当前缩放因子
    const scaleBase: number = Math.min(
      this.canvasWidth / imgW,
      this.canvasHeight / imgH
    )
    const realScale: number = scaleBase * this.zoom

    if (realScale <= 0) {
      return Math.max(MIN_RADIUS, Math.floor(this.strokeWidth))
    }

    // strokeWidth 是“屏幕上的半径（px）”，除以 realScale 得到“图像像素半径”
    let r: number = this.strokeWidth / realScale

    if (r < MIN_RADIUS) {
      r = MIN_RADIUS
    }

    return Math.floor(r)
  }

  private ensureRemoteUser(clientId: string): void {
    // 已经存在就不重复添加
    const existed: OnlineUserInfo | undefined = this.onlineUsers
      .find((u: OnlineUserInfo) => u.clientId === clientId);
    if (existed) {
      return;
    }

    // 🎨 关键：颜色由 clientId 决定
    const color: string = this.pickColorForClient(clientId);

    const remoteUser: OnlineUserInfo = {
      clientId: clientId,
      displayColor: color,
      isSelf: false
    };

    this.onlineUsers = [...this.onlineUsers, remoteUser];
  }

  // 根据 clientId 算一个稳定的颜色索引，同一个 clientId 在任何设备上都一样
  // 根据 clientId 选择一个稳定的颜色：同一个 clientId → 同一个颜色
  private pickColorForClient(clientId: string): string {
    let hash: number = 0;
    for (let i = 0; i < clientId.length; i++) {
      hash = (hash * 31 + clientId.charCodeAt(i)) >>> 0; // 无符号 32bit
    }

    const paletteSize: number = this.userColorPalette.length;
    if (paletteSize === 0) {
      return '#000000'; // 兜底
    }

    const idx: number = hash % paletteSize;
    return this.userColorPalette[idx];
  }

  // 把当前画面同步给其他协作端（不会影响本地撤回栈）
  private async syncCanvasToOthers(): Promise<void> {
    // 没开协作、没连上、没图 → 直接不发
    if (!this.collabEnabled) {
      return;
    }
    if (!this.collabClient || !this.collabClient.connected) {
      console.info('[Collab] not connected, skip syncCanvasToOthers');
      return;
    }
    if (!this.pixelMap) {
      console.info('[Collab] no pixelMap, skip syncCanvasToOthers');
      return;
    }

    // ✅ 用 lastOpDesc 作为这次同步的“描述”
    const desc: string = this.lastOpDesc || '';

    await this.broadcastImageToPeers(this.pixelMap as image.PixelMap, desc);
  }

  // ===== 操作记录：追加一条日志 =====
  // ===== 操作记录：追加一条日志 =====
  private appendOpLog(userId: string, message: string, colorOpt?: string): void {
    // 1) 优先使用外部传进来的颜色（比如本机操作用 this.localColor）
    let color: string | undefined = colorOpt;

    // 2) 如果没传颜色，尝试从在线用户列表里找这个人的 displayColor
    if (!color) {
      const u: OnlineUserInfo | undefined = this.onlineUsers
        .find((item: OnlineUserInfo) => item.clientId === userId);
      if (u) {
        color = u.displayColor;
      }
    }

    // 3) 还找不到，就兜底用本地的 pickColorForClient 保证不会是空
    if (!color) {
      color = this.pickColorForClient(userId);
    }

    // 简单时间戳
    const now: Date = new Date();
    const ts: string = this.formatTime(now);

    const id: number = ++this.opSeq;
    const item: OperationLogItem = {
      id: id,
      userId: userId,
      userColor: color,
      message: message,
      timestamp: ts
    };

    // 最多保留 50 条，超过就从前面丢
    const maxLen: number = 50;
    const list: Array<OperationLogItem> = [...this.opLogList, item];
    if (list.length > maxLen) {
      list.shift();
    }
    this.opLogList = list;
  }

  // 时间格式化 HH:MM:SS
  private formatTime(d: Date): string {
    const h: string = d.getHours().toString().padStart(2, '0');
    const m: string = d.getMinutes().toString().padStart(2, '0');
    const s: string = d.getSeconds().toString().padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  // 把当前 PixelMap 打包成 PNG + base64，通过 WebSocket 发给所有人
  // 把当前 PixelMap 打包成 PNG + base64，通过 WebSocket 发给所有人
  // 把当前画面（底图 + 绘制层 + 亮度/对比度）打包成 PNG + base64，通过 WebSocket 发给所有人
  private async broadcastImageToPeers(pm: image.PixelMap, opDesc: string): Promise<void> {
    // 1) 克隆一份用于发送的临时代码（不要直接改 this.pixelMap）
    const sendPm: image.PixelMap = await this.clonePixelMap(pm)

    try {
      // 2) 如果有绘制层，把绘制层 merge 到 sendPm 上（让远端也看到画的线条/矩形等）
      if (this.drawPixelMap) {
        await this.mergeDrawLayerIntoBase(sendPm, this.drawPixelMap as image.PixelMap)
      }

      // 3) 把当前亮度 / 对比度烘焙到 sendPm（只影响 sendPm，本地 state 不变）
      await this.bakeToneForSave(sendPm)

      // 4) pack 成 PNG 的 ArrayBuffer
      const packer = image.createImagePacker()
      const packOpts: image.PackingOption = {
        format: 'image/png',
        quality: 100
      }
      const pngBuffer: ArrayBuffer = await packer.packToData(sendPm, packOpts)
      packer.release?.()

      // 5) ArrayBuffer -> base64
      const pngBase64: string = this.arrayBufferToBase64(pngBuffer)

      const senderId: string = this.localClientId || this.clientId
      const msg: CollabMessage = {
        type: 'imageSync',
        clientId: senderId,
        payload: {
          format: 'image/png',
          dataBase64: pngBase64,
          opDesc: opDesc, // 👈 使用参数里的描述
        } as CollabImageSyncPayload
      }

      this.collabClient.send(msg)
      console.info('[Collab] broadcast image-sync, size(base64)=', pngBase64.length)
    } finally {
      // 6) 释放临时 PixelMap
      sendPm.release?.()
    }
  }

  // 统一封装：图像修改后，记录一条操作 + 同步到其他端
  // 统一封装：图像修改后，记录一条操作 + 同步到其他端
  private async logAndSyncAfterImageChange(opDesc: string): Promise<void> {
    const selfId: string = this.localClientId || this.clientId
    // 1) 本机操作日志
    this.appendOpLog(selfId, opDesc, this.localColor)

    // 2) 协作描述，给对端显示同样的文字
    this.lastOpDesc = opDesc

    // 3) 如果没在协作 / 没连上 / 没有图，就只记日志，不发图
    if (!this.collabEnabled ||
      !this.collabClient ||
      !this.collabClient.connected ||
      !this.pixelMap) {
      return
    }

    // 4) 准备要发送的 PixelMap：
    //    - 默认是当前 this.pixelMap
    //    - 如果有亮度/对比度参数，就 clone 一张临时图，先把亮度/对比度烘焙进去再发
    let pmForSend: image.PixelMap = this.pixelMap as image.PixelMap

    if (this.brightnessLevel !== 0 || this.contrastLevel !== 0) {
      // clone 一份临时图
      const cloned: image.PixelMap = await this.clonePixelMap(pmForSend)
      // 把当前 brightnessLevel / contrastLevel 烘焙进去（不会修改 this.brightnessLevel / this.contrastLevel）
      await this.bakeToneForSave(cloned)
      pmForSend = cloned
    }

    // 5) 真正通过 WebSocket 广播
    await this.broadcastImageToPeers(pmForSend, opDesc)

    // 6) 如果用的是临时 clone，用完释放掉
    if (pmForSend !== this.pixelMap) {
      pmForSend.release?.()
    }
  }

  // 把 ArrayBuffer 转成 base64 字符串
  // ArrayBuffer -> base64 字符串
  // ArrayBuffer -> base64 string
  private arrayBufferToBase64(buf: ArrayBuffer): string {
    // 显式类型：Uint8Array
    const uint8: Uint8Array = new Uint8Array(buf)
    const base64Helper: util.Base64Helper = new util.Base64Helper()
    const base64Str: string = base64Helper.encodeToStringSync(uint8)
    return base64Str
  }

  // base64 string -> ArrayBuffer
  private base64ToArrayBuffer(b64: string): ArrayBuffer {
    const base64Helper: util.Base64Helper = new util.Base64Helper()
    // decodeSync 返回 Uint8Array
    const uint8: Uint8Array = base64Helper.decodeSync(b64)
    // Uint8Array 自带 buffer，就是 ArrayBuffer
    const buf: ArrayBuffer = uint8.buffer as ArrayBuffer
    return buf
  }

  // 把远端发来的 base64 PNG 转成 PixelMap 并应用到本地
  // ⭐ 建议：直接用这个版本覆盖你现有的 applyRemoteImage
  private async applyRemoteImage(payload: CollabImageSyncPayload): Promise<void> {
    // 1. 先把 payload.dataBase64 解成 PixelMap（你原来的逻辑）
    const buf: ArrayBuffer = this.base64ToArrayBuffer(payload.dataBase64);
    const imgSource: image.ImageSource = image.createImageSource(buf);
    const remotePm: image.PixelMap = await imgSource.createPixelMap({
      editable: true
    });
    imgSource.release?.();

    // 2. 在“接收远端画面”之前，把当前整张图压一份快照到 history 里
    if (this.pixelMap) {
      const currentPm: image.PixelMap = this.pixelMap as image.PixelMap;
      const backupPm: image.PixelMap = await this.clonePixelMap(currentPm);
      await this.pushHistorySnapshot(true, backupPm);
    }

    // 3. 释放当前底图
    if (this.pixelMap) {
      (this.pixelMap as image.PixelMap).release?.();
    }

    // 4. 替换为远端底图（协作 flatten 之后的“总画面”）
    this.pixelMap = remotePm;

    // 5. 更新 originalPixelMap（方便 resetView 回到“协作后的初始状态”）
    if (this.originalPixelMap) {
      this.originalPixelMap.release?.();
    }
    this.originalPixelMap = await this.clonePixelMap(remotePm);

    // 6. ⭐ 关键修改：协作图像之后，直接在 pixelMap 上作画，
    //    所以这里把 drawPixelMap 清掉，不再新建透明 overlay
    if (this.drawPixelMap) {
      this.drawPixelMap.release?.();
      this.drawPixelMap = undefined;
    }
    this.drawPixelVersion++;
    console.info('[Collab] applyRemoteImage: set pixelMap from remote, clear drawPixelMap, will draw directly on pixelMap.');

    // 7. 视图参数可以按你原来逻辑处理
    this.zoom = 1.0;
    this.offsetX = 0;
    this.offsetY = 0;
    this.brightnessLevel = 0.0;
    this.contrastLevel = 0.0;
    this.accumulatedRotate = 0;

    this.pixelVersion++;
  }

  // ⭐ 新增：在任何会改画面的操作之前，保存“整张图”的快照
  private async pushFullSnapshotBeforeChange(): Promise<void> {
    if (!this.pixelMap) {
      return;
    }
    const currentPm: image.PixelMap = this.pixelMap as image.PixelMap;
    // 一定要 clone，一定不能直接把 this.pixelMap 传进去
    const backupPm: image.PixelMap = await this.clonePixelMap(currentPm);

    // includePixel = true，pmForSnapshot 用我们 clone 出来的 backupPm
    await this.pushHistorySnapshot(true, backupPm);
  }
}
