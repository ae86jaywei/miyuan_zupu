import { Theme } from '../theme/Theme';

/** 详情页“标签：值”行 */
@Component
export struct InfoRow {
  @Prop label: string;
  @Prop value: string;
  @Prop valueColor: string = Theme.ink;
  @Prop labelWidth: number = 76;
  @Prop privacy: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(12.5)
        .fontColor(Theme.inkTertiary)
        .width(this.labelWidth)
        .flexShrink(0)
      if (this.privacy) {
        Text('私')
          .fontSize(9)
          .fontColor(Theme.danger)
          .backgroundColor('#FCEDEA')
          .borderRadius(4)
          .padding({ left: 3, right: 3, top: 1, bottom: 1 })
          .margin({ right: 4 })
      }
      Text(this.value)
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
