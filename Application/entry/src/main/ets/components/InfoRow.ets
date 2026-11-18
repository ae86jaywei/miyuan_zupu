import { T, uiFontFamily } from 'common_base';
import { Theme } from 'common_base';

/** 详情页“标签：值”行 */
@Component
export struct InfoRow {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @Prop label: string;
  @Prop value: string;
  @Prop valueColor: string = Theme.ink;
  @Prop labelWidth: number = 76;
  @Prop privacy: boolean = false;

  build() {
    Row() {
      Text(T(this.label)).fontFamily(uiFontFamily())
        .fontSize(12.5)
        .fontColor(Theme.inkTertiary)
        .width(this.labelWidth)
        .flexShrink(0)
      if (this.privacy) {
        Text(T('私')).fontFamily(uiFontFamily())
          .fontSize(9)
          .fontColor(Theme.danger)
          .backgroundColor(Theme.dangerBg)
          .borderRadius(4)
          .padding({ left: 3, right: 3, top: 1, bottom: 1 })
          .margin({ right: 4 })
      }
      Text(T(this.value)).fontFamily(uiFontFamily())
        .fontSize(13.5)
        .fontColor(this.valueColor)
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6, bottom: 6 })
  }
}
