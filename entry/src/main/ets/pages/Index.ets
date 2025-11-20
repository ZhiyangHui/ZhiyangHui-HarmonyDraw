import { promptAction } from '@kit.ArkUI'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { image } from '@kit.ImageKit'
import { fileIo } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'


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
  @State pixelVersion: number = 0

  // 旋转中标志，防止连点导致两次右旋
  private isRotating: boolean = false
  private accumulatedRotate: number = 0 // 之前旋转的总度数

  // 旋转 / 亮度 / 对比度
  @State rotateDeg: number = 0 // 旋转角度
  // @State brightness: number = 0.0       // -1.0 ~ 1.0
  // @State contrast: number = 0.0         // -1.0 ~ 1.0

  // 手势内部状态
  private lastPanX: number = 0
  private lastPanY: number = 0
  private lastZoom: number = 1.0

  build() {
    Column() {
      // 顶部工具栏
      Column() {
        Row({ space: 8 }) {

          Button('裁剪', { type: ButtonType.Capsule })
            .height(32)
            .fontSize(12)
            .onClick(() => this.cropCenter()) // 空壳函数

          // —— 按钮：左旋 90°
          Button('左旋90°', { type: ButtonType.Capsule })
            .height(32)
            .fontSize(12)
            .onClick(() => this.rotateLeft90()) // 空壳函数

          // —— 按钮：右旋 90°
          Button('右旋90°', { type: ButtonType.Capsule })
            .height(32)
            .fontSize(12)
            .onClick(() => this.rotateRight90()) // 空壳函数


          Button('变亮', { type: ButtonType.Capsule })
            .height(32)
            .fontSize(12)
            .onClick(() => this.adjustBrightness(0.1)) // 空壳

          Button('变暗', { type: ButtonType.Capsule })
            .height(32)
            .fontSize(12)
            .onClick(() => this.adjustBrightness(-0.1)) // 空壳


        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 8 })
        .justifyContent(FlexAlign.Start)
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

          // =============================
          // 1) 图片渲染层（无手势，纯展示）
          // =============================
          Image(this.pixelMap)
            .id(`img-${this.pixelVersion}`)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
            .scale({ x: this.zoom, y: this.zoom })
            .translate({ x: this.offsetX, y: this.offsetY })


          // =============================
          // 2) 透明手势捕获层（只接收手势，不挡按钮）
          // =============================
          Stack()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Transparent)   // 全透明
            .hitTestBehavior(HitTestMode.Transparent)
            // ⬆ 关键：不阻挡点击事件，只接收手势
            .gesture(
              GestureGroup(GestureMode.Parallel,

                // 拖动
                PanGesture({ direction: PanDirection.All, distance: 2 })
                  .onActionStart(event => {
                    this.lastPanX = this.offsetX
                    this.lastPanY = this.offsetY
                  })
                  .onActionUpdate(event => {
                    this.offsetX = this.lastPanX + event.offsetX
                    this.offsetY = this.lastPanY + event.offsetY
                  }),

                // 双指缩放
                PinchGesture()
                  .onActionStart(event => {
                    this.lastZoom = this.zoom
                  })
                  .onActionUpdate(event => {
                    let next = this.lastZoom * event.scale
                    const MIN_ZOOM = 0.3
                    const MAX_ZOOM = 5.0
                    if (next < MIN_ZOOM) next = MIN_ZOOM
                    if (next > MAX_ZOOM) next = MAX_ZOOM
                    this.zoom = next
                  })
              )
            )
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
      .shadow({ radius: 16, color: '#1A000000', offsetY: 2 })
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
        bottom: 0
      })
      .backgroundColor('#F7F8FA')
      .border({ width: { top: 0.5 }, color: '#E5E7EB' })
      .alignItems(VerticalAlign.Center)

    }
    .width('100%').height('100%')
    .backgroundColor('#FFFFFF')
    .padding(12)
  }

  private async resetView() {
    // 重置视图参数（缩放 / 平移）
    this.zoom = 1.0
    this.offsetX = 0
    this.offsetY = 0

    // 没图片就啥也不干
    if (!this.pixelMap) {
      this.accumulatedRotate = 0
      return
    }

    // 本来就没旋转过，直接返回
    if (this.accumulatedRotate === 0) {
      return
    }

    // 正在旋转就先不抢，避免打架
    if (this.isRotating) {
      return
    }

    // 算出旋回去的角度
    const back = (360 - this.accumulatedRotate) % 360
    if (back === 0) {
      this.accumulatedRotate = 0
      return
    }

    try {
      this.isRotating = true
      await (this.pixelMap as image.PixelMap).rotate(back)
      this.pixelVersion++
      this.accumulatedRotate = 0
    } catch (err) {
      const e = err as ErrorWithCode
      console.error(`resetView rotateBack failed, code=${e?.code}, msg=${e?.message}`)
      promptAction.showToast({ message: '重置图片失败' })
    } finally {
      this.isRotating = false
    }
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
      if (this.pixelMap) {
        this.pixelMap.release?.()
      }
      this.pixelMap = pm
      this.resetView()

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
      // 判空
      if (!this.pixelMap) {
        promptAction.showToast({ message: '请先打开图片' })
        return
      }

      // 拿到上下文
      const context = getContext(this) as common.UIAbilityContext

      // 获取 PhotoAccessHelper
      const helper = photoAccessHelper.getPhotoAccessHelper(context)

      // 通过 createAsset 在系统相册中新建一个图片文件
      const uri: string = await helper.createAsset(
        photoAccessHelper.PhotoType.IMAGE,
        'jpg'
      )

      // 用 fileIo 打开这个 uri，拿到可写的 fd
      const file = await fileIo.open(
        uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      )

      // 用 ImagePacker 把 PixelMap 直接打包进这个文件
      const packer = image.createImagePacker()
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 90
      }

      // 把 PixelMap 的数据写入到打开的那个文件 fd 里
      await new Promise<void>((resolve, reject) => {
        packer.packToFile(
          this.pixelMap as image.PixelMap,
          file.fd,
          packOpts,
          (err: BusinessError) => {
            if (err) {
              reject(err)
            } else {
              resolve()
            }
          }
        )
      })

      // 释放资源
      packer.release?.()
      await fileIo.close(file)

      promptAction.showToast({ message: '已保存到相册 ' })
    } catch (err) {
      const e = err as BusinessError
      console.error(`saveImage failed, code=${e?.code}, msg=${e?.message}`)
      promptAction.showToast({ message: '保存失败' })
    }
  }

  // 裁剪
  private cropCenter() {
    // 什么都不做
  }

  // 向右旋转 90 度（顺时针）
  private async rotateRight90() {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }
    if (this.isRotating) {
      return
    }

    this.isRotating = true
    try {
      await (this.pixelMap as image.PixelMap).rotate(90)

      // 这里记录累计旋转
      this.accumulatedRotate = (this.accumulatedRotate + 90) % 360

      this.pixelVersion++
    } catch (err) {
      const e = err as ErrorWithCode
      console.error(`rotateRight90 failed, code=${e?.code}, msg=${e?.message}`)
      promptAction.showToast({ message: '右旋失败' })
    } finally {
      this.isRotating = false
    }
  }


  // 向左旋转 90 度（逆时针）
  private async rotateLeft90() {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }
    if (this.isRotating) {
      return
    }

    this.isRotating = true
    try {
      // 实际对 PixelMap 做顺时针 270°（等价于逆时针 90°）
      await (this.pixelMap as image.PixelMap).rotate(270)

      // 累计角度也加上 270°
      this.accumulatedRotate = (this.accumulatedRotate + 270) % 360

      this.pixelVersion++
    } catch (err) {
      const e = err as ErrorWithCode
      console.error(`rotateLeft90 failed, code=${e?.code}, msg=${e?.message}`)
      promptAction.showToast({ message: '左旋失败' })
    } finally {
      this.isRotating = false
    }
  }


  // 调整亮度
  private adjustBrightness(delta: number) {

  }



}
