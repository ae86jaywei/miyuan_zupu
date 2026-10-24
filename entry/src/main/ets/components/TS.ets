import { Theme, Spacing } from '../theme/Theme';

/**
 * 卡片标题容器（TS = Title Section）。
 *
 * 说明：鸿蒙的“尾随闭包”语法要求被调用组件只有一个 @BuilderParam；
 * 若同时传自定义属性会被判定为非法语法。因此这里采用两段式写法：
 *
 *   TS({ title: '世代分布', subtitle: '各世人数与占比', icon: '📊' })
 *   Column() {
 *     ...内容...
 *   }
 *   .width('100%')
 *   .padding(Spacing.L)
 *   .backgroundColor(Theme.card)
 *   .borderRadius(16)
 */
@Component
export struct TS {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop icon: string = '';

  build() {
    Row() {
      if (this.icon.length > 0) {
        Text(this.icon).fontSize(15).margin({ right: Spacing.S })
      }
      if (this.title.length > 0) {
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
              .maxLines(2)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.M, bottom: Spacing.XS })
  }
}
