import { promptAction } from '@kit.ArkUI'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { image } from '@kit.ImageKit'
import { fileIo } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { effectKit } from '@kit.ArkGraphics2D'


// 自定义错误类型
interface ErrorWithCode {
  code?: number | string
  message?: string
}

// 每一步画布状态快照，用于撤销
// interface CanvasSnapshot {
//   pixelMap?: image.PixelMap
//   zoom: number
//   offsetX: number
//   offsetY: number
//   brightnessLevel: number
//   contrastLevel: number
//   accumulatedRotate: number
// }
interface CanvasSnapshot {
  pixelMap?: image.PixelMap // 底图快照
  drawPixelMap?: image.PixelMap // ⭐ 新增：绘制图层快照
  zoom: number
  offsetX: number
  offsetY: number
  brightnessLevel: number
  contrastLevel: number
  accumulatedRotate: number
}


enum TopMenu {
  None,
  Image, // 图片操作
  Shape, // 形状
  Brush // 画笔
}

enum ShapeTool {
  None,
  Point,
  Line,
  Rect,
  Circle,
  Ellipse,
  FreeDraw
}

enum BrushTool {
  None,
  Pen,
  Highlighter,
  Eraser
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
  @State currentBrush: BrushTool = BrushTool.None
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

  build() {
    Column() {
      // 顶部工具栏
      Column() {
        Column() {
          // 顶部工具栏
          Column() {
            // === 一级菜单：图片操作 / 形状 / 画笔 / 撤销 ===
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

              // 一级按钮：撤销（这里先占位，后面你接入真正的撤销逻辑）
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
                    .onClick(() => this.currentShape = ShapeTool.Point)

                  Button('直线', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Line ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Line ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.currentShape = ShapeTool.Line)

                  Button('矩形', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Rect ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Rect ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.currentShape = ShapeTool.Rect)

                  Button('圆', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Circle ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Circle ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.currentShape = ShapeTool.Circle)

                  Button('椭圆', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.Ellipse ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.Ellipse ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.currentShape = ShapeTool.Ellipse)

                  Button('线条', { type: ButtonType.Normal })
                    .height(28)
                    .fontSize(11)
                    .backgroundColor(this.currentShape === ShapeTool.FreeDraw ? '#2563EB' : '#E5F3FF')
                    .fontColor(this.currentShape === ShapeTool.FreeDraw ? '#FFFFFF' : '#1D4ED8')
                    .onClick(() => this.currentShape = ShapeTool.FreeDraw)

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

                  // ===== 第 1 行：橡皮擦 =====
                  Row({ space: 8 }) {
                    Button('橡皮擦', { type: ButtonType.Normal })
                      .height(28)
                      .fontSize(11)
                      .backgroundColor(this.currentBrush === BrushTool.Eraser ? '#FB923C' : '#FEF3C7')
                      .fontColor(this.currentBrush === BrushTool.Eraser ? '#FFFFFF' : '#92400E')
                      .onClick(() => {
                        this.currentBrush = BrushTool.Eraser
                      })
                  }
                  .height(32)
                  .padding({ left: 4, right: 4, bottom: 4 })


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


                  // ===== 第 4 行：颜色选择（全局颜色，形状 + 画笔共用） =====
                  Row({ space: 8 }) {
                    // 黑色
                    Button('', { type: ButtonType.Normal })
                      .width(24)
                      .height(24)
                      .backgroundColor('#000000')
                      .borderRadius(12)
                      .border({ width: 1, color: '#E5E7EB' })
                      .onClick(() => {
                        this.strokeR = 0
                        this.strokeG = 0
                        this.strokeB = 0
                      })

                    // 红色
                    Button('', { type: ButtonType.Normal })
                      .width(24)
                      .height(24)
                      .backgroundColor('#EF4444')
                      .borderRadius(12)
                      .border({ width: 1, color: '#E5E7EB' })
                      .onClick(() => {
                        this.strokeR = 239
                        this.strokeG = 68
                        this.strokeB = 68
                      })

                    // 绿色
                    Button('', { type: ButtonType.Normal })
                      .width(24)
                      .height(24)
                      .backgroundColor('#22C55E')
                      .borderRadius(12)
                      .border({ width: 1, color: '#E5E7EB' })
                      .onClick(() => {
                        this.strokeR = 34
                        this.strokeG = 197
                        this.strokeB = 94
                      })

                    // 蓝色
                    Button('', { type: ButtonType.Normal })
                      .width(24)
                      .height(24)
                      .backgroundColor('#3B82F6')
                      .borderRadius(12)
                      .border({ width: 1, color: '#E5E7EB' })
                      .onClick(() => {
                        this.strokeR = 59
                        this.strokeG = 130
                        this.strokeB = 246
                      })
                  }
                  .height(32)
                  .padding({ left: 4, right: 4 })

                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .width('100%')
              .padding({ bottom: 8 })
            }
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
              .onClick(() => this.resetView())
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

      // ========== 新增：为这张图片创建一层透明的绘制层 ==========
      if (this.drawPixelMap) {
        this.drawPixelMap.release?.()
      }
      this.drawPixelMap = await this.createEmptyDrawLayerLike(pm)
      this.drawPixelVersion++
      // =========================================================

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

      // 保存前把亮度真正写进像素
      const pm: image.PixelMap = this.pixelMap as image.PixelMap
      await this.bakeToneToPixelMap(pm)

      // 下面保持原来的保存逻辑不变，用 pm 保存
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
          pm, // ← 用已经烘焙亮度后的 pixelMap
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

  private async doCrop() {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    const pm = this.pixelMap as image.PixelMap
    const info = await pm.getImageInfo()

    // 求实际显示尺寸（考虑 contain + zoom）
    const scaleBase = Math.min(
      this.canvasWidth / info.size.width,
      this.canvasHeight / info.size.height
    )

    const realW = info.size.width * scaleBase * this.zoom
    const realH = info.size.height * scaleBase * this.zoom

    // 图片左上角（受 offsetX/Y 影响）
    const imageLeft = (this.canvasWidth - realW) / 2 + this.offsetX
    const imageTop = (this.canvasHeight - realH) / 2 + this.offsetY

    // UI 裁剪框（未裁边界前）
    let uiX1 = Math.min(this.cropStartX, this.cropEndX)
    let uiY1 = Math.min(this.cropStartY, this.cropEndY)
    let uiX2 = Math.max(this.cropStartX, this.cropEndX)
    let uiY2 = Math.max(this.cropStartY, this.cropEndY)

    // 将裁剪框限制到图片所在区域
    const imgX1 = imageLeft
    const imgY1 = imageTop
    const imgX2 = imageLeft + realW
    const imgY2 = imageTop + realH

    // 与图片显示区域求交集
    uiX1 = Math.max(uiX1, imgX1)
    uiY1 = Math.max(uiY1, imgY1)
    uiX2 = Math.min(uiX2, imgX2)
    uiY2 = Math.min(uiY2, imgY2)

    // 若交集无效，直接结束
    if (uiX2 <= uiX1 || uiY2 <= uiY1) {
      promptAction.showToast({ message: '裁剪区域超出图片范围' })
      this.cropMode = false
      return
    }

    // 映射到像素坐标
    const px1 = (uiX1 - imageLeft) * (info.size.width / realW)
    const py1 = (uiY1 - imageTop) * (info.size.height / realH)
    const px2 = (uiX2 - imageLeft) * (info.size.width / realW)
    const py2 = (uiY2 - imageTop) * (info.size.height / realH)

    const cropX = Math.max(0, Math.floor(px1))
    const cropY = Math.max(0, Math.floor(py1))
    const cropW = Math.floor(px2 - px1)
    const cropH = Math.floor(py2 - py1)

    if (cropW <= 0 || cropH <= 0) {
      promptAction.showToast({ message: '裁剪区域太小' })
      this.cropMode = false
      return
    }

    // ========= 核心修改部分开始 =========

    // 1) 先 clone 一份“裁剪前的完整图”作为历史快照
    const backupPm = await this.clonePixelMap(pm)
    await this.pushHistorySnapshot(true, backupPm)

    // 2) 在当前 pixelMap 上原地裁剪（保持 this.pixelMap 引用不变）
    await pm.crop({
      x: cropX,
      y: cropY,
      size: { width: cropW, height: cropH }
    })

    // ========= 核心修改部分结束 =========

    // 完成后复位视图
    this.cropMode = false
    this.zoom = 1
    this.offsetX = 0
    this.offsetY = 0
    this.pixelVersion++

    // 清空裁剪框，避免上次残留
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
    } catch (err) {
      const e = err as Error
      console.error(`rotateLeft90 failed: ${e.message}`)
      promptAction.showToast({ message: '左旋失败' })
    } finally {
      this.isRotating = false
    }
  }

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
    // 先只记录当前形状，真正绘制逻辑以后再加
    this.currentShape = shape
  }

  private selectBrush(brush: BrushTool) {
    // 先只记录当前画笔
    this.currentBrush = brush
  }

  private async undo() {
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

    this.pixelVersion++
  }

  // 在「绘制图层」上画一个点（uiX/uiY 是画布上的点击坐标）
  private async drawPointAtUi(uiX: number, uiY: number) {
    if (!this.pixelMap) {
      return
    }

    await this.pushHistorySnapshot(false)

    // 1. 画布尺寸防御
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      console.info('>>> drawPointAtUi: canvas size is 0, skip')
      return
    }

    // 2. 必须已经有绘制图层（在 pickImage 里创建）
    if (!this.drawPixelMap) {
      promptAction.showToast({ message: '绘制图层不存在，请重新打开图片' })
      return
    }

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

    // ===== 2) 在「绘制图层」上改像素 =====
    const layerPm: image.PixelMap = this.drawPixelMap as image.PixelMap
    const info: image.ImageInfo = await layerPm.getImageInfo()
    const width: number = info.size.width
    const height: number = info.size.height

    if (px < 0 || py < 0 || px >= width || py >= height) {
      console.info('>>> drawPointAtUi: pixel out of layer range')
      return
    }

    const byteLength: number = layerPm.getPixelBytesNumber()
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength)
    await layerPm.readPixelsToBuffer(buffer)
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

    const radius: number = this.strokeWidth > 0 ? this.strokeWidth : 4
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
          // 橡皮擦：只擦掉绘制层的 alpha
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
    await layerPm.writeBufferToPixels(buffer)

    // 和你对主图的做法保持一致：clone 一份新的，赋给 @State
    const newLayer: image.PixelMap = await this.clonePixelMap(layerPm)
    // 旧的图层可以释放（可选）
    if (this.drawPixelMap && this.drawPixelMap !== newLayer) {
      this.drawPixelMap.release?.()
    }
    this.drawPixelMap = newLayer

    console.info(`>>> draw layer created: size=${(await this.drawPixelMap!.getImageInfo()).size.width}x${(await this.drawPixelMap!.getImageInfo()).size.height}`)


    this.drawPixelVersion++ // id(`draw-${drawPixelVersion}`) 也一起变
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

    promptAction.showToast({ message: '直线已绘制' })
  }

