import { promptAction } from '@kit.ArkUI'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { image } from '@kit.ImageKit'
import { fileIo } from '@kit.CoreFileKit'

// 自定义错误类型
interface ErrorWithCode {
  code?: number | string
  message?: string
}


@Entry
@Component
struct Index {
  // 画布状态
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
        Text('鸿绘')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#6B7280')
          .layoutWeight(1)

        Button('打开图片', { type: ButtonType.Capsule })
          .height(40).padding({ left:14, right:14 })
          .onClick(() => this.pickImage())

        Button('保存', { type: ButtonType.Capsule })
          .height(40).padding({ left:14, right:14 })
          .onClick(() => this.saveImage())

        Button('重置', { type: ButtonType.Capsule })
          .height(40).padding({ left:14, right:14 })
          .backgroundColor('#EEF2FF')
          .fontColor('#3B82F6')
          .onClick(() => this.resetView())
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

      const uri: string = uris[0]
      console.info(`>>> Selected URI = ${uri}`)

      // 2. 用 fileIo 打开 uri，拿 fd
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)

      // 3. 创建 ImageSource
      const imgSource: image.ImageSource = image.createImageSource(file.fd)
      if (!imgSource) {
        await fileIo.close(file)
        throw new Error('createImageSource 返回空')
      }

      // 4. 从 ImageSource 创建 PixelMap
      const pm: image.PixelMap = await imgSource.createPixelMap({
        editable: true
      })

      // 5. 释放底层资源
      imgSource.release?.()
      await fileIo.close(file)

      // 6. 更新 UI 状态
      if (this.pixelMap) {
        this.pixelMap.release?.()
      }
      this.pixelMap = pm
      this.resetView()

      promptAction.showToast({ message: '图片已加载 ✅' })
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

  // === 保存图片（占位实现）===
  private async saveImage() {
    try {
      if (!this.pixelMap) {
        promptAction.showToast({ message: '请先打开图片' })
        return
      }
      // TODO：这里后续接入导出/保存逻辑
      promptAction.showToast({ message: '保存功能即将接入' })
    } catch (err) {
      console.error('saveImage error', err)
      promptAction.showToast({ message: '保存失败' })
    }
  }
}
