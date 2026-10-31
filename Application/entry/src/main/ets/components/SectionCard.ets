import { Theme, Spacing } from '../theme/Theme';

/**
 * 分区卡片标题（供需要“标题 + 内容卡片”组合的页面使用）。
 */
@Component
export struct CardHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop icon: string = '';

  build() {
    Row() {
      if (this.icon.length > 0) {
        Text(this.icon).fontSize(15).margin({ right: Spacing.S })
      }
      Column() {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.M, bottom: Spacing.M })
  }
}