  // 在绘制图层 drawPixelMap 上画一条“带粗细的直线”
  private async drawLineBetweenPixels(x0: number, y0: number, x1: number, y1: number): Promise<void> {
    if (!this.pixelMap) {
      return
    }

    // ⭐ 和画点一样，先记录一次历史快照（只记录状态 + 绘制层）
    await this.pushHistorySnapshot(false)

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

    const radius: number = this.strokeWidth > 0 ? this.strokeWidth : 4
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
    await this.pushHistorySnapshot(false)

    // 2）在绘制层上画矩形
    await this.drawRectBetweenPixels(x0, y0, x1, y1)

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

    const radius: number = this.strokeWidth > 0 ? this.strokeWidth : 4
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

    const strokeRadius: number = this.strokeWidth > 0 ? this.strokeWidth : 4
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
    await this.pushHistorySnapshot(false)

    // 3）真正画圆（在绘制图层上）
    await this.drawCircleBetweenPixels(left, top, right, bottom)

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
    await this.pushHistorySnapshot(false)

    // 2）真正在绘制图层里画椭圆
    await this.drawEllipseBetweenPixels(left, top, right, bottom)

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

    const thickRadius: number = this.strokeWidth > 0 ? this.strokeWidth : 4
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

    const radius: number = this.strokeWidth > 0 ? this.strokeWidth : 4
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

    const pm = this.pixelMap as image.PixelMap

    this.freeBufferReady = false

    this.freeDrawByteLength = pm.getPixelBytesNumber()
    this.freeDrawArrayBuffer = new ArrayBuffer(this.freeDrawByteLength)

    // 异步读取像素（不能在手势里 await）
    pm.readPixelsToBuffer(this.freeDrawArrayBuffer).then(() => {
      this.freeDrawBuffer = new Uint8Array(this.freeDrawArrayBuffer!)
      this.freeBufferReady = true
    })
  }

  private async handleFreeDrawEnd(): Promise<void> {
    // 这里不再检查 isFreeDrawing，只检查当前工具 & pixelMap
    if (this.currentShape !== ShapeTool.FreeDraw || !this.pixelMap) {
      return
    }

    this.isFreeDrawing = false

    const pm: image.PixelMap = this.pixelMap as image.PixelMap

    // 1) 把最后的内存 buffer 写回 pixelMap
    if (this.freeDrawArrayBuffer) {
      await pm.writeBufferToPixels(this.freeDrawArrayBuffer)
    }

    // 2) clone 一份新的 PixelMap —— 触发真正的 UI 刷新
    const newPm: image.PixelMap = await this.clonePixelMap(pm)

    if (this.pixelMap && this.pixelMap !== newPm) {
      (this.pixelMap as image.PixelMap).release?.()
    }

    this.pixelMap = newPm
    this.pixelVersion++ // Image() 会刷新

    // 3) 清空缓存
    this.freeDrawBuffer = null
    this.freeDrawArrayBuffer = null
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
}
