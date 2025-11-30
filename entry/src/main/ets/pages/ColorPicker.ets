// entry/src/main/ets/pages/ColorPicker.ets

// ArkTS 6.0：所有对象类型必须显式 interface
interface RGBColor {
  r: number
  g: number
  b: number
}

@Component
export struct ColorWheelPicker {
  @Link strokeR: number
  @Link strokeG: number
  @Link strokeB: number
  private readonly wheelSize: number = 60
  @State selX: number = 100
  @State selY: number = 0

  build() {
    Stack() {
      Image($r('app.media.color_wheel'))
        .width(this.wheelSize)
        .height(this.wheelSize)
        .objectFit(ImageFit.Contain)

      Circle()
        .width(16)
        .height(16)
        .fill(Color.White)
        .stroke('#111827')
        .strokeWidth(2)
        .position({
          x: this.selX - 8,
          y: this.selY - 8
        })

      Stack()
        .width(this.wheelSize)
        .height(this.wheelSize)
        .backgroundColor(Color.Transparent)
        .gesture(
          GestureGroup(GestureMode.Parallel,
            TapGesture()
              .onAction(event => {
                if (!event.fingerList || event.fingerList.length === 0) {
                  return
                }
                const finger = event.fingerList[0]
                this.handlePick(finger.localX, finger.localY)
              }),
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

  private handlePick(uiX: number, uiY: number): void {
    const cx = this.wheelSize / 2
    const cy = this.wheelSize / 2

    const dx = uiX - cx
    const dy = uiY - cy
    const dist = Math.sqrt(dx * dx + dy * dy)

    const maxRadius = this.wheelSize / 2
    if (dist <= 0 || dist > maxRadius) {
      return
    }

    this.selX = uiX
    this.selY = uiY

    let angle = Math.atan2(dy, dx)
    let hue = angle * 180 / Math.PI

    if (hue < 0) {
      hue += 360
    }

    const rgb: RGBColor = this.hsvToRgb(hue, 1.0, 1.0)

    this.strokeR = rgb.r
    this.strokeG = rgb.g
    this.strokeB = rgb.b
  }

  private hsvToRgb(h: number, s: number, v: number): RGBColor {
    const c = v * s
    const hPrime = h / 60
    const x = c * (1 - Math.abs((hPrime % 2) - 1))

    let r1 = 0, g1 = 0, b1 = 0

    if (hPrime >= 0 && hPrime < 1) {
      r1 = c;
      g1 = x;
      b1 = 0
    } else if (hPrime >= 1 && hPrime < 2) {
      r1 = x;
      g1 = c;
      b1 = 0
    } else if (hPrime >= 2 && hPrime < 3) {
      r1 = 0;
      g1 = c;
      b1 = x
    } else if (hPrime >= 3 && hPrime < 4) {
      r1 = 0;
      g1 = x;
      b1 = c
    } else if (hPrime >= 4 && hPrime < 5) {
      r1 = x;
      g1 = 0;
      b1 = c
    } else if (hPrime >= 5 && hPrime < 6) {
      r1 = c;
      g1 = 0;
      b1 = x
    }

    const m = v - c

    return {
      r: Math.round((r1 + m) * 255),
      g: Math.round((g1 + m) * 255),
      b: Math.round((b1 + m) * 255)
    }
  }
}
