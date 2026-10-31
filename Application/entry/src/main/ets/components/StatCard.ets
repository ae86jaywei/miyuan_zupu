import { Theme, Radius, Spacing } from '../theme/Theme';

/** 统计数字卡 */
@Component
export struct StatCard {
  @Prop label: string;
  @Prop value: string;
  @Prop unit: string = '';
  @Prop accent: string = Theme.primary;
  @Prop icon: string = '';
  @Prop compact: boolean = false;

  build() {
    Column() {
      Row() {
        if (this.icon.length > 0) {
          Text(this.icon).fontSize(14).margin({ right: 4 })
        }
        Text(this.label)
          .fontSize(this.compact ? 11 : 12)
          .fontColor(Theme.inkTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Row() {
        Text(this.value)
          .fontSize(this.compact ? 20 : 26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accent)
        if (this.unit.length > 0) {
          Text(this.unit)
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .margin({ left: 2, bottom: 3 })
        }
      }
      .alignItems(VerticalAlign.Bottom)
      .width('100%')
      .margin({ top: 4 })
    }
    .padding(this.compact ? 10 : Spacing.M)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.M)
    .border({ width: 0.5, color: Theme.line })
    .alignItems(HorizontalAlign.Start)
  }
}
