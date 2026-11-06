import { Theme, Spacing } from '../theme/Theme';
import { BackButton } from './BackButton';

/**
 * 二级页面统一顶栏（返回 / 标题 / 右侧操作文字 / 加载态）。
 */
@Component
export struct PageNavBar {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop actionText: string = '';
  @Prop busy: boolean = false;
  onBack: () => void = (): void => {};
  onAction: () => void = (): void => {};

  build() {
    Row() {
      BackButton({
        onBack: (): void => {
          this.onBack();
        }
      })
      Column() {
        Text(this.title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 1 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.busy) {
        LoadingProgress().width(20).height(20).color(Theme.primary)
      } else if (this.actionText.length > 0) {
        Text(this.actionText)
          .fontSize(12.5)
          .fontColor(Theme.primary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor(Theme.highlightBg)
          .onClick((): void => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .padding({ left: Spacing.S, right: Spacing.L, top: 4, bottom: 4 })
    .backgroundColor(Theme.card)
    .border({ width: { bottom: 0.5 }, color: Theme.line })
  }
}
