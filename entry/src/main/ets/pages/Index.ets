import promptAction from '@ohos.promptAction'
import filePicker from '@ohos.file.picker'
import image from '@ohos.multimedia.image'

@Entry
@Component
struct Index {
  // 画布状态（
  @State pixelMap?: image.PixelMap = undefined
  @State zoom: number = 1.0
  @State offsetX: number = 0
  @State offsetY: number = 0

  // 手势内部状态
  private lastPanX: number = 0
  private lastPanY: number = 0

  build() {
    Column() {
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
          Image(this.pixelMap)
            .objectFit(ImageFit.Contain)
            .width('100%').height('100%')
          // === 若你保留交互，这里别动 ===
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
      .shadow({ radius: 16, color:'#1A000000', offsetY: 2 })
      .padding(2)
      .clip(true)

      // 底部工具栏
      Row({ space: 10 }) {
        // 左侧标题弱化，给按钮腾空间
        Text('鸿绘')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#6B7280')
          .layoutWeight(1)

        // 统一按钮规格：高度/内边距/最小宽
        Button('打开图片', { type: ButtonType.Capsule })
          .height(40).padding({ left:14, right:14 })
        Button('保存', { type: ButtonType.Capsule })
          .height(40).padding({ left:14, right:14 })
        Button('重置', { type: ButtonType.Capsule })
          .height(40).padding({ left:14, right:14 })
          .backgroundColor('#EEF2FF')   // 弱主次对比
          .fontColor('#3B82F6')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 0 })
      .backgroundColor('#F7F8FA')
      .border({ width: { top: 0.5 }, color: '#E5E7EB' })
      .alignItems(VerticalAlign.Center)

    }
    .width('100%').height('100%')
    .backgroundColor('#F2F4F7')
    .padding(12)
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
    try {
      if (!this.pixelMap) {
        promptAction.showToast({ message: '请先打开图片' })
        return
      }
      // TODO: 保存逻辑
      promptAction.showToast({ message: '保存功能即将接入' })
    } catch (err) {
      promptAction.showToast({ message: '保存失败' })
      console.error('saveImage error', err)
    }
  }
}
