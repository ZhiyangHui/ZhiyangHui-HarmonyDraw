// entry/src/main/ets/pages/ColorPicker.ets
// 用于 HSV -> RGB 转换的返回结构
interface RGBColor {
  r: number
  g: number
  b: number
}

@Component
export struct ColorWheelPicker {
  // 与外部画笔颜色状态绑定
  // 颜色选中后，直接影响外部画笔的 RGB
  @Link strokeR: number
  @Link strokeG: number
  @Link strokeB: number
  // 色环的物理尺寸（正方形）
  private readonly wheelSize: number = 60
  // 选中点在色环局部坐标系中的位置
  // 初始值只是占位，真正位置由点击/拖动决定
  @State selX: number = 100
  @State selY: number = 0

  build() {
    Stack() {
      // 底层：色环图片
      // 只负责提供视觉上的 Hue 分布
      Image($r('app.media.color_wheel'))
        .width(this.wheelSize)
        .height(this.wheelSize)
        .objectFit(ImageFit.Contain)

      // 中层：选中点指示器
      // 一个带描边的小圆，表示当前选中的颜色位置
      Circle()
        .width(16)
        .height(16)
        .fill(Color.White)
        .stroke('#111827')
        .strokeWidth(2)
        // 指示器以圆心对齐点击位置
        .position({
          x: this.selX - 8,
          y: this.selY - 8
        })

      // 顶层：透明手势层
      // 专门用于接收点击 / 拖动事件
      Stack()
        .width(this.wheelSize)
        .height(this.wheelSize)
        .backgroundColor(Color.Transparent)
        .gesture(
          // 并行手势：支持点选 + 拖动
          GestureGroup(GestureMode.Parallel,
            // 单击选择颜色
            TapGesture()
              .onAction(event => {
                if (!event.fingerList || event.fingerList.length === 0) {
                  return
                }
                const finger = event.fingerList[0]
                this.handlePick(finger.localX, finger.localY)
              }),
            // 拖动连续取色
            PanGesture({ direction: PanDirection.All })
              .onActionStart(event => {
                if (!event.fingerList || event.fingerList.length === 0) {
                  return
                }
                const finger = event.fingerList[0]
                this.handlePick(finger.localX, finger.localY)
              })
              .onActionUpdate(event => {
                if (!event.fingerList || event.fingerList.length === 0) {
                  return
                }
                const finger = event.fingerList[0]
                this.handlePick(finger.localX, finger.localY)
              })
          )
        )
    }
    .width(this.wheelSize)
    .height(this.wheelSize)
  }

  /**
   * 根据触摸点坐标计算颜色
   * uiX / uiY：色环局部坐标系中的点击位置
   */
  private handlePick(uiX: number, uiY: number): void {
    // 色环中心点坐标
    const cx = this.wheelSize / 2
    const cy = this.wheelSize / 2

    // 将点击点转换为以中心为原点的坐标
    const dx = uiX - cx
    const dy = uiY - cy

    // 到中心点的距离
    const dist = Math.sqrt(dx * dx + dy * dy)

    // 色环最大有效半径
    const maxRadius = this.wheelSize / 2

    // 点击在圆外或异常情况，直接忽略
    if (dist <= 0 || dist > maxRadius) {
      return
    }

    // 更新选中点位置（用于 UI 指示）
    this.selX = uiX
    this.selY = uiY

    // 使用 atan2 计算角度，范围是 [-π, π]
    let angle = Math.atan2(dy, dx)

    // 转换为角度制（Hue）
    let hue = angle * 180 / Math.PI

    // 统一到 [0, 360) 区间
    if (hue < 0) {
      hue += 360
    }

    // 色环：固定 S=1，V=1
    // 半径只用于限制范围，不参与明度计算
    const rgb: RGBColor = this.hsvToRgb(hue, 1.0, 1.0)

    // 回写到外部画笔颜色
    this.strokeR = rgb.r
    this.strokeG = rgb.g
    this.strokeB = rgb.b
  }

  /**
   * HSV 转 RGB
   * h：色相 [0, 360)
   * s：饱和度 [0, 1]
   * v：明度 [0, 1]
   */
  private hsvToRgb(h: number, s: number, v: number): RGBColor {
    // c 表示当前颜色的最大色度（饱和度和明度共同决定）
    const c = v * s

    // 将 Hue 从 0~360° 映射到 0~6，用来判断当前颜色落在哪一个 RGB 色区
    const hPrime = h / 60

    // 计算色区内的过渡通道值：
    // 在一个 60° 色区内，该通道会从 0 → c → 0 变化
    const x = c * (1 - Math.abs((hPrime % 2) - 1))

    // 未加偏移前的 RGB 分量
    let r1 = 0, g1 = 0, b1 = 0

    // 根据色相所在区间确定 RGB 组合
    if (hPrime >= 0 && hPrime < 1) {
      r1 = c
      g1 = x
      b1 = 0
    } else if (hPrime >= 1 && hPrime < 2) {
      r1 = x
      g1 = c
      b1 = 0
    } else if (hPrime >= 2 && hPrime < 3) {
      r1 = 0
      g1 = c
      b1 = x
    } else if (hPrime >= 3 && hPrime < 4) {
      r1 = 0
      g1 = x
      b1 = c
    } else if (hPrime >= 4 && hPrime < 5) {
      r1 = x
      g1 = 0
      b1 = c
    } else if (hPrime >= 5 && hPrime < 6) {
      r1 = c
      g1 = 0
      b1 = x
    }

    // 明度偏移
    const m = v - c

    // 映射到 [0, 255] 的整数 RGB
    return {
      r: Math.round((r1 + m) * 255),
      g: Math.round((g1 + m) * 255),
      b: Math.round((b1 + m) * 255)
    }
  }
}
