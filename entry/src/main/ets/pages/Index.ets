import promptAction from '@ohos.promptAction'
import filePicker from '@ohos.file.picker'
import image from '@ohos.multimedia.image'

@Entry
@Component
export struct Index {
  // 画布状态（避免与 ArkUI 的 .scale()/.translate() 同名）
  @State pixelMap?: image.PixelMap = undefined
  @State zoom: number = 1.0
  @State offsetX: number = 0
  @State offsetY: number = 0

  // 手势内部状态
  private lastPanX: number = 0
  private lastPanY: number = 0

  build() {
    Column({ space: 8 }) {
      // 顶部栏
      Row({ space: 8 }) {
        Text('鸿绘 HarmonyDraw')
          .fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)

        Button('打开图片', { type: ButtonType.Capsule })
          .onClick(() => this.pickImage())

        Button('保存', { type: ButtonType.Capsule })
          .onClick(() => this.saveImage())

        Button('重置', { type: ButtonType.Capsule })
          .onClick(() => this.resetView())
      }
      .padding(12).backgroundColor('#F6F6F7').width('100%')

      // 画布区域
      Stack() {
        if (!this.pixelMap) {
          Column() {
            Text('点击“打开图片”开始编辑').fontSize(16).opacity(0.8)
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          Image(this.pixelMap)
            .objectFit(ImageFit.Contain)
            .width('100%').height('100%')
            .scale({ x: this.zoom, y: this.zoom })           // 使用组件属性，不与@State重名
            .translate({ x: this.offsetX, y: this.offsetY }) // 平移
        }
      }
      .width('100%').height('100%').backgroundColor('#FFFFFF')
      // 拖拽手势
      .gesture(
        PanGesture()
          .onActionStart(e => {
            const f = e.fingerList[0]
            this.lastPanX = f.localX
            this.lastPanY = f.localY
          })
          .onActionUpdate(e => {
            const f = e.fingerList[0]
            this.offsetX += (f.localX - this.lastPanX)
            this.offsetY += (f.localY - this.lastPanY)
            this.lastPanX = f.localX
            this.lastPanY = f.localY
          })
      )
      // 捏合缩放
      .gesture(
        PinchGesture()
          .onActionUpdate(e => {
            const next = this.zoom * e.scale
            this.zoom = Math.min(6.0, Math.max(0.2, next))
          })
      )
      // 双击复位
      .gesture(
        TapGesture({ count: 2 }).onAction(() => this.resetView())
      )
      .padding(8)
    }
    .width('100%').height('100%').backgroundColor('#FAFAFA')
  }

  private resetView() {
    this.zoom = 1.0
    this.offsetX = 0
    this.offsetY = 0
  }

  // 打开图片 → PixelMap
  private async pickImage() {
    try {
      const picker = new filePicker.PhotoViewPicker()
      // NEXT：这里没有 MIMEType 字段，传最大选择数即可
      const res = await picker.select({ maxSelectNumber: 1 })
      if (!res || !res.photoUris || res.photoUris.length === 0) return

      const uri = res.photoUris[0]
      const src = image.createImageSource(uri)
      const pm = await src.createPixelMap({})
      this.pixelMap = pm
      this.resetView()
    } catch (err) {
      promptAction.showToast({ message: `打开失败：${JSON.stringify(err)}` })
    }
  }

  private async saveImage() {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }
    // 下一步我们接 ImagePacker + 媒体库写入
    promptAction.showToast({ message: '保存功能即将接入' })
  }
}
