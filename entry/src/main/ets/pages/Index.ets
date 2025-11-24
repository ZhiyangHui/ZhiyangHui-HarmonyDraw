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
  @State brightnessLevel: number = 0.0 // -0.5 ~ 0.5 左右，0 是原图
  @State contrastLevel: number = 0.0   // -1.0 ~ 1.0（0 是原图对比度）

  // 手势内部状态
  private lastPanX: number = 0
  private lastPanY: number = 0
  private lastZoom: number = 1.0

  build() {
    Column() {
      // 顶部工具栏
      Column() {
        Column() {
          Scroll() {
            Row({ space: 8 }) {

              Button('对比度+', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .onClick(() => this.adjustContrast(0.1))

              Button('对比度-', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .onClick(() => this.adjustContrast(-0.1))

              Button('左旋90°', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .onClick(() => this.rotateLeft90())

              Button('右旋90°', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .onClick(() => this.rotateRight90())

              Button('变亮', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .onClick(() => this.adjustBrightness(0.05))

              Button('变暗', { type: ButtonType.Capsule })
                .height(32)
                .fontSize(12)
                .onClick(() => this.adjustBrightness(-0.05))
            }
            .height(38)
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 10 })
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

            // 图片渲染层（无手势，纯展示）
            Image(this.pixelMap)
              .id(`img-${this.pixelVersion}`)
              .objectFit(ImageFit.Contain)
              .width('100%')
              .height('100%')
              .scale({ x: this.zoom, y: this.zoom })
              .translate({ x: this.offsetX, y: this.offsetY })
              .colorFilter(this.buildToneMatrix())


            // 透明手势捕获层（只接收手势，不挡按钮）
            Stack()
              .width('100%')
              .height('100%')
              .backgroundColor(Color.Transparent)   // 全透明
              .hitTestBehavior(HitTestMode.Transparent)
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
                      if (next < MIN_ZOOM) {
                        next = MIN_ZOOM
                      }
                      if (next > MAX_ZOOM) {
                        next = MAX_ZOOM
                      }
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

    // 重置亮度到默认值
    if (this.brightnessLevel !== 0) {
      this.brightnessLevel = 0.0
    }

    // 重置对比度到默认值
    if (this.contrastLevel !== 0) {
      this.contrastLevel = 0.0
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

  // 亮度调整
  private async adjustBrightness(delta: number) {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

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
  private adjustContrast(delta: number) {
    if (!this.pixelMap) {
      promptAction.showToast({ message: '请先打开图片' })
      return
    }

    this.contrastLevel += delta

    const MAX_CONTRAST: number = 1.0   // 对比度增强上限
    const MIN_CONTRAST: number = -1.0  // 对比度降低下限

    if (this.contrastLevel > MAX_CONTRAST) {
      this.contrastLevel = MAX_CONTRAST
    }
    if (this.contrastLevel < MIN_CONTRAST) {
      this.contrastLevel = MIN_CONTRAST
    }
  }

}
