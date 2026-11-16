import { Theme, Spacing } from '../theme/Theme';
import { uiFontFamily } from '../service/ScriptService';

/** 空状态提示 */
@Component
export struct EmptyHint {
  @Prop icon: string = '📜';
  @Prop title: string = '暂无数据';
  @Prop desc: string = '';

  build() {
    Column() {
      Text(this.icon).fontFamily(uiFontFamily()).fontSize(40).opacity(0.6)
      Text(T(this.title)).fontFamily(uiFontFamily())
        .fontSize(15)
        .fontColor(Theme.inkSecondary)
        .margin({ top: Spacing.M })
      if (this.desc.length > 0) {
        Text(this.desc).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 6 })
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding(Spacing.XXL)
    .justifyContent(FlexAlign.Center)
  }
}
